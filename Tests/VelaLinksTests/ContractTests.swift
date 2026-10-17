import XCTest
@testable import VelaLinks

/// Sends one batch with every field and checks the exact JSON field names and formats of the Vela Links contract.
final class ContractTests: XCTestCase {
    private func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex
    }

    func testOneBatchHasExactlyTheDocumentedFieldNamesAndFormats() async throws {
        let store = MemoryStorage()
        let server = EventServer()
        server.install()
        let clock = FakeClock()
        var options = EventTracker.Options()
        options.autoTrack = false
        options.flushEvery = 3600
        let tracker = EventTracker(api: try makeApi(), store: store, platform: "ios", appVersion: "2.3 RC1+b.5_x",
                                   now: { clock.date }, options: options)
        tracker.start()
        await tracker.setUserId("User_123~!")
        tracker.noteLink("FIRST12", installSource: false)
        tracker.noteLink("LAST34", installSource: false)
        tracker.track("signup", properties: ["plan": "gold", "n": 3, "ratio": 0.5, "ok": true, "none": NSNull()],
                      once: true)
        clock.advance(2)
        tracker.track("purchase", properties: nil, value: 499.5, currency: "inr", orderId: "ORD-1:a.b_c")
        clock.advance(2)
        tracker.trackScreen(String(repeating: "S", count: 150))
        await tracker.flush()

        let batch = try XCTUnwrap(server.batches.first)
        XCTAssertEqual(Set(batch.keys), ["iid", "bid", "platform", "app_version", "uid", "first_link", "last_link", "events"])
        XCTAssertTrue(matches(batch["iid"] as? String ?? "", "[0-9a-f]{32}"))
        XCTAssertTrue(matches(batch["bid"] as? String ?? "", "[0-9a-f]{24}"))
        XCTAssertEqual(batch["platform"] as? String, "ios")
        XCTAssertEqual(batch["app_version"] as? String, "2.3RC1+b.5_x")
        XCTAssertEqual(batch["uid"] as? String, "User_123~!")
        XCTAssertEqual(batch["first_link"] as? String, "FIRST12")
        XCTAssertEqual(batch["last_link"] as? String, "LAST34")

        let events = try XCTUnwrap(batch["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        for event in events {
            XCTAssertTrue(matches(event["eid"] as? String ?? "", "[0-9a-f]{24}"))
            XCTAssertTrue(event["ts"] is NSNumber)
            XCTAssertEqual(floor((event["ts"] as? Double) ?? -1), (event["ts"] as? Double) ?? -2) // whole milliseconds
        }
        let signup = events[0]
        XCTAssertEqual(Set(signup.keys), ["name", "ts", "props", "eid", "once"])
        XCTAssertEqual(signup["once"] as? Bool, true)
        XCTAssertEqual((signup["ts"] as? NSNumber)?.int64Value, FakeClock().ms)
        let props = try XCTUnwrap(signup["props"] as? [String: Any])
        XCTAssertEqual(props["plan"] as? String, "gold")
        XCTAssertEqual(props["n"] as? Int, 3)
        XCTAssertEqual(props["ratio"] as? Double, 0.5)
        XCTAssertEqual(props["ok"] as? Bool, true)
        XCTAssertTrue(props["none"] is NSNull)

        let purchase = events[1]
        XCTAssertEqual(Set(purchase.keys), ["name", "ts", "value", "currency", "eid", "order_id"])
        XCTAssertEqual(purchase["value"] as? Double, 499.5)
        XCTAssertEqual(purchase["currency"] as? String, "INR")
        XCTAssertEqual(purchase["order_id"] as? String, "ORD-1:a.b_c")
        XCTAssertNil(purchase["once"]) // only present when true

        let screen = events[2]
        XCTAssertEqual(Set(screen.keys), ["name", "ts", "screen", "eid"])
        XCTAssertEqual(screen["name"] as? String, "screen_view")
        XCTAssertEqual((screen["screen"] as? String)?.count, 100)

        // the request itself
        let request = try XCTUnwrap(FakeURLProtocol.seen.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/events")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(request.header("X-Api-Key"), "vl_key")
        await tracker.stop()
    }

    func testTheOtherEndpointsUseTheDocumentedBodies() async throws {
        FakeURLProtocol.reset { r in
            switch r.path {
            case "/v1/links": return .reply(201, "{\"url\":\"u\"}")
            case "/v1/match": return .reply(200, "{\"matched\":false}")
            default: return .reply(200, linkJSON)
            }
        }
        let api = try makeApi(appId: { "com.acme.app" })
        _ = try await api.createLink(["route": "/r", "params": ["a": 1]])
        _ = try await api.match(platform: "ios", token: "vlink:Ab12Cd34Ef")
        _ = try await api.match(platform: "ios", token: nil)
        await api.reportOpen(code: "abc", source: "qr")
        _ = try await api.resolve(slug: "s", code: "abc")
        let seen = FakeURLProtocol.seen
        XCTAssertEqual(seen.map { "\($0.method) \($0.path)" },
                       ["POST /v1/links", "POST /v1/match", "POST /v1/match", "POST /v1/open", "GET /v1/links/s/abc"])
        XCTAssertEqual(seen[0].json?["route"] as? String, "/r")
        XCTAssertEqual(seen[1].json as? [String: String], ["platform": "ios", "token": "vlink:Ab12Cd34Ef"])
        XCTAssertEqual(seen[2].json as? [String: String], ["platform": "ios"])
        XCTAssertEqual(seen[3].json as? [String: String], ["code": "abc", "source": "qr"])
        XCTAssertTrue(seen[0...3].allSatisfy { $0.header("X-App-Id") == "com.acme.app" })
        XCTAssertEqual(seen[4].body.count, 0)
    }

    func testStorageKeysAreTheDocumentedOnes() {
        XCTAssertEqual([StorageKeys.iid, StorageKeys.queue, StorageKeys.firstLink, StorageKeys.lastLink,
                        StorageKeys.optedOut, StorageKeys.firstOpenSent, StorageKeys.lastActive, StorageKeys.userId,
                        StorageKeys.onceDone, StorageKeys.deferredChecked, StorageKeys.deferredAttempts],
                       ["iid", "queue", "first_link", "last_link", "opted_out", "first_open_sent", "last_active",
                        "user_id", "once_done", "deferred_checked", "deferred_attempts"].map { "vela_links." + $0 })
    }

    func testUserDefaultsStorageRoundTripsInASuite() throws {
        let name = "vela-links-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let s = UserDefaultsStorage(defaults)
        XCTAssertNil(try s.string(forKey: "k"))
        try s.setString("v", forKey: "k")
        try s.setBool(false, forKey: "b")
        try s.setInt(1_792_238_400_000, forKey: "i")
        try s.setStrings(["a", "b"], forKey: "l")
        XCTAssertEqual(try s.string(forKey: "k"), "v")
        XCTAssertEqual(try s.bool(forKey: "b"), false)
        XCTAssertEqual(try s.int(forKey: "i"), 1_792_238_400_000)
        XCTAssertEqual(try s.strings(forKey: "l"), ["a", "b"])
        XCTAssertTrue(try s.contains("b"))
        try s.remove(forKey: "b")
        XCTAssertFalse(try s.contains("b"))
        XCTAssertNil(try s.bool(forKey: "b"))
    }
}
