import SwiftUI

struct NewGroupView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// Called with the new group id after creation.
    var onCreate: (String) -> Void

    @State private var name = ""
    @State private var query = ""
    @State private var results: [UserView] = []
    @State private var selected: [UserView] = []
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("Name", text: $name)
                }
                if !selected.isEmpty {
                    Section("Members (\(selected.count))") {
                        ForEach(selected) { user in
                            personRow(user, trailing: "minus.circle.fill", tint: .red) { toggle(user) }
                        }
                    }
                }
                Section("Add people") {
                    TextField("Search nickname", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: query) { _, q in runSearch(q) }
                    ForEach(results) { user in
                        personRow(user, trailing: "plus.circle", tint: .accentColor) {
                            toggle(user); query = ""; results = []
                        }
                    }
                }
            }
            .navigationTitle("New group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(creating || name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
            }
        }
    }

    private func personRow(_ user: UserView, trailing: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                AvatarView(photoKey: user.photoUrl, name: user.nickname, size: 28)
                Text(user.nickname)
                Spacer()
                Image(systemName: trailing).foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
    }

    private func runSearch(_ q: String) {
        Task {
            guard q.count >= 2 else { results = []; return }
            let found = await app.searchUsers(q)
            results = found.filter { u in !selected.contains(where: { $0.id == u.id }) }
        }
    }

    private func toggle(_ user: UserView) {
        if let idx = selected.firstIndex(of: user) { selected.remove(at: idx) }
        else { selected.append(user) }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        if let id = await app.createGroup(name: name.trimmingCharacters(in: .whitespaces),
                                          memberIDs: selected.map { $0.id }) {
            onCreate(id)
            dismiss()
        }
    }
}
