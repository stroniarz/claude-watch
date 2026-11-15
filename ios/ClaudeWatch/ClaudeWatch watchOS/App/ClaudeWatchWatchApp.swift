import SwiftUI

// MARK: - Design Tokens (watchOS)

enum Theme {
    enum Background {
        static let primary = Color(hex: "000000")
        static let capture = Color(hex: "1a2233")
        static let overlay = Color(hex: "1a1a1a")
    }

    enum Text {
        static let primary = Color(hex: "E87A35")
        static let secondary = Color(hex: "666666")
        static let dimmed = Color(hex: "555555")
    }

    enum Accent {
        static let success = Color(hex: "34C759")
        static let error = Color(hex: "FF3B30")
        static let approval = Color(hex: "E8A735")
    }
}

// MARK: - App Entry Point

@main
struct ClaudeWatchWatchApp: App {
    @StateObject private var sessionManager = WatchViewState.shared
    @StateObject private var orka = OrkaModel.shared
    /// Nowe id resetuje nawigację do ekranu Orki (dotknięcie komplikacji).
    @State private var rootID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                OrkaHomeView(model: orka)
            }
            .id(rootID)
            .environmentObject(sessionManager)
            .onOpenURL { url in
                if url.scheme == "stroniarz", url.host == "orka" { rootID = UUID() }
            }
            .onAppear { OrkaBackground.schedule() }
            .onChange(of: scenePhase) { _, phase in
                // Powrót z tarczy (np. po dotknięciu komplikacji): świeże liczniki bez ponownego otwierania widoku.
                if phase == .active { Task { await orka.refresh() } }
            }
        }
        .backgroundTask(.appRefresh(OrkaBackground.task)) {
            await OrkaBackground.run()
        }
    }
}

/// Dotychczasowy ekran Agent Watch (sesje Claude/Codex przez bridge), teraz pod „Sesje Claude”.
struct LegacyRootView: View {
    @EnvironmentObject private var sessionManager: WatchViewState

    var body: some View {
        if sessionManager.isPaired {
            MultiSessionPager()
        } else {
            OnboardingView()
        }
    }
}
