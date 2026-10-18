import XCTest
@testable import VelaLinks

final class EventTrackerTests: XCTestCase {
    var clock = FakeClock()
    var store = MemoryStorage()
    var trackers: [EventTracker] = []

    override func setUp() {
        clock = FakeClock()
        store = MemoryStorage()
        trackers = []
    }

    override func tearDown() async throws {
        for t in trackers { await t.stop() }
    }

    func tracker(_ server: EventServer, autoTrack: Bool = true, enabled: Bool = true, flushAt: Int = 20,
                 version: String? = "2.3.1", platform: String? = "ios", start: Bool = true) throws -> EventTracker {
        server.install()
        trackers.forEach { $0.drainStorage() } // a restart reads what the earlier run has written
        var options = EventTracker.Options()
        options.autoTrack = autoTrack
        options.enabled = enabled
        options.flushAt = flushAt
        options.flushEvery = 3600
        options.identityFlushTimeout = 2
        let c = clock
        let t = EventTracker(api: try makeApi(base: "https://links.x.com"), store: store, platform: platform,
                             appVersion: version, now: { c.date }, options: options)
        trackers.append(t)
        if start { t.start() }
        return t
    }

    private func events(_ batch: [String: Any]) -> [[String: Any]] { batch["events"] as? [[String: Any]] ?? [] }

    // MARK: automatic events

    func testTheFirstLaunchReportsFirstOpenAndSessionStartOnce() async throws {
        let server = EventServer()
        let t = try tracker(server)
        await t.flush()
        XCTAssertEqual(server.names, ["first_open", "session_start"])
        let again = try tracker(server)
        clock.advance(300)
        await again.flush()
        XCTAssertEqual(server.names, ["first_open", "session_start"]) // a quick relaunch is the same visit
    }

    func testComingBackAfterMoreThan30MinutesIsANewSession() async throws {
        let server = EventServer()
        try await tracker(server).flush()
        clock.advance(31 * 60)
        let t = try tracker(server)
        await t.flush()
        XCTAssertEqual(server.names, ["first_open", "session_start", "session_start"])
    }

    func testAutoTrackFalseReportsNothingByItself() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        await t.flush()
        XCTAssertTrue(server.batches.isEmpty)
        t.track("signup")
        await t.flush()
        XCTAssertEqual(server.names, ["signup"])
    }

    func testGoingToTheBackgroundSendsWhatIsWaitingAndComingBackLaterStartsASession() async throws {
        let server = EventServer()
        let t = try tracker(server)
        t.track("add_to_cart")
        t.appDidEnterBackground()
        await eventually("the background flush") { Set(server.names).isSuperset(of: ["add_to_cart", "first_open"]) }
        clock.advance(2 * 3600)
        t.appWillEnterForeground()
        await t.flush()
        XCTAssertEqual(server.names.filter { $0 == "session_start" }.count, 2)
    }

    func testAnInstallWithTheLinkCheckDoneStillReportsFirstOpenOnce() async throws {
        try store.setBool(true, forKey: StorageKeys.deferredChecked)
        let server = EventServer()
        let t = try tracker(server)
        await t.flush()
        XCTAssertEqual(server.names, ["first_open", "session_start"])
    }

    func testANewInstallReportsFirstOpenAndTheFlagIsStoredAfterTheEventIsSaved() async throws {
        let server = EventServer()
        server.status = 503 // offline: the event stays in the saved queue
        let t = try tracker(server)
        t.drainStorage()
        XCTAssertEqual(try store.bool(forKey: StorageKeys.firstOpenSent), true)
        XCTAssertTrue(try store.string(forKey: StorageKeys.queue)?.contains("first_open") ?? false)
    }

    // MARK: what is sent

    func testWhatIsSentForOneSimpleBatch() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("signup", properties: ["plan": "gold"])
        t.trackScreen("Home")
        await t.flush()
        let batch = try XCTUnwrap(server.batches.first)
        XCTAssertEqual(server.batches.count, 1)
        XCTAssertEqual((batch["iid"] as? String)?.count, 32)
        XCTAssertEqual(batch["platform"] as? String, "ios")
        XCTAssertEqual(batch["app_version"] as? String, "2.3.1")
        let list = events(batch)
        XCTAssertEqual(list.first?["name"] as? String, "signup")
        XCTAssertEqual(list.first?["props"] as? [String: String], ["plan": "gold"])
        XCTAssertEqual((list.first?["ts"] as? NSNumber)?.int64Value, clock.ms)
        XCTAssertEqual((list.last?["eid"] as? String)?.count, 24)
        XCTAssertNotEqual(list.first?["eid"] as? String, list.last?["eid"] as? String)
        var last = list.last ?? [:]
        last["eid"] = nil
        XCTAssertEqual(Set(last.keys), ["name", "ts", "screen"])
        XCTAssertEqual(last["screen"] as? String, "Home")
    }

    func testTheSameInstallIdIsUsedEveryTimeAndANewOneAfterAReset() async throws {
        let server = EventServer()
        let a = try tracker(server, autoTrack: false)
        a.track("one")
        await a.flush()
        let b = try tracker(server, autoTrack: false)
        b.track("two")
        await b.flush()
        XCTAssertEqual(server.batches[0]["iid"] as? String, server.batches[1]["iid"] as? String)
        await b.reset()
        b.track("three")
        await b.flush()
        XCTAssertNotEqual(server.batches[2]["iid"] as? String, server.batches[0]["iid"] as? String)
    }

    func testBigQueuesGoOutInBatchesOfAtMost50() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false, flushAt: 1000)
        for i in 0..<120 { t.track("event_\(i)") }
        await t.flush()
        XCTAssertEqual(server.batches.map { events($0).count }, [50, 50, 20])
    }

    func testAPurchaseCarriesItsAmountAndCurrency() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track(EventNames.purchase, value: 499, currency: "inr")
        await t.flush()
        let e = try XCTUnwrap(events(server.batches[0]).first)
        XCTAssertEqual((e["value"] as? NSNumber)?.doubleValue, 499)
        XCTAssertEqual(e["currency"] as? String, "INR")
    }

    func testTheInstallLinkAndTheLatestLinkTravelWithTheEvents() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.noteLink("FIRST12", installSource: false)
        t.noteLink("LATER34", installSource: false)
        t.track("signup")
        await t.flush()
        XCTAssertEqual(server.batches[0]["first_link"] as? String, "FIRST12")
        XCTAssertEqual(server.batches[0]["last_link"] as? String, "LATER34")
        t.noteLink("DEFER56", installSource: true) // a matched install overrides
        t.track("again")
        await t.flush()
        XCTAssertEqual(server.batches.last?["first_link"] as? String, "DEFER56")
    }

    func testThePlatformIsLeftOutWhenThereIsNone() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false, platform: nil)
        t.track("signup")
        await t.flush()
        XCTAssertNil(server.batches[0]["platform"])
    }

    func testAnAppVersionWithSpacesIsCleanedAndCutToTwentyCharacters() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false, version: "2.3 RC1 (debug)")
        t.track("signup")
        await t.flush()
        XCTAssertEqual(server.batches[0]["app_version"] as? String, "2.3RC1debug")
        XCTAssertEqual(Check.cleanVersion(String(repeating: "1", count: 30))?.count, 20)
        XCTAssertNil(Check.cleanVersion("()  é"))
    }

    // MARK: bad input and failures

    func testInvalidNamesAmountsAndCurrenciesAreDroppedQuietly() throws {
        let t = try tracker(EventServer(), autoTrack: false)
        t.track("x")
        t.track("1bad")
        t.track("has space")
        t.track("name\n")
        t.track(String(repeating: "a", count: 41))
        t.track("purchase", value: -1, currency: "INR")
        t.track("purchase", value: .nan, currency: "INR")
        t.track("purchase", value: .infinity, currency: "INR")
        t.track("purchase", value: 5, currency: "RUPEES")
        XCTAssertEqual(t.pending, 0)
        t.track("good_one")
        XCTAssertEqual(t.pending, 1)
    }

    func testPropertiesAreLimitedToTenSimpleValues() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        var props: [String: Any] = ["nested": ["a": 1], "list": [1], "long": String(repeating: "x", count: 500)]
        for i in 0..<20 { props["k\(i)"] = i }
        t.track("many", properties: props)
        await t.flush()
        let sent = try XCTUnwrap(events(server.batches[0]).first?["props"] as? [String: Any])
        XCTAssertEqual(sent.count, 10)
        XCTAssertNil(sent["nested"])
        XCTAssertNil(sent["list"])
    }

    func testPropertyValueTypesAndLimits() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("types", properties: ["s": String(repeating: "y", count: 300), "i": 3, "d": 2.5, "b": true,
                                      "n": NSNull(), "bad key": 1, "1x": 1, "nan": Double.nan,
                                      "inf": Double.infinity])
        await t.flush()
        let sent = try XCTUnwrap(events(server.batches[0]).first?["props"] as? [String: Any])
        XCTAssertEqual((sent["s"] as? String)?.count, 100)
        XCTAssertEqual(sent["i"] as? Int, 3)
        XCTAssertEqual(sent["d"] as? Double, 2.5)
        XCTAssertEqual(sent["b"] as? Bool, true)
        XCTAssertTrue(sent["n"] is NSNull)
        XCTAssertEqual(Set(sent.keys), ["s", "i", "d", "b", "n"])
    }

    func testNumbersThatAreNotFiniteAreLeftOutOfProperties() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("signup", properties: ["a": Double.nan, "b": Double.infinity, "c": 3])
        await t.flush()
        let sent = try XCTUnwrap(events(server.batches[0]).first?["props"] as? [String: Any])
        XCTAssertEqual(sent.keys.sorted(), ["c"])
    }

    func testAServerErrorKeepsTheEventsAndALaterTrySendsThem() async throws {
        let server = EventServer(503)
        let t = try tracker(server, autoTrack: false)
        t.track("signup")
        await t.flush()
        XCTAssertEqual(t.pending, 1)
        server.status = 202
        clock.advance(60)
        await t.flush()
        XCTAssertEqual(t.pending, 0)
        XCTAssertEqual(server.names, ["signup"])
    }

    func testBackOffNewEventsWaitAForcedFlushDoesNot() async throws {
        let server = EventServer(503)
        let t = try tracker(server, autoTrack: false, flushAt: 1)
        t.track("signup") // flushAt 1 sends at once and fails
        await eventually("the first try") { server.hits == 1 && !t.isFlushing }
        server.status = 202
        t.track("login") // would send immediately without the back-off
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(server.names.isEmpty)
        XCTAssertEqual(server.hits, 1)
        await t.flush(force: true)
        XCTAssertEqual(server.names, ["signup", "login"])
    }

    func testBackOffGrowsFrom30SecondsAndDoublesUpTo300() async throws {
        let server = EventServer(503)
        let t = try tracker(server, autoTrack: false)
        t.track("signup")
        await t.flush()
        XCTAssertEqual(server.hits, 1)
        clock.advance(29)
        await t.flush()
        XCTAssertEqual(server.hits, 1) // still inside the first 30 s
        clock.advance(2)
        await t.flush()
        XCTAssertEqual(server.hits, 2)
        clock.advance(59) // the wait is now 60 s
        await t.flush()
        XCTAssertEqual(server.hits, 2)
        clock.advance(2)
        await t.flush()
        XCTAssertEqual(server.hits, 3)
        for _ in 0..<6 { // 120, 240, then 300 for ever
            clock.advance(301)
            await t.flush()
        }
        XCTAssertEqual(server.hits, 9)
        clock.advance(299)
        await t.flush()
        XCTAssertEqual(server.hits, 9)
        clock.advance(2)
        await t.flush()
        XCTAssertEqual(server.hits, 10)
    }

    func testABatchThatIsSentAgainKeepsItsIdAndTheSameEvents() async throws {
        let server = EventServer(503)
        let t = try tracker(server, autoTrack: false)
        var ids: [String] = []
        var counts: [Int] = []
        FakeURLProtocol.reset { r in
            ids.append(r.json?["bid"] as? String ?? "")
            counts.append((r.json?["events"] as? [Any])?.count ?? 0)
            return .reply(ids.count >= 3 ? 202 : 503, "{}")
        }
        t.track("signup")
        await t.flush()
        t.track("login") // arrives after the failed attempt: must not change the repeated batch
        await t.flush(force: true)
        await t.flush(force: true)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(ids[0].count, 24)
        XCTAssertEqual(ids[1], ids[0]) // sent again with the same id and the same single event
        XCTAssertEqual(ids[2], ids[0])
        XCTAssertEqual(counts, [1, 1, 1, 1])
        XCTAssertNotEqual(ids[3], ids[0]) // the next batch (the late event) is a new one
    }

    func testAnEventIsSavedAtOnce() throws {
        let t = try tracker(EventServer(), autoTrack: false)
        t.track("signup")
        t.drainStorage()
        XCTAssertTrue(try store.string(forKey: StorageKeys.queue)?.contains("signup") ?? false)
    }

    func testTheSameEventTwiceWithinASecondIsCountedOnce() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("add_to_cart", properties: ["sku": "a"])
        t.track("add_to_cart", properties: ["sku": "a"])
        t.track("add_to_cart", properties: ["sku": "b"]) // different details: a different event
        clock.advance(2)
        t.track("add_to_cart", properties: ["sku": "b"])
        await t.flush()
        XCTAssertEqual(server.names.count, 3)
    }

    func testDebounceCoversEveryField() throws {
        let t = try tracker(EventServer(), autoTrack: false)
        t.track("purchase", value: 10, currency: "INR", orderId: "A")
        t.track("purchase", value: 10, currency: "INR", orderId: "A")
        XCTAssertEqual(t.pending, 1)
        t.track("purchase", value: 10, currency: "INR", orderId: "B")
        t.track("purchase", value: 11, currency: "INR", orderId: "B")
        t.track("purchase", value: 11, currency: "USD", orderId: "B")
        XCTAssertEqual(t.pending, 4)
    }

    func testAOnceOnlyEventIsSentASingleTimeAlsoAfterARestart() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("tutorial_done", once: true)
        t.track("tutorial_done", once: true)
        clock.advance(5)
        t.track("tutorial_done", once: true)
        await t.flush()
        XCTAssertEqual(server.names, ["tutorial_done"])
        let again = try tracker(server, autoTrack: false)
        again.track("tutorial_done", once: true)
        await again.flush()
        XCTAssertEqual(server.names, ["tutorial_done"])
        XCTAssertEqual(events(server.batches[0])[0]["once"] as? Bool, true)
    }

    func testOnceOnlyIsPerPersonANewUserIdCanDoItAgain() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("tutorial_done", once: true)
        await t.flush()
        await t.setUserId("user_b")
        t.track("tutorial_done", once: true)
        await t.flush()
        XCTAssertEqual(server.names, ["tutorial_done", "tutorial_done"])
        t.track("tutorial_done", once: true)
        await t.flush()
        XCTAssertEqual(server.names.count, 2)
        t.drainStorage()
        XCTAssertEqual(Set(try store.strings(forKey: StorageKeys.onceDone) ?? []), ["|tutorial_done", "user_b|tutorial_done"])
    }

    func testLegacyOnceEntriesWithoutASeparatorBelongToTheAnonymousPerson() async throws {
        try store.setStrings(["tutorial_done"], forKey: StorageKeys.onceDone)
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("tutorial_done", once: true)
        await t.flush()
        XCTAssertTrue(server.batches.isEmpty)
        await t.setUserId("someone")
        t.track("tutorial_done", once: true)
        await t.flush()
        XCTAssertEqual(server.names, ["tutorial_done"])
    }

    func testAPurchaseWithAnOrderIdCarriesItAndABadOrderIdIsLeftOffButThePurchaseIsKept() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("purchase", value: 10, currency: "INR", orderId: "ORD-1")
        clock.advance(2)
        t.track("purchase", value: 10, currency: "INR", orderId: "bad id!")
        await t.flush()
        let list = events(server.batches[0])
        XCTAssertEqual(list[0]["order_id"] as? String, "ORD-1")
        XCTAssertNil(list[1]["order_id"])
        XCTAssertEqual(list.count, 2)
    }

    func testTheUserIdTravelsSurvivesARestartAndAResetClearsIt() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        await t.setUserId("user 1") // spaces are not allowed
        await t.setUserId("user_123")
        t.track("signup")
        await t.flush()
        XCTAssertEqual(server.batches[0]["uid"] as? String, "user_123")
        let again = try tracker(server, autoTrack: false)
        again.track("login")
        await again.flush()
        XCTAssertEqual(server.batches.last?["uid"] as? String, "user_123")
        await again.reset()
        again.track("other")
        await again.flush()
        XCTAssertNil(server.batches.last?["uid"])
    }

    func testAUserIdTheServiceWouldRefuseIsIgnored() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        await t.setUserId("user\u{2028}x")
        await t.setUserId("é")
        await t.setUserId("user\n")
        await t.setUserId(String(repeating: "a", count: 101))
        await t.setUserId("")
        t.track("signup")
        await t.flush()
        XCTAssertNil(server.batches[0]["uid"])
        await t.setUserId(String(repeating: "a", count: 100))
        t.track("two")
        await t.flush()
        XCTAssertEqual((server.batches.last?["uid"] as? String)?.count, 100)
    }

    func testSigningInOrOutSendsWhatWasWaitingUnderTheOldIdentityFirst() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("add_to_cart")
        await t.setUserId("user_a")
        XCTAssertEqual(server.batches.count, 1)
        XCTAssertNil(server.batches[0]["uid"])
        t.track("checkout")
        await t.reset()
        XCTAssertEqual(server.batches.count, 2)
        XCTAssertEqual(server.batches.last?["uid"] as? String, "user_a")
        XCTAssertEqual(t.pending, 0)
    }

    func testIdentityChangeGivesUpWaitingAfterTheTimeout() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("add_to_cart")
        FakeURLProtocol.reset { _ in .hang }
        let started = Date()
        await t.setUserId("user_a")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.5)
    }

    func testABatchTheServiceRefusesForGoodIsThrownAway() async throws {
        let t = try tracker(EventServer(422), autoTrack: false)
        t.track("signup")
        await t.flush()
        XCTAssertEqual(t.pending, 0)
    }

    func testARefusedKeyKeepsTheEventsToTryAgain() async throws {
        for status in [401, 403, 408] {
            store = MemoryStorage() // each try is a fresh install
            let t = try tracker(EventServer(status), autoTrack: false)
            t.track("signup")
            await t.flush()
            XCTAssertEqual(t.pending, 1, "status \(status)")
        }
    }

    func testANetworkErrorNeverThrows() async throws {
        let t = try tracker(EventServer(), autoTrack: false)
        FakeURLProtocol.reset { _ in .fail(URLError(.notConnectedToInternet)) }
        t.track("signup")
        await t.flush()
        XCTAssertEqual(t.pending, 1)
    }

    func testSentEventsAreRemovedByIdentityNotByCount() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("first_one")
        FakeURLProtocol.reset { [clock] r in
            clock.advance(0)
            return server.reply(r)
        }
        t.track("second_one")
        await t.flush()
        XCTAssertEqual(server.names, ["first_one", "second_one"])
        XCTAssertEqual(t.pending, 0)
    }

    func testWaitingEventsSurviveAClosedAppAndWeekOldOnesAreDropped() async throws {
        let server = EventServer(503)
        let first = try tracker(server, autoTrack: false)
        first.track("kept")
        await first.flush()
        await first.stop()
        clock.advance(3 * 86400)
        server.status = 202
        let second = try tracker(server, autoTrack: false)
        await second.flush()
        XCTAssertEqual(server.names, ["kept"])
        server.status = 503
        second.track("too_old")
        await second.flush()
        await second.stop()
        clock.advance(8 * 86400)
        server.status = 202
        let third = try tracker(server, autoTrack: false)
        await third.flush()
        XCTAssertEqual(server.names, ["kept"])
    }

    func testAFullQueueDropsScreenViewsBeforeSignUpsAndPurchases() throws {
        let t = try tracker(EventServer(503), autoTrack: false, flushAt: 1000)
        t.track("signup")
        for i in 0..<210 {
            clock.advance(2)
            t.track("screen_view", screen: "S\(i)")
        }
        XCTAssertEqual(t.pending, 200)
        t.drainStorage()
        XCTAssertTrue(try store.string(forKey: StorageKeys.queue)?.contains("signup") ?? false)
    }

    func testAFullQueueWithoutScreenViewsDropsTheOldestEvent() throws {
        let t = try tracker(EventServer(503), autoTrack: false, flushAt: 1000)
        for i in 0..<201 {
            clock.advance(2)
            t.track("event_\(i)")
        }
        XCTAssertEqual(t.pending, 200)
        t.drainStorage()
        let saved = try XCTUnwrap(try store.string(forKey: StorageKeys.queue))
        XCTAssertFalse(saved.contains("\"event_0\""))
        XCTAssertTrue(saved.contains("\"event_200\""))
    }

    func testAScreenShownWhileTrackingWasOffIsReportedAfterTrackingIsTurnedOn() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        await t.setEnabled(false)
        t.trackScreen("Home")
        await t.setEnabled(true)
        t.trackScreen("Home")
        await t.flush()
        let screens = server.batches.flatMap { events($0).compactMap { $0["screen"] as? String } }
        XCTAssertEqual(screens, ["Home"])
    }

    func testTrackScreenReportsTheSameScreenOnceUntilSomethingElseIsShown() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.trackScreen("Home")
        t.trackScreen("Home")
        clock.advance(5)
        t.trackScreen("Cart")
        clock.advance(5)
        t.trackScreen("Home")
        await t.flush()
        let screens = server.batches.flatMap { events($0).compactMap { $0["screen"] as? String } }
        XCTAssertEqual(screens, ["Home", "Cart", "Home"])
    }

    // MARK: consent

    func testTurningTrackingOffDiscardsWaitingEventsStopsNewOnesAndIsRemembered() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false)
        t.track("before")
        await t.setEnabled(false)
        t.track("after")
        await t.flush()
        XCTAssertTrue(server.batches.isEmpty)
        XCTAssertFalse(t.isEnabled)
        let restarted = try tracker(server, autoTrack: false)
        restarted.track("still_off")
        await restarted.flush()
        XCTAssertTrue(server.batches.isEmpty)
        await restarted.setEnabled(true)
        restarted.track("back_on")
        await restarted.flush()
        XCTAssertEqual(server.names, ["back_on"])
    }

    func testStartingDisabledReportsNothingNotEvenFirstOpen() async throws {
        let server = EventServer()
        let t = try tracker(server, enabled: false)
        await t.flush()
        XCTAssertTrue(server.batches.isEmpty)
        XCTAssertEqual(t.pending, 0)
    }

    func testConsentFlowDisabledThenEnabledStartsTheAutomaticEvents() async throws {
        let server = EventServer()
        let t = try tracker(server, enabled: false)
        t.track("ignored_while_off")
        XCTAssertEqual(t.pending, 0)
        await t.setEnabled(true)
        t.track("signup")
        await t.flush()
        XCTAssertEqual(server.names, ["first_open", "session_start", "signup"])
        t.drainStorage()
        XCTAssertEqual(try store.bool(forKey: StorageKeys.optedOut), false)
        XCTAssertEqual(try store.bool(forKey: StorageKeys.firstOpenSent), true)
    }

    func testAChoiceMadeBeforeStartFinishesIsRemembered() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false, start: false)
        await t.setEnabled(false) // before start()
        t.start()
        t.track("signup")
        XCTAssertEqual(t.pending, 0)
        t.drainStorage()
        XCTAssertEqual(try store.bool(forKey: StorageKeys.optedOut), true)
    }

    func testAnOptOutFromAnEarlierRunStaysInForce() async throws {
        try store.setBool(true, forKey: StorageKeys.optedOut)
        let server = EventServer()
        let t = try tracker(server)
        await t.flush()
        XCTAssertFalse(t.isEnabled)
        XCTAssertTrue(server.batches.isEmpty)
    }

    func testBrokenStorageDisablesTrackingWithoutAnyError() async throws {
        store.failing = true
        let server = EventServer()
        let t = try tracker(server)
        t.track("signup")
        await t.setEnabled(true)
        await t.setUserId("user_1")
        await t.flush()
        XCTAssertFalse(t.isEnabled)
        XCTAssertTrue(server.batches.isEmpty)
    }

    func testCallsBeforeStartDoNotCrash() async throws {
        let server = EventServer()
        let t = try tracker(server, autoTrack: false, start: false)
        t.track("early")
        await t.flush() // no install id yet: nothing is sent
        XCTAssertTrue(server.batches.isEmpty)
        t.start()
        await t.flush()
        XCTAssertEqual(server.names, ["early"])
    }
}
