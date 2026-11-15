import Foundation
import WatchConnectivity
#if os(iOS)
import UIKit
#endif
#if os(watchOS)
import WidgetKit
#endif

/// Liczniki Orki w tle (STR-1463), gdy zegarek nie może zapytać „na żywo”.
///
/// Zegarek w zadaniu odświeżania wysyła `transferUserInfo([refreshKey: …])`.
/// iPhone odbiera ją, gdy appka działa (nie ma gwarancji, że system obudzi ją w tle
/// dla transferUserInfo — budzi tylko sendMessage), pobiera `/panel/api/zegarek` i odsyła liczniki przez
/// `transferCurrentComplicationUserInfo` — kanał przeznaczony dla komplikacji,
/// który budzi appkę zegarka. Zegarek zapisuje je w App Group i przeładowuje widget.
enum OrkaSync {
    static let refreshKey = "orkaRefresh"
    static let countersKey = "orkaCounters"
    /// Nie częściej niż co 30 min prosimy telefon w tle: najwyżej 48/dobę przy budżecie
    /// komplikacji ok. 50/dobę (po jego wyczerpaniu iPhone wysyła zwykłe transferUserInfo).
    static let minRequestInterval: TimeInterval = 1800

    /// Obsługuje userInfo Orki; `true` = wiadomość była nasza.
    @discardableResult
    static func handleUserInfo(_ userInfo: [String: Any]) -> Bool {
        #if os(iOS)
        if userInfo[refreshKey] != nil {
            refreshForWatch()
            return true
        }
        #endif
        #if os(watchOS)
        if let data = userInfo[countersKey] as? Data {
            // Snapshot z datą danych wyliczoną na iPhonie: paczka mogła czekać w kolejce godzinami.
            if let snapshot = try? JSONDecoder().decode(OrkaSnapshot.self, from: data) {
                store(snapshot)
            }
            return true
        }
        #endif
        return false
    }

    #if os(iOS)
    private static let refreshLock = NSLock()
    nonisolated(unsafe) private static var lastRefresh = Date.distantPast

    /// iPhone: pobierz liczniki i wyślij je komplikacji (prośby z kolejki łączone: najwyżej co 60 s).
    static func refreshForWatch(service: OrkaService = HandsfreeClient.fromSettings(), now: Date = Date()) {
        let go = refreshLock.withLock { () -> Bool in
            guard now.timeIntervalSince(lastRefresh) >= 60 else { return false }
            lastRefresh = now
            return true
        }
        guard go else { return }
        let background = BackgroundTime.begin()
        Task {
            defer { background.end() }
            if case .success(let counters) = await service.counters(), counters.wiekS != nil {
                pushToComplication(counters)
            }
        }
    }

    static func pushToComplication(_ counters: OrkaCounters) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(OrkaSnapshot(counters: counters)) else { return }
        let payload: [String: Any] = [countersKey: data]
        if session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(payload)
        } else {
            session.transferUserInfo(payload)
        }
    }
    #endif

    #if os(watchOS)
    static let didUpdate = Notification.Name("OrkaSync.didUpdate")
    private static let lastRequestKey = "orka.lastBackgroundRequest"
    /// store() woła ekran (MainActor), zadanie tła i delegat WCSession: odczyt–porównanie–zapis pod blokadą.
    private static let storeLock = NSLock()

    /// Zegarek: zapisz liczniki pobrane przed chwilą.
    static func store(_ counters: OrkaCounters, fetchedAt: Date = Date()) {
        store(OrkaSnapshot(counters: counters, fetchedAt: fetchedAt))
    }

    /// Zegarek: zapisz snapshot (nie cofamy się do starszych danych), przeładuj komplikację, powiadom ekran.
    static func store(_ snapshot: OrkaSnapshot) {
        let saved = storeLock.withLock { () -> Bool in
            if let current = OrkaStore.load(), current.dataDate > snapshot.dataDate { return false }
            OrkaStore.save(snapshot)
            return true
        }
        guard saved else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: OrkaStore.widgetKind)
        NotificationCenter.default.post(name: didUpdate, object: nil)
    }

    /// Zegarek bez połączenia „na żywo”: poproś iPhone'a o liczniki przez kolejkę WCSession.
    static func requestInBackground(now: Date = Date()) {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastRequestKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= minRequestInterval,
              WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        defaults.set(now, forKey: lastRequestKey)
        // Jeśli iPhone nie odebrał poprzednich próśb (appka niebudzona), nie piętrzymy ich w kolejce.
        WCSession.default.outstandingUserInfoTransfers
            .filter { $0.userInfo[refreshKey] != nil }
            .forEach { $0.cancel() }
        WCSession.default.transferUserInfo([refreshKey: now.timeIntervalSince1970])
    }
    #endif
}

#if os(iOS)
private final class BackgroundIDBox: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
}
#endif

/// Czas pracy w tle dla wywołania HTTPS po przebudzeniu przez zegarek (tylko iOS).
struct BackgroundTime: Sendable {
    #if os(iOS)
    let id: UIBackgroundTaskIdentifier

    static func begin() -> BackgroundTime {
        // Testy jednostkowe działają bez appki (brak UIApplication).
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return BackgroundTime(id: .invalid) }
        // Wywołanie z wątku WCSession: beginBackgroundTask jest bezpieczne wątkowo.
        let box = BackgroundIDBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "StroniarzRelay") {
            // Czas się skończył: oddaj zadanie, inaczej iOS zamknie appkę.
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        return BackgroundTime(id: box.id)
    }

    func end() {
        guard id != .invalid else { return }
        let id = self.id
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
    }
    #else
    static func begin() -> BackgroundTime { BackgroundTime() }
    func end() {}
    #endif
}
