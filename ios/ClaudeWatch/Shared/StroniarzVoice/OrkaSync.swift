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
/// iPhone (budzony w tle) pobiera `/panel/api/zegarek` i odsyła liczniki przez
/// `transferCurrentComplicationUserInfo` — kanał przeznaczony dla komplikacji,
/// który budzi appkę zegarka. Zegarek zapisuje je w App Group i przeładowuje widget.
enum OrkaSync {
    static let refreshKey = "orkaRefresh"
    static let countersKey = "orkaCounters"
    /// Nie częściej niż co 10 min prosimy telefon w tle (budżet komplikacji: ok. 50/dobę).
    static let minRequestInterval: TimeInterval = 600

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
            if let counters = try? JSONDecoder().decode(OrkaCounters.self, from: data) {
                store(counters)
            }
            return true
        }
        #endif
        return false
    }

    #if os(iOS)
    /// iPhone: pobierz liczniki i wyślij je komplikacji.
    static func refreshForWatch(service: OrkaService = HandsfreeClient.fromSettings()) {
        let background = BackgroundTime.begin()
        Task {
            defer { background.end() }
            if case .success(let counters) = await service.counters() {
                pushToComplication(counters)
            }
        }
    }

    static func pushToComplication(_ counters: OrkaCounters) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(counters) else { return }
        let payload: [String: Any] = [countersKey: data]
        if session.isComplicationEnabled {
            session.transferCurrentComplicationUserInfo(payload)
        } else {
            session.transferUserInfo(payload)
        }
    }
    #endif

    #if os(watchOS)
    static let didUpdate = Notification.Name("OrkaSync.didUpdate")
    private static let lastRequestKey = "orka.lastBackgroundRequest"

    /// Zegarek: zapisz liczniki, przeładuj komplikację, powiadom ekran Orki.
    static func store(_ counters: OrkaCounters, fetchedAt: Date = Date()) {
        let snapshot = OrkaSnapshot(counters: counters, fetchedAt: fetchedAt)
        if let current = OrkaStore.load(), current.dataDate > snapshot.dataDate { return }   // nie cofamy się
        OrkaStore.save(snapshot)
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
        WCSession.default.transferUserInfo([refreshKey: now.timeIntervalSince1970])
    }
    #endif
}

/// Czas pracy w tle dla wywołania HTTPS po przebudzeniu przez zegarek (tylko iOS).
struct BackgroundTime: Sendable {
    #if os(iOS)
    let id: UIBackgroundTaskIdentifier

    static func begin() -> BackgroundTime {
        // Testy jednostkowe działają bez appki (brak UIApplication).
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return BackgroundTime(id: .invalid) }
        // Wywołanie z wątku WCSession: beginBackgroundTask jest bezpieczne wątkowo.
        return BackgroundTime(id: UIApplication.shared.beginBackgroundTask(withName: "StroniarzRelay"))
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
