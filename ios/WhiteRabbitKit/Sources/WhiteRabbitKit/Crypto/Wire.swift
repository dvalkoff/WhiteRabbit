import Foundation

/// The X3DH initiator header carried inside the first message(s) of a session.
struct PrekeyHeaderWire: Codable, Sendable {
    var identityKeyEd: Data
    var identityKeyX: Data
    var ephemeralKey: Data
    var signedPreKeyID: Int32
    var oneTimePreKeyID: Int32
    var usedOneTimePreKey: Bool

    init(_ h: X3DH.InitiatorHeader) {
        identityKeyEd = h.identityKeyEd
        identityKeyX = h.identityKeyX
        ephemeralKey = h.ephemeralKey
        signedPreKeyID = h.signedPreKeyID
        oneTimePreKeyID = h.oneTimePreKeyID
        usedOneTimePreKey = h.usedOneTimePreKey
    }

    var model: X3DH.InitiatorHeader {
        X3DH.InitiatorHeader(
            identityKeyEd: identityKeyEd,
            identityKeyX: identityKeyX,
            ephemeralKey: ephemeralKey,
            signedPreKeyID: signedPreKeyID,
            oneTimePreKeyID: oneTimePreKeyID,
            usedOneTimePreKey: usedOneTimePreKey
        )
    }
}

/// The complete opaque payload that travels as `SendMessage.ciphertext`. The
/// server stores/relays this as bytes and cannot read any of it.
struct EncryptedMessage: Codable, Sendable {
    var prekey: PrekeyHeaderWire?   // present only while bootstrapping a session
    var header: RatchetHeader
    var body: Data

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> EncryptedMessage {
        try JSONDecoder().decode(EncryptedMessage.self, from: data)
    }
}
