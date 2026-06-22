import SwiftUI

/// Picks a conversation to forward selected messages into.
struct ForwardPickerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List(app.chatStore.conversations) { convo in
                Button {
                    onPick(convo.peerID)
                    dismiss()
                } label: {
                    HStack {
                        AvatarView(photoKey: convo.isGroup ? nil : app.chatStore.photoKey(for: convo.peerID),
                                   name: convo.nickname, size: 36, isGroup: convo.isGroup)
                        Text(convo.nickname)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle("Forward to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
