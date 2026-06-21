import Foundation

/// Metadata describing one encrypted attachment. Travels *inside* the E2E
/// plaintext, so the server never learns the symmetric key, filename or mime —
/// it only ever stores the opaque ciphertext blob under `key`.
struct Attachment: Codable, Equatable, Identifiable {
    var key: String        // object-storage key for the ciphertext blob
    var keyB64: String     // base64 symmetric key to decrypt the blob
    var mime: String
    var name: String
    var size: Int
    var width: Int?
    var height: Int?

    var id: String { key }
    var isImage: Bool { mime.hasPrefix("image/") }
    var isVideo: Bool { mime.hasPrefix("video/") }
    var isMedia: Bool { isImage || isVideo }
}

/// The structured plaintext of a message: optional text plus 0..N attachments.
/// A batch of media/files picked together is a single message (one album), not
/// many. Encrypted as JSON and handed to the Double Ratchet.
struct MessageContent: Codable {
    var text: String?
    var attachments: [Attachment] = []

    static func text(_ s: String) -> MessageContent { MessageContent(text: s, attachments: []) }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> MessageContent {
        if let c = try? JSONDecoder().decode(MessageContent.self, from: data) { return c }
        return .text(String(data: data, encoding: .utf8) ?? "")
    }

    /// Short preview for the chat feed.
    var preview: String {
        if !attachments.isEmpty {
            let label: String
            if attachments.allSatisfy({ $0.isImage }) { label = attachments.count > 1 ? "📷 \(attachments.count) Photos" : "📷 Photo" }
            else if attachments.allSatisfy({ $0.isVideo }) { label = attachments.count > 1 ? "🎬 \(attachments.count) Videos" : "🎬 Video" }
            else if attachments.allSatisfy({ $0.isMedia }) { label = "🖼 \(attachments.count) Media" }
            else if attachments.count > 1 { label = "📎 \(attachments.count) Files" }
            else { label = "📎 " + (attachments.first?.name ?? "File") }
            if let t = text, !t.isEmpty { return label + " · " + t }
            return label
        }
        return text ?? ""
    }
}
