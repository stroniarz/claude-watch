import Combine
import SwiftUI
import UIKit

@MainActor
final class OrkaPhoneConnection: ObservableObject {
    @Published private(set) var state: OrkaPhoneAvailability = .checking
    @Published private(set) var settingsNote = "Uzupełnij adres Maca i token w Ustawieniach."
    private var generation = UUID()

    /// `quiet`: ponowne sprawdzenie (powrót z tła, zmiana zakładki) nie podmienia gotowej treści na „sprawdzam” —
    /// to kasowało stos nawigacji, arkusz potwierdzenia i WebView (review r1). Stan zmienia się dopiero przy błędzie.
    func check(quiet: Bool = false) async {
        let id = UUID()
        generation = id
        if !(quiet && state == .ready) { state = .checking }
        guard let base = OrkaPhoneEndpoint.baseURL(HandsfreeSettings.baseURL),
              let token = HandsfreeSettings.token else {
            settingsNote = "Ustaw adres HTTPS Maca w domenie .ts.net i zapisz token w Keychain."
            state = .needsSettings
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8  // całe ping(); zimny start Tailscale On Demand potrzebuje kilku sekund
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let result = await HandsfreeClient(baseURL: base, token: token, session: session).ping()
        guard generation == id, !Task.isCancelled else { return }
        settingsNote = "Mac odrzucił dostęp. Sprawdź token w Ustawieniach."
        state = .afterPing(result)
    }
}

struct OrkaPhoneRootView: View {
    private enum Tab { case orka, panel, agent, settings }
    @EnvironmentObject private var relayService: RelayService
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = OrkaPhoneConnection()
    @StateObject private var orka = OrkaPhoneModel()
    @State private var selection: Tab = OrkaPhoneRootView.initialTab
    @State private var redirectedToSettings = false

    /// Debug: `SIMCTL_CHILD_ORKA_TAB=panel` otwiera od razu zakładkę (zrzuty). W Release zawsze Orka.
    private static var initialTab: Tab {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["ORKA_TAB"] {
        case "panel": return .panel
        case "agent": return .agent
        case "ustawienia": return .settings
        default: return .orka
        }
        #else
        return .orka
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            connectedContent {
                OrkaPhoneHomeView(model: orka, active: selection == .orka && scenePhase != .background)
            }
            .tabItem { Label("Orka", systemImage: "bubble.left.and.bubble.right") }.tag(Tab.orka)

            connectedContent {
                OrkaPhonePanelView(active: selection == .panel && scenePhase != .background,
                                   retry: { Task { await connection.check() } },
                                   openSettings: { selection = .settings })
            }
            .tabItem { Label("Panel", systemImage: "rectangle.3.group") }.tag(Tab.panel)

            Group {
                if relayService.isPaired { ConnectionStatusView() } else { PairingView() }
            }
            .tabItem { Label("Agent", systemImage: "terminal") }.tag(Tab.agent)

            NavigationStack {
                VoiceSettingsView()
                    .safeAreaInset(edge: .top) {
                        if connection.state == .needsSettings {
                            Text(connection.settingsNote).font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding().background(.regularMaterial)
                        }
                    }
            }
                .tabItem { Label("Ustawienia", systemImage: "gearshape") }.tag(Tab.settings)
        }
        .task {
            // Użytkownik samego mostka Claude (bez tokenu Orki) startuje w zakładce Agent, nie w Ustawieniach.
            if relayService.isPaired, !HandsfreeSettings.isConfigured, selection == .orka { selection = .agent }
            await connection.check()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await connection.check(quiet: true) } }
        }
        .onChange(of: selection) { old, new in
            // Ciche sprawdzenie: wyjście z Ustawień nie niszczy stosu Orki ani panelu (review r2).
            if old == .settings && new != .settings { Task { await connection.check(quiet: true) } }
        }
        .onChange(of: connection.state) { _, state in
            // Najwyżej raz na uruchomienie i tylko z zakładek Orki — Agent i Ustawienia zostają osiągalne.
            if state == .needsSettings, !redirectedToSettings, selection == .orka || selection == .panel {
                redirectedToSettings = true
                selection = .settings
            }
        }
    }

    @ViewBuilder
    private func connectedContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        switch connection.state {
        case .ready: content()
        case .checking:
            ProgressView("Sprawdzam połączenie z Makiem…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsSettings:
            ContentUnavailableView {
                Label("Skonfiguruj połączenie", systemImage: "key")
            } description: {
                Text(connection.settingsNote)
            } actions: {
                Button("Otwórz Ustawienia") { selection = .settings }.buttonStyle(.borderedProminent)
                Button("Spróbuj ponownie") { Task { await connection.check() } }
            }
        case .offline:
            OrkaPhoneOfflineView(retry: { Task { await connection.check() } },
                                 openSettings: { selection = .settings })
        }
    }
}

struct OrkaPhoneOfflineView: View {
    let retry: () -> Void
    let openSettings: () -> Void
    @Environment(\.openURL) private var openURL
    private let tailscaleURL = URL(string: "tailscale://")!

    var body: some View {
        ContentUnavailableView {
            Label("Brak połączenia z Makiem", systemImage: "network.slash")
        } description: {
            Text("Włącz Tailscale na iPhonie i upewnij się, że Mac jest obudzony. W Tailscale wybierz: Ustawienia → VPN On Demand → zawsze.")
        } actions: {
            Button("Spróbuj ponownie", action: retry).buttonStyle(.borderedProminent)
            if UIApplication.shared.canOpenURL(tailscaleURL) {
                Button("Otwórz Tailscale") { openURL(tailscaleURL) }
            }
            Button("Ustawienia połączenia", action: openSettings)
        }
    }
}
