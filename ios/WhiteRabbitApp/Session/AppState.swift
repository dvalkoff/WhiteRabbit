import AVFoundation
import Combine
import Foundation
import OSLog
import UIKit
import WhiteRabbitKit

let log = Logger(subsystem: "com.whiterabbit.app", category: "app")

/// Which kind of note the chat input records. Global across chats, persisted.
enum RecorderMode: String { case voice, video }

struct SessionInfo: Equatable {
    let userID: String
    let nickname: String
}

/// AppState is the top-level coordinator: it owns the API client, the realtime
/// socket, the CryptoService, and the ChatStore, and wires inbound socket events
/// through decryption into the local store.
///
/// v1 simplification: the identity/prekeys are regenerated on each login and
/// kept in memory (no Keychain persistence yet). Sessions therefore live for the
/// app run. Persisting the CryptoService is a documented follow-up.
@MainActor
final class AppState: ObservableObject {
    @Published var session: SessionInfo?
    @Published var isConnected = false
    @Published var authError: String?
    @Published var isBusy = false
    @Published var recorderMode: RecorderMode =
        RecorderMode(rawValue: UserDefaults.standard.string(forKey: "recorderMode") ?? "") ?? .voice

    func toggleRecorderMode() {
        recorderMode = recorderMode == .voice ? .video : .voice
        UserDefaults.standard.set(recorderMode.rawValue, forKey: "recorderMode")
    }

    let chatStore = ChatStore()

    private let api: APIClient
    private let baseURL: URL
    private var ws: WebSocketClient?
    private var crypto: CryptoService?
    private let files: FileService
    private var cancellables = Set<AnyCancellable>()

    init(baseURL: URL) {
        self.baseURL = baseURL
        let api = APIClient(baseURL: baseURL)
        self.api = api
        self.files = FileService(api: api)
        // ChatStore is a nested ObservableObject; re-publish its changes so views
        // observing AppState refresh when messages/conversations change.
        chatStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var myUserID: String? { session?.userID }

    // MARK: - Auth

    func register(nickname: String, password: String) async {
        await authenticate { try await self.api.register(nickname: nickname, password: password) }
    }

    func login(nickname: String, password: String) async {
        await authenticate { try await self.api.login(nickname: nickname, password: password) }
    }

    private func authenticate(_ call: @escaping () async throws -> AuthResponse) async {
        isBusy = true
        authError = nil
        defer { isBusy = false }
        do {
            let resp = try await call()
            api.accessToken = resp.accessToken

            // Generate fresh E2E keys and publish the public bundle.
            let crypto = CryptoService.generate()
            self.crypto = crypto
            try await api.uploadKeys(crypto.keyUpload())

            session = SessionInfo(userID: resp.userId, nickname: resp.nickname)
            connectSocket(token: resp.accessToken)
            await loadGroups()
        } catch {
            authError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func logout() {
        ws?.disconnect()
        ws = nil
        crypto = nil
        api.accessToken = nil
        session = nil
        chatStore.reset()
        isConnected = false
    }

    // MARK: - Socket

    private func connectSocket(token: String) {
        let ws = WebSocketClient(baseURL: baseURL, token: token)
        ws.onConnectionChange = { [weak self] up in
            Task { @MainActor in self?.isConnected = up }
        }
        ws.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.ws = ws
        ws.connect()
    }

    // MARK: - Groups

    /// Load the user's groups and register them as conversations + cache member
    /// names for sender labels.
    func loadGroups() async {
        guard let groups = try? await api.listGroups() else { return }
        for g in groups { registerGroup(g) }
    }

    private func registerGroup(_ g: GroupView) {
        for m in g.members { chatStore.remember(peerID: m.id, nickname: m.nickname, photoKey: m.photoUrl) }
        chatStore.upsertGroup(id: g.id, name: g.name, memberIDs: g.members.map { $0.id })
    }

    /// Create a group and return its id (for navigation).
    func createGroup(name: String, memberIDs: [String]) async -> String? {
        guard let g = try? await api.createGroup(name: name, memberIDs: memberIDs) else { return nil }
        registerGroup(g)
        return g.id
    }

    func addGroupMember(groupID: String, user: UserView) async {
        if let g = try? await api.addGroupMember(groupID: groupID, userID: user.id) { registerGroup(g) }
    }

    /// Remove a member, or leave the group when removing yourself.
    func removeGroupMember(groupID: String, userID: String) async {
        guard let g = try? await api.removeGroupMember(groupID: groupID, userID: userID) else { return }
        if userID == session?.userID {
            chatStore.removeConversation(groupID)
        } else {
            registerGroup(g)
        }
    }

    private func ensureGroupLoaded(_ groupID: String) async {
        guard chatStore.conversation(groupID) == nil else { return }
        if let g = try? await api.getGroup(groupID) { registerGroup(g) }
    }

    // MARK: - Profile

    func myProfile() async -> UserView? { try? await api.me() }

    func updateNickname(_ nickname: String) async -> String? {
        do {
            let u = try await api.updateMe(nickname: nickname)
            session = SessionInfo(userID: u.id, nickname: u.nickname)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Could not update nickname"
        }
    }

    func changePassword(old: String, new: String) async -> String? {
        do {
            try await api.changePassword(old: old, new: new)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Could not change password"
        }
    }

    func updatePhoto(_ data: Data) async {
        guard let key = try? await files.uploadPlain(data, mime: "image/jpeg") else { return }
        _ = try? await api.updateMe(photoURL: key)
        avatarCache[key] = UIImage(data: data)
        if let s = session { session = s } // nudge observers
    }

    private func handle(_ event: WSEvent) {
        switch event {
        case let .incoming(messageID, senderID, ciphertext, type, _, createdAtMs):
            Task { await handleIncoming(messageID: messageID, senderID: senderID, ciphertext: ciphertext,
                                        type: type, createdAtMs: createdAtMs) }
        case let .ack(clientID, messageID, _):
            log.debug("ack received client=\(clientID, privacy: .public) server=\(messageID, privacy: .public)")
            // Find which conversation this client id belongs to.
            for (peerID, msgs) in chatStore.messagesByPeer where msgs.contains(where: { $0.clientID == clientID }) {
                chatStore.applyAck(clientID: clientID, serverID: messageID, peerID: peerID)
            }
        case let .receipt(messageID, senderID, kind):
            if kind == .delivered { chatStore.markDelivered(messageID: messageID, peerID: senderID) }
        case .typing:
            break
        case let .error(code, message):
            log.error("ws error \(code, privacy: .public): \(message, privacy: .public)")
        }
    }

    private func handleIncoming(messageID: String, senderID: String, ciphertext: Data,
                               type: Messenger_V1_MessageType, createdAtMs: Int64) async {
        guard let crypto else { return }
        log.debug("incoming msg=\(messageID, privacy: .public) from=\(senderID, privacy: .public) bytes=\(ciphertext.count)")
        let plaintext: Data
        do {
            plaintext = try crypto.decrypt(ciphertext, from: senderID)
        } catch {
            log.error("decrypt failed from \(senderID, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        let content = MessageContent.decode(plaintext)
        let isGroup = content.groupID != nil
        let convID = content.groupID ?? senderID
        let when = Date(timeIntervalSince1970: Double(createdAtMs) / 1000)

        // Control messages mutate an existing message rather than adding one.
        if let target = content.deleteOf {
            chatStore.markDeleted(messageID: target, peerID: convID)
            ws?.sendDeliveryReceipt(messageID: messageID, to: senderID)
            return
        }
        if let target = content.editOf {
            chatStore.applyEdit(messageID: target, newText: content.text ?? "", peerID: convID, at: when)
            ws?.sendDeliveryReceipt(messageID: messageID, to: senderID)
            return
        }

        // Make sure the group conversation and the sender's name are known before
        // we file the message (so it renders with the right title/sender label).
        if isGroup { await ensureGroupLoaded(convID) }
        if chatStore.nickname(for: senderID).count <= 8 { await resolveNickname(senderID) }

        let known = chatStore.conversation(convID) != nil
        var msg = ChatMessage(id: messageID, clientID: nil, peerID: convID,
                              senderID: senderID,
                              senderName: isGroup ? chatStore.nickname(for: senderID) : nil,
                              text: content.text ?? "", attachments: content.attachments,
                              isMine: false, timestamp: when, delivery: .delivered)
        msg.replyTo = content.replyTo
        msg.forwarded = content.forwarded
        chatStore.addMessage(msg, incrementUnread: true)
        ws?.sendDeliveryReceipt(messageID: messageID, to: senderID)
        if !known && !isGroup { await resolveNickname(senderID) }
    }

    private func resolveNickname(_ userID: String) async {
        if let user = try? await api.getUser(userID) {
            chatStore.remember(peerID: user.id, nickname: user.nickname, photoKey: user.photoUrl)
        }
    }

    // MARK: - Sending

    /// Open a chat with a person. This only remembers their nickname; the
    /// conversation appears in the feed once the first message is sent or received.
    func startConversation(with user: UserView) {
        chatStore.remember(peerID: user.id, nickname: user.nickname, photoKey: user.photoUrl)
    }

    func searchUsers(_ query: String) async -> [UserView] {
        (try? await api.searchUsers(query)) ?? []
    }

    /// How long to wait for a server Ack before marking a message as failed.
    private static let sendTimeout: Duration = .seconds(15)

    func send(text: String, to conversationID: String, replyingTo: ChatMessage? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var content = MessageContent.text(trimmed)
        if let r = replyingTo { content.replyTo = replyPreview(for: r) }
        await sendContent(content, to: conversationID, localText: trimmed, attachments: [])
    }

    /// A locally-picked or recorded attachment awaiting upload.
    struct PendingMedia {
        let data: Data
        let mime: String
        let name: String
        var width: Int?
        var height: Int?
        var durationMs: Int?
        var waveform: [Int]?
        var round: Bool?
    }

    /// Encrypt and upload a batch of attachments, then send them as a SINGLE
    /// message (one album) with an optional caption.
    func sendAttachments(_ items: [PendingMedia], caption: String = "", to conversationID: String) async {
        guard !items.isEmpty else { return }
        do {
            var atts: [Attachment] = []
            for item in items {
                let att = try await files.encryptAndUpload(item.data, mime: item.mime, name: item.name,
                                                           width: item.width, height: item.height,
                                                           durationMs: item.durationMs, waveform: item.waveform,
                                                           round: item.round)
                blobCache[att.key] = item.data // render our own attachments without a round-trip
                atts.append(att)
            }
            let content = MessageContent(text: caption.isEmpty ? nil : caption, attachments: atts)
            await sendContent(content, to: conversationID, localText: caption, attachments: atts)
        } catch {
            log.error("attachment upload failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Send to a conversation. For a group the message is fanned out per member
    /// over each member's own 1:1 ratchet (the server stays group-unaware); for a
    /// 1:1 chat it goes to the single peer.
    private func sendContent(_ content: MessageContent, to conversationID: String, localText: String,
                             attachments: [Attachment]) async {
        guard let myID = session?.userID else { return }

        var content = content
        if chatStore.isGroup(conversationID) { content.groupID = conversationID }

        let clientID = UUID().uuidString
        var local = ChatMessage(id: clientID, clientID: clientID, peerID: conversationID,
                                senderID: myID, text: localText, attachments: attachments,
                                isMine: true, timestamp: Date(), delivery: .sending)
        local.replyTo = content.replyTo
        local.forwarded = content.forwarded
        chatStore.addMessage(local)

        let recipients = recipients(for: conversationID)
        guard !recipients.isEmpty else { return }

        let type: Messenger_V1_MessageType = attachments.isEmpty ? .text
            : (attachments.contains { $0.isMedia } ? .image : .file)
        guard let payload = try? content.encoded() else {
            chatStore.markFailed(clientID: clientID, peerID: conversationID); return
        }
        if await deliver(payload: payload, type: type, clientID: clientID, to: recipients) {
            scheduleSendTimeout(clientID: clientID, peerID: conversationID)
        } else {
            chatStore.markFailed(clientID: clientID, peerID: conversationID)
        }
    }

    /// Recipients a conversation fans out to (group members minus me, or the peer).
    private func recipients(for conversationID: String) -> [String] {
        guard let myID = session?.userID else { return [] }
        if let g = chatStore.conversation(conversationID), g.isGroup {
            return g.memberIDs.filter { $0 != myID }
        }
        return conversationID == myID ? [] : [conversationID]
    }

    /// Encrypt a payload to each recipient (per-recipient ratchet) and send it.
    @discardableResult
    private func deliver(payload: Data, type: Messenger_V1_MessageType, clientID: String, to recipients: [String]) async -> Bool {
        guard let crypto else { return false }
        var anySent = false
        for r in recipients {
            do {
                let bundle = crypto.hasSession(with: r) ? nil : try await api.fetchBundle(userID: r)
                let (cipher, isPrekey) = try crypto.encrypt(payload, to: r, bundle: bundle)
                ws?.sendMessage(recipientID: r, ciphertext: cipher, type: type, isPrekey: isPrekey, clientID: clientID)
                anySent = true
            } catch {
                log.error("deliver to \(r, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return anySent
    }

    // MARK: - Edit / delete / forward

    private func replyPreview(for m: ChatMessage) -> ReplyPreview {
        ReplyPreview(messageID: m.id, sender: senderDisplay(m), text: String(m.previewText.prefix(120)))
    }

    private func senderDisplay(_ m: ChatMessage) -> String {
        if m.isMine { return session?.nickname ?? "You" }
        return m.senderName ?? chatStore.nickname(for: m.senderID)
    }

    /// Edit your own message's text, for everyone.
    func editMessage(_ message: ChatMessage, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.isMine, message.delivery != .sending, !trimmed.isEmpty else { return }
        chatStore.applyEdit(messageID: message.id, newText: trimmed, peerID: message.peerID, at: Date())
        var content = MessageContent.text(trimmed)
        content.editOf = message.id
        if chatStore.isGroup(message.peerID) { content.groupID = message.peerID }
        if let payload = try? content.encoded() {
            await deliver(payload: payload, type: .text, clientID: UUID().uuidString,
                          to: recipients(for: message.peerID))
        }
    }

    /// Delete messages. Your own are deleted for everyone; others' are removed
    /// only from your view.
    func deleteMessages(_ messages: [ChatMessage]) async {
        for m in messages {
            if m.isMine && m.delivery != .sending {
                chatStore.markDeleted(messageID: m.id, peerID: m.peerID)
                var content = MessageContent()
                content.deleteOf = m.id
                if chatStore.isGroup(m.peerID) { content.groupID = m.peerID }
                if let payload = try? content.encoded() {
                    await deliver(payload: payload, type: .text, clientID: UUID().uuidString,
                                  to: recipients(for: m.peerID))
                }
            } else {
                chatStore.removeMessage(id: m.id, peerID: m.peerID)
            }
        }
    }

    /// Forward messages (text and/or attachments) to another conversation.
    func forwardMessages(_ messages: [ChatMessage], to conversationID: String) async {
        for m in messages.sorted(by: { $0.timestamp < $1.timestamp }) where !m.deleted {
            var content = MessageContent(text: m.text.isEmpty ? nil : m.text, attachments: m.attachments)
            content.forwarded = true
            await sendContent(content, to: conversationID, localText: m.text, attachments: m.attachments)
        }
    }

    // MARK: - Attachment data (decrypt-on-demand with an in-memory cache)

    private var blobCache: [String: Data] = [:]
    private var thumbCache: [String: UIImage] = [:]
    private var avatarCache: [String: UIImage] = [:]

    /// Load a profile avatar (stored unencrypted) by its object key.
    func avatarImage(forKey key: String) async -> UIImage? {
        guard !key.isEmpty else { return nil }
        if let cached = avatarCache[key] { return cached }
        guard let url = try? await api.downloadURL(key: key),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return nil }
        avatarCache[key] = img
        return img
    }

    /// Generate (and cache) a poster-frame thumbnail for a video attachment.
    func videoThumbnail(_ attachment: Attachment) async -> UIImage? {
        if let cached = thumbCache[attachment.key] { return cached }
        guard let url = await attachmentFileURL(attachment) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        do {
            let cg = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
            let img = UIImage(cgImage: cg)
            thumbCache[attachment.key] = img
            return img
        } catch {
            return nil
        }
    }

    /// Return the decrypted bytes for an attachment, downloading + decrypting on
    /// first access and caching the result.
    func attachmentData(_ attachment: Attachment) async -> Data? {
        if let cached = blobCache[attachment.key] { return cached }
        do {
            let data = try await files.downloadAndDecrypt(attachment)
            blobCache[attachment.key] = data
            return data
        } catch {
            log.error("attachment download failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Decrypt an attachment to a temporary file and return its URL, so it can be
    /// previewed/saved/shared (QuickLook). The file keeps its original name.
    func attachmentFileURL(_ attachment: Attachment) async -> URL? {
        guard let data = await attachmentData(attachment) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wr-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Prefix with the key hash to avoid collisions across distinct blobs.
        let safeName = attachment.name.isEmpty ? "file" : attachment.name
        let url = dir.appendingPathComponent("\(abs(attachment.key.hashValue))-\(safeName)")
        do {
            try data.write(to: url)
            return url
        } catch {
            log.error("write temp attachment failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Mark a message as failed if it hasn't been acknowledged within the timeout.
    private func scheduleSendTimeout(clientID: String, peerID: String) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.sendTimeout)
            guard let self else { return }
            if self.chatStore.deliveryState(clientID: clientID, peerID: peerID) == .sending {
                log.error("send timed out client=\(clientID, privacy: .public)")
                self.chatStore.markFailed(clientID: clientID, peerID: peerID)
            }
        }
    }

    /// Resend a previously failed message.
    func resend(message: ChatMessage) async {
        chatStore.removeMessage(id: message.id, peerID: message.peerID)
        await send(text: message.text, to: message.peerID)
    }
}
