import Foundation
import WhiteRabbitKit

enum APIError: Error, LocalizedError {
    case http(Int, String)
    case decoding
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .http(_, let msg): return msg
        case .decoding: return "Unexpected server response"
        case .transport(let e): return e.localizedDescription
        }
    }
}

/// REST client for auth, prekey distribution, and search. Holds the base URL and
/// the current access token.
final class APIClient {
    let baseURL: URL
    var accessToken: String?

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.session = URLSession(configuration: .default)
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // MARK: - Auth

    func register(nickname: String, password: String) async throws -> AuthResponse {
        try await post("/v1/register", body: Credentials(nickname: nickname, password: password), authed: false)
    }

    func login(nickname: String, password: String) async throws -> AuthResponse {
        try await post("/v1/login", body: Credentials(nickname: nickname, password: password), authed: false)
    }

    // MARK: - Keys

    func uploadKeys(_ upload: KeyUpload) async throws {
        let req = UploadKeysRequest(
            registrationId: upload.registrationID,
            identityKeyEd: upload.identityKeyEd,
            identityKeyX: upload.identityKeyX,
            signedPrekeyId: upload.signedPreKeyID,
            signedPrekey: upload.signedPreKey,
            signedPrekeySig: upload.signedPreKeySig,
            oneTimePrekeys: upload.oneTimePreKeys.map { OneTimePreKeyDTO(keyId: $0.id, publicKey: $0.publicKey) }
        )
        let _: EmptyResponse = try await post("/v1/keys", body: req, authed: true, allowEmpty: true)
    }

    func fetchBundle(userID: String) async throws -> PreKeyBundle {
        let resp: BundleResponse = try await get("/v1/keys/\(userID)")
        return resp.model
    }

    // MARK: - Users

    func searchUsers(_ query: String) async throws -> [UserView] {
        try await get("/v1/users/search", query: [URLQueryItem(name: "q", value: query)])
    }

    func me() async throws -> UserView { try await get("/v1/me") }

    func getUser(_ userID: String) async throws -> UserView { try await get("/v1/users/\(userID)") }

    // MARK: - Profile

    struct UpdateMeRequest: Encodable { var nickname: String?; var photoUrl: String? }

    func updateMe(nickname: String? = nil, photoURL: String? = nil) async throws -> UserView {
        try await patch("/v1/me", body: UpdateMeRequest(nickname: nickname, photoUrl: photoURL))
    }

    struct ChangePasswordRequest: Encodable { let oldPassword: String; let newPassword: String }

    func changePassword(old: String, new: String) async throws {
        let _: EmptyResponse = try await post("/v1/me/password",
            body: ChangePasswordRequest(oldPassword: old, newPassword: new), authed: true, allowEmpty: true)
    }

    // MARK: - Groups

    struct CreateGroupRequest: Encodable { let name: String; let memberIds: [String] }
    struct AddMemberRequest: Encodable { let userId: String }

    func createGroup(name: String, memberIDs: [String]) async throws -> GroupView {
        try await post("/v1/groups", body: CreateGroupRequest(name: name, memberIds: memberIDs), authed: true)
    }

    func listGroups() async throws -> [GroupView] { try await get("/v1/groups") }

    func getGroup(_ id: String) async throws -> GroupView { try await get("/v1/groups/\(id)") }

    func addGroupMember(groupID: String, userID: String) async throws -> GroupView {
        try await post("/v1/groups/\(groupID)/members", body: AddMemberRequest(userId: userID), authed: true)
    }

    func removeGroupMember(groupID: String, userID: String) async throws -> GroupView {
        try await delete("/v1/groups/\(groupID)/members/\(userID)")
    }

    // MARK: - Files

    private struct UploadURLResponse: Decodable { let key: String; let url: URL }
    private struct DownloadURLResponse: Decodable { let url: URL }

    func uploadURL() async throws -> (key: String, url: URL) {
        let r: UploadURLResponse = try await postEmpty("/v1/files/upload-url")
        return (r.key, r.url)
    }

    func downloadURL(key: String) async throws -> URL {
        let r: DownloadURLResponse = try await get("/v1/files/download-url",
                                                   query: [URLQueryItem(name: "key", value: key)])
        return r.url
    }

    // MARK: - TURN

    struct ICEServer: Decodable { let urls: [String]; let username: String?; let credential: String? }
    private struct TurnResponse: Decodable { let iceServers: [ICEServer] }

    func turnServers() async throws -> [ICEServer] {
        let r: TurnResponse = try await get("/v1/turn")
        return r.iceServers
    }

    // MARK: - Plumbing

    private struct EmptyResponse: Codable {}

    private func get<R: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> R {
        var req = URLRequest(url: makeURL(path, query: query))
        req.httpMethod = "GET"
        applyAuth(&req)
        return try await send(req)
    }

    /// Builds a URL from a path and optional query items. Using URLComponents
    /// avoids appendingPathComponent percent-encoding the "?" of a query string.
    private func makeURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    private func patch<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        var req = URLRequest(url: makeURL(path))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        applyAuth(&req)
        return try await send(req)
    }

    private func delete<R: Decodable>(_ path: String) async throws -> R {
        var req = URLRequest(url: makeURL(path))
        req.httpMethod = "DELETE"
        applyAuth(&req)
        return try await send(req)
    }

    private func postEmpty<R: Decodable>(_ path: String) async throws -> R {
        var req = URLRequest(url: makeURL(path))
        req.httpMethod = "POST"
        applyAuth(&req)
        return try await send(req)
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, body: B, authed: Bool, allowEmpty: Bool = false) async throws -> R {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        if authed { applyAuth(&req) }
        return try await send(req, allowEmpty: allowEmpty)
    }

    private func applyAuth(_ req: inout URLRequest) {
        if let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func send<R: Decodable>(_ req: URLRequest, allowEmpty: Bool = false) async throws -> R {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? decoder.decode([String: String].self, from: data))?["error"] ?? "HTTP \(http.statusCode)"
            throw APIError.http(http.statusCode, msg)
        }
        if allowEmpty, data.isEmpty, let empty = EmptyResponse() as? R { return empty }
        do {
            return try decoder.decode(R.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }
}
