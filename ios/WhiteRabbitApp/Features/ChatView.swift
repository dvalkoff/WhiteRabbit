import SwiftUI

struct ChatView: View {
    @EnvironmentObject var app: AppState
    let peerID: String

    @State private var draft = ""

    private var messages: [ChatMessage] { app.chatStore.messages(for: peerID) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg) {
                                Task { await app.resend(message: msg) }
                            }
                            .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let text = draft
                    draft = ""
                    Task { await app.send(text: text, to: peerID) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(app.chatStore.nickname(for: peerID))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.chatStore.clearUnread(peerID: peerID) }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var onRetry: () -> Void

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 40) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(message.isMine ? Color.accentColor : Color(.systemGray5))
                    .foregroundStyle(message.isMine ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                if message.isMine {
                    if message.delivery == .failed {
                        Button(action: onRetry) {
                            Label("Failed — tap to retry", systemImage: "exclamationmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text(statusText).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !message.isMine { Spacer(minLength: 40) }
        }
    }

    private var statusText: String {
        switch message.delivery {
        case .sending: return "sending…"
        case .sent: return "sent"
        case .delivered: return "delivered"
        case .failed: return "failed"
        }
    }
}
