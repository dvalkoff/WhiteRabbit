import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.session == nil {
            AuthView()
        } else {
            ChatListView()
        }
    }
}
