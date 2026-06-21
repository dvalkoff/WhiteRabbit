import CryptoKit
import Foundation

/// X3DH (Extended Triple Diffie-Hellman) initial key agreement. Produces the
/// shared secret `SK` that seeds the Double Ratchet, allowing a session to start
/// even when the recipient is offline (their prekeys live on the server).
enum X3DH {

    /// The header an initiator includes with the first message so the responder
    /// can reconstruct the same shared secret.
    struct InitiatorHeader: Sendable {
        let identityKeyEd: Data      // initiator Ed25519 public (associated data)
        let identityKeyX: Data       // initiator X25519 public (IK_A)
        let ephemeralKey: Data       // initiator ephemeral X25519 public (EK_A)
        let signedPreKeyID: Int32    // which of the responder's signed prekeys was used
        let oneTimePreKeyID: Int32   // which one-time prekey was used (-1 if none)
        let usedOneTimePreKey: Bool
    }

    /// Run X3DH as the initiator against a fetched bundle. Returns the shared
    /// secret and the header to attach to the first message.
    static func initiate(identity: IdentityKeyPair, bundle: PreKeyBundle)
        throws -> (sharedSecret: Data, header: InitiatorHeader, responderSignedPreKey: Data) {
        guard bundle.verify() else { throw CryptoError.invalidBundle }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        // DH1 = DH(IK_A, SPK_B)
        let dh1 = try Primitives.dh(identity.agreement, bundle.signedPreKey)
        // DH2 = DH(EK_A, IK_B)
        let dh2 = try Primitives.dh(ephemeral, bundle.identityKeyX)
        // DH3 = DH(EK_A, SPK_B)
        let dh3 = try Primitives.dh(ephemeral, bundle.signedPreKey)

        var ikm = dh1 + dh2 + dh3
        if bundle.hasOneTimePreKey {
            // DH4 = DH(EK_A, OPK_B)
            ikm += try Primitives.dh(ephemeral, bundle.oneTimePreKey)
        }

        let sk = deriveSK(ikm)
        let header = InitiatorHeader(
            identityKeyEd: identity.publicEd,
            identityKeyX: identity.publicX,
            ephemeralKey: ephemeral.publicKey.rawRepresentation,
            signedPreKeyID: bundle.signedPreKeyID,
            oneTimePreKeyID: bundle.hasOneTimePreKey ? bundle.oneTimePreKeyID : -1,
            usedOneTimePreKey: bundle.hasOneTimePreKey
        )
        return (sk, header, bundle.signedPreKey)
    }

    /// Run X3DH as the responder, using the local private keys identified in the
    /// initiator's header. `oneTimePreKey` must be supplied iff the initiator
    /// used one.
    static func respond(identity: IdentityKeyPair,
                        signedPreKey: SignedPreKey,
                        oneTimePreKey: OneTimePreKey?,
                        header: InitiatorHeader) throws -> Data {
        // DH1 = DH(SPK_B, IK_A)
        let dh1 = try Primitives.dh(signedPreKey.key, header.identityKeyX)
        // DH2 = DH(IK_B, EK_A)
        let dh2 = try Primitives.dh(identity.agreement, header.ephemeralKey)
        // DH3 = DH(SPK_B, EK_A)
        let dh3 = try Primitives.dh(signedPreKey.key, header.ephemeralKey)

        var ikm = dh1 + dh2 + dh3
        if header.usedOneTimePreKey {
            guard let otk = oneTimePreKey else { throw CryptoError.invalidKey }
            // DH4 = DH(OPK_B, EK_A)
            ikm += try Primitives.dh(otk.key, header.ephemeralKey)
        }
        return deriveSK(ikm)
    }

    /// HKDF over the concatenated DH outputs, prefixed with the curve25519 `F`
    /// constant per the X3DH spec.
    private static func deriveSK(_ ikm: Data) -> Data {
        let f = Data(repeating: 0xFF, count: 32)
        return Primitives.hkdf(ikm: f + ikm,
                               salt: Data(repeating: 0, count: 32),
                               info: "WhiteRabbitX3DH",
                               count: 32)
    }
}
