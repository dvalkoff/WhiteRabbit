import SwiftUI

struct GroupInfoView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let groupID: String
    /// Called when the user leaves the group (so the parent can pop the chat).
    var onLeave: () -> Void

    @State private var query = ""
    @State private var results: [UserView] = []

    private var convo: Conversation? { app.chatStore.conversation(groupID) }
    private var memberIDs: [String] { convo?.memberIDs ?? [] }
    private var myID: String { app.session?.userID ?? "" }

    var body: some View {
        NavigationStack {
            List {
                Section("Members (\(memberIDs.count))") {
                    ForEach(memberIDs, id: \.self) { id in
                        memberRow(id)
                    }
                }

                Section("Add people") {
                    TextField("Search nickname", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: query) { _, q in runSearch(q) }
                    ForEach(results) { user in
                        addRow(user)
                    }
                }

                Section {
                    Button("Leave group", role: .destructive) {
                        Task {
                            await app.removeGroupMember(groupID: groupID, userID: myID)
                            dismiss(); onLeave()
                        }
                    }
                }
            }
            .navigationTitle(convo?.nickname ?? "Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func memberRow(_ id: String) -> some View {
        let title = app.chatStore.nickname(for: id) + (id == myID ? " (you)" : "")
        return HStack {
            AvatarView(photoKey: nil, name: app.chatStore.nickname(for: id), size: 32)
            Text(title)
            Spacer()
            if id != myID {
                Button { Task { await app.removeGroupMember(groupID: groupID, userID: id) } } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addRow(_ user: UserView) -> some View {
        Button {
            Task { await app.addGroupMember(groupID: groupID, user: user); query = ""; results = [] }
        } label: {
            HStack {
                AvatarView(photoKey: user.photoUrl, name: user.nickname, size: 28)
                Text(user.nickname)
                Spacer()
                Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.plain)
    }

    private func runSearch(_ q: String) {
        Task {
            guard q.count >= 2 else { results = []; return }
            let found = await app.searchUsers(q)
            results = found.filter { !memberIDs.contains($0.id) }
        }
    }
}
