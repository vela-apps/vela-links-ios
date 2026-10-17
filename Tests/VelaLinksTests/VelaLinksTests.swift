import XCTest
@testable import VelaLinks

final class VelaLinksTests: XCTestCase {
    var store = MemoryStorage()
    var clock = FakeClock()

    override func setUp() {
        store = MemoryStorage()
        clock = FakeClock()
        FakeURLProtocol.reset(nil)
    }

    func deps(source: FakeInstallSource? = nil, center: NotificationCenter = NotificationCenter(),
              observe: Bool = false) -> Dependencies {
        var d = Dependencies()
        d.fetcher = makeFetcher()
        d.store = store
        d.installSource = source ?? FakeInstallSource(nil)
        let c = clock
        d.now = { c.date }
        d.notificationCenter = center
        d.observeLifecycle = observe
        d.appVersion = "1.2.3"
        d.backgroundTasks = nil
        d.flushEvery = 3600
        return d
    }

    func config(key: String = "k", slug: String? = nil, matchDeferred: Bool = false, reportOpens: Bool = true,
                trackEvents: Bool = true, autoTrack: Bool = false, appId: String? = "com.x.app") -> Configuration {
        var c = Configuration(apiKey: key, baseUrl: "https://links.x.com")
        c.slug = slug
        c.matchDeferred = matchDeferred
        c.reportOpens = reportOpens
        c.trackEvents = trackEvents
        c.autoTrack = autoTrack
        c.appId = appId
        return c
    }

    func sdk(_ c: Configuration? = nil, _ d: Dependencies? = nil) async throws -> VelaLinks {
        let s = VelaLinks()
        try await s.configure(c ?? config(), d ?? deps())
        return s
    }

    private func linkReply(_ r: Captured, events: EventServer? = nil) -> FakeReply {
        switch r.path {
        case "/v1/events": return events?.reply(r) ?? .reply(202, "{}")
        case "/v1/open": return .reply(204, "")
        case "/v1/links": return .reply(201, "{\"url\":\"https://links.x.com/l/my-day/abc\"}")
        case "/v1/match": return .reply(200, "{\"matched\":false}")
        default: return .reply(200, linkJSON)
        }
    }

    func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: links

    func testCreateLinkPostsToTheAPIAndReturnsTheShortUrl() async throws {
        FakeURLProtocol.reset { self.linkReply($0) }
        let s = try await sdk()
        let made = try await s.createLink(route: "/invite", params: ["id": "42"], title: "Hi", campaign: "c",
                                          expiresInHours: 5)
        XCTAssertEqual(made, "https://links.x.com/l/my-day/abc")
        let seen = try XCTUnwrap(FakeURLProtocol.seen.first)
        XCTAssertEqual(seen.header("X-Api-Key"), "k")
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.json?["route"] as? String, "/invite")
        XCTAssertEqual(seen.json?["title"] as? String, "Hi")
        XCTAssertEqual(seen.json?["campaign"] as? String, "c")
        XCTAssertEqual(seen.json?["expires_in_hours"] as? Int, 5)
        XCTAssertNil(seen.json?["description"])
    }

    func testCreateLinkSurfacesAPIErrorsAndAnEmptyRoute() async throws {
        FakeURLProtocol.reset { _ in .reply(401, "{\"detail\":\"Invalid API key\"}") }
        let s = try await sdk()
        let error = await expectThrows { try await s.createLink(route: "/x") }
        XCTAssertEqual(error?.statusCode, 401)
        let empty = await expectThrows { try await s.createLink(route: "  ") }
        XCTAssertEqual(empty?.kind, .invalidArgument)
        let unconfigured = await expectThrows { try await VelaLinks().createLink(route: "/x") }
        XCTAssertEqual(unconfigured?.kind, .invalidArgument)
    }

    func testResolveEmitsToListenersOrHoldsTheLinkWhenThereAreNone() async throws {
        FakeURLProtocol.reset { _ in .reply(200, "{\"code\":\"abc\",\"route\":\"/invite\",\"params\":{\"id\":\"42\"}}") }
        let s = try await sdk(config(reportOpens: false))
        _ = await s.resolve(url: url("https://links.x.com/l/my-day/abc"))
        XCTAssertEqual(s.consumePendingLink()?.route, "/invite")
        XCTAssertNil(s.consumePendingLink()) // never handed out twice

        var iterator = s.links.makeAsyncIterator()
        _ = await s.resolve(url: url("myday://l/my-day/abc"))
        let next = await iterator.next()
        XCTAssertEqual(next?.params["id"] as? String, "42")
        XCTAssertFalse(next?.deferred ?? true)
    }

    func testAClosureHandlerReceivesLinksOnTheMainThreadUntilCancelled() async throws {
        FakeURLProtocol.reset { _ in .reply(200, linkJSON) }
        let s = try await sdk(config(reportOpens: false))
        let got = expectation(description: "handler")
        var onMain = false
        var count = 0
        let observation = s.onLink { _ in
            onMain = Thread.isMainThread
            count += 1
            got.fulfill()
        }
        _ = await s.resolve(url: url("https://h/l/s/abc"))
        await fulfillment(of: [got], timeout: 5)
        XCTAssertTrue(onMain)
        observation.cancel()
        _ = await s.resolve(url: url("https://h/l/s/abc"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(s.consumePendingLink()) // nobody listening again: held
    }

    func testALinkAListenerReceivedIsNotKeptToBeHandedOutAgain() async throws {
        FakeURLProtocol.reset { _ in .reply(200, linkJSON) }
        let s = try await sdk(config(reportOpens: false))
        _ = await s.resolve(url: url("https://h/l/s/abc")) // nobody listening: kept
        var iterator = s.links.makeAsyncIterator()
        _ = await s.resolve(url: url("https://h/l/s/abc")) // delivered, old copy dropped
        let first = await iterator.next()
        XCTAssertNotNil(first)
        XCTAssertNil(s.consumePendingLink())
    }

    func testAMalformedLinkIsIgnoredWithoutAnyNetworkCall() async throws {
        FakeURLProtocol.reset { _ in .reply(200, linkJSON) }
        let s = try await sdk()
        let nothing = await s.resolve(url: url("myday://l/../admin"))
        XCTAssertNil(nothing)
        XCTAssertFalse(s.handle(url: url("myday://l/../admin")))
        XCTAssertTrue(FakeURLProtocol.seen.isEmpty)
    }

    func testOpeningFromAQRLinkReportsQrAndAPlainLinkReportsLink() async throws {
        FakeURLProtocol.reset { self.linkReply($0) }
        let s = try await sdk()
        _ = await s.resolve(url: url("https://my-day.links.x.com/l/my-day/abc?s=qr"))
        _ = await s.resolve(url: url("https://my-day.links.x.com/l/my-day/abc"))
        _ = await s.resolve(url: url("myday://l/my-day/abc"))
        await s.currentEngine()?.idle()
        let opens = FakeURLProtocol.seen.filter { $0.path == "/v1/open" }
        XCTAssertEqual(opens.compactMap { $0.json?["source"] as? String }.sorted(), ["link", "link", "qr"])
        XCTAssertTrue(opens.allSatisfy { $0.json?["code"] as? String == "abc" && $0.header("X-Api-Key") == "k" })
    }

    func testReportOpensFalseSendsNothingAndAFailingReportNeverThrows() async throws {
        FakeURLProtocol.reset { self.linkReply($0) }
        let off = try await sdk(config(reportOpens: false))
        _ = await off.resolve(url: url("https://h/l/s/abc"))
        await off.currentEngine()?.idle()
        XCTAssertTrue(FakeURLProtocol.seen.filter { $0.path == "/v1/open" }.isEmpty)

        FakeURLProtocol.reset { r in r.path == "/v1/open" ? .fail(URLError(.notConnectedToInternet)) : self.linkReply(r) }
        let on = try await sdk()
        let link = await on.resolve(url: url("https://h/l/s/abc?s=qr"))
        await on.currentEngine()?.idle()
        XCTAssertEqual(link?.route, "/x")
    }

    func testAnUnknownLinkReportsNothing() async throws {
        FakeURLProtocol.reset { _ in .reply(404, "not found") }
        let s = try await sdk()
        let nothing = await s.resolve(url: url("https://h/l/s/nope?s=qr"))
        XCTAssertNil(nothing)
        await s.currentEngine()?.idle()
        XCTAssertTrue(FakeURLProtocol.seen.filter { $0.path == "/v1/open" }.isEmpty)
    }

    func testEveryCallCarriesTheAppIdExceptThePublicLookup() async throws {
        FakeURLProtocol.reset { self.linkReply($0) }
        let s = try await sdk(config(appId: "com.acme.shop"))
        _ = try await s.createLink(route: "/x")
        _ = await s.resolve(url: url("https://h/l/s/abc"))
        await s.currentEngine()?.idle()
        let signed = FakeURLProtocol.seen.filter { $0.path != "/v1/links/s/abc" }
        XCTAssertEqual(signed.count, 2) // create and open report
        XCTAssertTrue(signed.allSatisfy { $0.header("X-App-Id") == "com.acme.shop" })
        let lookup = FakeURLProtocol.seen.first { $0.path == "/v1/links/s/abc" }
        XCTAssertNil(lookup?.header("X-App-Id"))
        XCTAssertNil(lookup?.header("X-Api-Key"))
    }

    func testTheBundleIdentifierIsTheDefaultAppId() async throws {
        FakeURLProtocol.reset { self.linkReply($0) }
        let s = try await sdk(config(appId: nil))
        _ = try await s.createLink(route: "/x")
        XCTAssertEqual(FakeURLProtocol.seen.first?.header("X-App-Id"), Bundle.main.bundleIdentifier)
    }

    func testWithASlugSetLinksOfAnotherAppAreIgnoredWithoutARequest() async throws {
        FakeURLProtocol.reset { _ in .reply(200, linkJSON) }
        let s = try await sdk(config(slug: "my-day", reportOpens: false))
        let other = await s.resolve(url: url("https://h/l/other-app/abc"))
        XCTAssertNil(other)
        XCTAssertTrue(FakeURLProtocol.seen.isEmpty)
        let mine = await s.resolve(url: url("https://h/l/My-Day/abc"))
        XCTAssertNotNil(mine)
    }

    func testAConfigureWithAnInsecureUrlOrEmptyKeyIsRefused() async throws {
        let s = VelaLinks()
        var bad = config()
        bad.baseUrl = "http://links.x.com"
        let insecure = await expectThrows { try await s.configure(bad, self.deps()) }
        XCTAssertEqual(insecure?.kind, .invalidArgument)
        let empty = await expectThrows { try await s.configure(self.config(key: "  "), self.deps()) }
        XCTAssertEqual(empty?.kind, .invalidArgument)
        XCTAssertFalse(s.isConfigured)
    }

    func testTwoConfiguresAtOnceLeaveExactlyOneWorkingEngine() async throws {
        FakeURLProtocol.reset { self.linkReply($0) }
        let s = VelaLinks()
        let first = Task { try await s.configure(self.config(key: "a"), self.deps()) }
        try await Task.sleep(nanoseconds: 50_000_000) // "a" is first in line
        let second = Task { try await s.configure(self.config(key: "b"), self.deps()) }
        try await first.value
        try await second.value
        XCTAssertTrue(s.isConfigured)
        _ = try await s.createLink(route: "/x")
        XCTAssertEqual(FakeURLProtocol.seen.last?.header("X-Api-Key"), "b")
    }

    func testABadBaseUrlOnASecondConfigureLeavesTheRunningEngineAlone() async throws {
        FakeURLProtocol.reset { self.linkReply($0) }
        let s = try await sdk()
        let running = s.currentEngine()
        var bad = config()
        bad.baseUrl = "http://evil.com"
        _ = await expectThrows { try await s.configure(bad, self.deps()) }
        XCTAssertTrue(running === s.currentEngine())
        let link = await s.resolve(url: url("https://h/l/s/abc"))
        XCTAssertNotNil(link)
    }

    func testReconfiguringShutsTheOldEngineDown() async throws {
        let s = try await sdk()
        let old = try XCTUnwrap(s.currentEngine())
        try await s.configure(config(key: "b"), deps())
        XCTAssertTrue(old.isDisposed)
        XCTAssertFalse(try XCTUnwrap(s.currentEngine()).isDisposed)
    }

    // MARK: events through the SDK

    func testTheOneLineMethodsAndTheDefaultCurrency() async throws {
        let server = EventServer()
        server.install()
        let s = try await sdk()
        s.track("signup", properties: ["plan": "free"])
        s.trackPurchase(99.5)
        s.trackScreen("Home")
        await s.flush()
        let list = (server.batches.first?["events"] as? [[String: Any]]) ?? []
        XCTAssertEqual(list.compactMap { $0["name"] as? String }, ["signup", "purchase", "screen_view"])
        XCTAssertEqual(list[1]["currency"] as? String, "INR")
        XCTAssertTrue(s.trackingEnabled)
        await s.setTrackingEnabled(false)
        XCTAssertFalse(s.trackingEnabled)
    }

    func testALinkThatOpensTheAppIsRememberedAsTheSourceOfLaterEvents() async throws {
        let server = EventServer()
        FakeURLProtocol.reset { self.linkReply($0, events: server) }
        let s = try await sdk()
        _ = await s.resolve(url: url("https://h/l/s/abc"))
        s.track("signup")
        await s.flush()
        XCTAssertEqual(server.batches.first?["first_link"] as? String, "abc")
        XCTAssertEqual(server.batches.first?["last_link"] as? String, "abc")
    }

    func testTrackingBeforeConfigureFinishesIsKeptInOrderAndNeverCrashes() async throws {
        let server = EventServer()
        server.install()
        let s = VelaLinks()
        s.track("early_one")
        s.trackScreen("Splash")
        await s.setUserId("user_early")
        await s.flush() // before configure: queued, returns at once
        XCTAssertFalse(s.trackingEnabled)
        XCTAssertNil(s.consumePendingLink())
        try await s.configure(config(), deps())
        s.track("late_one")
        await s.flush()
        await eventually("the queued calls") { server.names.count == 3 }
        XCTAssertEqual(server.names, ["early_one", "screen_view", "late_one"])
        // the early events were sent under the identity they were made under, the late one under the new user id
        XCTAssertNil(server.batches.first?["uid"])
        XCTAssertEqual(server.batches.last?["uid"] as? String, "user_early")
    }

    func testAppLifecycleNotificationsFlushAndStartSessions() async throws {
        let server = EventServer()
        server.install()
        let center = NotificationCenter()
        let s = try await sdk(config(autoTrack: true), deps(center: center, observe: true))
        s.track("add_to_cart")
        center.post(name: Lifecycle.didEnterBackground, object: nil)
        await eventually("the background flush") { server.names.contains("add_to_cart") }
        clock.advance(3 * 3600)
        center.post(name: Lifecycle.willEnterForeground, object: nil)
        await s.flush()
        XCTAssertEqual(server.names.filter { $0 == "session_start" }.count, 2)
        await s.shutdownAndWait()
        let before = server.hits
        center.post(name: Lifecycle.didEnterBackground, object: nil) // no longer listening
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(server.hits, before)
    }

    func testConsentFlowThroughThePublicAPI() async throws {
        let server = EventServer()
        server.install()
        let s = try await sdk(config(trackEvents: false, autoTrack: true))
        s.track("ignored")
        await s.flush()
        XCTAssertTrue(server.batches.isEmpty)
        await s.setTrackingEnabled(true)
        await s.flush()
        XCTAssertEqual(server.names, ["first_open", "session_start"])
    }

    func testShutdownEndsStreamsAndStopsResolving() async throws {
        FakeURLProtocol.reset { _ in .reply(200, linkJSON) }
        let s = try await sdk()
        var iterator = s.links.makeAsyncIterator()
        await s.shutdownAndWait()
        s.shutdown()
        let ended = await iterator.next()
        XCTAssertNil(ended)
        XCTAssertFalse(s.isConfigured)
        let nothing = await s.resolve(url: url("https://h/l/s/abc"))
        XCTAssertNil(nothing)
        s.track("after") // never crashes
    }

    // MARK: handle(url:) and handle(userActivity:)

    func testHandleURLIsFireAndForgetAndIgnoresADoubleHandOver() async throws {
        FakeURLProtocol.reset { self.linkReply($0) }
        let s = try await sdk(config(reportOpens: false))
        var iterator = s.links.makeAsyncIterator()
        XCTAssertTrue(s.handle(url: url("https://h/l/s/abc")))
        XCTAssertTrue(s.handle(url: url("https://h/l/s/abc"))) // the same address again within 2 seconds
        XCTAssertFalse(s.handle(url: url("https://h/other")))
        let link = await iterator.next()
        XCTAssertEqual(link?.code, "abc")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(FakeURLProtocol.seen.filter { $0.path.hasPrefix("/v1/links/") }.count, 1)
    }

    func testHandleUserActivityReadsTheWebpageURL() async throws {
        FakeURLProtocol.reset { self.linkReply($0) }
        let s = try await sdk(config(reportOpens: false))
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url("https://h/l/s/abc")
        XCTAssertTrue(s.handle(userActivity: activity))
        let other = NSUserActivity(activityType: "something.else")
        other.webpageURL = url("https://h/l/s/abc")
        XCTAssertFalse(s.handle(userActivity: other))
        let plain = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        plain.webpageURL = url("https://h/not-a-link")
        XCTAssertFalse(s.handle(userActivity: plain))
        await eventually("the link") { s.consumePendingLink() != nil }
    }

    // MARK: deferred matching through configure

    func testConfigureMatchesDeferredLinksAndEmitsThemAsDeferred() async throws {
        FakeURLProtocol.reset { r in
            r.path == "/v1/match"
                ? .reply(200, "{\"matched\":true,\"link\":{\"code\":\"zzz\",\"route\":\"/promo\",\"params\":{}}}")
                : self.linkReply(r)
        }
        let source = FakeInstallSource("vlink:Ab12Cd34Ef")
        let s = try await sdk(config(matchDeferred: true), deps(source: source))
        await s.waitForDeferredCheck()
        let link = try XCTUnwrap(s.consumePendingLink())
        XCTAssertTrue(link.deferred)
        XCTAssertEqual(link.route, "/promo")
        XCTAssertEqual(source.cleared, ["vlink:Ab12Cd34Ef"])
        s.currentEngine()?.tracker.drainStorage()
        XCTAssertEqual(try store.string(forKey: StorageKeys.firstLink), "zzz")
    }

    func testMatchDeferredFalseNeverReadsTheClipboard() async throws {
        let source = FakeInstallSource("vlink:Ab12Cd34Ef")
        let s = try await sdk(config(matchDeferred: false), deps(source: source))
        await s.waitForDeferredCheck()
        XCTAssertEqual(source.reads, 0)
    }

    // MARK: models

    func testLinkParsingIsStrictAboutTypes() {
        XCTAssertNil(VelaLink.tryParse(["code": 1, "route": "/x"]))
        XCTAssertNil(VelaLink.tryParse(["code": "a"]))
        XCTAssertNil(VelaLink.tryParse(["code": "a", "route": "/x", "params": "nope"]))
        XCTAssertNil(VelaLink.tryParse(["code": "a", "route": "/x", "title": 5]))
        let ok = VelaLink.tryParse(["code": "a", "route": "/x", "title": "T", "campaign": NSNull()], deferred: true)
        XCTAssertEqual(ok?.title, "T")
        XCTAssertNil(ok?.campaign)
        XCTAssertEqual(ok?.deferred, true)
        XCTAssertEqual(ok?.params.count, 0)
    }

    func testTheSharedInstanceAlwaysExistsAndIsSafeBeforeConfigure() {
        let s = VelaLinks.shared
        XCTAssertTrue(s === VelaLinks.shared)
        XCTAssertFalse(s.trackingEnabled)
        XCTAssertNil(s.consumePendingLink())
    }
}
