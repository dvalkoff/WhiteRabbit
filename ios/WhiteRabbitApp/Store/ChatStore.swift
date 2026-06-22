import Foundation

enum DeliveryState: String { case sending, sent, delivered, failed }

/// A call-history entry shown inline in the chat (generated locally per device).
struct CallLog: Equatable {
    enum Outcome: String { case answered, missed, declined, cancelled, busy, failed }
    var incoming: Bool
    var video: Bool
    var outcome: Outcome
    var durationSec: Int

    var durationText: String { String(format: "%d:%02d", durationSec / 60, durationSec % 60) }

    var text: String {
        switch outcome {
        case .answered:  return "\(incoming ? "Incoming" : "Outgoing") \(video ? "video " : "")call · \(durationText)"
        case .missed:    return "Missed \(video ? "video " : "")call"
        case .declined:  return incoming ? "Declined call" : "Call declined"
        case .cancelled: return "Cancelled call"
        case .busy:      return "Line busy"
        case .failed:    return "Call failed"
        }
    }

    var icon: String {
        switch outcome {
        case .answered:  return incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill"
        case .missed, .cancelled: return "phone.down.fill"
        default:         return "phone.fill"
        }
    }

    var isMissed: Bool { outcome == .missed }
}

/// A single decrypted message held locally. The server only ever stores
/// ciphertext, so all plaintext history lives on-device.
struct ChatMessage: Identifiable, Equatable {
    var id: String          // server message id (or temp client id while sending)
    var clientID: String?   // correlates the Ack for an outgoing message
    let peerID: String      // conversation id (peer userID for 1:1, groupID for group)
    var senderID: String = ""   // who sent it (used to label group messages)
    var senderName: String?     // resolved display name of the sender (groups)
    var text: String              // optional caption / text body
    var attachments: [Attachment] = []
    let isMine: Bool
    let timestamp: Date
    var delivery: DeliveryState
    var editedAt: Date?
    var deleted: Bool = false
    var replyTo: ReplyPreview?
    var forwarded: Bool = false
    var callLog: CallLog?

    /// One-line representation for the chat feed / search.
    var previewText: String {
        if deleted { return "🚫 Message deleted" }
        if let callLog { return "📞 " + callLog.text }
        return MessageContent(text: text.isEmpty ? nil : text, attachments: attachments).preview
    }
}

/// A conversation row in the feed — a 1:1 chat or a group.
struct Conversation: Identifiable, Equatable {
    let peerID: String         // peer userID for 1:1, groupID for group
    var nickname: String       // display title (peer nickname or group name)
    var isGroup: Bool = false
    var memberIDs: [String] = []   // group members (for fan-out), groups only
    var lastMessage: String
    var lastMessageAt: Date
    var unread: Int

    var id: String { peerID }
}

/// In-memory store of conversations and messages, published to SwiftUI. The feed
/// is the conversation list sorted by most recent activity (requirement #3).
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var messagesByPeer: [String: [ChatMessage]] = [:]

    /// Known peer nicknames, independent of whether a conversation row exists yet.
    /// Lets us open a chat (and label it) without creating an empty feed entry.
    private var nicknameCache: [String: String] = [:]
    /// Known peer avatar object keys, so rows can render others' profile photos.
    private var photoCache: [String: String] = [:]

    func photoKey(for id: String) -> String? { photoCache[id] }

    func messages(for peerID: String) -> [ChatMessage] {
        messagesByPeer[peerID] ?? []
    }

    func nickname(for peerID: String) -> String {
        conversations.first(where: { $0.peerID == peerID })?.nickname
            ?? nicknameCache[peerID]
            ?? String(peerID.prefix(8))
    }

    /// Remember a peer's nickname without creating a conversation row. A row is
    /// only created once an actual message exists (see addMessage).
    func remember(peerID: String, nickname: String, photoKey: String? = nil) {
        nicknameCache[peerID] = nickname
        if let photoKey, !photoKey.isEmpty { photoCache[peerID] = photoKey }
        // If a 1:1 conversation already exists, keep its label fresh.
        if let idx = conversations.firstIndex(where: { $0.peerID == peerID && !$0.isGroup }) {
            conversations[idx].nickname = nickname
        }
    }

    /// Create or update a group conversation. Unlike 1:1 chats, groups exist
    /// server-side and so appear in the feed immediately (even before messages).
    func upsertGroup(id: String, name: String, memberIDs: [String]) {
        if let idx = conversations.firstIndex(where: { $0.peerID == id }) {
            conversations[idx].nickname = name
            conversations[idx].isGroup = true
            conversations[idx].memberIDs = memberIDs
        } else {
            conversations.append(Conversation(peerID: id, nickname: name, isGroup: true,
                                              memberIDs: memberIDs, lastMessage: "",
                                              lastMessageAt: .distantPast, unread: 0))
        }
        sortFeed()
    }

    func conversation(_ id: String) -> Conversation? {
        conversations.first { $0.peerID == id }
    }

    func isGroup(_ id: String) -> Bool { conversation(id)?.isGroup ?? false }

    func addMessage(_ msg: ChatMessage, incrementUnread: Bool = false, nickname: String? = nil) {
        var list = messagesByPeer[msg.peerID] ?? []
        // Dedupe by id (a message may arrive via fast-path and store-and-forward).
        guard !list.contains(where: { $0.id == msg.id }) else { return }
        list.append(msg)
        list.sort { $0.timestamp < $1.timestamp }
        messagesByPeer[msg.peerID] = list

        if let idx = conversations.firstIndex(where: { $0.peerID == msg.peerID }) {
            conversations[idx].lastMessage = msg.previewText
            conversations[idx].lastMessageAt = msg.timestamp
            if let nickname { conversations[idx].nickname = nickname }
            if incrementUnread { conversations[idx].unread += 1 }
        } else {
            conversations.append(Conversation(peerID: msg.peerID,
                                              nickname: nickname ?? nicknameCache[msg.peerID] ?? String(msg.peerID.prefix(8)),
                                              lastMessage: msg.previewText, lastMessageAt: msg.timestamp,
                                              unread: incrementUnread ? 1 : 0))
        }
        sortFeed()
    }

    /// Append a call-history entry to a conversation.
    func addCallLog(peerID: String, _ log: CallLog, at: Date) {
        var msg = ChatMessage(id: UUID().uuidString, clientID: nil, peerID: peerID,
                              text: "", isMine: !log.incoming, timestamp: at, delivery: .sent)
        msg.callLog = log
        addMessage(msg, incrementUnread: log.isMissed)
    }

    /// Apply a server Ack: promote the temp outgoing message to its server id.
    func applyAck(clientID: String, serverID: String, peerID: String) {
        guard var list = messagesByPeer[peerID] else { return }
        if let idx = list.firstIndex(where: { $0.clientID == clientID }) {
            list[idx].id = serverID
            list[idx].delivery = .sent
            messagesByPeer[peerID] = list
        }
    }

    /// Replace the text of a message (edit-for-everyone).
    func applyEdit(messageID: String, newText: String, peerID: String, at: Date) {
        guard var list = messagesByPeer[peerID] else { return }
        if let idx = list.firstIndex(where: { $0.id == messageID }) {
            list[idx].text = newText
            list[idx].editedAt = at
            messagesByPeer[peerID] = list
            refreshPreview(peerID)
        }
    }

    /// Tombstone a message (delete-for-everyone).
    func markDeleted(messageID: String, peerID: String) {
        guard var list = messagesByPeer[peerID] else { return }
        if let idx = list.firstIndex(where: { $0.id == messageID }) {
            list[idx].deleted = true
            list[idx].text = ""
            list[idx].attachments = []
            messagesByPeer[peerID] = list
            refreshPreview(peerID)
        }
    }

    private func refreshPreview(_ peerID: String) {
        guard let last = messagesByPeer[peerID]?.last,
              let idx = conversations.firstIndex(where: { $0.peerID == peerID }) else { return }
        conversations[idx].lastMessage = last.previewText
    }

    func markDelivered(messageID: String, peerID: String) {
        guard var list = messagesByPeer[peerID] else { return }
        if let idx = list.firstIndex(where: { $0.id == messageID }) {
            list[idx].delivery = .delivered
            messagesByPeer[peerID] = list
        }
    }

    /// Mark an outgoing message (identified by its client id) as failed.
    func markFailed(clientID: String, peerID: String) {
        guard var list = messagesByPeer[peerID] else { return }
        if let idx = list.firstIndex(where: { $0.clientID == clientID }) {
            list[idx].delivery = .failed
            messagesByPeer[peerID] = list
        }
    }

    /// Current delivery state of an outgoing message by client id, if present.
    func deliveryState(clientID: String, peerID: String) -> DeliveryState? {
        messagesByPeer[peerID]?.first(where: { $0.clientID == clientID })?.delivery
    }

    func removeMessage(id: String, peerID: String) {
        messagesByPeer[peerID]?.removeAll { $0.id == id }
    }

    // MARK: - Search

    /// Conversations whose nickname matches the query.
    func searchConversations(_ query: String) -> [Conversation] {
        let q = query.lowercased()
        return conversations.filter { $0.nickname.lowercased().contains(q) }
    }

    /// A message that matched a local full-text search, with its peer for display.
    struct MessageHit: Identifiable {
        let message: ChatMessage
        var id: String { message.id }
        var peerID: String { message.peerID }
    }

    /// Local full-text search across all decrypted message text (server can't do
    /// this — it only holds ciphertext). Most recent first.
    func searchMessages(_ query: String, limit: Int = 50) -> [MessageHit] {
        let q = query.lowercased()
        var hits: [ChatMessage] = []
        for (_, list) in messagesByPeer {
            for m in list where m.text.lowercased().contains(q) {
                hits.append(m)
            }
        }
        return hits.sorted { $0.timestamp > $1.timestamp }.prefix(limit).map { MessageHit(message: $0) }
    }

    func clearUnread(peerID: String) {
        if let idx = conversations.firstIndex(where: { $0.peerID == peerID }) {
            conversations[idx].unread = 0
        }
    }

    func removeConversation(_ id: String) {
        conversations.removeAll { $0.peerID == id }
        messagesByPeer[id] = nil
    }

    func reset() {
        conversations = []
        messagesByPeer = [:]
    }

    private func sortFeed() {
        conversations.sort { $0.lastMessageAt > $1.lastMessageAt }
    }
}
