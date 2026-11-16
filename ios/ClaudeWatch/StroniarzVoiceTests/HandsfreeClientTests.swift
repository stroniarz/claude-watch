import XCTest

/// Serves canned responses and records requests; one handler per test.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Data(reading: stream)
        }
        Self.requests.append(recorded)
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (status, body) = try handler(recorded)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            append(buffer, count: n)
        }
    }
}

final class HandsfreeClientTests: XCTestCase {
    private let base = URL(string: "https://mac.example.ts.net:8444")!
    private let token = "t0ken-t0ken-t0ken-t0ken-xyz"

    override func setUp() {
        MockURLProtocol.handler = nil
        MockURLProtocol.requests = []
    }

    private func client(token: String? = "t0ken-t0ken-t0ken-t0ken-xyz", base: URL? = nil) -> HandsfreeClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return HandsfreeClient(baseURL: base ?? self.base, token: token, session: URLSession(configuration: config))
    }

    func testAskSendsJSONWithBearerAndConversationID() async throws {
        MockURLProtocol.handler = { _ in (200, "Yard czeka na wycenę.\n") }
        let outcome = await client().ask("co z Yardem?", conversationID: "c-1")
        XCTAssertEqual(outcome, .answer("Yard czeka na wycenę."))

        let req = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://mac.example.ts.net:8444/ask")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(req.timeoutInterval, 12)
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["text": "co z Yardem?", "conversation_id": "c-1"])
    }

    func testAskWithoutConversationIDOmitsField() async throws {
        MockURLProtocol.handler = { _ in (200, "ok") }
        _ = await client().ask("pytanie", conversationID: nil)
        let body = try XCTUnwrap(MockURLProtocol.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["text": "pytanie"])
    }

    func testBriefAndPingAreGET() async {
        MockURLProtocol.handler = { req in (200, req.url!.path == "/brief" ? "Raport." : "Połączenie jest.") }
        let brief = await client().brief()
        let ping = await client().ping()
        XCTAssertEqual(brief, .answer("Raport."))
        XCTAssertEqual(ping, .answer("Połączenie jest."))
        XCTAssertEqual(MockURLProtocol.requests.map(\.httpMethod), ["GET", "GET"])
        XCTAssertNil(MockURLProtocol.requests.first?.httpBody)
    }

    func test401SaysCheckToken() async {
        MockURLProtocol.handler = { _ in (401, "Brak dostępu. Sprawdź token w skrócie.") }
        let outcome = await client().ask("x", conversationID: nil)
        XCTAssertEqual(outcome.failure, .unauthorized)
        XCTAssertEqual(outcome.spoken, VoicePhrases.unauthorized)
        XCTAssertTrue(outcome.failure!.endsConversation)
    }

    func test429KeepsServerSentence() async {
        MockURLProtocol.handler = { _ in (429, "Za dużo prób z błędnym tokenem. Spróbuj za kwadrans.") }
        let outcome = await client().ask("x", conversationID: nil)
        XCTAssertEqual(outcome.failure, .tooMany)
        XCTAssertEqual(outcome.spoken, "Za dużo prób z błędnym tokenem. Spróbuj za kwadrans.")
        XCTAssertFalse(outcome.failure!.endsConversation)
    }

    func test429WithoutBodyUsesDefault() async {
        MockURLProtocol.handler = { _ in (429, "") }
        let outcome = await client().brief()
        XCTAssertEqual(outcome.spoken, VoicePhrases.tooMany)
    }

    func test502FromTailscaleServeMeansNoConnection() async {
        MockURLProtocol.handler = { _ in (502, "<html>Bad Gateway</html>") }
        let outcome = await client().ask("x", conversationID: nil)
        XCTAssertEqual(outcome.failure, .noConnection)
        XCTAssertEqual(outcome.spoken, VoicePhrases.noConnection)
    }

    func test500WithSentenceIsSpoken() async {
        MockURLProtocol.handler = { _ in (500, "Coś poszło nie tak po stronie serwera. Spróbuj za chwilę.") }
        let outcome = await client().ask("x", conversationID: nil)
        XCTAssertEqual(outcome.failure, .server)
        XCTAssertEqual(outcome.spoken, "Coś poszło nie tak po stronie serwera. Spróbuj za chwilę.")
    }

    func testNetworkErrorSaysCheckTailscale() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let outcome = await client().ask("x", conversationID: nil)
        XCTAssertEqual(outcome, .failure(.noConnection))
        XCTAssertEqual(outcome.spoken, "Nie mam połączenia z Makiem, sprawdź Tailscale.")
    }

    func testDNSFailureSaysCheckTailscale() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotFindHost) }
        let outcome = await client().ping()
        XCTAssertEqual(outcome.failure, .noConnection)
    }

    func testTimeoutIsNotFatal() async {
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let outcome = await client().ask("x", conversationID: nil)
        XCTAssertEqual(outcome.failure, .timeout)
        XCTAssertFalse(outcome.failure!.endsConversation)
    }

    func testEmptyBodyIsServerFailure() async {
        MockURLProtocol.handler = { _ in (200, "  ") }
        let outcome = await client().brief()
        XCTAssertEqual(outcome.failure, .server)
    }

    func testMissingTokenDoesNotHitNetwork() async {
        let outcome = await client(token: nil).ask("x", conversationID: nil)
        XCTAssertEqual(outcome, .failure(.notConfigured))
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testRelayRoundTrip() {
        let outcomes: [HandsfreeOutcome] = [
            .answer("Odpowiedź."),
            .failure(.noConnection),
            .failure(.tooMany, spoken: "Za dużo prób."),
        ]
        for outcome in outcomes {
            XCTAssertEqual(VoiceRelay.decode(VoiceRelay.encode(outcome)), outcome)
        }
        XCTAssertEqual(VoiceRelay.decode(["failure": "nonsense"]).failure, .server)
    }
}
