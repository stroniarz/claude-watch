import SwiftUI

@main
struct ClaudeWatchApp: App {

    @StateObject private var sessionManager = WatchSessionManager.shared
    @StateObject private var relayService = RelayService.shared

    init() {
        WatchSessionManager.shared.onVoiceRequest = { request, reply in
            VoiceRelay.handle(request, reply: reply)
        }
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            OrkaPhoneRootView()
            .environmentObject(sessionManager)
            .environmentObject(relayService)
            .preferredColorScheme(.dark)
        }
    }
}
