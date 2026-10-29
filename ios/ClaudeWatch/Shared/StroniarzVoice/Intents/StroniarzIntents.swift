import AppIntents
import Foundation

/// "Rozmawiaj ze Stroniarzem": a loop of Siri dialogs inside one `perform()`.
/// Siri does the dictation (`requestValue`), so it works from the lock screen.
struct ConverseIntent: AppIntent {
    static let title: LocalizedStringResource = "Rozmawiaj ze Stroniarzem"
    static let description = IntentDescription(
        "Rozmowa głosowa ze Stroniarzem: pytanie, odpowiedź, „Coś jeszcze?”. Powiedz „koniec”, żeby skończyć.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Pytanie", requestValueDialog: IntentDialog("Słucham."))
    var question: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = ConversationEngine(service: VoiceEnvironment.service(), cue: VoiceEnvironment.cue())
        let closing: String
        do {
            closing = try await engine.run(first: question) { prompt in
                try await $question.requestValue(IntentDialog(stringLiteral: prompt))
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            // Silence or "anuluj" while Siri was listening.
            closing = VoicePhrases.goodbye
        }
        return .result(dialog: IntentDialog(stringLiteral: closing))
    }
}

/// "Raport Stroniarz": reads /brief.
struct BriefIntent: AppIntent {
    static let title: LocalizedStringResource = "Raport Stroniarz"
    static let description = IntentDescription("Czyta raport: ogony do klientów, decyzje, sesje, skrzynki.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await VoiceEnvironment.service().brief().spoken
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// Building block for a personal shortcut that does Polish dictation and Polish
/// speech itself ("Dyktuj tekst" → this → "Powiedz tekst"). Returns text only,
/// no dialog, so Siri does not read the answer twice.
struct AskStroniarzIntent: AppIntent {
    static let title: LocalizedStringResource = "Zapytaj Stroniarza"
    static let description = IntentDescription(
        "Wysyła pytanie do Stroniarza i zwraca odpowiedź do przeczytania. „Raport” czyta raport, Koniec rozmowy (np. „dzięki”, brak połączenia) kończy się zdaniem „Do usłyszenia.”. Kolejne pytania w ciągu 3 minut są jedną rozmową.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Pytanie")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Zapytaj Stroniarza: \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = await ConversationStore.shared.conversationID()
        let engine = ConversationEngine(service: VoiceEnvironment.service(), conversationID: id)
        let turn = await engine.respond(to: text)
        guard turn.ended else { return .result(value: turn.spoken) }
        await ConversationStore.shared.end()
        // The shortcut stops its loop on "Do usłyszenia" (see docs/stroniarz-voice.md).
        let closing = turn.spoken == VoicePhrases.goodbye ? turn.spoken : "\(turn.spoken) \(VoicePhrases.goodbye)"
        return .result(value: closing)
    }
}

/// "Test połączenia" from Shortcuts/Siri: /ping.
struct PingStroniarzIntent: AppIntent {
    static let title: LocalizedStringResource = "Sprawdź połączenie ze Stroniarzem"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await VoiceEnvironment.service().ping().spoken
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// Siri phrases. Each must contain the app name (CFBundleDisplayName = "Stroniarz").
/// Siri has no Polish, so English phrases are listed too; the Polish wording
/// ("Rozmawiaj ze Stroniarzem") works best as a personal shortcut name.
struct StroniarzShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConverseIntent(),
            phrases: [
                "Rozmawiaj z \(.applicationName)",
                "\(.applicationName) rozmowa",
                "Talk to \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Rozmowa",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: BriefIntent(),
            phrases: [
                "Raport \(.applicationName)",
                "\(.applicationName) raport",
                "\(.applicationName) report",
            ],
            shortTitle: "Raport",
            systemImageName: "list.bullet.rectangle"
        )
    }
}
