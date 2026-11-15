import AVFoundation
import Combine
import Foundation
import WatchConnectivity
import WatchKit

/// Stan appki zegarka (STR-1463): liczniki, rozmowa z Orką-orkiestratorką, szybkie pytanie do panelu, akcje.
@MainActor
final class OrkaModel: ObservableObject {
    static let shared = OrkaModel()

    /// Szybkie pytanie do asystenta panelu (czyta tablice; odpowiada od razu).
    enum Talk: Equatable {
        case idle
        case thinking(question: String)
        case answer(question: String, text: String, failed: Bool)
    }

    /// Jedna wypowiedź w rozmowie z Orką-orkiestratorką.
    struct Line: Identifiable, Equatable {
        enum Who { case me, orka, info }
        let id = UUID()
        let who: Who
        let text: String
    }

    enum ChatStatus: Equatable {
        case idle
        case sending
        case waiting(since: Date)
        case failed(String)
    }

    @Published private(set) var snapshot: OrkaSnapshot? = OrkaStore.load()
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var talk: Talk = .idle
    @Published private(set) var chat: [Line] = []
    @Published private(set) var chatStatus: ChatStatus = .idle
    @Published private(set) var speaking = false
    @Published private(set) var voiceNote: String?

    private let service: RelayHandsfreeService
    private let player = OrkaPlayer()
    private var observers: [NSObjectProtocol] = []
    private var askGeneration = 0
    private var chatGeneration = 0
    /// Odpowiedzi Orki po tej chwili (epoch Maca ≈ zegarka; oba z NTP).
    private var repliesSince: Double = 0
    /// Głos, na który czekamy (id prośby do iPhone'a) i czy grać go od razu.
    private var awaitedAudio: String?
    private var lastAudio: URL?

    /// Ile czekamy na odpowiedź Orki po ostatniej wiadomości (Orka bywa zajęta albo restartuje mostek).
    static let replyWindow: TimeInterval = 180

    init(service: RelayHandsfreeService = RelayHandsfreeService()) {
        self.service = service
        player.onFinish = { [weak self] in Task { @MainActor in self?.speaking = false } }
        observers.append(NotificationCenter.default.addObserver(forName: OrkaSync.didUpdate, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.snapshot = OrkaStore.load() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: OrkaAudio.didArrive, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["id"] as? String
            let url = note.userInfo?["url"] as? URL
            Task { @MainActor in self?.audioArrived(id: id, url: url) }
        })
        #if DEBUG
        loadPreview()
        #endif
    }

    #if DEBUG
    /// Podgląd w symulatorze (zrzuty dla Michała): `SIMCTL_CHILD_ORKA_SEED=<plik JSON z /zegarek>`,
    /// opcjonalnie `ORKA_TALK="pytanie|odpowiedź"` (szybkie pytanie) albo `ORKA_CHAT="ja|Orka"` (rozmowa z Orką).
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
        if let pair = env["ORKA_CHAT"]?.split(separator: "|", maxSplits: 1), pair.count == 2 {
            chat = [Line(who: .me, text: String(pair[0])), Line(who: .orka, text: String(pair[1]))]
        }
    }
    #endif

    // MARK: - Liczniki

    /// Pobiera liczniki przez iPhone'a; bez telefonu zostawia ostatnie i prosi o nie w tle.
    /// `fresh`: przed akcją — serwer odświeża stan sesji, bo akcje odmawiają przy stanie > 2 min.
    func refresh(fresh: Bool = false) async {
        #if DEBUG
        if Self.preview { return }
        #endif
        guard !loading else { return }
        loading = true
        defer { loading = false }
        switch await service.counters(fresh: fresh) {
        case .success(let counters) where counters.wiekS == nil:
            error = "Mac jeszcze zbiera stan panelu. Spróbuj za chwilę."
        case .success(let counters):
            OrkaSync.store(counters)
            snapshot = OrkaStore.load()
            error = nil
        case .failure(let failure):
            error = failure.phrase
            OrkaSync.requestInBackground()
        }
    }

    // MARK: - Rozmowa z Orką-orkiestratorką

    /// Wiadomość wprost do sesji orkiestratora; potem czekamy na jej `speak` i czytamy go głosem voice-inbox.
    func tellOrka(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatGeneration += 1
        let generation = chatGeneration
        chat.append(Line(who: .me, text: text))
        chatStatus = .sending
        WKInterfaceDevice.current().play(.start)
        if repliesSince == 0 { repliesSince = Date().timeIntervalSince1970 - 5 }
        Task {
            let result = await service.action("orka/napisz", body: OrkaActions.tellOrka(text))
            guard generation == chatGeneration else { return }
            switch result {
            case .delivered:
                WKInterfaceDevice.current().play(.click)
                chatStatus = .waiting(since: Date())
                await pollReplies(generation: generation)
            case .notSent(let why), .unknown(let why):
                WKInterfaceDevice.current().play(.failure)
                chatStatus = .failed(why)
            }
        }
    }

    private func pollReplies(generation: Int) async {
        let deadline = Date().addingTimeInterval(Self.replyWindow)
        var misses = 0
        while generation == chatGeneration, Date() < deadline {
            switch await service.orkaReplies(since: repliesSince, wait: 8) {
            case .success(let replies):
                misses = 0
                guard generation == chatGeneration else { return }
                guard !replies.odpowiedzi.isEmpty else { continue }
                repliesSince = max(repliesSince, replies.odpowiedzi.map(\.ts).max() ?? repliesSince)
                for reply in replies.odpowiedzi { chat.append(Line(who: .orka, text: reply.tekst)) }
                WKInterfaceDevice.current().play(.notification)
                chatStatus = .idle
                speak(replies.odpowiedzi.map(\.tekst).joined(separator: " "))
                return
            case .failure(let failure):
                misses += 1
                if misses >= 3 {
                    chatStatus = .failed(failure.phrase)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if generation == chatGeneration, case .waiting = chatStatus {
            chat.append(Line(who: .info, text: "Orka jeszcze nie odpowiedziała. Odpowiedź usłyszysz w voice-inbox; tu zobaczysz ją po ponownym otwarciu rozmowy."))
            chatStatus = .idle
        }
    }

    /// Po ponownym wejściu w rozmowę: dociągnij to, co Orka powiedziała w międzyczasie.
    func catchUpReplies() {
        guard repliesSince > 0, chatStatus == .idle else { return }
        chatGeneration += 1
        let generation = chatGeneration
        Task {
            guard case .success(let replies) = await service.orkaReplies(since: repliesSince, wait: 0),
                  generation == chatGeneration, !replies.odpowiedzi.isEmpty else { return }
            repliesSince = max(repliesSince, replies.odpowiedzi.map(\.ts).max() ?? repliesSince)
            for reply in replies.odpowiedzi { chat.append(Line(who: .orka, text: reply.tekst)) }
        }
    }

    func leaveChat() {
        chatGeneration += 1
        if case .waiting = chatStatus { chatStatus = .idle }
        stopSpeaking()
    }

    // MARK: - Szybkie pytanie (asystent panelu)

    func ask(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        stopSpeaking()
        askGeneration += 1
        let generation = askGeneration
        talk = .thinking(question: question)
        WKInterfaceDevice.current().play(.start)
        Task {
            let outcome = await service.askOrka(question)
            guard generation == askGeneration else { return }   // nowsze pytanie albo wyjście
            talk = .answer(question: question, text: outcome.spoken, failed: outcome.failure != nil)
            WKInterfaceDevice.current().play(outcome.failure == nil ? .success : .failure)
            speak(outcome.spoken)
        }
    }

    func endTalk() {
        askGeneration += 1
        stopSpeaking()
        talk = .idle
    }

    // MARK: - Akcje (szybkie odpowiedzi sesjom, blokery)

    func reply(to session: OrkaCounters.Waiting, text: String) async -> OrkaActionResult {
        let result = await service.action("pokieruj", body: OrkaActions.reply(to: session, text: text))
        WKInterfaceDevice.current().play(result.delivered ? .success : .failure)
        if result.delivered { Task { await refresh() } }
        return result
    }

    func answer(blocker nr: Int, text: String) async -> OrkaActionResult {
        let result = await service.action("bloker/odpowiedz", body: OrkaActions.answer(blocker: nr, text: text))
        WKInterfaceDevice.current().play(result.delivered ? .success : .failure)
        if result.delivered { Task { await refresh(fresh: true) } }
        return result
    }

    // MARK: - Głos voice-inbox

    /// Prosi iPhone'a o głos voice-inbox; plik przychodzi osobno i gra, jeśli to wciąż ta wypowiedź.
    func speak(_ text: String) {
        let id = UUID().uuidString
        awaitedAudio = id
        voiceNote = "Głos w drodze…"
        speaking = true
        Task {
            let queued = await service.requestSpeech(text, audioID: id)
            guard awaitedAudio == id else { return }
            if !queued {
                speaking = false
                voiceNote = "Głos voice-inbox niedostępny — odpowiedź jest na ekranie."
                return
            }
            // Plik zwykle dochodzi w kilka sekund; po 25 s przestajemy czekać.
            try? await Task.sleep(for: .seconds(25))
            if awaitedAudio == id {
                awaitedAudio = nil
                speaking = false
                voiceNote = "Głos nie dotarł — odpowiedź jest na ekranie."
            }
        }
    }

    private func audioArrived(id: String?, url: URL?) {
        guard let id, let url, id == awaitedAudio else { return }
        awaitedAudio = nil
        lastAudio = url
        voiceNote = nil
        speaking = player.play(url)
        if !speaking { voiceNote = "Nie udało się odtworzyć głosu." }
    }

    /// „Powtórz”: ostatni plik głosu, a gdy go nie ma — nowa synteza.
    func replay(_ text: String) {
        if let lastAudio, FileManager.default.fileExists(atPath: lastAudio.path) {
            speaking = player.play(lastAudio)
        } else {
            speak(text)
        }
    }

    func stopSpeaking() {
        awaitedAudio = nil
        player.stop()
        speaking = false
        voiceNote = nil
    }
}

/// Odtwarzanie pliku głosu na głośniku zegarka (albo AirPods).
final class OrkaPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    func play(_ url: URL) -> Bool {
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.delegate = self
        self.player = player
        return player.play()
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        onFinish?()
    }
}

/// Odświeżanie liczników w tle (budżet watchOS: zwykle kilka razy na godzinę przy komplikacji na tarczy).
enum OrkaBackground {
    static let task = "orka-refresh"
    static let interval: TimeInterval = 15 * 60

    @MainActor
    static func schedule(after interval: TimeInterval = OrkaBackground.interval) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval), userInfo: task as NSString) { _ in }
    }

    /// Zadanie tła: najpierw planujemy następne (system może uśpić proces w trakcie), potem krótka próba
    /// „na żywo” przez iPhone'a, a gdy się nie da — prośba w kolejce WCSession. Bez HTTPS z zegarka (brak Tailscale).
    static func run() async {
        await schedule()
        switch await RelayHandsfreeService().counters(timeout: 6, directFallback: false) {
        case .success(let counters) where counters.wiekS == nil: break
        case .success(let counters): OrkaSync.store(counters)
        case .failure: OrkaSync.requestInBackground()
        }
    }

    /// Zadanie WatchConnectivity (paczka z iPhone'a przez transferCurrentComplicationUserInfo):
    /// aktywuj sesję i poczekaj chwilę, aż delegat odbierze zaległe dane.
    static func receive() async {
        if WCSession.default.activationState != .activated { WatchSessionManager.shared.activate() }
        for _ in 0..<25 {
            if WCSession.default.activationState == .activated, !WCSession.default.hasContentPending { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
