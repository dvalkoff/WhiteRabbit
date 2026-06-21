import CryptoKit
import Foundation

/// The public key material to upload to the server (`POST /v1/keys`). Field
/// names match the server's JSON via the REST client.
public struct KeyUpload {
    public let registrationID: Int32
    public let identityKeyEd: Data
    public let identityKeyX: Data
    public let signedPreKeyID: Int32
    public let signedPreKey: Data
    public let signedPreKeySig: Data
    public let oneTimePreKeys: [(id: Int32, publicKey: Data)]
}

/// CryptoService is the single entry point for all E2E encryption. It owns the
/// local identity and prekeys and manages a Double Ratchet session per peer.
/// All cryptography is isolated here, behind a small surface, so the rest of the
/// app never touches keys directly.
public final class CryptoService {
    public let identity: IdentityKeyPair
    public let registrationID: Int32
    private var signedPreKey: SignedPreKey
    private var oneTimePreKeys: [Int32: OneTimePreKey]

    // Per-peer session plus the pending X3DH header to attach until we hear back.
    private final class Entry {
        var ratchet: RatchetSession
        var pendingPrekey: PrekeyHeaderWire?
        init(_ r: RatchetSession, pendingPrekey: PrekeyHeaderWire? = nil) {
            self.ratchet = r
            self.pendingPrekey = pendingPrekey
        }
    }
    private var sessions: [String: Entry] = [:]

    public init(identity: IdentityKeyPair, registrationID: Int32,
                signedPreKey: SignedPreKey, oneTimePreKeys: [OneTimePreKey]) {
        self.identity = identity
        self.registrationID = registrationID
        self.signedPreKey = signedPreKey
        self.oneTimePreKeys = Dictionary(uniqueKeysWithValues: oneTimePreKeys.map { ($0.id, $0) })
    }

    /// Generate a brand-new identity with a signed prekey and a batch of
    /// one-time prekeys (used at registration).
    public static func generate(oneTimeCount: Int = 100) -> CryptoService {
        let identity = IdentityKeyPair()
        let spk = SignedPreKey(id: 1, identity: identity)
        let otks = (1...oneTimeCount).map { OneTimePreKey(id: Int32($0)) }
        let regID = Int32.random(in: 1...0x3FFF)
        return CryptoService(identity: identity, registrationID: regID,
                             signedPreKey: spk, oneTimePreKeys: otks)
    }

    /// The current public bundle to upload to the server.
    public func keyUpload() -> KeyUpload {
        KeyUpload(
            registrationID: registrationID,
            identityKeyEd: identity.publicEd,
            identityKeyX: identity.publicX,
            signedPreKeyID: signedPreKey.id,
            signedPreKey: signedPreKey.publicKey,
            signedPreKeySig: signedPreKey.signature,
            oneTimePreKeys: oneTimePreKeys.values.sorted { $0.id < $1.id }.map { ($0.id, $0.publicKey) }
        )
    }

    public func hasSession(with peerID: String) -> Bool { sessions[peerID] != nil }

    // MARK: - Encrypt

    /// Encrypt `plaintext` for `peerID`. If no session exists yet, `bundle` must
    /// be supplied (fetched from the server) to bootstrap one via X3DH. Returns
    /// the opaque payload and whether it carries a prekey header.
    public func encrypt(_ plaintext: Data, to peerID: String, bundle: PreKeyBundle?) throws -> (payload: Data, isPrekey: Bool) {
        let entry: Entry
        if let existing = sessions[peerID] {
            entry = existing
        } else {
            guard let bundle else { throw CryptoError.missingSession }
            let (sk, header, peerSPK) = try X3DH.initiate(identity: identity, bundle: bundle)
            let ratchet = RatchetSession.initiator(sharedSecret: sk, peerSignedPreKey: peerSPK)
            entry = Entry(ratchet, pendingPrekey: PrekeyHeaderWire(header))
            sessions[peerID] = entry
        }

        let (header, body) = try entry.ratchet.encrypt(plaintext: plaintext)
        let msg = EncryptedMessage(prekey: entry.pendingPrekey, header: header, body: body)
        let isPrekey = entry.pendingPrekey != nil
        return (try msg.encoded(), isPrekey)
    }

    // MARK: - Decrypt

    /// Forget the session with a peer so the next outbound message performs a
    /// fresh X3DH handshake. Used to self-heal after an unrecoverable decrypt
    /// (e.g. the peer re-logged-in with new keys and we have stale state).
    public func resetSession(with peerID: String) {
        sessions[peerID] = nil
    }

    /// Decrypt an opaque payload received from `peerID`.
    ///
    /// Two layers of robustness:
    ///  1. Each attempt runs on a throwaway *clone* of the session and only
    ///     commits (advanced ratchet, consumed prekey, stored session) on
    ///     success — so a bad message never poisons the session or burns a prekey.
    ///  2. A prekey (X3DH handshake) message can (re)establish a session even
    ///     when one already exists. If the current session can't decrypt it, we
    ///     treat it as the start of a *new* session and replace the stale one.
    ///     This is what lets a conversation recover after a peer re-logs-in with
    ///     fresh keys.
    public func decrypt(_ payload: Data, from peerID: String) throws -> Data {
        let msg = try EncryptedMessage.decode(payload)

        // 1. Try the existing session (on a clone; commit only on success).
        if let existing = sessions[peerID],
           let working = try? existing.ratchet.clone(),
           let plaintext = try? working.decrypt(header: msg.header, ciphertext: msg.body) {
            existing.ratchet = working
            existing.pendingPrekey = nil // we've heard from the peer
            return plaintext
        }

        // 2. If this is a handshake message, (re)establish a fresh session,
        //    discarding any stale one.
        if let pk = msg.prekey {
            let h = pk.model
            var usedOTK: OneTimePreKey?
            if h.usedOneTimePreKey {
                usedOTK = oneTimePreKeys[h.oneTimePreKeyID]
                guard usedOTK != nil else { throw CryptoError.invalidKey }
            }
            let sk = try X3DH.respond(identity: identity, signedPreKey: signedPreKey,
                                      oneTimePreKey: usedOTK, header: h)
            let working = RatchetSession.responder(sharedSecret: sk, signedPreKey: signedPreKey)
            // Nothing committed until this succeeds.
            let plaintext = try working.decrypt(header: msg.header, ciphertext: msg.body)
            if h.usedOneTimePreKey { oneTimePreKeys[h.oneTimePreKeyID] = nil }
            sessions[peerID] = Entry(working) // replace any stale session
            return plaintext
        }

        // 3. Non-handshake message we can't read (e.g. peer re-keyed). Drop the
        //    stale session so our next send re-initiates a fresh handshake.
        sessions[peerID] = nil
        throw CryptoError.missingSession
    }
}
