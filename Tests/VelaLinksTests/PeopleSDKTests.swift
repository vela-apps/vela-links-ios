import XCTest
@testable import VelaLinks

/// The identity token on the tracker, the hooks the in-app controller needs, and the public people and shopping calls. Ported from
/// the Flutter SDK's `people_test.dart` and `vela_links_people_test.dart`.
final class PeopleSDKTests: XCTestCase {
    var service = FakeService()
    var store = MemoryStorage()
    var clock = FakeClock()
    var trackers: [EventTracker] = []
    var sdks: [VelaLinks] = []

    override func setUp() {
        service = FakeService()
        store = MemoryStorage()
        clock = FakeClock()
        trackers = []
        sdks = []
        service.install()
    }

    override func tearDown() async throws {
        for t in trackers { await t.stop() }
        for s in sdks { await s.shutdownAndWait() }
    }

    private func tracker(autoTrack: Bool = false) throws -> EventTracker {
        var options = EventTracker.Options()
        options.autoTrack = autoTrack
        options.flushEvery = 3600
        let c = clock
        let t = EventTracker(api: try makeApi(), store: store, platform: "ios", appVersion: "2.3.1", now: { c.date },
                             options: options)
        trackers.append(t)
        trackers.forEach { $0.drainStorage() }
        t.start()
        return t
    }

    private func sdk(configure: Bool = true) async throws -> VelaLinks {
        service.install()
        var d = Dependencies()
        d.fetcher = makeFetcher()
        d.store = store
        d.installSource = FakeInstallSource(nil)
        d.observeLifecycle = false
        d.appVersion = "1.2.3"
        d.backgroundTasks = nil
        d.flushEvery = 3600
        d.presenter = nil
        d.peopleOptions = PeopleSync.Options(debounce: 3600, retryEvery: 3600, soon: 3600)
        var c = Configuration(apiKey: "vl_key", baseUrl: "https://links.x.com")
        c.matchDeferred = false
        c.autoTrack = false
        c.appId = "com.x.app"
        let s = VelaLinks()
        sdks.append(s)
        if configure { try await s.configure(c, d) }
        return s
    }

    // MARK: identity token on the tracker

    func testTheIdentityTokenIsKeptSentWithEventsClearedOnResetAndRefusesBadValues() async throws {
        let t = try tracker()
        let changes = Counter()
        t.hooks = EventTracker.Hooks(onIdentity: { changes.bump() })
        await t.setIdentityToken("has spaces")
        await t.setIdentityToken(String(repeating: "x", count: 1001))
        await t.setIdentityToken("")
        XCTAssertNil(t.currentIdentityToken)
        await t.setIdentityToken(" abc.def ")
        XCTAssertEqual(t.currentIdentityToken, "abc.def")
        await t.setIdentityToken("abc.def")
        XCTAssertEqual(changes.value, 1, "the same token again is not a change")
        t.track("login")
        await t.flush(force: true)
        XCTAssertEqual(service.to("/v1/events").first?["identity_token"] as? String, "abc.def")
        t.drainStorage()
        let restarted = try tracker()
        XCTAssertEqual(restarted.currentIdentityToken, "abc.def", "it survives a restart")
        await restarted.reset()
        XCTAssertNil(restarted.currentIdentityToken)
        restarted.drainStorage()
        XCTAssertNil(try store.string(forKey: StorageKeys.identityToken))
        await t.setIdentityToken(nil)
        XCTAssertEqual(changes.value, 2, "signing out is a change")
    }

    func testEventsOfAnEarlierPersonGoOutWithoutTheNewPersonsToken() async throws {
        let t = try tracker()
        await t.setUserId("u1")
        t.track("a_event")
        await t.setIdentityToken("tok.one")
        await t.setUserId("u2") // sends the waiting event under u1 first
        await t.flush(force: true)
        let first = try XCTUnwrap(service.to("/v1/events").first)
        XCTAssertEqual(first["uid"] as? String, "u1")
        XCTAssertEqual(first["identity_token"] as? String, "tok.one", "u1 was still the person signed in when it was sent")
    }

    func testANewSessionGetsANewId() throws {
        let t = try tracker(autoTrack: true)
        let first = t.sessionId
        XCTAssertEqual(first.count, 16)
        XCTAssertEqual(t.sessionId, first)
        clock.advance(2 * 3600)
        let later = try tracker(autoTrack: true)
        XCTAssertNotEqual(later.sessionId, first)
    }

    func testTheHooksHearAboutEventsScreensAndLifecycleButNotDuplicates() async throws {
        let t = try tracker()
        let heard = Log()
        t.hooks = EventTracker.Hooks(onForeground: { heard.add("foreground") }, onBackground: { heard.add("background") },
                                     onTracked: { name, isScreen in heard.add("\(isScreen ? "screen" : "event"):\(name)") })
        t.track("add_to_cart")
        t.track("add_to_cart") // the same event within a second is counted once
        t.trackScreen("/fresh")
        t.trackScreen("/fresh") // the same screen twice in a row is reported once
        t.track("Bad Name")
        t.appDidEnterBackground()
        t.appWillEnterForeground()
        XCTAssertEqual(heard.items, ["event:add_to_cart", "screen:/fresh", "background", "foreground"])
    }

    // MARK: the public calls

    func testWhatTheAppTellsAboutAPersonIsSentOnlyOnceASignedIdentityIsGivenAndCarriesIt() async throws {
        let s = try await sdk()
        s.setUserProperties(["lang": "te", "phone": "9848012345"])
        s.registerPushToken(String(repeating: "f", count: 40))
        XCTAssertTrue(s.setConsent("push", granted: true, policyVersion: "2026-10"))
        await s.flush()
        XCTAssertEqual(service.count("/v1/users/profile"), 0, "nobody is proven yet")
        await s.setIdentityToken("signed.token")
        await s.flush()
        XCTAssertEqual(service.to("/v1/users/profile").first?["attrs"] as? [String: String], ["lang": "te"])
        XCTAssertEqual(service.to("/v1/users/push-token").first?["provider"] as? String, "fcm")
        XCTAssertEqual(service.to("/v1/users/consent").first?["policy_version"] as? String, "2026-10")
        XCTAssertEqual(service.to("/v1/users/consent").first?["identity_token"] as? String, "signed.token")
        s.track("login")
        await s.flush()
        XCTAssertEqual(service.to("/v1/events").last?["identity_token"] as? String, "signed.token")
        XCTAssertEqual(service.headers(of: "/v1/users/profile").first?["X-Api-Key"], "vl_key")
        await s.flush()
        XCTAssertEqual(service.count("/v1/users/push-token"), 1, "a token already delivered is not sent twice")
    }

    func testSigningOutForgetsThePersonTheTokenWhatWasAgreedAndTheInstallIdentity() async throws {
        let s = try await sdk()
        await s.setIdentityToken("signed.token")
        s.registerPushToken(String(repeating: "t", count: 30))
        await s.flush()
        s.setConsent("inapp", granted: true, policyVersion: "v1")
        XCTAssertEqual(s.consentOf("inapp"), true)
        let before = s.installId
        XCTAssertNotNil(before)
        await s.resetUser()
        XCTAssertEqual(service.to("/v1/users/push-token/remove").first?["token"] as? String, String(repeating: "t", count: 30),
                       "the service is told before the identity is cleared")
        XCTAssertEqual(service.to("/v1/users/push-token/remove").first?["identity_token"] as? String, "signed.token")
        XCTAssertNil(s.consentOf("inapp"))
        XCTAssertNotEqual(s.installId, before)
        await s.flush()
        XCTAssertEqual(service.count("/v1/users/consent"), 0)
    }

    func testSwitchingTrackingOffForgetsWhatWasWaitingToBeSentAboutThePerson() async throws {
        let s = try await sdk()
        s.setUserProperties(["lang": "te"])
        await s.setTrackingEnabled(false)
        await s.setIdentityToken("signed.token")
        await s.setTrackingEnabled(true)
        await s.flush()
        XCTAssertEqual(service.count("/v1/users/profile"), 0)
    }

    func testConsentTakesEffectImmediatelyAndABadAnswerIsRefused() async throws {
        let s = try await sdk()
        XCTAssertTrue(s.setConsent("push", granted: true, policyVersion: "v1"))
        XCTAssertEqual(s.consentOf("push"), true)
        XCTAssertTrue(s.setConsent("push", granted: false, policyVersion: "v1", source: "settings_toggle"))
        XCTAssertEqual(s.consentOf("push"), false)
        XCTAssertFalse(s.setConsent("fax", granted: true, policyVersion: "v1"))
        XCTAssertFalse(s.setConsent("push", granted: true, policyVersion: "bad version!"))
        XCTAssertEqual(s.consentOf("push"), false, "a refused answer changes nothing")
    }

    func testCallsMadeBeforeConfigureAreKeptAndRunInOrder() async throws {
        let s = try await sdk(configure: false)
        s.setUserProperties(["lang": "te"])
        XCTAssertTrue(s.setConsent("push", granted: true, policyVersion: "v1"))
        XCTAssertNil(s.consentOf("push"), "not known until configure has finished")
        XCTAssertNil(s.installId)
        await s.setIdentityToken("signed.token")
        var d = Dependencies()
        d.fetcher = makeFetcher()
        d.store = store
        d.installSource = FakeInstallSource(nil)
        d.observeLifecycle = false
        d.backgroundTasks = nil
        d.presenter = nil
        d.peopleOptions = PeopleSync.Options(debounce: 3600, retryEvery: 3600, soon: 3600)
        var c = Configuration(apiKey: "vl_key", baseUrl: "https://links.x.com")
        c.matchDeferred = false
        c.autoTrack = false
        try await s.configure(c, d)
        await eventually("the queued calls to run") { s.consentOf("push") == true }
        await s.flush()
        XCTAssertEqual(service.count("/v1/users/profile"), 1)
        XCTAssertEqual(service.count("/v1/users/consent"), 1)
    }

    func testTheRawApnsTokenIsSentAsHexWithTheApnsProvider() async throws {
        let s = try await sdk()
        await s.setIdentityToken("signed.token")
        s.registerPushToken(apnsDeviceToken: Data((0..<32).map { UInt8($0) }))
        await s.flush()
        let sent = try XCTUnwrap(service.to("/v1/users/push-token").first)
        XCTAssertEqual(sent["provider"] as? String, "apns")
        XCTAssertEqual(sent["token"] as? String, (0..<32).map { String(format: "%02x", $0) }.joined())
    }

    func testShoppingHelpersSendTheStandardEventsWithPlainValues() async throws {
        let s = try await sdk()
        s.trackAddToCart(items: 2, cartValue: 540, store: "gpn", category: "sweets")
        clock.advance(2)
        s.trackRemoveFromCart(store: "gpn")
        s.trackBeginCheckout(items: 1, cartValue: 540)
        s.trackViewItem(category: "sweets")
        s.trackSignup(method: "phone")
        s.trackLogin()
        await s.flush()
        let events = service.to("/v1/events").flatMap { $0["events"] as? [[String: Any]] ?? [] }
        var byName: [String: [String: Any]] = [:]
        for event in events { byName[event["name"] as? String ?? ""] = event }
        let add = byName["add_to_cart"]?["props"] as? [String: Any]
        XCTAssertEqual(add?["items"] as? Int, 2)
        XCTAssertEqual(add?["cart_value"] as? Double, 540)
        XCTAssertEqual(add?["store"] as? String, "gpn")
        XCTAssertEqual(add?["category"] as? String, "sweets")
        let remove = byName["remove_from_cart"]?["props"] as? [String: Any]
        XCTAssertEqual(remove?["items"] as? Int, 1)
        XCTAssertEqual(remove?["store"] as? String, "gpn")
        XCTAssertNil(remove?["cart_value"])
        let begin = byName["begin_checkout"]?["props"] as? [String: Any]
        XCTAssertEqual(begin?["items"] as? Int, 1)
        XCTAssertEqual(begin?["cart_value"] as? Double, 540)
        XCTAssertEqual((byName["view_item"]?["props"] as? [String: Any])?["category"] as? String, "sweets")
        XCTAssertEqual((byName["signup"]?["props"] as? [String: Any])?["method"] as? String, "phone")
        XCTAssertNotNil(byName["login"])
    }

    func testMessageControlsNeverBreakAnythingEvenWithNothingToDrawOn() async throws {
        let s = try await sdk()
        s.setQuietScreens(["/payment"])
        s.pauseMessages()
        s.resumeMessages()
        s.setInAppMessageHandler { _, _ in }
        s.setInAppMessageHandler(nil)
        XCTAssertNotNil(s.installId)
    }
}

/// A counter two threads may touch.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.sync { count += 1 } }
    var value: Int { lock.sync { count } }
}

/// A list two threads may touch.
final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ item: String) { lock.sync { list.append(item) } }
    var items: [String] { lock.sync { list } }
}
