import AVFoundation
import Combine
import Foundation
import OSLog
import UIKit
import WhiteRabbitKit

let log = Logger(subsystem: "com.whiterabbit.app", category: "app")

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

    private func handle(_ event: WSEvent) {
        switch event {
        case let .incoming(messageID, senderID, ciphertext, type, _, createdAtMs):
            handleIncoming(messageID: messageID, senderID: senderID, ciphertext: ciphertext,
                           type: type, createdAtMs: createdAtMs)
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
                               type: Messenger_V1_MessageType, createdAtMs: Int64) {
        guard let crypto else { return }
        log.debug("incoming msg=\(messageID, privacy: .public) from=\(senderID, privacy: .public) bytes=\(ciphertext.count)")
        do {
            let plaintext = try crypto.decrypt(ciphertext, from: senderID)
            let content = MessageContent.decode(plaintext)
            let msg = ChatMessage(id: messageID, clientID: nil, peerID: senderID,
                                  text: content.text ?? "", attachments: content.attachments,
                                  isMine: false, timestamp: Date(timeIntervalSince1970: Double(createdAtMs) / 1000),
                                  delivery: .delivered)
            let known = chatStore.conversations.contains { $0.peerID == senderID }
            chatStore.addMessage(msg, incrementUnread: true)
            ws?.sendDeliveryReceipt(messageID: messageID, to: senderID)
            if !known { Task { await resolveNickname(senderID) } }
        } catch {
            log.error("decrypt failed from \(senderID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func resolveNickname(_ userID: String) async {
        if let user = try? await api.getUser(userID) {
            chatStore.remember(peerID: user.id, nickname: user.nickname)
        }
    }

    // MARK: - Sending

    /// Open a chat with a person. This only remembers their nickname; the
    /// conversation appears in the feed once the first message is sent or received.
    func startConversation(with user: UserView) {
        chatStore.remember(peerID: user.id, nickname: user.nickname)
    }

    func searchUsers(_ query: String) async -> [UserView] {
        (try? await api.searchUsers(query)) ?? []
    }

    /// How long to wait for a server Ack before marking a message as failed.
    private static let sendTimeout: Duration = .seconds(15)

    func send(text: String, to peerID: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await sendContent(.text(trimmed), to: peerID, localText: trimmed, attachments: [])
    }

    /// A locally-picked attachment awaiting upload.
    struct PendingMedia {
        let data: Data
        let mime: String
        let name: String
        var width: Int?
        var height: Int?
    }

    /// Encrypt and upload a batch of attachments, then send them as a SINGLE
    /// message (one album) with an optional caption.
    func sendAttachments(_ items: [PendingMedia], caption: String = "", to peerID: String) async {
        guard !items.isEmpty else { return }
        do {
            var atts: [Attachment] = []
            for item in items {
                let att = try await files.encryptAndUpload(item.data, mime: item.mime, name: item.name,
                                                           width: item.width, height: item.height)
                blobCache[att.key] = item.data // render our own attachments without a round-trip
                atts.append(att)
            }
            let content = MessageContent(text: caption.isEmpty ? nil : caption, attachments: atts)
            await sendContent(content, to: peerID, localText: caption, attachments: atts)
        } catch {
            log.error("attachment upload failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sendContent(_ content: MessageContent, to peerID: String, localText: String,
                             attachments: [Attachment]) async {
        guard let crypto, let myID = session?.userID, myID != peerID else { return }

        let clientID = UUID().uuidString
        let local = ChatMessage(id: clientID, clientID: clientID, peerID: peerID, text: localText,
                                attachments: attachments, isMine: true, timestamp: Date(), delivery: .sending)
        chatStore.addMessage(local)

        do {
            // Bootstrap a session by fetching the peer's bundle if we don't have one.
            let bundle = crypto.hasSession(with: peerID) ? nil : try await api.fetchBundle(userID: peerID)
            let payload = try content.encoded()
            let (cipher, isPrekey) = try crypto.encrypt(payload, to: peerID, bundle: bundle)
            let type: Messenger_V1_MessageType = attachments.isEmpty ? .text
                : (attachments.contains { $0.isMedia } ? .image : .file)
            log.debug("sending client=\(clientID, privacy: .public) to=\(peerID, privacy: .public) bytes=\(cipher.count) prekey=\(isPrekey) connected=\(self.isConnected)")
            ws?.sendMessage(recipientID: peerID, ciphertext: cipher, type: type,
                            isPrekey: isPrekey, clientID: clientID)
            scheduleSendTimeout(clientID: clientID, peerID: peerID)
        } catch {
            log.error("send failed client=\(clientID, privacy: .public): \(String(describing: error), privacy: .public)")
            chatStore.markFailed(clientID: clientID, peerID: peerID)
        }
    }

    // MARK: - Attachment data (decrypt-on-demand with an in-memory cache)

    private var blobCache: [String: Data] = [:]
    private var thumbCache: [String: UIImage] = [:]

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
