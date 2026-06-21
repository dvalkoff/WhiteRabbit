import CryptoKit
import Foundation

/// Low-level building blocks shared by X3DH and the Double Ratchet. All are thin
/// wrappers over CryptoKit primitives — we never implement curve math or AEAD
/// ourselves, only the well-specified protocol that composes them.
enum Primitives {

    /// X25519 Diffie-Hellman returning the raw 32-byte shared secret.
    static func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pubRaw: Data) throws -> Data {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubRaw)
        let ss = try priv.sharedSecretFromKeyAgreement(with: pub)
        return ss.withUnsafeBytes { Data($0) }
    }

    /// HKDF-SHA256 producing `count` bytes.
    static func hkdf(ikm: Data, salt: Data, info: String, count: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: count
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// HMAC-SHA256.
    static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// Root-key KDF: from the current root key and a fresh DH output, derive a
    /// new root key and a chain key.
    static func kdfRootKey(rootKey: Data, dhOut: Data) -> (rootKey: Data, chainKey: Data) {
        let out = hkdf(ikm: dhOut, salt: rootKey, info: "WhiteRabbitRootKey", count: 64)
        return (Data(out[0..<32]), Data(out[32..<64]))
    }

    /// Chain-key KDF: ratchet the symmetric chain forward, producing the next
    /// chain key and the message key for this step.
    static func kdfChainKey(chainKey: Data) -> (chainKey: Data, messageKey: Data) {
        let messageKey = hmac(key: chainKey, data: Data([0x01]))
        let nextChain = hmac(key: chainKey, data: Data([0x02]))
        return (nextChain, messageKey)
    }

    /// Derive a ChaChaPoly key + nonce from a message key.
    static func messageKeyMaterial(_ messageKey: Data) -> (key: SymmetricKey, nonce: ChaChaPoly.Nonce) {
        let material = hkdf(ikm: messageKey, salt: Data(repeating: 0, count: 32),
                            info: "WhiteRabbitMessageKey", count: 44)
        let key = SymmetricKey(data: material[0..<32])
        let nonce = try! ChaChaPoly.Nonce(data: material[32..<44])
        return (key, nonce)
    }

    /// AEAD seal. `aad` binds the ciphertext to the message header.
    static func seal(plaintext: Data, messageKey: Data, aad: Data) throws -> Data {
        let (key, nonce) = messageKeyMaterial(messageKey)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        // ciphertext + tag (nonce is deterministic from the message key).
        return box.ciphertext + box.tag
    }

    /// AEAD open.
    static func open(ciphertext: Data, messageKey: Data, aad: Data) throws -> Data {
        let (key, nonce) = messageKeyMaterial(messageKey)
        guard ciphertext.count >= 16 else { throw CryptoError.malformedMessage }
        let ct = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        do {
            return try ChaChaPoly.open(box, using: key, authenticating: aad)
        } catch {
            throw CryptoError.decryptionFailed
        }
    }
}
