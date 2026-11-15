import Foundation
import WatchConnectivity

/// Watch → iPhone relay for the handsfree API over WCSession.
///
/// The watch has no Tailscale, so by default it asks the iPhone, which makes the
/// HTTPS call and replies with the outcome. The message uses its own top-level
/// key instead of `WatchMessage`, because it needs a real reply payload.
enum VoiceRelay {
    static let requestKey = "stroniarzVoice"
    static let configKey = "stroniarzVoiceConfig"

    enum Op: String {
        case ping, brief, ask
        /// STR-1463: liczniki panelu Orki i rozmowa z Orką.
        case zegarek, orka
    }

    /// Klucz odpowiedzi z licznikami (JSON `OrkaCounters` jako Data).
    static let countersKey = "counters"

    static func encode(_ result: Result<OrkaCounters, HandsfreeFailure>) -> [String: Any] {
        switch result {
        case .success(let counters):
            guard let data = try? JSONEncoder().encode(counters) else { return encode(HandsfreeOutcome.failure(.server)) }
            return [countersKey: data]
        case .failure(let f):
            return encode(HandsfreeOutcome.failure(f))
        }
    }

    static func decodeCounters(_ reply: [String: Any]) -> Result<OrkaCounters, HandsfreeFailure> {
        if let data = reply[countersKey] as? Data,
           let counters = try? JSONDecoder().decode(OrkaCounters.self, from: data) {
            return .success(counters)
        }
        if let raw = reply["failure"] as? String { return .failure(HandsfreeFailure(rawValue: raw) ?? .server) }
        return .failure(.server)
    }

    static func encode(_ outcome: HandsfreeOutcome) -> [String: Any] {
        switch outcome {
        case .answer(let text):
            return ["text": text]
        case .failure(let f, let text):
            return ["text": text, "failure": f.rawValue]
        }
    }

    static func decode(_ reply: [String: Any]) -> HandsfreeOutcome {
        let text = reply["text"] as? String ?? ""
        if let raw = reply["failure"] as? String {
            let f = HandsfreeFailure(rawValue: raw) ?? .server
            return .failure(f, spoken: text.isEmpty ? f.phrase : text)
        }
        return text.isEmpty ? .failure(.server) : .answer(text)
    }

    #if os(iOS)
    /// iPhone side: answer a relayed request with the HTTPS client.
    static func handle(_ request: [String: Any], reply: @escaping @Sendable ([String: Any]) -> Void,
                       service: HandsfreeService & OrkaService = HandsfreeClient.fromSettings()) {
        // Extract plain values before the Task: [String: Any] is not Sendable.
        let op = Op(rawValue: request["op"] as? String ?? "")
        let text = request["text"] as? String ?? ""
        let conversationID = request["conversation_id"] as? String
        // Zegarek budzi appkę w tle: poproś system o czas na wywołanie HTTPS.
        let background = BackgroundTime.begin()
        Task {
            defer { background.end() }
            switch op {
            case .ping:    reply(encode(await service.ping()))
            case .brief:   reply(encode(await service.brief()))
            case .ask:     reply(encode(await service.ask(text, conversationID: conversationID)))
            case .orka:    reply(encode(await service.askOrka(text)))
            case .zegarek: reply(encode(await service.counters()))
            case nil:     reply(encode(HandsfreeOutcome.failure(.server)))
            }
        }
    }

    /// Sends base URL and token to the watch for the direct (public URL) mode.
    static func pushConfigToWatch() -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              let token = HandsfreeSettings.token else { return false }
        WCSession.default.transferUserInfo([configKey: [
            "baseURL": HandsfreeSettings.baseURLString,
            "token": token,
        ]])
        return true
    }
    #endif

    #if os(watchOS)
    /// Watch side: store config pushed from the iPhone.
    static func applyConfig(_ config: [String: Any]) {
        if let base = config["baseURL"] as? String { HandsfreeSettings.baseURLString = base }
        if let token = config["token"] as? String { HandsfreeSettings.token = token }
    }
    #endif
}

#if os(watchOS)
/// Watch: relay through the iPhone when it is reachable, otherwise call the
/// Mac directly if the watch has a config (only works with a public URL).
struct RelayHandsfreeService: HandsfreeService {
    static let timeout: TimeInterval = 16

    func ping() async -> HandsfreeOutcome { await send(.ping) }
    func brief() async -> HandsfreeOutcome { await send(.brief) }
    func ask(_ text: String, conversationID: String?) async -> HandsfreeOutcome {
        await send(.ask, text: text, conversationID: conversationID)
    }

    private func send(_ op: VoiceRelay.Op, text: String = "", conversationID: String? = nil) async -> HandsfreeOutcome {
        let timeout = op == .orka ? HandsfreeClient.orkaTimeout + 4 : Self.timeout
        switch await relay(op, text: text, conversationID: conversationID, timeout: timeout) {
        case .reply(let reply): return reply.outcome
        case .timedOut:         return .failure(.timeout)
        case .unavailable:      return await direct(op, text: text, conversationID: conversationID)
        }
    }

    /// Odpowiedź iPhone'a zdekodowana od razu w wątku WCSession ([String: Any] nie jest Sendable).
    struct RelayReply: Sendable {
        let outcome: HandsfreeOutcome
        let counters: Result<OrkaCounters, HandsfreeFailure>

        init(_ reply: [String: Any]) {
            outcome = VoiceRelay.decode(reply)
            counters = VoiceRelay.decodeCounters(reply)
        }
    }

    enum RelayResult: Sendable {
        case reply(RelayReply)
        case timedOut
        case unavailable
    }

    /// Wysyła prośbę do iPhone'a; `unavailable` = telefon poza zasięgiem albo błąd WCSession.
    private func relay(_ op: VoiceRelay.Op, text: String, conversationID: String?,
                       timeout: TimeInterval) async -> RelayResult {
        let session = WCSession.default
        await Self.ensureActivated(session)
        guard session.activationState == .activated, session.isReachable else { return .unavailable }
        var payload: [String: Any] = ["op": op.rawValue, "text": text]
        if let conversationID { payload["conversation_id"] = conversationID }
        let message: [String: Any] = [VoiceRelay.requestKey: payload]
        return await withCheckedContinuation { (cont: CheckedContinuation<RelayResult, Never>) in
            let once = Once(cont)
            session.sendMessage(message, replyHandler: { once.resume(.reply(RelayReply($0))) },
                                errorHandler: { _ in once.resume(.unavailable) })
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.timedOut) }
        }
    }

    /// A Siri launch may run the intent before any view has activated WCSession.
    private static func ensureActivated(_ session: WCSession) async {
        guard session.activationState != .activated else { return }
        WatchSessionManager.shared.activate()
        for _ in 0..<20 where session.activationState != .activated {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func direct(_ op: VoiceRelay.Op, text: String, conversationID: String?) async -> HandsfreeOutcome {
        guard HandsfreeSettings.isConfigured else { return .failure(.noPhone) }
        let client = HandsfreeClient.fromSettings()
        switch op {
        case .ping:    return await client.ping()
        case .brief:   return await client.brief()
        case .ask:     return await client.ask(text, conversationID: conversationID)
        case .orka:    return await client.askOrka(text)
        case .zegarek: return .failure(.server)   // liczniki idą przez counters()
        }
    }
}

extension RelayHandsfreeService: OrkaService {
    /// Serwer czeka na świeży stan do 8 s, iPhone dokłada sieć.
    static let countersTimeout: TimeInterval = HandsfreeClient.countersTimeout + 4

    func counters() async -> Result<OrkaCounters, HandsfreeFailure> {
        switch await relay(.zegarek, text: "", conversationID: nil, timeout: Self.countersTimeout) {
        case .reply(let reply): return reply.counters
        case .timedOut:         return .failure(.timeout)
        case .unavailable:
            guard HandsfreeSettings.isConfigured else { return .failure(.noPhone) }
            return await HandsfreeClient.fromSettings().counters()
        }
    }

    func askOrka(_ text: String) async -> HandsfreeOutcome { await send(.orka, text: text) }
}

/// Resumes a continuation at most once (reply vs. error vs. timeout race).
private final class Once<Value: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<Value, Never>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<Value, Never>) { self.cont = cont }

    func resume(_ value: Value) {
        let c = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { cont = nil }
            return cont
        }
        c?.resume(returning: value)
    }
}
#endif

/// The service and cue the intents use on this platform.
enum VoiceEnvironment {
    static func service() -> HandsfreeService {
        #if os(watchOS)
        return RelayHandsfreeService()
        #else
        return HandsfreeClient.fromSettings()
        #endif
    }

    static func cue() -> ThinkingCue {
        #if os(iOS)
        return HandsfreeSettings.thinkingCue ? SpeechThinkingCue() : SilentThinkingCue()
        #else
        return SilentThinkingCue()
        #endif
    }
}
