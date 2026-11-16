import Foundation

/// Wraps a slow call with an audible "Myślę" (see `SpeechThinkingCue`).
protocol ThinkingCue: Sendable {
    func around(_ operation: @Sendable () async -> HandsfreeOutcome) async -> HandsfreeOutcome
}

struct SilentThinkingCue: ThinkingCue {
    func around(_ operation: @Sendable () async -> HandsfreeOutcome) async -> HandsfreeOutcome {
        await operation()
    }
}

/// One spoken turn: what to do with an utterance and what to say back.
struct ConversationTurn: Equatable {
    let spoken: String
    let ended: Bool
}

/// The conversation loop, independent of Siri so it can be unit-tested.
///
/// `listen(prompt)` says the prompt and returns the next utterance — in the
/// intent that is `$question.requestValue(IntentDialog(prompt))`.
struct ConversationEngine: Sendable {
    let service: HandsfreeService
    var cue: ThinkingCue = SilentThinkingCue()
    var maxTurns = 8
    var conversationID = UUID().uuidString

    /// Handles one utterance. Used by the loop below and by the Shortcuts action.
    func respond(to utterance: String) async -> ConversationTurn {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return ConversationTurn(spoken: VoicePhrases.didNotHear, ended: false) }
        if VoicePhrases.isEnd(text) { return ConversationTurn(spoken: VoicePhrases.goodbye, ended: true) }
        let outcome: HandsfreeOutcome
        if VoicePhrases.isBrief(text) {
            outcome = await cue.around { await service.brief() }
        } else {
            let id = conversationID
            outcome = await cue.around { await service.ask(text, conversationID: id) }
        }
        return ConversationTurn(spoken: outcome.spoken, ended: outcome.failure?.endsConversation ?? false)
    }

    /// Runs the whole conversation and returns the closing sentence.
    func run(first: String?, listen: (String) async throws -> String) async throws -> String {
        var utterance: String
        if let first, !first.trimmingCharacters(in: .whitespaces).isEmpty {
            utterance = first
        } else {
            utterance = try await listen(VoicePhrases.listening)
        }
        for turn in 1...maxTurns {
            let reply = await respond(to: utterance)
            if reply.ended { return reply.spoken }
            if turn == maxTurns { return "\(reply.spoken) \(VoicePhrases.turnLimit)" }
            let prompt = reply.spoken == VoicePhrases.didNotHear
                ? reply.spoken
                : "\(reply.spoken) \(VoicePhrases.anythingElse)"
            utterance = try await listen(prompt)
        }
        return VoicePhrases.goodbye
    }
}

/// Keeps one conversation id alive across separate Shortcuts action runs, so
/// follow-ups ("a Yard?") reach the server with the same context.
actor ConversationStore {
    static let shared = ConversationStore()

    private let idleTimeout: TimeInterval
    private var current: (id: String, lastUsed: Date)?

    init(idleTimeout: TimeInterval = 180) {
        self.idleTimeout = idleTimeout
    }

    func conversationID(now: Date = Date()) -> String {
        if let current, now.timeIntervalSince(current.lastUsed) < idleTimeout {
            self.current = (current.id, now)
            return current.id
        }
        let id = UUID().uuidString
        current = (id, now)
        return id
    }

    func end() { current = nil }
}
