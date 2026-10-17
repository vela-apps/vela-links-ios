import XCTest
@testable import VelaLinks

final class DeferredMatcherTests: XCTestCase {
    private let link = "{\"code\":\"abc\",\"route\":\"/invite\",\"params\":{\"id\":\"7\"}}"
    private var store = MemoryStorage()

    override func setUp() {
        store = MemoryStorage()
        FakeURLProtocol.reset(nil)
    }

    private func matcher(_ source: FakeInstallSource) throws -> DeferredMatcher {
        DeferredMatcher(api: try makeApi(), store: store, source: source)
    }

    func testOnlyTextThatLooksLikeOurClipboardTokenIsUsed() {
        XCTAssertEqual(DeferredMatcher.extractToken("vlink:Ab12Cd34Ef"), "vlink:Ab12Cd34Ef")
        for raw in ["my bank password is hunter2", "vlink:", "vlink:no spaces allowed", "https://example.com",
                    "vlink:Ab12Cd34Ef\n", "vlink:short", "vlink:" + String(repeating: "a", count: 33), ""] {
            XCTAssertNil(DeferredMatcher.extractToken(raw), raw)
        }
        XCTAssertNil(DeferredMatcher.extractToken(nil))
    }

    func testTheTokenIsSentTheLinkComesBackDeferredAndTheTokenIsCleared() async throws {
        FakeURLProtocol.reset { _ in .reply(200, "{\"matched\":true,\"method\":\"token\",\"link\":\(self.link)}") }
        let source = FakeInstallSource("vlink:Ab12Cd34Ef")
        let found = try await matcher(source).run()
        let sent = FakeURLProtocol.seen.first?.json as? [String: String]
        XCTAssertEqual(sent, ["platform": "ios", "token": "vlink:Ab12Cd34Ef"])
        XCTAssertEqual(found?.deferred, true)
        XCTAssertEqual(found?.route, "/invite")
        XCTAssertEqual(source.cleared, ["vlink:Ab12Cd34Ef"])
    }

    func testSomethingUnrelatedOnTheClipboardSendsNoToken() async throws {
        FakeURLProtocol.reset { _ in .reply(200, "{\"matched\":false}") }
        _ = try await matcher(FakeInstallSource("my private note")).run()
        XCTAssertEqual(FakeURLProtocol.seen.first?.json as? [String: String], ["platform": "ios"])
        XCTAssertFalse(String(decoding: FakeURLProtocol.seen.first?.body ?? Data(), as: UTF8.self).contains("private"))
    }

    func testItOnlyRunsOnce() async throws {
        FakeURLProtocol.reset { _ in .reply(200, "{\"matched\":false}") }
        let m = try matcher(FakeInstallSource(nil))
        let first = await m.run()
        let second = await m.run()
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(FakeURLProtocol.seen.count, 1)
    }

    func testFailuresAreRetriedButOnlyThreeLaunches() async throws {
        FakeURLProtocol.reset { _ in .reply(500, "boom") }
        let source = FakeInstallSource("vlink:Ab12Cd34Ef")
        let m = try matcher(source)
        for _ in 0..<6 { _ = await m.run() }
        XCTAssertEqual(FakeURLProtocol.seen.count, DeferredMatcher.maxAttempts)
        XCTAssertEqual(source.reads, DeferredMatcher.maxAttempts)
        XCTAssertEqual(try store.bool(forKey: StorageKeys.deferredChecked), true)
        XCTAssertTrue(source.cleared.isEmpty)
    }

    func testANetworkErrorNeverThrowsAndCountsAsAFailedTry() async throws {
        FakeURLProtocol.reset { _ in .fail(URLError(.notConnectedToInternet)) }
        let found = try await matcher(FakeInstallSource(nil)).run()
        XCTAssertNil(found)
        XCTAssertEqual(try store.int(forKey: StorageKeys.deferredAttempts), 1)
    }

    func testAMatchedAnswerThatIsNotAValidLinkIsIgnored() async throws {
        FakeURLProtocol.reset { _ in .reply(200, "{\"matched\":true,\"link\":{\"code\":1}}") }
        let found = try await matcher(FakeInstallSource(nil)).run()
        XCTAssertNil(found)
    }

    func testBrokenStorageNeverThrowsOrMatches() async throws {
        FakeURLProtocol.reset { _ in .reply(200, "{\"matched\":false}") }
        store.failing = true
        let found = try await matcher(FakeInstallSource(nil)).run()
        XCTAssertNil(found)
        XCTAssertTrue(FakeURLProtocol.seen.isEmpty)
    }
}
