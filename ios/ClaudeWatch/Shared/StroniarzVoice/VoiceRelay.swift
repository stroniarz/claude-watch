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
                       service: HandsfreeService = HandsfreeClient.fromSettings()) {
        // Extract plain values before the Task: [String: Any] is not Sendable.
        let op = Op(rawValue: request["op"] as? String ?? "")
        let text = request["text"] as? String ?? ""
        let conversationID = request["conversation_id"] as? String
        Task {
            let outcome: HandsfreeOutcome
            switch op {
            case .ping:  outcome = await service.ping()
            case .brief: outcome = await service.brief()
            case .ask:   outcome = await service.ask(text, conversationID: conversationID)
            case nil:    outcome = .failure(.server)
            }
            reply(encode(outcome))
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
        let session = WCSession.default
        await Self.ensureActivated(session)
        guard session.activationState == .activated, session.isReachable else {
            return await direct(op, text: text, conversationID: conversationID)
        }
        var payload: [String: Any] = ["op": op.rawValue, "text": text]
        if let conversationID { payload["conversation_id"] = conversationID }
        let message: [String: Any] = [VoiceRelay.requestKey: payload]
        let relayed = await withCheckedContinuation { (cont: CheckedContinuation<HandsfreeOutcome?, Never>) in
            let once = Once(cont)
            session.sendMessage(message, replyHandler: { once.resume(VoiceRelay.decode($0)) },
                                errorHandler: { _ in once.resume(nil) })
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { once.resume(.failure(.timeout)) }
        }
        if let relayed { return relayed }
        return await direct(op, text: text, conversationID: conversationID)
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
        case .ping:  return await client.ping()
        case .brief: return await client.brief()
        case .ask:   return await client.ask(text, conversationID: conversationID)
        }
    }
}

/// Resumes a continuation at most once (reply vs. error vs. timeout race).
private final class Once: @unchecked Sendable {
    private var cont: CheckedContinuation<HandsfreeOutcome?, Never>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<HandsfreeOutcome?, Never>) { self.cont = cont }

    func resume(_ value: HandsfreeOutcome?) {
        let c = lock.withLock { () -> CheckedContinuation<HandsfreeOutcome?, Never>? in
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
