import CryptoKit
import Foundation

/// Encrypts attachment blobs client-side and moves the ciphertext to/from object
/// storage via presigned URLs. The blob is sealed with a fresh random symmetric
/// key (ChaChaPoly); that key travels only inside the E2E message, never to the
/// server. The server and object store therefore only ever see ciphertext.
final class FileService {
    private let api: APIClient
    private let session = URLSession(configuration: .default)

    init(api: APIClient) { self.api = api }

    /// Encrypt `data`, upload the ciphertext, and return the attachment metadata
    /// to embed in the E2E message.
    func encryptAndUpload(_ data: Data, mime: String, name: String,
                          width: Int? = nil, height: Int? = nil,
                          durationMs: Int? = nil, waveform: [Int]? = nil,
                          round: Bool? = nil) async throws -> Attachment {
        let key = SymmetricKey(size: .bits256)
        let sealed = try ChaChaPoly.seal(data, using: key)
        let blob = sealed.combined // nonce + ciphertext + tag

        let (objectKey, putURL) = try await api.uploadURL()
        var req = URLRequest(url: putURL)
        req.httpMethod = "PUT"
        let (_, resp) = try await session.upload(for: req, from: blob)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "blob upload failed")
        }

        let keyB64 = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        return Attachment(key: objectKey, keyB64: keyB64, mime: mime, name: name,
                          size: data.count, width: width, height: height,
                          durationMs: durationMs, waveform: waveform, round: round)
    }

    /// Upload bytes WITHOUT encryption (used for profile avatars, which need to be
    /// viewable by anyone who can see the user). Returns the object key.
    func uploadPlain(_ data: Data, mime: String) async throws -> String {
        let (objectKey, putURL) = try await api.uploadURL()
        var req = URLRequest(url: putURL)
        req.httpMethod = "PUT"
        let (_, resp) = try await session.upload(for: req, from: data)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "avatar upload failed")
        }
        return objectKey
    }

    /// Download the ciphertext for an attachment and decrypt it.
    func downloadAndDecrypt(_ attachment: Attachment) async throws -> Data {
        let getURL = try await api.downloadURL(key: attachment.key)
        let (blob, resp) = try await session.data(from: getURL)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "blob download failed")
        }
        guard let keyData = Data(base64Encoded: attachment.keyB64) else {
            throw APIError.decoding
        }
        let box = try ChaChaPoly.SealedBox(combined: blob)
        return try ChaChaPoly.open(box, using: SymmetricKey(data: keyData))
    }
}
