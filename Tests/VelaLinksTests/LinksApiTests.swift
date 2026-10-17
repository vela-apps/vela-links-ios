import XCTest
@testable import VelaLinks

final class LinksApiTests: XCTestCase {
    override func setUp() { FakeURLProtocol.reset(nil) }

    func testBaseUrlMustBeHttpsExceptForLocalhost() throws {
        for bad in ["http://links.x.com", "ftp://links.x.com", "links.x.com", ""] {
            XCTAssertThrowsError(try LinksApi.normaliseBaseUrl(bad), bad)
        }
        XCTAssertEqual(try LinksApi.normaliseBaseUrl("https://links.x.com//"), "https://links.x.com")
        XCTAssertEqual(try LinksApi.normaliseBaseUrl("http://localhost:8000"), "http://localhost:8000")
        XCTAssertEqual(try LinksApi.normaliseBaseUrl("http://10.0.2.2:8000"), "http://10.0.2.2:8000")
    }

    func testBaseUrlWithUserQueryOrFragmentIsRefusedAndTidied() throws {
        for bad in ["https://user@links.x.com", "https://user:pw@links.x.com", "https://links.x.com?a=1",
                    "https://links.x.com/#x", "http://localhost.evil.com", "http://links.x.com", "ftp://links.x.com"] {
            XCTAssertThrowsError(try LinksApi.normaliseBaseUrl(bad), bad)
        }
        XCTAssertEqual(try LinksApi.normaliseBaseUrl("HTTPS://Links.X.com/"), "https://links.x.com")
        XCTAssertEqual(try LinksApi.normaliseBaseUrl("https://links.x.com/api//"), "https://links.x.com/api")
        XCTAssertEqual(try LinksApi.normaliseBaseUrl("http://LOCALHOST:8000"), "http://localhost:8000")
    }

    func testATimeoutBecomesAnError() async throws {
        FakeURLProtocol.reset { _ in .hang }
        let error = await expectThrows { try await makeApi(timeout: 0.1).createLink(["route": "/x"]) }
        XCTAssertEqual(error?.kind, .timeout)
    }

    func testAConnectionErrorBecomesAnError() async throws {
        FakeURLProtocol.reset { _ in .fail(URLError(.notConnectedToInternet)) }
        let error = await expectThrows { try await makeApi().createLink(["route": "/x"]) }
        XCTAssertEqual(error?.kind, .network)
    }

    func testAnyKindOfFailureIsAnError() async throws {
        for failure: Error in [URLError(.serverCertificateUntrusted), URLError(.secureConnectionFailed),
                               NSError(domain: "x", code: 1)] {
            FakeURLProtocol.reset { _ in .fail(failure) }
            _ = await expectThrows("\(failure)") { try await makeApi().createLink(["route": "/x"]) }
        }
    }

    func testTheServerMessageAndStatusAreKept() async throws {
        FakeURLProtocol.reset { _ in .reply(401, "{\"detail\":\"Invalid API key\"}") }
        let error = await expectThrows { try await makeApi().createLink(["route": "/x"]) }
        XCTAssertEqual(error?.statusCode, 401)
        XCTAssertEqual(error?.message, "Invalid API key")
    }

    func testANonJSONErrorBodyIsNotEchoed() async throws {
        FakeURLProtocol.reset { _ in .reply(500, "<html>secret stack trace</html>") }
        let error = await expectThrows { try await makeApi().createLink(["route": "/x"]) }
        XCTAssertEqual(error?.message, "Request failed (500)")
    }

    func testAVeryLongServerMessageIsNotPassedOn() async throws {
        FakeURLProtocol.reset { _ in .reply(400, "{\"detail\":\"" + String(repeating: "x", count: 5000) + "\"}") }
        let error = await expectThrows { try await makeApi().createLink(["route": "/x"]) }
        XCTAssertLessThan(error?.message.count ?? 1000, 100)
    }

    func testReportingAnOpenNeverThrows() async throws {
        FakeURLProtocol.reset { _ in .fail(URLError(.notConnectedToInternet)) }
        try await makeApi().reportOpen(code: "abc", source: "link")
        FakeURLProtocol.reset { _ in .fail(URLError(.serverCertificateUntrusted)) }
        try await makeApi().reportOpen(code: "abc", source: "link")
    }

    func testTheCodeAndSlugAreEncodedIntoThePath() async throws {
        FakeURLProtocol.reset { _ in .reply(404, "not found") }
        let link = try await makeApi().resolve(slug: "my day", code: "a/b")
        XCTAssertNil(link)
        XCTAssertEqual(FakeURLProtocol.seen.first?.url.absoluteString, "https://links.x.com/v1/links/my%20day/a%2Fb")
    }

    func testEveryAuthenticatedCallCarriesTheKey() async throws {
        FakeURLProtocol.reset { r in .reply(r.path == "/v1/links" ? 201 : 200, "{\"url\":\"u\",\"matched\":false}") }
        let api = try makeApi()
        _ = try await api.createLink(["route": "/x"])
        _ = try await api.match(platform: "ios", token: nil)
        await api.reportOpen(code: "abc", source: "qr")
        XCTAssertEqual(FakeURLProtocol.seen.map { $0.header("X-Api-Key") }, ["vl_key", "vl_key", "vl_key"])
        XCTAssertEqual(FakeURLProtocol.seen.first?.header("Content-Type"), "application/json")
    }

    func testARedirectIsRefusedAndTheKeyIsNeverSentToAnotherAddress() async throws {
        FakeURLProtocol.reset { _ in .redirect("https://evil.example/steal") }
        let error = await expectThrows { try await makeApi().createLink(["route": "/x"]) }
        XCTAssertEqual(error?.statusCode, 302)
        XCTAssertTrue(FakeURLProtocol.seen.allSatisfy { $0.url.host == "links.x.com" })
    }

    func testAPlain3xxAnswerIsRefused() async throws {
        FakeURLProtocol.reset { _ in .reply(301, "") }
        let error = await expectThrows { try await makeApi().createLink(["route": "/x"]) }
        XCTAssertEqual(error?.kind, .redirect)
    }

    func testUnexpected201BodiesAreErrors() async throws {
        for body in ["[]", "{\"url\": 5}", "{\"url\": \"\"}", "not json", "{}"] {
            FakeURLProtocol.reset { _ in .reply(201, body) }
            _ = await expectThrows(body) { try await makeApi().createLink(["route": "/x"]) }
        }
    }

    func testAnUnreadableLinkAnswerIsNotFound() async throws {
        for body in ["[]", "nope", "{\"code\": 1}", "{\"code\": \"a\"}"] {
            FakeURLProtocol.reset { _ in .reply(200, body) }
            let link = try await makeApi().resolve(slug: "s", code: "abc")
            XCTAssertNil(link, body)
        }
    }

    func testThePublicLookupCarriesNeitherTheKeyNorTheAppId() async throws {
        FakeURLProtocol.reset { _ in .reply(404, "{}") }
        _ = try await makeApi(appId: { "com.acme.shop" }, key: "secret-key").resolve(slug: "s", code: "abc")
        let headers = (FakeURLProtocol.seen.first?.headers ?? [:]).keys.map { $0.lowercased() }
        XCTAssertFalse(headers.contains("x-api-key"))
        XCTAssertFalse(headers.contains("x-app-id"))
    }

    func testTheKeyIsNeverPartOfAnErrorMessage() async throws {
        FakeURLProtocol.reset { _ in .fail(URLError(.networkConnectionLost)) }
        let error = await expectThrows { try await makeApi(key: "vl_super_secret").createLink(["route": "/x"]) }
        XCTAssertFalse("\(String(describing: error))".contains("vl_super_secret"))
    }

    func testAnAnswerStreamedInChunksIsCutOffAtTheLimit() async throws {
        let chunks = (0..<40).map { _ in Data(repeating: 65, count: 64 * 1024) }
        FakeURLProtocol.reset { _ in .chunks(200, chunks) }
        let error = await expectThrows { try await makeApi().createLink(["route": "/x"]) }
        XCTAssertTrue(error?.message.contains("too much") ?? false)
    }

    func testParamsThatAreNotJSONAreAnInvalidArgument() async throws {
        FakeURLProtocol.reset { _ in .reply(201, "{}") }
        let error = await expectThrows { try await makeApi().createLink(["route": "/x", "params": ["a": Date()]]) }
        XCTAssertEqual(error?.kind, .invalidArgument)
        let nan = await expectThrows { try await makeApi().createLink(["route": "/x", "params": ["a": Double.nan]]) }
        XCTAssertEqual(nan?.kind, .invalidArgument)
        XCTAssertTrue(FakeURLProtocol.seen.isEmpty)
    }

    func testIfTheAppIdCannotBeReadTheCallStillGoesOut() async throws {
        FakeURLProtocol.reset { _ in .reply(201, "{\"url\":\"u\"}") }
        _ = try await makeApi(appId: { nil }).createLink(["route": "/x"])
        XCTAssertNil(FakeURLProtocol.seen.first?.header("X-App-Id"))
    }

    func testEventSendResults() async throws {
        let cases: [(Int, EventSendResult)] = [(200, .sent), (202, .sent), (401, .retry), (403, .retry), (408, .retry),
                                               (429, .retry), (500, .retry), (503, .retry), (400, .drop), (404, .drop),
                                               (422, .drop)]
        for (status, expected) in cases {
            FakeURLProtocol.reset { _ in .reply(status, "{}") }
            let result = try await makeApi().sendEvents(["iid": "a"])
            XCTAssertEqual(result, expected, "status \(status)")
        }
        FakeURLProtocol.reset { _ in .fail(URLError(.timedOut)) }
        let offline = try await makeApi().sendEvents(["iid": "a"])
        XCTAssertEqual(offline, .retry)
    }
}
