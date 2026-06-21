import CryptoKit
import Foundation

/// The long-term identity of a local user. We use two separate Curve25519 keys:
/// an Ed25519 key for *signing* (e.g. signing the signed prekey) and an X25519
/// key for *Diffie-Hellman* in X3DH. (Signal folds these into one key via
/// XEdDSA; keeping them separate is simpler with CryptoKit and equally secure.)
public struct IdentityKeyPair {
    public let signing: Curve25519.Signing.PrivateKey
    public let agreement: Curve25519.KeyAgreement.PrivateKey

    public init() {
        self.signing = Curve25519.Signing.PrivateKey()
        self.agreement = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(signing: Curve25519.Signing.PrivateKey,
                agreement: Curve25519.KeyAgreement.PrivateKey) {
        self.signing = signing
        self.agreement = agreement
    }

    public var publicEd: Data { signing.publicKey.rawRepresentation }
    public var publicX: Data { agreement.publicKey.rawRepresentation }
}

/// A signed prekey: a medium-term X25519 key whose public part is signed by the
/// identity's Ed25519 key so peers can verify it belongs to the user.
public struct SignedPreKey {
    public let id: Int32
    public let key: Curve25519.KeyAgreement.PrivateKey
    public let signature: Data

    public init(id: Int32, identity: IdentityKeyPair) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        self.id = id
        self.key = key
        // Sign the public DH key with the identity signing key.
        self.signature = try! identity.signing.signature(for: key.publicKey.rawRepresentation)
    }

    public init(id: Int32, key: Curve25519.KeyAgreement.PrivateKey, signature: Data) {
        self.id = id
        self.key = key
        self.signature = signature
    }

    public var publicKey: Data { key.publicKey.rawRepresentation }
}

/// A one-time prekey: a single-use X25519 key.
public struct OneTimePreKey {
    public let id: Int32
    public let key: Curve25519.KeyAgreement.PrivateKey

    public init(id: Int32) {
        self.id = id
        self.key = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(id: Int32, key: Curve25519.KeyAgreement.PrivateKey) {
        self.id = id
        self.key = key
    }

    public var publicKey: Data { key.publicKey.rawRepresentation }
}

/// The public bundle a peer fetches to start a session (mirrors the server's
/// `bundleResponse`).
public struct PreKeyBundle: Sendable {
    public let registrationID: Int32
    public let identityKeyEd: Data
    public let identityKeyX: Data
    public let signedPreKeyID: Int32
    public let signedPreKey: Data
    public let signedPreKeySig: Data
    public let hasOneTimePreKey: Bool
    public let oneTimePreKeyID: Int32
    public let oneTimePreKey: Data

    public init(registrationID: Int32, identityKeyEd: Data, identityKeyX: Data,
                signedPreKeyID: Int32, signedPreKey: Data, signedPreKeySig: Data,
                hasOneTimePreKey: Bool, oneTimePreKeyID: Int32, oneTimePreKey: Data) {
        self.registrationID = registrationID
        self.identityKeyEd = identityKeyEd
        self.identityKeyX = identityKeyX
        self.signedPreKeyID = signedPreKeyID
        self.signedPreKey = signedPreKey
        self.signedPreKeySig = signedPreKeySig
        self.hasOneTimePreKey = hasOneTimePreKey
        self.oneTimePreKeyID = oneTimePreKeyID
        self.oneTimePreKey = oneTimePreKey
    }

    /// Verifies the signed prekey signature against the identity Ed25519 key.
    public func verify() -> Bool {
        guard let edKey = try? Curve25519.Signing.PublicKey(rawRepresentation: identityKeyEd) else {
            return false
        }
        return edKey.isValidSignature(signedPreKeySig, for: signedPreKey)
    }
}

enum CryptoError: Error {
    case invalidBundle
    case invalidKey
    case decryptionFailed
    case missingSession
    case malformedMessage
}
