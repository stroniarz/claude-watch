import AVFoundation
import Combine
import Foundation

@MainActor
final class OrkaPhoneModel: ObservableObject {
    @Published private(set) var snapshot: OrkaSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var conversation: OrkaPhoneConversation
    @Published private(set) var sending = false
    @Published private(set) var chatStatus: String?
    @Published private(set) var voiceNote: String?
    /// Ostatni wynik i trwające wysyłki per cel — w modelu (żyje w roocie), nie w widoku: powrót z tła
    /// albo przebudowa ekranu nie może zgubić wyniku i skusić do ponownego „wdrażaj” (review r1).
    @Published private(set) var lastResults: [String: (text: String, result: OrkaActionResult, at: Date)] = [:]
    @Published private(set) var inFlight: Set<String> = []

    private static let chatKey = "orka.phone.conversation.v1"
    private static let snapshotKey = "orka.phone.snapshot.v1"
    private static let baseKey = "orka.phone.base.v1"
    /// Adres Maca, z którego pochodzą snapshot i kursor — po zmianie adresu dane są unieważniane,
    /// żeby nr blokera/sesji z jednego Maca nie poszedł do innego (review Codex r1).
    private var dataBase: String? = UserDefaults.standard.string(forKey: OrkaPhoneModel.baseKey)
    /// Chwila ostatniego udanego odczytu liczników (do „sesja nadal czeka”).
    private(set) var lastRefreshOK: Date?
    private var visible = false
    private var chatVisible = false
    private var runID = UUID()
    private var reading = false
    private var freshPending = false
    private var pollTask: Task<Void, Never>?
    private var pollID = UUID()
    private var speechTask: Task<Void, Never>?
    private var speechQueue: [String] = []
    private let player = OrkaPhonePlayer()

    init() {
        let defaults = UserDefaults.standard
        conversation = defaults.data(forKey: Self.chatKey)
            .flatMap { try? JSONDecoder().decode(OrkaPhoneConversation.self, from: $0) } ?? OrkaPhoneConversation()
        snapshot = defaults.data(forKey: Self.snapshotKey)
            .flatMap { try? JSONDecoder().decode(OrkaSnapshot.self, from: $0) }
        player.onFinish = { [weak self] in self?.playNext() }
    }

    private var client: HandsfreeClient {
        HandsfreeClient(baseURL: OrkaPhoneEndpoint.baseURL(HandsfreeSettings.baseURL), token: HandsfreeSettings.token)
    }

    /// Wywołanie z .task(id:) — znika wraz z kartą lub po przejściu appki do tła.
    func runVisible() async {
        let id = UUID()
        runID = id
        visible = true
        defer {
            if runID == id {
                suspend()
            }
        }
        await refresh()
        await catchUp()
        resumePolling()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard runID == id else { return }
            await refresh()
            await catchUp()
        }
    }

    func suspend() {
        visible = false
        runID = UUID()
        pollID = UUID()
        pollTask?.cancel()
        pollTask = nil
        stopSpeaking()
    }

    /// Unieważnia dane z innego adresu Maca (zmiana w Ustawieniach).
    private func dropDataFromOtherMac() {
        let current = HandsfreeSettings.baseURLString
        guard dataBase != current else { return }
        if dataBase != nil {
            snapshot = nil
            conversation.cursor = nil
            UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
            saveChat()
        }
        dataBase = current
        UserDefaults.standard.set(current, forKey: Self.baseKey)
    }

    /// Przed akcją: poczekaj na trwający odczyt i zrób świeży; `true` tylko gdy się udał.
    func refreshForAction() async -> Bool {
        while loading {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
        }
        let started = Date()
        await refresh(fresh: true)
        return (lastRefreshOK ?? .distantPast) >= started
    }

    func refresh(fresh: Bool = false) async {
        dropDataFromOtherMac()
        guard !loading else {
            if fresh { freshPending = true }
            return
        }
        loading = true
        defer {
            loading = false
            if freshPending {
                freshPending = false
                Task { await refresh(fresh: true) }
            }
        }
        switch await client.counters(fresh: fresh) {
        case .success(let counters):
            snapshot = OrkaSnapshot(counters: counters)
            if counters.wiekS != nil { lastRefreshOK = Date() }
            error = counters.wiekS == nil ? "Mac jeszcze zbiera stan panelu. Spróbuj za chwilę." : nil
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.snapshotKey)
            }
        case .failure(let failure):
            // Anulowanie (zmiana ekranu w trakcie) to nie brak połączenia.
            if Task.isCancelled { return }
            error = failure.phrase
        }
    }

    func perform(_ action: OrkaPhoneAction) async -> OrkaActionResult {
        dropDataFromOtherMac()
        // Samo wysłanie nie jest automatycznie ponawiane, także po utracie połączenia.
        let key = action.targetKey
        inFlight.insert(key)
        let result = await client.action(action.path, body: action.body)
        inFlight.remove(key)
        lastResults[key] = (action.text, result, Date())
        if result.delivered { await refresh(fresh: true) }
        return result
    }

    /// Synchronicznie, przed startem zadania: podwójne dotknięcie „Wyślij” nie wyśle dwa razy.
    func markInFlight(_ action: OrkaPhoneAction) { inFlight.insert(action.targetKey) }

    /// Wynik ostatniej akcji do tego celu z ostatnich 15 minut.
    func recentResult(for target: OrkaPhoneAction.Target) -> (text: String, result: OrkaActionResult, at: Date)? {
        guard let hit = lastResults[OrkaPhoneAction.key(target)], hit.at > Date().addingTimeInterval(-900) else { return nil }
        return hit
    }

    func tellOrka(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        conversation.append(.me, text)
        saveChat()
        // Bez kursora sprzed wysyłki nie da się pewnie odebrać szybkiej odpowiedzi.
        guard await ensureCursor() else {
            let message = "Nie wysłano: nie udało się otworzyć skrzynki Orki. Spróbuj ponownie."
            chatStatus = message
            conversation.append(.info, message)
            saveChat()
            return
        }
        chatStatus = "Wysyłam do Orki…"
        let result = await client.action("orka/napisz", body: OrkaActions.tellOrka(text, source: "telefon"))
        conversation.append(.info, result.text)
        switch result {
        case .delivered:
            chatStatus = "Wiadomość dostarczona. Czekam na odpowiedź Orki…"
            conversation.waitingUntil = Date().addingTimeInterval(OrkaPhoneConversation.replyWindow)
        case .unknown:
            // Mogło dojść: sprawdzaj skrzynkę, ale nigdy samoczynnie nie wysyłaj ponownie.
            chatStatus = result.text
            conversation.waitingUntil = Date().addingTimeInterval(OrkaPhoneConversation.replyWindow)
        case .notSent: chatStatus = result.text
        }
        saveChat()
        resumePolling()
    }

    private func saveChat() {
        if let data = try? JSONEncoder().encode(conversation) {
            UserDefaults.standard.set(data, forKey: Self.chatKey)
        }
    }

    private func ensureCursor() async -> Bool {
        if conversation.cursor != nil { return true }
        guard case .success(let replies) = await client.orkaReplies(after: nil, wait: 0) else { return false }
        // Inne odczytanie mogło skończyć się podczas await.
        if conversation.cursor == nil {
            conversation.cursor = replies.ostatni
            saveChat()
        }
        return true
    }

    @discardableResult
    private func receive(_ replies: OrkaReplies) -> Bool {
        let texts = conversation.receive(replies)
        saveChat()
        if !texts.isEmpty {
            chatStatus = nil
            if visible && chatVisible {
                // Każda część osobno: /mow ma limit długości pojedynczej wypowiedzi.
                speechQueue.append(contentsOf: texts)
                if speechTask == nil && !player.isPlaying { playNext() }
            }
        }
        return !texts.isEmpty
    }

    private func catchUp() async {
        guard !reading, pollTask == nil else { return }
        reading = true
        defer { reading = false }
        guard await ensureCursor() else { return }
        // Skrzynka zwraca po 10 wpisów; nie przeskakuj kursorem do `ostatni`.
        for _ in 0..<20 {
            guard !Task.isCancelled, visible,
                  case .success(let replies) = await client.orkaReplies(after: conversation.cursor, wait: 0) else { return }
            receive(replies)
            if (conversation.cursor ?? 0) >= replies.ostatni { return }
        }
    }

    private func resumePolling() {
        guard visible, pollTask == nil, let deadline = conversation.waitingUntil, deadline > Date() else { return }
        let id = UUID()
        pollID = id
        pollTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.pollID == id { self.pollTask = nil } }
            // Nie uruchamiaj drugiego odczytu w czasie wejścia/pull-to-refresh.
            while self.reading && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            var failures = 0
            var receivedReply = false
            while !Task.isCancelled, self.visible,
                  let deadline = self.conversation.waitingUntil, deadline > Date() {
                let result = await self.client.orkaReplies(after: self.conversation.cursor,
                                                          wait: min(8, deadline.timeIntervalSinceNow))
                guard !Task.isCancelled else { return }
                switch result {
                case .success(let replies):
                    failures = 0
                    if self.receive(replies) { receivedReply = true }
                case .failure:
                    failures += 1
                    if failures >= 3 {
                        self.chatStatus = "Nie udało się odczytać skrzynki Orki. Zostanie sprawdzona po powrocie do rozmowy."
                        return
                    }
                }
                // Ochrona przed gorącą pętlą, jeśli serwer nie wykorzysta long-poll.
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self.conversation.waitingUntil = nil
            self.saveChat()
            if !receivedReply {
                self.chatStatus = "Orka jeszcze nie odpowiedziała. Jej odpowiedź pojawi się po odświeżeniu albo po powrocie do rozmowy."
            }
        }
    }

    func setChatVisible(_ value: Bool) {
        chatVisible = value
        if value && visible {
            Task {
                await catchUp()
                resumePolling()
            }
        } else if !value { stopSpeaking() }
    }

    func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        speechQueue.removeAll()
        player.stop()
        voiceNote = nil
    }

    private func playNext() {
        guard visible, chatVisible, !speechQueue.isEmpty else { return }
        let text = speechQueue.removeFirst()
        voiceNote = "Pobieram głos Orki…"
        speechTask = Task { [weak self] in
            guard let self else { return }
            let audio = await self.client.speech(text, voice: OrkaVoiceChoice.slug)
            guard !Task.isCancelled, self.visible, self.chatVisible else { return }
            self.speechTask = nil
            if let audio, self.player.play(audio.data) {
                self.voiceNote = nil
            } else {
                self.voiceNote = "Głos Orki jest niedostępny. Odpowiedź znajdziesz w rozmowie."
                self.playNext()
            }
        }
    }
}

@MainActor
private final class OrkaPhonePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?
    var isPlaying: Bool { player?.isPlaying == true }

    func play(_ data: Data) -> Bool {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let audio = try AVAudioPlayer(data: data)
            player = audio
            audio.delegate = self
            guard audio.play() else { stop(); return false }
            return true
        } catch {
            stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            return false
        }
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.stop()
            self.onFinish?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
