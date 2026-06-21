import SwiftUI

struct AuthView: View {
    @EnvironmentObject var app: AppState
    @State private var nickname = ""
    @State private var password = ""
    @State private var isRegistering = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("WhiteRabbit")
                .font(.largeTitle.bold())
            Text("End-to-end encrypted messenger")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("Nickname", text: $nickname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            if let err = app.authError {
                Text(err).foregroundStyle(.red).font(.footnote)
            }

            Button {
                Task {
                    if isRegistering {
                        await app.register(nickname: nickname, password: password)
                    } else {
                        await app.login(nickname: nickname, password: password)
                    }
                }
            } label: {
                if app.isBusy {
                    ProgressView()
                } else {
                    Text(isRegistering ? "Create account" : "Log in")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.isBusy || nickname.count < 3 || password.count < 8)
            .padding(.horizontal)

            Button(isRegistering ? "Have an account? Log in" : "New here? Create account") {
                isRegistering.toggle()
                app.authError = nil
            }
            .font(.footnote)

            Spacer()
        }
        .padding()
    }
}
