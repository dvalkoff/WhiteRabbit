import SwiftUI

struct NewChatView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// Called when a person is picked. The parent dismisses this sheet and opens
    /// the chat in the main navigation stack.
    var onSelect: (UserView) -> Void

    @State private var query = ""
    @State private var results: [UserView] = []

    var body: some View {
        NavigationStack {
            List(results) { user in
                Button {
                    onSelect(user)
                    dismiss()
                } label: {
                    HStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 36, height: 36)
                            .overlay(Text(user.nickname.prefix(1).uppercased()))
                        Text(user.nickname)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView("Find people",
                                           systemImage: "magnifyingglass",
                                           description: Text("Search by nickname to start a chat."))
                }
            }
            .searchable(text: $query, prompt: "Search people")
            .onChange(of: query) { _, newValue in
                Task { results = await app.searchUsers(newValue) }
            }
            .navigationTitle("New chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
