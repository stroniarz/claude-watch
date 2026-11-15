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

    static let unknownText = "Brak pewnej odpowiedzi Maca — nie wiadomo, czy doszło. Sprawdź w sesji, zanim wyślesz ponownie."

    /// Odpowiedź HTTP akcji → wynik. „Nie wysłano” tylko gdy pewne: 2xx z `dostarczone: false` albo odmowa
    /// walidacji 4xx (przed wykonaniem). 5xx, brak odpowiedzi i nieczytelne 2xx → „nie wiadomo” (review r1).
    static func parse(status: Int, data: Data) -> OrkaActionResult {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["blad"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (200..<300).contains(status), let json {
            if json["ok"] as? Bool == true, json["dostarczone"] as? Bool == true {
                return .delivered(to: json["do"] as? String)
            }
            if json["dostarczone"] as? Bool == false {
                return .notSent(message ?? "Nie wysłano.")
            }
            return .unknown(message ?? unknownText)
        }
        if (400..<500).contains(status) {
            return .notSent(message.map { $0.hasPrefix("Nie wysłano") ? $0 : "Nie wysłano: \($0)" } ?? "Nie wysłano (błąd \(status)).")
        }
        return .unknown(unknownText)
    }
}

struct OrkaReply: Codable, Equatable, Sendable {
    /// Rosnący numer wpisu w skrzynce zegarka — kursor (nie czas).
    let nr: Int
    let ts: Double
    let tekst: String
    /// Nadawca wpisu w skrzynce zegarka (np. „orka”).
    let od: String?
}

struct OrkaReplies: Codable, Equatable, Sendable {
    /// Największy numer w skrzynce (do ustawienia kursora bez czytania historii).
    let ostatni: Int
    /// Najstarsze najpierw, najwyżej 10.
    let odpowiedzi: [OrkaReply]
}

/// Ciała żądań akcji — w jednym miejscu, testowane (te same pola co panel).
enum OrkaActions {
    static let paths: Set<String> = ["orka/napisz", "pokieruj", "bloker/odpowiedz"]

    static func tellOrka(_ text: String, source: String = "zegarek", id: UUID = UUID()) -> [String: Any] {
        ["tekst": text, "zrodlo": source, "potwierdzam": true, "id_akcji": id.uuidString.lowercased()]
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
        guard let baseURL, let token else { return .notSent("Nie wysłano: " + HandsfreeFailure.notConfigured.phrase) }
        var request = URLRequest(url: baseURL.appendingPathComponent("panel/api/" + path), timeoutInterval: Self.actionTimeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let config = session.configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        config.timeoutIntervalForRequest = Self.actionTimeout
        config.timeoutIntervalForResource = Self.actionTimeout
        let actionSession = URLSession(configuration: config)
        defer { actionSession.finishTasksAndInvalidate() }
        do {
            let (reply, response) = try await actionSession.data(for: request)
            return OrkaActionResult.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: reply)
        } catch let error as URLError where error.code == .cannotFindHost || error.code == .cannotConnectToHost
                    || error.code == .notConnectedToInternet || error.code == .dnsLookupFailed {
            // Nie połączono się w ogóle — na pewno nie wysłano.
            return .notSent("Nie wysłano: " + VoicePhrases.noConnection)
        } catch {
            return .unknown(OrkaActionResult.unknownText)
        }
    }

    /// Wpisy skrzynki zegarka o numerze > `after` (serwer czeka do `wait` s, najwyżej 8).
    /// `after` = nil: tylko `ostatni` (ustawienie kursora bez historii).
    func orkaReplies(after: Int?, wait: Double) async -> Result<OrkaReplies, HandsfreeFailure> {
        var query = [URLQueryItem(name: "czekaj", value: String(Int(min(max(wait, 0), 8))))]
        if let after { query.append(URLQueryItem(name: "po", value: String(after))) }
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
        // Kursor PRZED wysłaniem: odpowiedź Orki będzie miała większy numer.
        guard case .success(let start) = await orkaReplies(after: nil, wait: 0) else {
            return VoicePhrases.noConnection
        }
        let result = await action("orka/napisz", body: OrkaActions.tellOrka(text, source: "siri"))
        guard result.delivered else { return result.text }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let left = deadline.timeIntervalSinceNow
            guard case .success(let replies) = await orkaReplies(after: start.ostatni, wait: min(8, max(0, left))) else { break }
            if !replies.odpowiedzi.isEmpty { return replies.odpowiedzi.map(\.tekst).joined(separator: " ") }
        }
        return OrkaPhrases.sentNoReplyYet
    }
}

enum OrkaVoiceChoice {
    /// Głos z voice-inbox (ten sam co odpowiedzi w PWA); Michał 15.11: systemowy TTS „tragiczny”.
    static let slug = "voice-inbox"
}

extension OrkaPhrases {
    static let sentNoReplyYet = "Wysłałem do Orki. Jeszcze nie odpowiedziała — jej odpowiedź zobaczysz w rozmowie z Orką na zegarku."
}
