import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        Group {
            if app.session == nil {
                AuthView()
            } else {
                ChatListView()
            }
        }
        // Calls surface over everything (incoming or outgoing). Presentation is
        // driven entirely by call state; the setter is a no-op so SwiftUI's
        // dismiss doesn't loop back into endLocally().
        .fullScreenCover(isPresented: Binding(
            get: { callManager.phase != .idle },
            set: { _ in }
        )) {
            CallView()
        }
    }
}
