import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var app: AppState
    @State private var showingNewChat = false
    @State private var showingNewGroup = false
    @State private var showingProfile = false
    @State private var path: [String] = []
    @State private var peerToOpen: String?
    @State private var searchText = ""
    @State private var peopleResults: [UserView] = []

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isSearching {
                    searchResults
                } else if app.chatStore.conversations.isEmpty {
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
            .searchable(text: $searchText, prompt: "Search people, chats, messages")
            .onChange(of: searchText) { _, q in
                Task {
                    let trimmed = q.trimmingCharacters(in: .whitespaces)
                    peopleResults = trimmed.count >= 2 ? await app.searchUsers(trimmed) : []
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { peerID in
                ChatView(peerID: peerID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingProfile = true } label: { Image(systemName: "person.crop.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Circle()
                            .fill(app.isConnected ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Menu {
                            Button { showingNewChat = true } label: { Label("New Chat", systemImage: "person") }
                            Button { showingNewGroup = true } label: { Label("New Group", systemImage: "person.3") }
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
            // Selecting a person/creating a group sets peerToOpen; once the sheet
            // dismisses we push the chat onto the main navigation stack.
            .sheet(isPresented: $showingNewChat, onDismiss: openPending) {
                NewChatView { user in
                    app.startConversation(with: user)
                    peerToOpen = user.id
                }
            }
            .sheet(isPresented: $showingNewGroup, onDismiss: openPending) {
                NewGroupView { groupID in peerToOpen = groupID }
            }
            .sheet(isPresented: $showingProfile) { ProfileView() }
        }
    }

    private func openPending() {
        if let peer = peerToOpen { peerToOpen = nil; path.append(peer) }
    }

    private func open(_ peerID: String) {
        searchText = ""
        path.append(peerID)
    }

    // Combined results across chats, local messages, and people on the server.
    private var searchResults: some View {
        let chats = app.chatStore.searchConversations(searchText)
        let messageHits = app.chatStore.searchMessages(searchText)
        let knownIDs = Set(app.chatStore.conversations.map { $0.peerID })
        let people = peopleResults.filter { !knownIDs.contains($0.id) }

        return List {
            if !chats.isEmpty {
                Section("Chats") {
                    ForEach(chats) { convo in
                        Button { open(convo.peerID) } label: { ConversationRow(convo: convo) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !messageHits.isEmpty {
                Section("Messages") {
                    ForEach(messageHits) { hit in
                        Button { open(hit.peerID) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.chatStore.nickname(for: hit.peerID)).font(.subheadline.bold())
                                Text(hit.message.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !people.isEmpty {
                Section("People") {
                    ForEach(people) { user in
                        Button {
                            app.startConversation(with: user)
                            open(user.id)
                        } label: {
                            HStack {
                                Circle().fill(Color.accentColor.opacity(0.2)).frame(width: 36, height: 36)
                                    .overlay(Text(user.nickname.prefix(1).uppercased()))
                                Text(user.nickname)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if chats.isEmpty && messageHits.isEmpty && people.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .listStyle(.plain)
    }
}

private struct ConversationRow: View {
    let convo: Conversation

    var body: some View {
        HStack {
            AvatarView(photoKey: nil, name: convo.nickname, size: 44, isGroup: convo.isGroup)
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
