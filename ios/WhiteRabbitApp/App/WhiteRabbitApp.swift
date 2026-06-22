import SwiftUI

enum AppConfig {
    /// Backend base URL. For the iOS Simulator, localhost reaches the host Mac.
    /// Override via the WR_BASE_URL environment variable when needed.
    static var baseURL: URL {
        if let s = ProcessInfo.processInfo.environment["WR_BASE_URL"], let u = URL(string: s) {
            return u
        }
        return URL(string: "http://localhost:8080")!
    }
}

@main
struct WhiteRabbitApp: App {
    @StateObject private var app = AppState(baseURL: AppConfig.baseURL)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.callManager)
        }
    }
}
