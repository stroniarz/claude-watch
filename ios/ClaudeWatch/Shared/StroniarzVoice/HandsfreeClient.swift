import Foundation

/// Why a handsfree call did not produce an answer. Every case maps to a
/// sentence that Siri can say; some of them end the conversation.
enum HandsfreeFailure: String, Error, Equatable {
    case notConfigured
    case noConnection
    case timeout
    case unauthorized
    case tooMany
    case server
    case noPhone

    var phrase: String {
        switch self {
        case .notConfigured: return VoicePhrases.notConfigured
        case .noConnection:  return VoicePhrases.noConnection
        case .timeout:       return VoicePhrases.timeout
        case .unauthorized:  return VoicePhrases.unauthorized
        case .tooMany:       return VoicePhrases.tooMany
        case .server:        return VoicePhrases.serverError
        case .noPhone:       return VoicePhrases.noPhone
        }
    }

    /// No point asking "Coś jeszcze?" when the next question would fail the same way.
    var endsConversation: Bool {
        switch self {
        case .notConfigured, .noConnection, .unauthorized, .noPhone: return true
        case .timeout, .tooMany, .server: return false
        }
    }
}

/// Result of one call: either text to read out or a failure.
enum HandsfreeOutcome: Equatable {
    case answer(String)
    case failure(HandsfreeFailure, spoken: String)

    static func failure(_ f: HandsfreeFailure) -> HandsfreeOutcome { .failure(f, spoken: f.phrase) }

    var spoken: String {
        switch self {
        case .answer(let text): return text
        case .failure(_, let text): return text
        }
    }

    var failure: HandsfreeFailure? {
        if case .failure(let f, _) = self { return f }
        return nil
    }
}

/// The three handsfree endpoints. Implemented over HTTPS (iPhone, or the watch
/// when the Mac is publicly reachable) and over WCSession (watch → iPhone).
protocol HandsfreeService: Sendable {
    func ping() async -> HandsfreeOutcome
    func brief() async -> HandsfreeOutcome
    func ask(_ text: String, conversationID: String?) async -> HandsfreeOutcome
}

/// HTTPS client for `voice_inbox.handsfree` (STR-1279).
struct HandsfreeClient: HandsfreeService {
    static let timeout: TimeInterval = 12

    let baseURL: URL?
    let token: String?
    let session: URLSession

    init(baseURL: URL?, token: String?, session: URLSession = HandsfreeClient.makeSession()) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Client configured from the app settings (Keychain token).
    static func fromSettings() -> HandsfreeClient {
        HandsfreeClient(baseURL: HandsfreeSettings.baseURL, token: HandsfreeSettings.token)
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    func ping() async -> HandsfreeOutcome { await call("ping", method: "GET", body: nil) }

    func brief() async -> HandsfreeOutcome { await call("brief", method: "GET", body: nil) }

    func ask(_ text: String, conversationID: String?) async -> HandsfreeOutcome {
        var payload: [String: String] = ["text": text]
        if let conversationID { payload["conversation_id"] = conversationID }
        let body = try? JSONSerialization.data(withJSONObject: payload)
        return await call("ask", method: "POST", body: body)
    }

    // MARK: - Private

    private func call(_ path: String, method: String, body: Data?) async -> HandsfreeOutcome {
        guard let baseURL, let token else { return .failure(.notConfigured) }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.outcome(status: status, text: text)
        } catch {
            return .failure(Self.failure(for: error))
        }
    }

    static func outcome(status: Int, text: String) -> HandsfreeOutcome {
        switch status {
        case 200..<300:
            return text.isEmpty ? .failure(.server) : .answer(text)
        case 401, 403:
            return .failure(.unauthorized)
        case 429:
            // Server distinguishes "too many questions" from "locked after bad tokens".
            return .failure(.tooMany, spoken: text.isEmpty ? VoicePhrases.tooMany : text)
        case 413:
            return .failure(.server, spoken: text.isEmpty ? VoicePhrases.serverError : text)
        default:
            // Something between the phone and the service (e.g. tailscale serve
            // with the service down) answers with HTML, not a sentence.
            if status >= 500, !text.isEmpty, !text.hasPrefix("<"), text.count < 400 {
                return .failure(.server, spoken: text)
            }
            return status == 502 || status == 503 || status == 504 ? .failure(.noConnection) : .failure(.server)
        }
    }

    static func failure(for error: Error) -> HandsfreeFailure {
        guard let urlError = error as? URLError else { return .noConnection }
        switch urlError.code {
        case .timedOut:
            return .timeout
        default:
            return .noConnection
        }
    }
}
