import Foundation
import OSLog

/// Decoded inbound events surfaced to the app layer.
enum WSEvent {
    case incoming(messageID: String, senderID: String, ciphertext: Data, type: Messenger_V1_MessageType, isPrekey: Bool, createdAtMs: Int64)
    case ack(clientID: String, messageID: String, createdAtMs: Int64)
    case receipt(messageID: String, senderID: String, kind: Messenger_V1_Receipt.Kind)
    case typing(peerID: String, typing: Bool)
    case error(code: String, message: String)
}

/// Realtime websocket client. Connects to `/v1/ws?token=`, frames protobuf
/// envelopes, auto-reconnects, and pings to keep presence fresh.
final class WebSocketClient: NSObject {
    private let baseURL: URL
    private var token: String
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    private var shouldRun = false
    private var reconnectDelay: TimeInterval = 1

    /// Called for each decoded inbound event (on an arbitrary queue).
    var onEvent: ((WSEvent) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    func connect() {
        shouldRun = true
        openSocket()
    }

    func disconnect() {
        shouldRun = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func openSocket() {
        guard shouldRun else { return }
        var comps = URLComponents(url: baseURL.appendingPathComponent("/v1/ws"), resolvingAgainstBaseURL: false)!
        // ws/wss derived from http/https base.
        if comps.scheme == "https" { comps.scheme = "wss" } else { comps.scheme = "ws" }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        log.debug("ws connecting to \(comps.url!.absoluteString, privacy: .public)")
        let task = session.webSocketTask(with: comps.url!)
        self.task = task
        task.resume()
        receiveLoop()
        schedulePing()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    log.debug("ws recv \(data.count) bytes")
                    self.handle(data)
                case .string(let s):
                    log.debug("ws recv string \(s.count) chars (ignored)")
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                log.error("ws receive failed: \(String(describing: error), privacy: .public)")
                self.onConnectionChange?(false)
                self.scheduleReconnect()
            }
        }
    }

    private func handle(_ data: Data) {
        guard let env = try? Messenger_V1_Envelope(serializedBytes: data), let payload = env.payload else {
            log.error("ws failed to parse envelope (\(data.count) bytes)")
            return
        }
        switch payload {
        case .incoming(let m):
            onEvent?(.incoming(messageID: m.messageID, senderID: m.senderID, ciphertext: m.ciphertext,
                               type: m.type, isPrekey: m.isPrekey, createdAtMs: m.createdAtUnixMs))
        case .ack(let a):
            onEvent?(.ack(clientID: a.clientID, messageID: a.messageID, createdAtMs: a.createdAtUnixMs))
        case .receipt(let r):
            onEvent?(.receipt(messageID: r.messageID, senderID: r.senderID, kind: r.kind))
        case .typing(let t):
            onEvent?(.typing(peerID: t.peerID, typing: t.typing))
        case .error(let e):
            onEvent?(.error(code: e.code, message: e.message))
        case .pong:
            break
        default:
            break
        }
    }

    // MARK: - Sending

    func send(_ env: Messenger_V1_Envelope) {
        guard let data = try? env.serializedData() else { return }
        task?.send(.data(data)) { error in
            if let error { log.error("ws send error: \(String(describing: error), privacy: .public)") }
        }
    }

    func sendMessage(recipientID: String, ciphertext: Data, type: Messenger_V1_MessageType, isPrekey: Bool, clientID: String) {
        var send = Messenger_V1_SendMessage()
        send.recipientID = recipientID
        send.ciphertext = ciphertext
        send.type = type
        send.isPrekey = isPrekey
        var env = Messenger_V1_Envelope()
        env.id = clientID
        env.payload = .send(send)
        self.send(env)
    }

    func sendDeliveryReceipt(messageID: String, to senderID: String) {
        var r = Messenger_V1_Receipt()
        r.messageID = messageID
        r.senderID = senderID
        r.kind = .delivered
        var env = Messenger_V1_Envelope()
        env.payload = .receipt(r)
        send(env)
    }

    // MARK: - Keepalive / reconnect

    private func schedulePing() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.shouldRun else { return }
            var env = Messenger_V1_Envelope()
            env.payload = .ping(Messenger_V1_Ping())
            self.send(env)
            self.schedulePing()
        }
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.openSocket()
        }
    }
}

extension WebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        reconnectDelay = 1
        onConnectionChange?(true)
    }
}
