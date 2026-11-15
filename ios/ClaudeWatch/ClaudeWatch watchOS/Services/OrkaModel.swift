import AVFoundation
import Foundation
import WatchKit

/// Stan ekranu Orki na zegarku (STR-1463): liczniki z panelu i rozmowa.
@MainActor
final class OrkaModel: ObservableObject {
    static let shared = OrkaModel()

    enum Talk: Equatable {
        case idle
        case thinking(question: String)
        case answer(question: String, text: String, failed: Bool)
    }

    @Published private(set) var snapshot: OrkaSnapshot? = OrkaStore.load()
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var talk: Talk = .idle
    @Published private(set) var speaking = false

    private let service: OrkaService
    private let voice = OrkaVoice()
    private var observer: NSObjectProtocol?
    private var askGeneration = 0

    init(service: OrkaService = RelayHandsfreeService()) {
        self.service = service
        voice.onFinish = { [weak self] in Task { @MainActor in self?.speaking = false } }
        observer = NotificationCenter.default.addObserver(forName: OrkaSync.didUpdate, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.snapshot = OrkaStore.load() }
        }
        #if DEBUG
        loadPreview()
        #endif
    }

    #if DEBUG
    /// Podgląd w symulatorze (zrzuty dla Michała): `SIMCTL_CHILD_ORKA_SEED=<plik JSON z /zegarek>`,
    /// opcjonalnie `SIMCTL_CHILD_ORKA_TALK="pytanie|odpowiedź"`. W buildzie Release tego nie ma.
    static var preview: Bool { ProcessInfo.processInfo.environment["ORKA_SEED"] != nil }

    private func loadPreview() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ORKA_SEED"], let data = FileManager.default.contents(atPath: path),
              let counters = try? JSONDecoder().decode(OrkaCounters.self, from: data) else { return }
        OrkaSync.store(counters, fetchedAt: Date())
        snapshot = OrkaStore.load()
        if let talk = env["ORKA_TALK"]?.split(separator: "|", maxSplits: 1), talk.count == 2 {
            self.talk = .answer(question: String(talk[0]), text: String(talk[1]), failed: false)
        }
    }
    #endif

    // MARK: - Liczniki

    /// Pobiera liczniki przez iPhone'a; bez telefonu zostawia ostatnie i prosi o nie w tle.
    func refresh() async {
        #if DEBUG
        if Self.preview { return }
        #endif
        guard !loading else { return }
        loading = true
        defer { loading = false }
        switch await service.counters() {
        case .success(let counters):
            OrkaSync.store(counters)
            snapshot = OrkaStore.load()
            error = nil
        case .failure(let failure):
            error = failure.phrase
            OrkaSync.requestInBackground()
        }
    }

    // MARK: - Rozmowa

    func ask(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        voice.stop()
        askGeneration += 1
        let generation = askGeneration
        talk = .thinking(question: question)
        WKInterfaceDevice.current().play(.start)
        Task {
            let outcome = await service.askOrka(question)
            guard generation == askGeneration else { return }   // nowsze pytanie albo „Zakończ”
            talk = .answer(question: question, text: outcome.spoken, failed: outcome.failure != nil)
            WKInterfaceDevice.current().play(outcome.failure == nil ? .success : .failure)
            speak(outcome.spoken)
        }
    }

    func speak(_ text: String) {
        speaking = true
        voice.say(text)
    }

    func stopSpeaking() {
        voice.stop()
        speaking = false
    }

    func endTalk() {
        askGeneration += 1
        stopSpeaking()
        talk = .idle
    }
}

/// Odpowiedź Orki głosem systemowym pl-PL (głos z panelu, `/mow`, to etap 2).
final class OrkaVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.polishVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// Najlepszy dostępny polski głos (rozszerzony, jeśli pobrany), inaczej domyślny pl-PL.
    static var polishVoice: AVSpeechSynthesisVoice? {
        let polish = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "pl-PL" }
        return polish.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "pl-PL")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onFinish?() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onFinish?() }
}

/// Odświeżanie liczników w tle (budżet watchOS: zwykle kilka razy na godzinę przy komplikacji na tarczy).
enum OrkaBackground {
    static let task = "orka-refresh"
    static let interval: TimeInterval = 15 * 60

    static func schedule(after interval: TimeInterval = OrkaBackground.interval) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval), userInfo: task as NSString) { _ in }
    }

    /// Zadanie tła: najpierw „na żywo” przez iPhone'a, a gdy się nie da — prośba w kolejce WCSession.
    static func run() async {
        defer { schedule() }
        switch await RelayHandsfreeService().counters() {
        case .success(let counters): OrkaSync.store(counters)
        case .failure: OrkaSync.requestInBackground()
        }
    }
}
