import Foundation

enum DeliveryState: String { case sending, sent, delivered, failed }

/// A single decrypted message held locally. The server only ever stores
/// ciphertext, so all plaintext history lives on-device.
struct ChatMessage: Identifiable, Equatable {
    let id: String          // server message id (or temp client id while sending)
    var clientID: String?   // correlates the Ack for an outgoing message
    let peerID: String
    let text: String              // optional caption / text body
    var attachments: [Attachment] = []
    let isMine: Bool
    let timestamp: Date
    var delivery: DeliveryState

    /// One-line representation for the chat feed / search.
    var previewText: String {
        MessageContent(text: text.isEmpty ? nil : text, attachments: attachments).preview
    }
}

/// A conversation row in the feed.
struct Conversation: Identifiable, Equatable {
    let peerID: String
    var nickname: String
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
    func remember(peerID: String, nickname: String) {
        nicknameCache[peerID] = nickname
        // If a conversation already exists, keep its label fresh.
        if let idx = conversations.firstIndex(where: { $0.peerID == peerID }) {
            conversations[idx].nickname = nickname
        }
    }

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

    /// Apply a server Ack: promote the temp outgoing message to its server id.
    func applyAck(clientID: String, serverID: String, peerID: String) {
        guard var list = messagesByPeer[peerID] else { return }
        if let idx = list.firstIndex(where: { $0.clientID == clientID }) {
            let m = list[idx]
            list[idx] = ChatMessage(id: serverID, clientID: clientID, peerID: m.peerID,
                                    text: m.text, attachments: m.attachments, isMine: m.isMine,
                                    timestamp: m.timestamp, delivery: .sent)
            messagesByPeer[peerID] = list
        }
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

    func reset() {
        conversations = []
        messagesByPeer = [:]
    }

    private func sortFeed() {
        conversations.sort { $0.lastMessageAt > $1.lastMessageAt }
    }
}
