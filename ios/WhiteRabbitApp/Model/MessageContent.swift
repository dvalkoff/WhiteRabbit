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
    var durationMs: Int?   // voice/video note length
    var waveform: [Int]?   // 0–100 amplitude bars for voice messages
    var round: Bool?       // true for circular video notes

    var id: String { key }
    var isImage: Bool { mime.hasPrefix("image/") }
    var isAudio: Bool { mime.hasPrefix("audio/") }
    var isVideo: Bool { mime.hasPrefix("video/") }
    var isVoice: Bool { isAudio }
    var isVideoNote: Bool { isVideo && round == true }
    /// "Media" = shown in the swipeable gallery. Voice and video notes are not.
    var isMedia: Bool { (isImage || isVideo) && round != true }
}

/// A quoted reference to another message, carried with a reply.
struct ReplyPreview: Codable, Equatable {
    var messageID: String
    var sender: String   // display name of the quoted message's author
    var text: String     // short preview of the quoted message
}

/// The structured plaintext of a message: optional text plus 0..N attachments.
/// A batch of media/files picked together is a single message (one album), not
/// many. Encrypted as JSON and handed to the Double Ratchet.
struct MessageContent: Codable {
    var text: String?
    var attachments: [Attachment] = []
    /// Set when this message belongs to a group; nil for a 1:1 message. The
    /// message is fanned out per-recipient, and each copy carries this id so the
    /// receiver files it under the group conversation.
    var groupID: String?

    // Control / metadata (all E2E — the server never interprets these).
    var editOf: String?          // server id of a message whose text this replaces
    var deleteOf: String?        // server id of a message to delete for everyone
    var replyTo: ReplyPreview?   // quoted message this is a reply to
    var forwarded: Bool = false  // marks a forwarded message

    /// True for edit/delete control messages (applied to an existing message,
    /// not rendered as a new bubble).
    var isControl: Bool { editOf != nil || deleteOf != nil }

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
            if attachments.count == 1, attachments[0].isVoice { label = "🎤 Voice message" }
            else if attachments.count == 1, attachments[0].isVideoNote { label = "⭕ Video message" }
            else if attachments.allSatisfy({ $0.isImage }) { label = attachments.count > 1 ? "📷 \(attachments.count) Photos" : "📷 Photo" }
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
