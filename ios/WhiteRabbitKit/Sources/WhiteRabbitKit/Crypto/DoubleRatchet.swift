import CryptoKit
import Foundation

/// Header sent with every ratchet message: the sender's current ratchet public
/// key, the length of the previous sending chain (PN), and the message number
/// within the current chain (N).
public struct RatchetHeader: Codable, Sendable, Equatable {
    public let dhPub: Data
    public let pn: UInt32
    public let n: UInt32

    /// Deterministic byte encoding used as part of the AEAD associated data so a
    /// header cannot be tampered with independently of its ciphertext.
    func aadBytes() -> Data {
        var d = Data()
        d.append(dhPub)
        var pnLE = pn.littleEndian
        var nLE = n.littleEndian
        withUnsafeBytes(of: &pnLE) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &nLE) { d.append(contentsOf: $0) }
        return d
    }
}

private struct SkippedKey: Codable {
    let dhPub: Data
    let n: UInt32
    let mk: Data
}

/// A Double Ratchet session with one peer. Codable so it can be persisted
/// (Keychain/GRDB) between launches. Implements the algorithm from the Signal
/// Double Ratchet specification, including out-of-order and skipped messages.
public final class RatchetSession: Codable {
    private static let maxSkip: UInt32 = 1000

    private var dhsPriv: Data
    private var dhsPub: Data
    private var dhrPub: Data?
    private var rk: Data
    private var cks: Data?
    private var ckr: Data?
    private var ns: UInt32 = 0
    private var nr: UInt32 = 0
    private var pn: UInt32 = 0
    private var skipped: [SkippedKey] = []

    private init(dhsPriv: Data, dhsPub: Data, dhrPub: Data?, rk: Data, cks: Data?, ckr: Data?) {
        self.dhsPriv = dhsPriv
        self.dhsPub = dhsPub
        self.dhrPub = dhrPub
        self.rk = rk
        self.cks = cks
        self.ckr = ckr
    }

    /// Deep-copy the session via its Codable representation. Used to attempt a
    /// decrypt on a throwaway copy so a failed decryption never mutates (and thus
    /// never corrupts) the live session.
    func clone() throws -> RatchetSession {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(RatchetSession.self, from: data)
    }

    /// Initialize as the X3DH initiator ("Alice"). `peerSignedPreKey` is the
    /// responder's signed prekey public, which seeds the first DH ratchet.
    public static func initiator(sharedSecret: Data, peerSignedPreKey: Data) -> RatchetSession {
        let dhs = Curve25519.KeyAgreement.PrivateKey()
        let dhOut = try! Primitives.dh(dhs, peerSignedPreKey)
        let (rk, cks) = Primitives.kdfRootKey(rootKey: sharedSecret, dhOut: dhOut)
        return RatchetSession(
            dhsPriv: dhs.rawRepresentation,
            dhsPub: dhs.publicKey.rawRepresentation,
            dhrPub: peerSignedPreKey,
            rk: rk, cks: cks, ckr: nil
        )
    }

    /// Initialize as the X3DH responder ("Bob"). `signedPreKey` is the local
    /// signed prekey the initiator used; it becomes our initial ratchet key.
    public static func responder(sharedSecret: Data, signedPreKey: SignedPreKey) -> RatchetSession {
        return RatchetSession(
            dhsPriv: signedPreKey.key.rawRepresentation,
            dhsPub: signedPreKey.key.publicKey.rawRepresentation,
            dhrPub: nil,
            rk: sharedSecret, cks: nil, ckr: nil
        )
    }

    // MARK: - Encrypt

    public func encrypt(plaintext: Data, externalAAD: Data = Data()) throws -> (header: RatchetHeader, ciphertext: Data) {
        guard let cks else { throw CryptoError.missingSession }
        let (nextCK, mk) = Primitives.kdfChainKey(chainKey: cks)
        self.cks = nextCK
        let header = RatchetHeader(dhPub: dhsPub, pn: pn, n: ns)
        ns += 1
        let ct = try Primitives.seal(plaintext: plaintext, messageKey: mk,
                                     aad: externalAAD + header.aadBytes())
        return (header, ct)
    }

    // MARK: - Decrypt

    public func decrypt(header: RatchetHeader, ciphertext: Data, externalAAD: Data = Data()) throws -> Data {
        if let pt = try tryskipped(header: header, ciphertext: ciphertext, externalAAD: externalAAD) {
            return pt
        }
        if dhrPub == nil || header.dhPub != dhrPub! {
            try skipMessageKeys(until: header.pn)
            try dhRatchet(header: header)
        }
        try skipMessageKeys(until: header.n)
        guard let ckr else { throw CryptoError.missingSession }
        let (nextCK, mk) = Primitives.kdfChainKey(chainKey: ckr)
        self.ckr = nextCK
        nr += 1
        return try Primitives.open(ciphertext: ciphertext, messageKey: mk,
                                   aad: externalAAD + header.aadBytes())
    }

    private func tryskipped(header: RatchetHeader, ciphertext: Data, externalAAD: Data) throws -> Data? {
        guard let idx = skipped.firstIndex(where: { $0.dhPub == header.dhPub && $0.n == header.n }) else {
            return nil
        }
        let entry = skipped[idx]
        let pt = try Primitives.open(ciphertext: ciphertext, messageKey: entry.mk,
                                     aad: externalAAD + header.aadBytes())
        skipped.remove(at: idx)
        return pt
    }

    private func skipMessageKeys(until: UInt32) throws {
        if nr + Self.maxSkip < until { throw CryptoError.malformedMessage }
        guard ckr != nil else { return }
        while nr < until {
            let (nextCK, mk) = Primitives.kdfChainKey(chainKey: ckr!)
            ckr = nextCK
            skipped.append(SkippedKey(dhPub: dhrPub!, n: nr, mk: mk))
            nr += 1
        }
    }

    private func dhRatchet(header: RatchetHeader) throws {
        pn = ns
        ns = 0
        nr = 0
        dhrPub = header.dhPub

        let dhsPrivKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhsPriv)
        let (rk1, ckr1) = Primitives.kdfRootKey(rootKey: rk, dhOut: try Primitives.dh(dhsPrivKey, dhrPub!))
        rk = rk1
        ckr = ckr1

        let newDHs = Curve25519.KeyAgreement.PrivateKey()
        dhsPriv = newDHs.rawRepresentation
        dhsPub = newDHs.publicKey.rawRepresentation
        let (rk2, cks1) = Primitives.kdfRootKey(rootKey: rk, dhOut: try Primitives.dh(newDHs, dhrPub!))
        rk = rk2
        cks = cks1
    }
}
