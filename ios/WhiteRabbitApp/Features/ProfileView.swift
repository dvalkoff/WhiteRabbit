import PhotosUI
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var photoKey: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var savingNick = false
    @State private var nickStatus: String?
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            AvatarView(photoKey: photoKey, name: nickname, size: 96)
                            PhotosPicker("Change photo", selection: $photoItem, matching: .images)
                                .font(.footnote)
                        }
                        Spacer()
                    }
                }

                Section("Nickname") {
                    TextField("Nickname", text: $nickname)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        Task { await saveNickname() }
                    } label: {
                        if savingNick { ProgressView() } else { Text("Save nickname") }
                    }
                    .disabled(savingNick || nickname.count < 3)
                    if let nickStatus { Text(nickStatus).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    Button("Change password") { showPassword = true }
                }

                Section {
                    Button("Log out", role: .destructive) { app.logout() }
                }
            }
            .navigationTitle("Profile")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showPassword) { ChangePasswordView() }
            .task {
                nickname = app.session?.nickname ?? ""
                if let me = await app.myProfile() { photoKey = me.photoUrl }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let jpeg = image.jpegData(compressionQuality: 0.85) {
                        await app.updatePhoto(jpeg)
                        if let me = await app.myProfile() { photoKey = me.photoUrl }
                    }
                }
            }
        }
    }

    private func saveNickname() async {
        savingNick = true
        defer { savingNick = false }
        nickStatus = await app.updateNickname(nickname) ?? "Saved"
    }
}

struct ChangePasswordView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                SecureField("Current password", text: $oldPassword)
                SecureField("New password (min 8)", text: $newPassword)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                Button {
                    Task { await change() }
                } label: {
                    if busy { ProgressView() } else { Text("Change password") }
                }
                .disabled(busy || oldPassword.isEmpty || newPassword.count < 8)
            }
            .navigationTitle("Change password")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func change() async {
        busy = true
        defer { busy = false }
        if let err = await app.changePassword(old: oldPassword, new: newPassword) {
            status = err
        } else {
            dismiss()
        }
    }
}
