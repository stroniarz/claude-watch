import XCTest

/// Records calls; answers from a script.
private final class FakeService: HandsfreeService, @unchecked Sendable {
    var asks: [(String, String?)] = []
    var briefs = 0
    var answer: (String) -> HandsfreeOutcome = { .answer("Odpowiedź na: \($0)") }

    func ping() async -> HandsfreeOutcome { .answer("Połączenie jest.") }
    func brief() async -> HandsfreeOutcome { briefs += 1; return .answer("Raport dnia.") }
    func ask(_ text: String, conversationID: String?) async -> HandsfreeOutcome {
        asks.append((text, conversationID))
        return answer(text)
    }
}

final class ConversationEngineTests: XCTestCase {

    /// Feeds utterances in order and records every prompt Siri would say.
    private final class Script: @unchecked Sendable {
        var utterances: [String]
        var prompts: [String] = []
        init(_ utterances: [String]) { self.utterances = utterances }
        func listen(_ prompt: String) throws -> String {
            prompts.append(prompt)
            guard !utterances.isEmpty else { throw CancellationError() }
            return utterances.removeFirst()
        }
    }

    func testLoopAsksSaysAnythingElseAndEndsOnKoniec() async throws {
        let service = FakeService()
        let engine = ConversationEngine(service: service, conversationID: "c-7")
        let script = Script(["co z Yardem?", "a Gastronet?", "koniec"])
        let closing = try await engine.run(first: nil) { try script.listen($0) }

        XCTAssertEqual(closing, VoicePhrases.goodbye)
        XCTAssertEqual(script.prompts, [
            "Słucham.",
            "Odpowiedź na: co z Yardem? Coś jeszcze?",
            "Odpowiedź na: a Gastronet? Coś jeszcze?",
        ])
        XCTAssertEqual(service.asks.map(\.0), ["co z Yardem?", "a Gastronet?"])
        XCTAssertEqual(service.asks.map(\.1), ["c-7", "c-7"])
    }

    func testFirstQuestionFromSiriPhraseSkipsSlucham() async throws {
        let service = FakeService()
        let script = Script(["dzięki"])
        let closing = try await ConversationEngine(service: service).run(first: "co nowego?") { try script.listen($0) }
        XCTAssertEqual(closing, VoicePhrases.goodbye)
        XCTAssertEqual(script.prompts, ["Odpowiedź na: co nowego? Coś jeszcze?"])
    }

    func testRaportCallsBrief() async throws {
        let service = FakeService()
        let script = Script(["raport", "stop"])
        _ = try await ConversationEngine(service: service).run(first: nil) { try script.listen($0) }
        XCTAssertEqual(service.briefs, 1)
        XCTAssertTrue(service.asks.isEmpty)
        XCTAssertEqual(script.prompts.last, "Raport dnia. Coś jeszcze?")
    }

    func testNoConnectionEndsConversation() async throws {
        let service = FakeService()
        service.answer = { _ in .failure(.noConnection) }
        let script = Script(["pytanie", "drugie"])
        let closing = try await ConversationEngine(service: service).run(first: nil) { try script.listen($0) }
        XCTAssertEqual(closing, "Nie mam połączenia z Makiem, sprawdź Tailscale.")
        XCTAssertEqual(script.prompts, ["Słucham."])
    }

    func testTimeoutKeepsConversationGoing() async throws {
        let service = FakeService()
        service.answer = { _ in .failure(.timeout) }
        let script = Script(["pytanie", "koniec"])
        _ = try await ConversationEngine(service: service).run(first: nil) { try script.listen($0) }
        XCTAssertEqual(script.prompts.last, "\(VoicePhrases.timeout) Coś jeszcze?")
    }

    func testEmptyUtteranceAsksToRepeatWithoutCallingServer() async throws {
        let service = FakeService()
        let script = Script(["  ", "koniec"])
        _ = try await ConversationEngine(service: service).run(first: nil) { try script.listen($0) }
        XCTAssertEqual(script.prompts, ["Słucham.", VoicePhrases.didNotHear])
        XCTAssertTrue(service.asks.isEmpty)
    }

    func testTurnLimit() async throws {
        let service = FakeService()
        let script = Script(Array(repeating: "pytanie", count: 10))
        var engine = ConversationEngine(service: service)
        engine.maxTurns = 3
        let closing = try await engine.run(first: nil) { try script.listen($0) }
        XCTAssertEqual(service.asks.count, 3)
        XCTAssertTrue(closing.hasSuffix(VoicePhrases.turnLimit))
    }

    func testSilencePropagatesFromListen() async {
        let script = Script([])
        do {
            _ = try await ConversationEngine(service: FakeService()).run(first: nil) { try script.listen($0) }
            XCTFail("expected throw")
        } catch {}
    }

    func testEndWords() {
        for text in ["koniec", "Koniec.", "stop", "nie, dzięki", "Dziękuję!", "to wszystko", "nic", "na razie", "dobra, koniec"] {
            XCTAssertTrue(VoicePhrases.isEnd(text), text)
        }
        for text in ["a nie Yard?", "co z Yardem", "nie wiem co z Gastronetem dzisiaj", "to", "Yard", "dlaczego koniec umowy z klientem jest jutro"] {
            XCTAssertFalse(VoicePhrases.isEnd(text), text)
        }
    }

    func testBriefWords() {
        XCTAssertTrue(VoicePhrases.isBrief("Raport"))
        XCTAssertTrue(VoicePhrases.isBrief("daj raport"))
        XCTAssertFalse(VoicePhrases.isBrief("co jest w raporcie o Yardzie"))
    }

    func testConversationStoreReusesIDWithinIdleWindow() async {
        let store = ConversationStore(idleTimeout: 180)
        let t0 = Date()
        let a = await store.conversationID(now: t0)
        let b = await store.conversationID(now: t0.addingTimeInterval(100))
        let c = await store.conversationID(now: t0.addingTimeInterval(250))  // 150 s since b → same
        let d = await store.conversationID(now: t0.addingTimeInterval(500))  // 250 s idle → new
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
        XCTAssertNotEqual(c, d)
        await store.end()
        let e = await store.conversationID(now: t0.addingTimeInterval(501))
        XCTAssertNotEqual(d, e)
    }
}
