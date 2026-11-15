import Foundation

// STR-1463 etap 2: kontakt wprost z Orką-orkiestratorką (sesja Claude), akcje z zegarka i głos voice-inbox.
// Michał 15.11: „tylko mój prawdziwy kontakt z Orką da porządne rozwiązanie… Orka może przekazywać dalej”.

/// Wynik akcji panelu (`/orka/napisz`, `/pokieruj`, `/bloker/odpowiedz`) — trzy jednoznaczne stany jak w panelu.
enum OrkaActionResult: Equatable, Sendable {
    case delivered(to: String?)
    case notSent(String)
    case unknown(String)

    var text: String {
        switch self {
        case .delivered(let to): return to.map { "Dostarczone do „\($0)”." } ?? "Dostarczone."
        case .notSent(let why): return why
        case .unknown(let why): return why
        }
    }

    var delivered: Bool { if case .delivered = self { return true } else { return false } }

    /// Odpowiedź HTTP 200 akcji → wynik. Błąd 4xx/5xx z `blad` → „Nie wysłano”, bo serwer odrzucił przed wysyłką.
    static func parse(status: Int, data: Data) -> OrkaActionResult {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = (json["blad"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (200..<300).contains(status) {
            if json["ok"] as? Bool == true, json["dostarczone"] as? Bool == true {
                return .delivered(to: json["do"] as? String)
            }
            if json["wynik_nieznany"] as? Bool == true {
                return .unknown(message ?? "Nie wiadomo, czy doszło — sprawdź w sesji.")
            }
            return .notSent(message ?? "Nie wysłano.")
        }
        if status == 0 { return .unknown("Brak odpowiedzi Maca — nie wiadomo, czy doszło. Sprawdź w sesji.") }
        return .notSent(message.map { $0.hasPrefix("Nie wysłano") ? $0 : "Nie wysłano: \($0)" } ?? "Nie wysłano (błąd \(status)).")
    }
}

struct OrkaReply: Codable, Equatable, Sendable {
    let ts: Double
    let tekst: String
    /// Nadawca wpisu w skrzynce zegarka (np. „orka”).
    let od: String?
}

struct OrkaReplies: Codable, Equatable, Sendable {
    let teraz: Double
    let odpowiedzi: [OrkaReply]
}

/// Ciała żądań akcji — w jednym miejscu, testowane (te same pola co panel).
enum OrkaActions {
    static let paths: Set<String> = ["orka/napisz", "pokieruj", "bloker/odpowiedz"]

    static func tellOrka(_ text: String, id: UUID = UUID()) -> [String: Any] {
        ["tekst": text, "potwierdzam": true, "id_akcji": id.uuidString.lowercased()]
    }

    static func reply(to session: OrkaCounters.Waiting, text: String, id: UUID = UUID()) -> [String: Any] {
        ["sesja_id": session.id ?? "", "konto": session.konto, "kanal_oczekiwany": session.kanal ?? "",
         "tekst": text, "potwierdzam": true, "id_akcji": id.uuidString.lowercased()]
    }

    static func answer(blocker nr: Int, text: String, id: UUID = UUID()) -> [String: Any] {
        ["nr": nr, "tekst": text, "potwierdzam": true, "id_akcji": id.uuidString.lowercased()]
    }

    /// Gotowe odpowiedzi dla czekającej sesji (jak w panelu).
    static let quickReplies = ["wdrażaj", "zmerguj", "ok, leć"]
}

extension HandsfreeClient {
    /// Akcja panelu: backend czeka do 42 s (napisz.py / bloker.py), więc klient 45 s.
    static let actionTimeout: TimeInterval = 45

    func action(_ path: String, body: [String: Any]) async -> OrkaActionResult {
        guard OrkaActions.paths.contains(path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return .notSent("Nieznana akcja.") }
        switch await callJSON("panel/api/" + path, method: "POST", body: data, timeout: Self.actionTimeout) {
        case .success(let reply):
            return OrkaActionResult.parse(status: 200, data: reply)
        case .failure(let f, let spoken):
            // Timeout/sieć po wysłaniu: nie wiemy, czy dotarło. Odmowa serwera (4xx z „blad”): na pewno nie wysłano.
            switch f {
            case .timeout, .noConnection: return .unknown("Brak odpowiedzi Maca — nie wiadomo, czy doszło. Sprawdź w sesji.")
            default: return .notSent(spoken.hasPrefix("Nie wysłano") ? spoken : "Nie wysłano: \(spoken)")
            }
        }
    }

    /// Wypowiedzi Orki po `since` (serwer czeka do `wait` s, najwyżej 8).
    func orkaReplies(since: Double, wait: Double) async -> Result<OrkaReplies, HandsfreeFailure> {
        let query = [URLQueryItem(name: "od", value: String(format: "%.6f", since)),
                     URLQueryItem(name: "czekaj", value: String(Int(min(max(wait, 0), 8))))]
        switch await callJSON("panel/api/orka/odpowiedzi", method: "GET", body: nil, timeout: min(wait, 8) + 8, query: query) {
        case .failure(let f, _): return .failure(f)
        case .success(let data):
            guard let replies = try? JSONDecoder().decode(OrkaReplies.self, from: data) else { return .failure(.server) }
            return .success(replies)
        }
    }

    /// Głos voice-inbox (`/panel/api/mow`, slug `voice-inbox`) → plik audio.
    func speech(_ text: String, voice: String = OrkaVoiceChoice.slug) async -> (data: Data, mime: String)? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["tekst": text, "glos": voice]) else { return nil }
        guard case .success(let reply) = await callJSON("panel/api/mow", method: "POST", body: body, timeout: 45),
              let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let b64 = json["audio_b64"] as? String, let audio = Data(base64Encoded: b64), !audio.isEmpty else { return nil }
        return (audio, json["mime"] as? String ?? "audio/mpeg")
    }

    /// Siri „Powiedz Orce”: wysyła do sesji orkiestratora i czeka do `wait` s na jej odpowiedź.
    func tellOrkaAndWait(_ text: String, wait: TimeInterval = 20) async -> String {
        let sentAt = Date().timeIntervalSince1970 - 2
        let result = await action("orka/napisz", body: OrkaActions.tellOrka(text))
        guard result.delivered else { return result.text }
        var since = sentAt
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let left = deadline.timeIntervalSinceNow
            guard case .success(let replies) = await orkaReplies(since: since, wait: min(8, max(0, left))) else { break }
            if !replies.odpowiedzi.isEmpty { return replies.odpowiedzi.map(\.tekst).joined(separator: " ") }
            since = max(since, sentAt)
        }
        return OrkaPhrases.sentNoReplyYet
    }
}

enum OrkaVoiceChoice {
    /// Głos z voice-inbox (ten sam co odpowiedzi w PWA); Michał 15.11: systemowy TTS „tragiczny”.
    static let slug = "voice-inbox"
}

extension OrkaPhrases {
    static let sentNoReplyYet = "Wysłałem do Orki. Jeszcze nie odpowiedziała — odpowiedź przyjdzie na zegarek i do voice-inbox."
}
