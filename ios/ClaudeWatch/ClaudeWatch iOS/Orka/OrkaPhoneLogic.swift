import Foundation

/// Reguły iPhone'a są osobne od klienta zegarka i intentów.
enum OrkaPhoneEndpoint {
    static func baseURL(_ url: URL?) -> URL? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host?.lowercased(),
              host.hasSuffix(".ts.net"), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        return url
    }

    static func panelURL(baseURL: URL?, token: String?) -> URL? {
        guard let base = self.baseURL(baseURL), let token, !token.isEmpty,
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/panel"
        // Token jest wartością fragmentu, nigdy query, ścieżki ani nagłówka nawigacji.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        parts.percentEncodedFragment = "t=" + (token.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        return parts.url
    }

    static func sameOrigin(_ url: URL?, as base: URL) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host?.lowercased() == base.host?.lowercased()
            && (url.port ?? 443) == (base.port ?? 443) && url.user == nil && url.password == nil
    }
}

enum OrkaPhoneAvailability: Equatable {
    case checking, ready, needsSettings, offline

    static func afterPing(_ outcome: HandsfreeOutcome) -> Self {
        switch outcome {
        case .answer: return .ready
        case .failure(.notConfigured, _), .failure(.unauthorized, _): return .needsSettings
        case .failure: return .offline
        }
    }
}

/// Wartość tworzona przy dotknięciu: odświeżenie listy nie zmienia celu ani id akcji.
struct OrkaPhoneAction: Identifiable {
    enum Target {
        case session(OrkaCounters.Waiting)
        case blocker(OrkaCounters.Blocker)
    }
    let id: UUID
    let target: Target
    let text: String
    /// Adres Maca, z którego pochodzi cel — akcja nie pójdzie do innego Maca po zmianie Ustawień (review Codex r3).
    let base: String

    init?(target: Target, text: String, id: UUID = UUID(), base: String = HandsfreeSettings.baseURLString) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        switch target {
        case .session(let session):
            guard session.id?.isEmpty == false, session.kanal?.isEmpty == false else { return nil }
        case .blocker(let blocker):
            guard blocker.mozna, blocker.typ != "sekret" else { return nil }
        }
        self.id = id
        self.target = target
        self.text = clean
        self.base = base
    }

    var title: String {
        switch target {
        case .session(let session):
            // Nazwy sesji się powtarzają (kilka w jednym katalogu) — dokładamy issue i cel.
            return ["Sesja „\(session.nazwa)”", session.issue, "konto \(session.konto)", session.kanal]
                .compactMap { $0 }.joined(separator: " · ")
        case .blocker(let blocker): return "Bloker #\(blocker.nr) · \(blocker.sesja)"
        }
    }

    /// Klucz celu (ten sam dla kolejnych akcji do tej samej sesji/blokera).
    var targetKey: String { Self.key(target) }

    static func key(_ target: Target) -> String {
        switch target {
        case .session(let s): return "s:\(s.konto):\(s.id ?? s.nazwa)"
        case .blocker(let b): return "b:\(b.nr)"
        }
    }

    var path: String {
        switch target {
        case .session: return "pokieruj"
        case .blocker: return "bloker/odpowiedz"
        }
    }

    var body: [String: Any] {
        switch target {
        case .session(let session): return OrkaActions.reply(to: session, text: text, id: id)
        case .blocker(let blocker): return OrkaActions.answer(blocker: blocker.nr, text: text, id: id)
        }
    }
}

struct OrkaPhoneConversation: Codable {
    struct Line: Identifiable, Codable, Equatable {
        enum Who: String, Codable { case me, orka, info }
        var id = UUID()
        let who: Who
        let text: String
    }

    static let replyWindow: TimeInterval = 180
    var cursor: Int?
    var lines: [Line] = []
    var waitingUntil: Date?

    mutating func append(_ who: Line.Who, _ text: String) {
        lines.append(Line(who: who, text: text))
        lines = Array(lines.suffix(60))
    }

    /// Kursor jest numerem, nie czasem. Po resecie skrzynki kolejny odczyt zaczyna od zera.
    @discardableResult
    mutating func receive(_ replies: OrkaReplies) -> [String] {
        guard let current = cursor else {
            cursor = replies.ostatni  // pierwsze wejście: bez czytania starej historii
            return []
        }
        if replies.ostatni < current { cursor = 0 }
        var received: [String] = []
        for reply in replies.odpowiedzi.sorted(by: { $0.nr < $1.nr }) where reply.nr > (cursor ?? 0) {
            cursor = reply.nr
            append(.orka, reply.tekst)
            received.append(reply.tekst)
        }
        return received
    }
}
