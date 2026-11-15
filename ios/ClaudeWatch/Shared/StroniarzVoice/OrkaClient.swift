import Foundation

/// Panel Orki dla zegarka (STR-1463): liczniki i rozmowa z Orką.
/// Na iPhonie przez HTTPS (`HandsfreeClient`), na zegarku przez iPhone'a (relay).
protocol OrkaService: Sendable {
    func counters() async -> Result<OrkaCounters, HandsfreeFailure>
    func askOrka(_ text: String) async -> HandsfreeOutcome
}

enum OrkaPhrases {
    /// Propozycja T3 żyje tylko w odpowiedzi HTTP (panel jej nie przechowuje), więc z zegarka
    /// nie ma czego „potwierdzić w panelu”: prosimy o powtórzenie zlecenia w panelu.
    static let noOrdersFromWatch = "Zleceń nie uruchamiam z zegarka. Powiedz to samo w panelu Orki, tam je potwierdzisz."
    static let emptyAnswer = "Orka nic nie odpowiedziała. Spróbuj jeszcze raz."
}

extension HandsfreeClient: OrkaService {
    /// Serwer czeka na świeży stan do 8 s, więc liczniki mają dłuższy limit niż /ask.
    static let countersTimeout: TimeInterval = 14
    /// Orka (T2) to wywołanie modelu: serwer daje mu do 60 s, zegarek czeka krócej.
    static let orkaTimeout: TimeInterval = 28

    func counters() async -> Result<OrkaCounters, HandsfreeFailure> {
        switch await callJSON("panel/api/zegarek", method: "GET", body: nil, timeout: Self.countersTimeout) {
        case .failure(let f, _):
            return .failure(f)
        case .success(let data):
            guard let counters = try? JSONDecoder().decode(OrkaCounters.self, from: data) else {
                return .failure(.server)
            }
            return .success(counters)
        }
    }

    func askOrka(_ text: String) async -> HandsfreeOutcome {
        let body = try? JSONSerialization.data(withJSONObject: ["tekst": text])
        switch await callJSON("panel/api/jarvis", method: "POST", body: body, timeout: Self.orkaTimeout) {
        case .failure(let f, let spoken):
            return .failure(f, spoken: spoken)
        case .success(let data):
            return Self.orkaOutcome(data)
        }
    }

    /// Odpowiedź `/panel/api/jarvis` → zdanie do przeczytania. T3 („zleć …”)
    /// nigdy nie jest uruchamiane ani potwierdzane z zegarka.
    static func orkaOutcome(_ data: Data) -> HandsfreeOutcome {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.server)
        }
        let proposal = json["propozycja"].map { !($0 is NSNull) } ?? false
        if json["poziom"] as? String == "T3" || proposal { return .answer(OrkaPhrases.noOrdersFromWatch) }
        let text = (json["tekst"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(.server, spoken: OrkaPhrases.emptyAnswer) }
        return .answer(text)
    }

    // MARK: - JSON

    enum JSONResult {
        case success(Data)
        case failure(HandsfreeFailure, spoken: String)
    }

    private func callJSON(_ path: String, method: String, body: Data?, timeout: TimeInterval) async -> JSONResult {
        guard let baseURL, let token else { return .failure(.notConfigured, spoken: HandsfreeFailure.notConfigured.phrase) }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        do {
            let longer = longerSession(timeout)
            defer { longer?.finishTasksAndInvalidate() }
            let (data, response) = try await (longer ?? session).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.jsonResult(status: status, data: data)
        } catch {
            let f = Self.failure(for: error)
            return .failure(f, spoken: f.phrase)
        }
    }

    /// Statusy jak w `outcome(status:text:)`; komunikat błędu z pola `blad`.
    static func jsonResult(status: Int, data: Data) -> JSONResult {
        if (200..<300).contains(status) { return .success(data) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["blad"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch outcome(status: status, text: message) {
        case .failure(let f, let spoken): return .failure(f, spoken: spoken)
        case .answer: return .failure(.server, spoken: VoicePhrases.serverError)
        }
    }
}

private extension HandsfreeClient {
    /// Sesja klienta ma limit 12 s; dłuższe wywołania idą kopią jej konfiguracji
    /// z większym limitem (kopia zachowuje też atrapę `protocolClasses` w testach).
    func longerSession(_ timeout: TimeInterval) -> URLSession? {
        guard session.configuration.timeoutIntervalForResource < timeout,
              let config = session.configuration.copy() as? URLSessionConfiguration else { return nil }
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }
}
