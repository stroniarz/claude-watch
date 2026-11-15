import XCTest

final class OrkaPhoneTests: XCTestCase {
    private let base = URL(string: "https://mac.example.ts.net:8444")!

    func testPanelTokenIsOnlyInEncodedFragment() throws {
        let fakeToken = "test-only&value=#?+ /%"
        let url = try XCTUnwrap(OrkaPhoneEndpoint.panelURL(baseURL: base, token: fakeToken))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/panel")
        XCTAssertNil(parts.query)
        XCTAssertNil(parts.user)
        XCTAssertNil(parts.password)
        XCTAssertEqual(parts.percentEncodedFragment?.removingPercentEncoding, "t=" + fakeToken)
        XCTAssertFalse(parts.percentEncodedFragment?.contains("&") ?? true)
        XCTAssertFalse(parts.percentEncodedFragment?.contains("#") ?? true)
    }

    func testPanelRejectsMissingTokenAndNonTailscaleURLs() {
        XCTAssertNil(OrkaPhoneEndpoint.panelURL(baseURL: base, token: nil))
        XCTAssertNil(OrkaPhoneEndpoint.panelURL(baseURL: base, token: ""))
        for address in ["http://mac.example.ts.net:8444", "https://example.com", "https://ts.net.evil.test",
                        "https://user:password@mac.example.ts.net", "https://mac.example.ts.net/other",
                        "https://mac.example.ts.net?token=x", "https://mac.example.ts.net#old"] {
            XCTAssertNil(OrkaPhoneEndpoint.panelURL(baseURL: URL(string: address), token: "test-only"), address)
        }
        XCTAssertNotNil(OrkaPhoneEndpoint.panelURL(baseURL: URL(string: "https://mac.example.ts.net/"), token: "test-only"))
    }

    func testNavigationAndMediaRequireSameHTTPSOrigin() {
        XCTAssertTrue(OrkaPhoneEndpoint.sameOrigin(base.appendingPathComponent("panel/rozmowa"), as: base))
        for address in ["http://mac.example.ts.net:8444/panel", "https://other.example.ts.net:8444/panel",
                        "https://mac.example.ts.net/panel", "https://mac.example.ts.net:443/panel",
                        "https://mac.example.ts.net.evil.test:8444", "https://user@mac.example.ts.net:8444"] {
            XCTAssertFalse(OrkaPhoneEndpoint.sameOrigin(URL(string: address), as: base), address)
        }
        XCTAssertTrue(OrkaPhoneEndpoint.sameOrigin(URL(string: "https://mac.example.ts.net:443/panel"),
                                                 as: URL(string: "https://mac.example.ts.net")!))
    }

    func testAvailabilitySeparatesSettingsFromOffline() {
        XCTAssertEqual(OrkaPhoneAvailability.afterPing(.answer("Jestem.")), .ready)
        for failure in [HandsfreeFailure.notConfigured, .unauthorized] {
            XCTAssertEqual(OrkaPhoneAvailability.afterPing(.failure(failure)), .needsSettings)
        }
        for failure in [HandsfreeFailure.noConnection, .timeout, .server, .tooMany, .noPhone] {
            XCTAssertEqual(OrkaPhoneAvailability.afterPing(.failure(failure)), .offline)
        }
    }

    func testFrozenSessionActionKeepsChannelAccountAndID() throws {
        let original = OrkaCounters.Waiting(nazwa: "Sesja A", issue: "STR-1", konto: "2", id: "session-a", kanal: "%7")
        var list = [original]
        let id = UUID()
        let action = try XCTUnwrap(OrkaPhoneAction(target: .session(list[0]), text: " wdrażaj\n", id: id))
        list[0] = OrkaCounters.Waiting(nazwa: "Sesja B", issue: nil, konto: "1", id: "session-b", kanal: "%9")
        XCTAssertEqual(action.path, "pokieruj")
        XCTAssertEqual(action.body["sesja_id"] as? String, "session-a")
        XCTAssertEqual(action.body["konto"] as? String, "2")
        XCTAssertEqual(action.body["kanal_oczekiwany"] as? String, "%7")
        XCTAssertEqual(action.body["tekst"] as? String, "wdrażaj")
        XCTAssertEqual(action.body["id_akcji"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(action.body["potwierdzam"] as? Bool, true)
        XCTAssertTrue(action.title.contains("Sesja A"))
    }

    func testMissingChannelSecretAndUnavailableBlockerCannotCreateActions() {
        let noChannel = OrkaCounters.Waiting(nazwa: "A", issue: nil, konto: "1", id: "a")
        XCTAssertNil(OrkaPhoneAction(target: .session(noChannel), text: "ok, leć"))
        let noID = OrkaCounters.Waiting(nazwa: "A", issue: nil, konto: "1", kanal: "%1")
        XCTAssertNil(OrkaPhoneAction(target: .session(noID), text: "ok, leć"))
        for blocker in [blocker(type: "sekret", allowed: true), blocker(type: "pytanie", allowed: false)] {
            XCTAssertNil(OrkaPhoneAction(target: .blocker(blocker), text: "odpowiedź"))
        }
        XCTAssertNil(OrkaPhoneAction(target: .blocker(blocker()), text: " \n "))
    }

    func testBlockerAndPhoneChatUseExistingContract() throws {
        let action = try XCTUnwrap(OrkaPhoneAction(target: .blocker(blocker()), text: "ok, leć"))
        XCTAssertEqual(action.path, "bloker/odpowiedz")
        XCTAssertEqual(action.body["nr"] as? Int, 17)
        XCTAssertTrue(action.title.contains("Sesja A"))
        let body = OrkaActions.tellOrka("Cześć", source: "telefon")
        XCTAssertEqual(body["zrodlo"] as? String, "telefon")
        XCTAssertEqual(body["potwierdzam"] as? Bool, true)
    }

    func testFirstInboxReadSetsBaselineWithoutHistoricalSpeech() {
        var conversation = OrkaPhoneConversation()
        let texts = conversation.receive(OrkaReplies(ostatni: 50, odpowiedzi: [reply(49)]))
        XCTAssertEqual(conversation.cursor, 50)
        XCTAssertTrue(conversation.lines.isEmpty)
        XCTAssertTrue(texts.isEmpty)
    }

    func testInboxSortsDeduplicatesAndDoesNotSkipPages() {
        var conversation = OrkaPhoneConversation(cursor: 10)
        XCTAssertEqual(conversation.receive(OrkaReplies(ostatni: 40, odpowiedzi: [reply(12), reply(11), reply(11), reply(9)])),
                       ["Odpowiedź 11", "Odpowiedź 12"])
        XCTAssertEqual(conversation.cursor, 12) // 13...40 muszą pozostać do odczytania
        XCTAssertTrue(conversation.receive(OrkaReplies(ostatni: 40, odpowiedzi: [reply(11), reply(12)])).isEmpty)
        XCTAssertEqual(conversation.lines.count, 2)
        _ = conversation.receive(OrkaReplies(ostatni: 40, odpowiedzi: [reply(13)]))
        XCTAssertEqual(conversation.cursor, 13)
    }

    func testInboxResetCanReceiveNewNumbering() {
        var conversation = OrkaPhoneConversation(cursor: 100)
        _ = conversation.receive(OrkaReplies(ostatni: 2, odpowiedzi: []))
        XCTAssertEqual(conversation.cursor, 0)
        XCTAssertEqual(conversation.receive(OrkaReplies(ostatni: 2, odpowiedzi: [reply(1), reply(2)])),
                       ["Odpowiedź 1", "Odpowiedź 2"])
        XCTAssertEqual(conversation.cursor, 2)
    }

    func testConversationPersistsCursorWindowAndBoundedHistory() throws {
        var conversation = OrkaPhoneConversation(cursor: 12)
        conversation.waitingUntil = Date(timeIntervalSince1970: 1000 + OrkaPhoneConversation.replyWindow)
        for i in 0..<75 { conversation.append(.me, "Wiadomość \(i)") }
        let restored = try JSONDecoder().decode(OrkaPhoneConversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertEqual(restored.cursor, 12)
        XCTAssertEqual(restored.lines.count, 60)
        XCTAssertEqual(restored.lines.first?.text, "Wiadomość 15")
        XCTAssertEqual(restored.waitingUntil, Date(timeIntervalSince1970: 1180))
        XCTAssertEqual(restored.lines, conversation.lines)
    }

    func testUncertainDeliveryDoesNotBecomeNotSent() {
        XCTAssertEqual(OrkaActionResult.parse(status: 502, data: Data()), .unknown(OrkaActionResult.unknownText))
        XCTAssertEqual(OrkaActionResult.parse(status: 200, data: Data("{}".utf8)), .unknown(OrkaActionResult.unknownText))
    }

    private func reply(_ nr: Int) -> OrkaReply { OrkaReply(nr: nr, ts: Double(nr), tekst: "Odpowiedź \(nr)", od: "orka") }

    private func blocker(type: String = "pytanie", allowed: Bool = true) -> OrkaCounters.Blocker {
        OrkaCounters.Blocker(nr: 17, sesja: "Sesja A", issue: nil, typ: type, potrzebuje: "Zgoda", stan: "otwarty", mozna: allowed)
    }
}
