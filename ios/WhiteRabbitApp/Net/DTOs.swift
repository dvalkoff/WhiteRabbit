import Foundation
import WhiteRabbitKit

// REST DTOs. The server marshals Go []byte as standard base64, which matches
// JSONDecoder/Encoder's default Data strategy. We use snake_case conversion.

struct AuthResponse: Codable {
    let userId: String
    let nickname: String
    let accessToken: String
    let refreshToken: String
}

struct Credentials: Codable {
    let nickname: String
    let password: String
}

struct RefreshRequest: Codable {
    let refreshToken: String
}

struct UserView: Codable, Identifiable, Hashable {
    let id: String
    let nickname: String
    var photoUrl: String?
}

struct OneTimePreKeyDTO: Codable {
    let keyId: Int32
    let publicKey: Data
}

struct UploadKeysRequest: Codable {
    let registrationId: Int32
    let identityKeyEd: Data
    let identityKeyX: Data
    let signedPrekeyId: Int32
    let signedPrekey: Data
    let signedPrekeySig: Data
    let oneTimePrekeys: [OneTimePreKeyDTO]
}

struct BundleResponse: Codable {
    let userId: String
    let registrationId: Int32
    let identityKeyEd: Data
    let identityKeyX: Data
    let signedPrekeyId: Int32
    let signedPrekey: Data
    let signedPrekeySig: Data
    let hasOneTimePrekey: Bool
    let oneTimePrekeyId: Int32
    let oneTimePrekey: Data

    var model: PreKeyBundle {
        PreKeyBundle(
            registrationID: registrationId,
            identityKeyEd: identityKeyEd,
            identityKeyX: identityKeyX,
            signedPreKeyID: signedPrekeyId,
            signedPreKey: signedPrekey,
            signedPreKeySig: signedPrekeySig,
            hasOneTimePreKey: hasOneTimePrekey,
            oneTimePreKeyID: oneTimePrekeyId,
            oneTimePreKey: oneTimePrekey
        )
    }
}
