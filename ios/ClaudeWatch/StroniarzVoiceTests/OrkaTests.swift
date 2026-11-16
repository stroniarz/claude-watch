import XCTest

/// STR-1463: liczniki Orki (`/panel/api/zegarek`), rozmowa (`/panel/api/jarvis`) i relay.
final class OrkaTests: XCTestCase {
    private let base = URL(string: "https://mac.example.ts.net:8444")!
    private let token = "t0ken-t0ken-t0ken-t0ken-xyz"

    private let sample = """
    {"ok": true, "czas": "2026-11-15 17:15", "wiek_s": 42, "czeka": 10, "pracuje": 7, "blokery": 1,
     "ogony": 40, "ogony_otwarte": 92, "limity": {"1": 68, "2": 97}, "limit": {"konto": "2", "proc": 97},
     "czekajace": [{"nazwa": "ircsklep", "issue": "STR-1", "konto": "1"}, {"nazwa": "yard", "issue": null, "konto": "2"}],
     "zdanie": "10 sesji czeka na Ciebie.", "bledy": 0}
    """

    override func setUp() {
        MockURLProtocol.handler = nil
        MockURLProtocol.requests = []
    }

    private func client(token: String? = "t0ken-t0ken-t0ken-t0ken-xyz") -> HandsfreeClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.timeoutIntervalForRequest = HandsfreeClient.timeout
        config.timeoutIntervalForResource = HandsfreeClient.timeout
        return HandsfreeClient(baseURL: base, token: token, session: URLSession(configuration: config))
    }

    // MARK: - Model

    func testDecodesCounters() throws {
        let c = try JSONDecoder().decode(OrkaCounters.self, from: Data(sample.utf8))
        XCTAssertEqual(c.czeka, 10)
        XCTAssertEqual(c.blokery, 1)
        XCTAssertEqual(c.ogony, 40)
        XCTAssertEqual(c.ogonyOtwarte, 92)
        XCTAssertEqual(c.wiekS, 42)
        XCTAssertEqual(c.limit, .init(konto: "2", proc: 97))
        XCTAssertEqual(c.limitShort, "k2 97%")
        XCTAssertEqual(c.czekajace.count, 2)
        XCTAssertNil(c.czekajace[1].issue)
    }

    func testDecodingIsTolerant() throws {
        let c = try JSONDecoder().decode(OrkaCounters.self, from: Data(#"{"czeka": 3, "limit": null, "nowe_pole": 1}"#.utf8))
        XCTAssertEqual(c.czeka, 3)
        XCTAssertEqual(c.blokery, 0)
        XCTAssertNil(c.limit)
        XCTAssertNil(c.limitShort)
        XCTAssertNil(c.wiekS)
    }

    func testSnapshotAgeAndStaleness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snap = OrkaSnapshot(counters: OrkaCounters(wiekS: 300), fetchedAt: now)
        XCTAssertEqual(snap.dataDate, now.addingTimeInterval(-300))
        XCTAssertEqual(snap.ageText(at: now), "5 min")
        XCTAssertEqual(snap.ageText(at: now.addingTimeInterval(-290)), "teraz")
        XCTAssertEqual(snap.ageText(at: now.addingTimeInterval(3 * 3600)), "3 h")
        XCTAssertEqual(snap.ageText(at: now.addingTimeInterval(86400)), "1 dzień")
        XCTAssertFalse(snap.isStale(at: now))
        XCTAssertTrue(snap.isStale(at: now.addingTimeInterval(2 * 3600)))
    }

    func testDraftsPlural() {
        let cases = [(1, "1 szkic"), (2, "2 szkice"), (4, "4 szkice"), (5, "5 szkiców"), (12, "12 szkiców"),
                     (22, "22 szkice"), (0, "0 szkiców"), (40, "40 szkiców")]
        for (n, text) in cases { XCTAssertEqual(OrkaCounters(ogony: n).draftsText, text) }
    }

    func testSnapshotRoundTrip() throws {
        let snap = OrkaSnapshot(counters: OrkaCounters(czeka: 2, limit: .init(konto: "1", proc: 5)))
        let back = try JSONDecoder().decode(OrkaSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(back, snap)
    }

    // MARK: - HTTP

    func testCountersRequest() async throws {
        MockURLProtocol.handler = { [sample] _ in (200, sample) }
        let result = await client().counters()
        XCTAssertEqual(try result.get().czeka, 10)
        let req = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://mac.example.ts.net:8444/panel/api/zegarek")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        // Dłuższy limit niż 12 s (serwer czeka do 8 s na świeży stan).
        XCTAssertEqual(req.timeoutInterval, HandsfreeClient.countersTimeout)
    }

    func testCountersErrors() async {
        MockURLProtocol.handler = { _ in (401, #"{"ok": false, "blad": "Brak dostępu."}"#) }
        let unauthorized = await client().counters()
        XCTAssertEqual(unauthorized.failureValue, .unauthorized)
        MockURLProtocol.handler = { _ in (200, "<html>nie JSON</html>") }
        let notJSON = await client().counters()
        XCTAssertEqual(notJSON.failureValue, .server)
        MockURLProtocol.handler = { _ in (502, "<html>bad gateway</html>") }
        let gateway = await client().counters()
        XCTAssertEqual(gateway.failureValue, .noConnection)
        let unconfigured = await client(token: nil).counters()
        XCTAssertEqual(unconfigured.failureValue, .notConfigured)
    }

    func testAskOrkaSendsTekstAndReadsAnswer() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"tekst": "Yard czeka na wycenę.", "poziom": "T2", "propozycja": null}"#) }
        let outcome = await client().askOrka("co z Yardem?")
        XCTAssertEqual(outcome, .answer("Yard czeka na wycenę."))
        let req = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(req.url?.path, "/panel/api/jarvis")
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["tekst": "co z Yardem?"])
        XCTAssertEqual(req.timeoutInterval, HandsfreeClient.orkaTimeout)
    }

    func testT3IsNeverConfirmedFromWatch() {
        let t3 = Data(#"{"tekst": "Przygotowałam zlecenie. Potwierdź je w panelu.", "poziom": "T3", "propozycja": {"opis": "x"}}"#.utf8)
        XCTAssertEqual(HandsfreeClient.orkaOutcome(t3), .answer(OrkaPhrases.noOrdersFromWatch))
        let proposalOnly = Data(#"{"tekst": "ok", "poziom": "T2", "propozycja": {}}"#.utf8)
        XCTAssertEqual(HandsfreeClient.orkaOutcome(proposalOnly), .answer(OrkaPhrases.noOrdersFromWatch))
        XCTAssertEqual(HandsfreeClient.orkaOutcome(Data(#"{"tekst": "  "}"#.utf8)).failure, .server)
    }

    func testAskOrkaRateLimitUsesServerSentence() async {
        MockURLProtocol.handler = { _ in (429, #"{"ok": false, "blad": "Za dużo pytań naraz. Odczekaj minutę."}"#) }
        let outcome = await client().askOrka("hej")
        XCTAssertEqual(outcome, .failure(.tooMany, spoken: "Za dużo pytań naraz. Odczekaj minutę."))
    }

    // MARK: - Etap 2: akcje, rozmowa z Orką

    func testActionResultParsing() {
        func parse(_ status: Int, _ body: String) -> OrkaActionResult { OrkaActionResult.parse(status: status, data: Data(body.utf8)) }
        XCTAssertEqual(parse(200, #"{"ok": true, "dostarczone": true, "do": "sesja k1:abcd1234"}"#), .delivered(to: "sesja k1:abcd1234"))
        XCTAssertEqual(parse(200, #"{"ok": false, "dostarczone": false, "blad": "Nie wysłano: brak kanału."}"#), .notSent("Nie wysłano: brak kanału."))
        XCTAssertEqual(parse(200, #"{"ok": false, "wynik_nieznany": true, "blad": "Nie potwierdzono."}"#), .unknown("Nie potwierdzono."))
        // Niepewne przypadki to „nie wiadomo”, nigdy „nie wysłano” (review r1).
        XCTAssertEqual(parse(200, "<html>"), .unknown(OrkaActionResult.unknownText))
        XCTAssertEqual(parse(200, #"{"ok": true}"#), .unknown(OrkaActionResult.unknownText))
        XCTAssertEqual(parse(500, #"{"ok": false, "blad": "Coś poszło nie tak"}"#), .unknown(OrkaActionResult.unknownText))
        XCTAssertEqual(parse(0, ""), .unknown(OrkaActionResult.unknownText))
        XCTAssertEqual(parse(400, #"{"ok": false, "blad": "Nieprawidłowy tekst."}"#), .notSent("Nie wysłano: Nieprawidłowy tekst."))
        XCTAssertEqual(parse(429, #"{"ok": false, "blad": "Za dużo pytań naraz."}"#), .notSent("Nie wysłano: Za dużo pytań naraz."))
    }

    func testActionBodies() {
        let id = UUID()
        let s = OrkaCounters.Waiting(nazwa: "Yard", issue: "STR-1", konto: "2", id: "abcd1234", kanal: "sesja k2:abcd1234")
        let reply = OrkaActions.reply(to: s, text: "wdrażaj", id: id)
        XCTAssertEqual(reply["sesja_id"] as? String, "abcd1234")
        XCTAssertEqual(reply["konto"] as? String, "2")
        XCTAssertEqual(reply["kanal_oczekiwany"] as? String, "sesja k2:abcd1234")
        XCTAssertEqual(reply["tylko_czekajaca"] as? Bool, true)
        XCTAssertEqual(reply["potwierdzam"] as? Bool, true)
        XCTAssertEqual(reply["id_akcji"] as? String, id.uuidString.lowercased())
        let blocker = OrkaActions.answer(blocker: 7, text: "ok, leć", id: id)
        XCTAssertEqual(blocker["nr"] as? Int, 7)
        let tell = OrkaActions.tellOrka("hej", source: "siri", id: id)
        XCTAssertEqual(tell["zrodlo"] as? String, "siri")
        XCTAssertEqual(OrkaActions.tellOrka("hej")["zrodlo"] as? String, "zegarek")
    }

    func testActionHTTPAndUnknownOnServerError() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"ok": true, "dostarczone": true, "do": "orkiestrator-k2"}"#) }
        let ok = await client().action("orka/napisz", body: OrkaActions.tellOrka("Co z Yardem?"))
        XCTAssertEqual(ok, .delivered(to: "orkiestrator-k2"))
        let req = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(req.url?.path, "/panel/api/orka/napisz")
        XCTAssertEqual(req.timeoutInterval, HandsfreeClient.actionTimeout)
        MockURLProtocol.handler = { _ in (502, "<html>bad gateway</html>") }
        let gateway = await client().action("pokieruj", body: ["tekst": "x"])
        XCTAssertEqual(gateway, .unknown(OrkaActionResult.unknownText))
        let unknownPath = await client().action("zlec", body: ["x": 1])
        XCTAssertEqual(unknownPath, .notSent("Nieznana akcja."))
    }

    func testOrkaRepliesCursorQuery() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"ok": true, "ostatni": 12, "odpowiedzi": [{"nr": 12, "ts": 1794769000.1234567, "tekst": "Przekazałam.", "od": "orka"}]}"#) }
        let replies = try await client().orkaReplies(after: 11, wait: 8).get()
        XCTAssertEqual(replies.ostatni, 12)
        XCTAssertEqual(replies.odpowiedzi.first?.nr, 12)
        let url = try XCTUnwrap(MockURLProtocol.requests.last?.url?.absoluteString)
        XCTAssertTrue(url.contains("po=11") && url.contains("czekaj=8"), url)
        _ = await client().orkaReplies(after: nil, wait: 0)
        XCTAssertFalse(try XCTUnwrap(MockURLProtocol.requests.last?.url?.absoluteString).contains("po="))
    }

    // MARK: - Relay

    func testRelayCountersRoundTrip() throws {
        let counters = try JSONDecoder().decode(OrkaCounters.self, from: Data(sample.utf8))
        let reply = VoiceRelay.encode(.success(counters) as Result<OrkaCounters, HandsfreeFailure>)
        XCTAssertNotNil(reply[VoiceRelay.countersKey] as? Data)
        XCTAssertEqual(try VoiceRelay.decodeCounters(reply).get(), counters)
        let failed = VoiceRelay.encode(.failure(.unauthorized) as Result<OrkaCounters, HandsfreeFailure>)
        XCTAssertEqual(VoiceRelay.decodeCounters(failed).failureValue, .unauthorized)
        XCTAssertEqual(VoiceRelay.decodeCounters([:]).failureValue, .server)
    }

    func testRelayHandlesOrkaAndZegarekOps() async throws {
        let service = FakeOrka()
        let orka = await relay(["op": "orka", "text": "ile czeka?"], service: service)
        XCTAssertEqual(VoiceRelay.decode(orka), .answer("Odpowiedź Orki na: ile czeka?"))
        let zegarek = await relay(["op": "zegarek"], service: service)
        XCTAssertEqual(try VoiceRelay.decodeCounters(zegarek).get().czeka, 4)
        let unknown = await relay(["op": "zle"], service: service)
        XCTAssertEqual(VoiceRelay.decode(unknown).failure, .server)
    }

    private func relay(_ request: [String: Any], service: FakeOrka) async -> [String: Any] {
        let box = ReplyBox()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            VoiceRelay.handle(request, reply: { box.value = $0; cont.resume() }, service: service)
        }
        return box.value
    }
}

private final class ReplyBox: @unchecked Sendable {
    var value: [String: Any] = [:]
}

private struct FakeOrka: HandsfreeService, OrkaService {
    func ping() async -> HandsfreeOutcome { .answer("ok") }
    func brief() async -> HandsfreeOutcome { .answer("brief") }
    func ask(_ text: String, conversationID: String?) async -> HandsfreeOutcome { .answer(text) }
    func counters() async -> Result<OrkaCounters, HandsfreeFailure> { .success(OrkaCounters(czeka: 4)) }
    func askOrka(_ text: String) async -> HandsfreeOutcome { .answer("Odpowiedź Orki na: \(text)") }
}

private extension Result where Failure == HandsfreeFailure {
    var failureValue: HandsfreeFailure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
