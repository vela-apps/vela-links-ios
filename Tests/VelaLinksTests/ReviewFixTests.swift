import XCTest
@testable import VelaLinks

/// Behaviour added in 1.0.1: identity safety, first_open with consent, links before configure, value and screen limits.
extension EventTrackerTests {
    private func sentEvents(_ batch: [String: Any]) -> [[String: Any]] { batch["events"] as? [[String: Any]] ?? [] }

    func testEventsStayWithThePersonTheyWereTrackedFor() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("before_sign_in")
        FakeURLProtocol.reset { _ in .hang } // the identity-change send cannot get through
        await t.setUserId("user_a")
        t.track("after_sign_in")
        server.install()
        await t.flush(force: true)
        XCTAssertEqual(server.batches.count, 2)
        guard server.batches.count == 2 else { return }
        XCTAssertNil(server.batches[0]["uid"])
        XCTAssertEqual(sentEvents(server.batches[0]).compactMap { $0["name"] as? String }, ["before_sign_in"])
        XCTAssertEqual(server.batches[1]["uid"] as? String, "user_a")
        XCTAssertEqual(sentEvents(server.batches[1]).compactMap { $0["name"] as? String }, ["after_sign_in"])
        XCTAssertEqual(t.pending, 0)
    }

    func testTheOwnerIsSavedWithTheQueueButNeverSent() async throws {
        let server = EventServer(503)
        let t = try tracker(server, autoTrack: false)
        await t.setUserId("user_a")
        t.track("signup")
        t.drainStorage()
        let saved = try XCTUnwrap(try store.string(forKey: StorageKeys.queue))
        XCTAssertTrue(saved.contains("\"_uid\":\"user_a\""), saved)
        XCTAssertTrue(saved.contains("_iid"), saved)
        server.status = 202
        await t.flush(force: true)
        let wire = try XCTUnwrap(sentEvents(try XCTUnwrap(server.batches.first)).first)
        XCTAssertNil(wire["_iid"])
        XCTAssertNil(wire["_uid"])
    }

    func testAQueueSavedByAnEarlierVersionGoesOutUnderTheCurrentIdentity() async throws {
        try store.setString("[{\"name\":\"old_one\",\"ts\":\(clock.ms),\"eid\":\"aabbccdd11\"}]", forKey: StorageKeys.queue)
        try store.setString("user_9", forKey: StorageKeys.userId)
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        await t.flush()
        XCTAssertEqual(server.batches.first?["uid"] as? String, "user_9")
        XCTAssertEqual(server.names, ["old_one"])
    }

    func testAForcedFlushWaitsForASendThatIsAlreadyRunning() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("signup")
        let calls = NSLock()
        nonisolated(unsafe) var count = 0
        FakeURLProtocol.reset { r in
            calls.lock()
            count += 1
            let first = count == 1
            calls.unlock()
            return first ? .hang : server.reply(r) // the first send is stuck until it times out
        }
        let running = Task { await t.flush() }
        try await Task.sleep(nanoseconds: 200_000_000)
        await t.flush(force: true)
        XCTAssertEqual(server.names, ["signup"]) // the forced flush did not give up because a send was running
        await running.value
    }

    func testAPersonWhoAgreesOnALaterLaunchStillGetsFirstOpen() async throws {
        try store.setBool(true, forKey: StorageKeys.deferredChecked) // launch 1 finished the link check, tracking was off
        let server = EventServer()
        let t = try tracker(server, enabled: false)
        await t.setEnabled(true)
        await t.flush()
        XCTAssertEqual(server.names, ["first_open", "session_start"])
    }

    func testAnAppKilledBeforeFirstOpenWasSavedSendsItOnTheNextStart() async throws {
        // launch 1 ran (session started, link check done) but was killed before first_open reached the saved queue
        try store.setBool(true, forKey: StorageKeys.deferredChecked)
        try store.setInt(Int(clock.ms), forKey: StorageKeys.lastActive)
        let server = EventServer()
        let t = try tracker(server)
        await t.flush()
        XCTAssertEqual(server.names, ["first_open"]) // the session is still the same visit
    }

    func testAnAppKilledAfterTheSaveButBeforeTheFlagSendsExactlyOneFirstOpen() async throws {
        let offline = EventServer(503)
        let first = try tracker(offline)
        first.drainStorage()
        await first.stop()
        first.drainStorage()
        XCTAssertTrue(try XCTUnwrap(try store.string(forKey: StorageKeys.queue)).contains("first_open"))
        try store.remove(forKey: StorageKeys.firstOpenSent) // killed before the flag was written
        let server = EventServer()
        let second = try tracker(server)
        await second.flush()
        XCTAssertEqual(server.names.filter { $0 == "first_open" }.count, 1)
        let sent = try XCTUnwrap(server.batches.first)
        let opens = (sent["events"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == "first_open" }
        XCTAssertEqual(opens.first?["once"] as? Bool, true)
    }

    func testAmountsAboveABillionAreDroppedBecauseTheServiceRefusesThem() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("purchase", value: 2_000_000_000, currency: "INR")
        XCTAssertEqual(t.pending, 0)
        t.track("purchase", value: 1_000_000_000, currency: "INR")
        XCTAssertEqual(t.pending, 1)
    }

    func testAScreenNameIsCutToOneHundredUnicodeScalars() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.trackScreen(String(repeating: "e\u{301}", count: 100)) // 100 characters, 200 scalars
        await t.flush()
        let screen = try XCTUnwrap(sentEvents(try XCTUnwrap(server.batches.first)).first?["screen"] as? String)
        XCTAssertEqual(screen.unicodeScalars.count, 100)
    }

    func testAResetBeforeStartStillMakesANewInstallId() async throws {
        let old = String(repeating: "a", count: 32)
        try store.setString(old, forKey: StorageKeys.iid)
        let server = EventServer()
        let t = try tracker(server, autoTrack: false, start: false)
        await t.reset()
        t.start()
        t.track("signup")
        await t.flush()
        let iid = try XCTUnwrap(server.batches.first?["iid"] as? String)
        XCTAssertNotEqual(iid, old)
        XCTAssertEqual(iid.count, 32)
    }
}

extension VelaLinksTests {
    func testFirstOpenIsReportedWhenAPersonAgreesAfterTheDeferredCheckFinished() async throws {
        let server = EventServer()
        FakeURLProtocol.reset { self.matchOrEvents($0, server) }
        let s = try await sdk(config(matchDeferred: true, trackEvents: false, autoTrack: true))
        await s.waitForDeferredCheck()
        XCTAssertEqual(try store.bool(forKey: StorageKeys.deferredChecked), true) // the check has finished
        await s.setTrackingEnabled(true)
        await s.flush()
        XCTAssertEqual(server.names, ["first_open", "session_start"])
    }

    private func matchOrEvents(_ r: Captured, _ server: EventServer) -> FakeReply {
        r.path == "/v1/match" ? .reply(200, "{\"matched\":false}") : server.reply(r)
    }

    func testALinkHandedOverBeforeConfigureIsResolvedWhenConfigureFinishes() async throws {
        FakeURLProtocol.reset { self.linkOnly($0) }
        let s = VelaLinks()
        XCTAssertTrue(s.handle(url: url("https://h/l/s/abc")))
        XCTAssertTrue(s.handle(url: url("https://h/l/s/abc"))) // the same address again within 2 seconds
        XCTAssertNil(s.consumePendingLink())
        try await s.configure(config(reportOpens: false), deps())
        await eventually("the held link") { FakeURLProtocol.seen.contains { $0.path.hasPrefix("/v1/links/") } }
        await eventually("the pending link") { s.currentEngine() != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(FakeURLProtocol.seen.filter { $0.path.hasPrefix("/v1/links/") }.count, 1)
        let link = try XCTUnwrap(s.consumePendingLink())
        XCTAssertEqual(link.code, "abc")
        XCTAssertNil(s.consumePendingLink()) // handed out once
    }

    func testAHeldLinkGoesToAListenerAndIsNotKeptAsPending() async throws {
        FakeURLProtocol.reset { self.linkOnly($0) }
        let s = VelaLinks()
        var iterator = s.links.makeAsyncIterator()
        XCTAssertTrue(s.handle(url: url("https://h/l/s/abc")))
        try await s.configure(config(reportOpens: false), deps())
        let link = await iterator.next()
        XCTAssertEqual(link?.code, "abc")
        XCTAssertNil(s.consumePendingLink())
    }

    private func linkOnly(_ r: Captured) -> FakeReply {
        r.path.hasPrefix("/v1/links/") ? .reply(200, linkJSON) : .reply(204, "")
    }
}

#if canImport(UIKit) && !os(macOS) && !os(watchOS)
final class RealBackgroundRunnerTests: XCTestCase {
    func testTheRealRunnerStartsAndEndsATaskWithoutCrashing() {
        let runner = UIKitBackgroundTaskRunner()
        if let token = runner.begin(name: "VelaLinks test", expiration: {}) { runner.end(token) }
    }
}
#endif
