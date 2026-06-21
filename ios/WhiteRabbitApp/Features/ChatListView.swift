import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var app: AppState
    @State private var showingNewChat = false
    @State private var path: [String] = []
    @State private var peerToOpen: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if app.chatStore.conversations.isEmpty {
                    ContentUnavailableView("No chats yet",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tap + to start a conversation."))
                } else {
                    List(app.chatStore.conversations) { convo in
                        NavigationLink(value: convo.peerID) {
                            ConversationRow(convo: convo)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { peerID in
                ChatView(peerID: peerID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Text(app.session?.nickname ?? "")
                        Button("Log out", role: .destructive) { app.logout() }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Circle()
                            .fill(app.isConnected ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Button { showingNewChat = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            // Selecting a person in the sheet sets peerToOpen; once the sheet has
            // dismissed we push the chat onto the main navigation stack.
            .sheet(isPresented: $showingNewChat, onDismiss: {
                if let peer = peerToOpen {
                    peerToOpen = nil
                    path.append(peer)
                }
            }) {
                NewChatView { user in
                    app.startConversation(with: user)
                    peerToOpen = user.id
                }
            }
        }
    }
}

private struct ConversationRow: View {
    let convo: Conversation

    var body: some View {
        HStack {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay(Text(convo.nickname.prefix(1).uppercased()).font(.headline))
            VStack(alignment: .leading, spacing: 2) {
                Text(convo.nickname).font(.headline)
                Text(convo.lastMessage).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if convo.unread > 0 {
                Text("\(convo.unread)")
                    .font(.caption2.bold())
                    .padding(6)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
        }
    }
}
