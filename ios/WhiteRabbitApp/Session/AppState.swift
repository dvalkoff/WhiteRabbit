import Combine
import Foundation
import OSLog
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
    private var cancellables = Set<AnyCancellable>()

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.api = APIClient(baseURL: baseURL)
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
            let text = String(data: plaintext, encoding: .utf8) ?? "<unreadable>"
            let msg = ChatMessage(id: messageID, clientID: nil, peerID: senderID, text: text,
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
        guard let crypto, let myID = session?.userID, myID != peerID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let clientID = UUID().uuidString
        let local = ChatMessage(id: clientID, clientID: clientID, peerID: peerID, text: trimmed,
                                isMine: true, timestamp: Date(), delivery: .sending)
        chatStore.addMessage(local)

        do {
            // Bootstrap a session by fetching the peer's bundle if we don't have one.
            let bundle = crypto.hasSession(with: peerID) ? nil : try await api.fetchBundle(userID: peerID)
            let (payload, isPrekey) = try crypto.encrypt(Data(trimmed.utf8), to: peerID, bundle: bundle)
            log.debug("sending client=\(clientID, privacy: .public) to=\(peerID, privacy: .public) bytes=\(payload.count) prekey=\(isPrekey) connected=\(self.isConnected)")
            ws?.sendMessage(recipientID: peerID, ciphertext: payload, type: .text,
                            isPrekey: isPrekey, clientID: clientID)
            scheduleSendTimeout(clientID: clientID, peerID: peerID)
        } catch {
            log.error("send failed client=\(clientID, privacy: .public): \(String(describing: error), privacy: .public)")
            chatStore.markFailed(clientID: clientID, peerID: peerID)
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
