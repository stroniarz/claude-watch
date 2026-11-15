import Foundation

/// Liczniki panelu Orki z `GET /panel/api/zegarek` (STR-1463).
///
/// Plik jest samodzielny: kompiluje się też w rozszerzeniu widgetów zegarka,
/// które nie ma reszty modułu StroniarzVoice.
struct OrkaCounters: Codable, Equatable, Sendable {
    struct Waiting: Codable, Equatable, Sendable {
        let nazwa: String
        let issue: String?
        let konto: String
    }

    struct Limit: Codable, Equatable, Sendable {
        let konto: String
        let proc: Int
    }

    let czas: String
    /// Sekundy od ostatniego odświeżenia stanu na Macu w chwili odpowiedzi.
    let wiekS: Int?
    let czeka: Int
    let pracuje: Int
    let blokery: Int
    /// Gotowe szkice do klientów („ogony”).
    let ogony: Int
    let ogonyOtwarte: Int
    let limity: [String: Int]
    let limit: Limit?
    let czekajace: [Waiting]
    let zdanie: String
    let bledy: Int

    enum CodingKeys: String, CodingKey {
        case czas, czeka, pracuje, blokery, ogony, limity, limit, czekajace, zdanie, bledy
        case wiekS = "wiek_s"
        case ogonyOtwarte = "ogony_otwarte"
    }

    init(czas: String = "", wiekS: Int? = nil, czeka: Int = 0, pracuje: Int = 0, blokery: Int = 0,
         ogony: Int = 0, ogonyOtwarte: Int = 0, limity: [String: Int] = [:], limit: Limit? = nil,
         czekajace: [Waiting] = [], zdanie: String = "", bledy: Int = 0) {
        self.czas = czas
        self.wiekS = wiekS
        self.czeka = czeka
        self.pracuje = pracuje
        self.blokery = blokery
        self.ogony = ogony
        self.ogonyOtwarte = ogonyOtwarte
        self.limity = limity
        self.limit = limit
        self.czekajace = czekajace
        self.zdanie = zdanie
        self.bledy = bledy
    }

    /// Odporne dekodowanie: brakujące pola = zero, żeby nowsza/starsza wersja serwera nie psuła tarczy.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        czas = (try? c.decode(String.self, forKey: .czas)) ?? ""
        wiekS = try? c.decodeIfPresent(Int.self, forKey: .wiekS)
        czeka = (try? c.decode(Int.self, forKey: .czeka)) ?? 0
        pracuje = (try? c.decode(Int.self, forKey: .pracuje)) ?? 0
        blokery = (try? c.decode(Int.self, forKey: .blokery)) ?? 0
        ogony = (try? c.decode(Int.self, forKey: .ogony)) ?? 0
        ogonyOtwarte = (try? c.decode(Int.self, forKey: .ogonyOtwarte)) ?? 0
        limity = (try? c.decode([String: Int].self, forKey: .limity)) ?? [:]
        limit = try? c.decodeIfPresent(Limit.self, forKey: .limit)
        czekajace = (try? c.decode([Waiting].self, forKey: .czekajace)) ?? []
        zdanie = (try? c.decode(String.self, forKey: .zdanie)) ?? ""
        bledy = (try? c.decode(Int.self, forKey: .bledy)) ?? 0
    }

    /// „1 szkic”, „2 szkice”, „5 szkiców”, „22 szkice”.
    var draftsText: String { "\(ogony) " + Self.odmiana(ogony, "szkic", "szkice", "szkiców") }

    static func odmiana(_ n: Int, _ jeden: String, _ kilka: String, _ wiele: String) -> String {
        if n == 1 { return jeden }
        if (2...4).contains(n % 10), !(12...14).contains(n % 100) { return kilka }
        return wiele
    }

    /// Krótki zapis limitu: „k2 97%”, albo nil bez danych.
    var limitShort: String? { limit.map { "k\($0.konto) \($0.proc)%" } }
}

/// Liczniki z chwilą, z której pochodzą dane (nie chwilą pobrania).
struct OrkaSnapshot: Codable, Equatable, Sendable {
    let counters: OrkaCounters
    /// Kiedy Mac ostatnio odświeżył stan: chwila pobrania minus `wiek_s`.
    let dataDate: Date

    init(counters: OrkaCounters, fetchedAt: Date = Date()) {
        self.counters = counters
        self.dataDate = fetchedAt.addingTimeInterval(-TimeInterval(max(0, counters.wiekS ?? 0)))
    }

    /// Dane starsze niż 2 h tarcza pokazuje wyszarzone.
    static let staleAfter: TimeInterval = 2 * 3600

    func isStale(at now: Date = Date()) -> Bool { now.timeIntervalSince(dataDate) > Self.staleAfter }

    /// „teraz”, „5 min”, „2 h”, „3 dni”.
    func ageText(at now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(dataDate)))
        switch s {
        case ..<60: return "teraz"
        case ..<3600: return "\(s / 60) min"
        case ..<86400: return "\(s / 3600) h"
        default:
            let d = s / 86400
            return d == 1 ? "1 dzień" : "\(d) dni"
        }
    }
}

/// Wspólny magazyn appki zegarka i widgetu (App Group). JSON pod jednym kluczem.
enum OrkaStore {
    static let appGroup = "group.pl.stroniarz.claudewatch"
    static let key = "orka.snapshot.v1"
    static let widgetKind = "OrkaCounters"

    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func load() -> OrkaSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(OrkaSnapshot.self, from: data)
    }

    static func save(_ snapshot: OrkaSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}
