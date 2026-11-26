import XCTest
@testable import VelaLinks

/// 1.2.0: push opens, consent read-back with the offers default, the clipboard left alone, device signals and the click id.
final class V120Tests: XCTestCase {
    private var store = MemoryStorage()
    private var sdks: [VelaLinks] = []
    private let lock = NSLock()
    private var consentState = "{}"
    private var consentStatus = 202
    private var calls: [Captured] = []

    override func setUp() {
        store = MemoryStorage()
        sdks = []
        calls = []
        consentState = "{}"
        consentStatus = 202
        FakeURLProtocol.reset { [self] request in
            let (state, status): (String, Int) = lock.sync {
                calls.append(request)
                return (consentState, consentStatus)
            }
            switch request.path {
            case "/v1/sdk/config": return .reply(200, "{\"schema\":1,\"inapp\":{\"enabled\":false}}")
            case "/v1/users/consent/state": return .reply(200, state)
            case "/v1/users/consent": return .reply(status, "{}")
            case "/v1/events": return .reply(202, "{\"accepted\":1,\"rejected\":0}")
            default: return .reply(202, "{}")
            }
        }
    }

    override func tearDown() async throws {
        for s in sdks { await s.shutdownAndWait() }
    }

    private func sdk() async throws -> VelaLinks {
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
        try await s.configure(c, d)
        return s
    }

    private func sent(_ path: String) -> [[String: Any]] {
        lock.sync { calls }.filter { $0.path == path }.compactMap { $0.json }
    }

    private func pushOpens() -> [[String: Any]] {
        sent("/v1/events").flatMap { ($0["events"] as? [[String: Any]]) ?? [] }.filter { $0["name"] as? String == "push_open" }
    }

    // MARK: push opens

    func testAPushOpenIsCountedWithItsCampaignAndReturnsThePage() async throws {
        let s = try await sdk()
        let open = s.trackPushOpen(["vela_campaign": "ios_cmp_1", "vela_route": "/offers", "vela_params": "{\"id\":\"42\"}",
                                    "gcm.message_id": "m1", "aps": ["alert": "Hi"]])
        XCTAssertEqual(open?.campaign, "ios_cmp_1")
        XCTAssertEqual(open?.route, "/offers")
        XCTAssertEqual(open?.params["id"] as? String, "42")
        await s.flush()
        XCTAssertEqual(pushOpens().count, 1)
        XCTAssertEqual((pushOpens().first?["props"] as? [String: Any])?["campaign"] as? String, "ios_cmp_1")
    }

    func testTheSamePushHandedOverTwiceIsCountedOnce() async throws {
        let s = try await sdk()
        let info: [AnyHashable: Any] = ["vela_campaign": "ios_cmp_2", "vela_route": "/x", "gcm.message_id": "m2"]
        XCTAssertNotNil(s.trackPushOpen(info))
        XCTAssertEqual(s.trackPushOpen(info)?.route, "/x", "the route still comes back so the app can open it")
        await s.flush()
        XCTAssertEqual(pushOpens().count, 1)
    }

    func testTheSendIdTellsPushesApartWhateverTheMessageId() async throws {
        let s = try await sdk()
        s.trackPushOpen(["vela_campaign": "ios_cmp_s", "vela_send_id": "snd_1"], messageId: "a")
        s.trackPushOpen(["vela_campaign": "ios_cmp_s", "vela_send_id": "snd_1"], messageId: "b")
        await s.flush()
        XCTAssertEqual(pushOpens().count, 1)
    }

    func testWithoutSendIdOrMessageIdACampaignCountsOncePerTenMinutes() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let reader = PushOpenReader(now: { now })
        XCTAssertTrue(reader.firstTime(campaign: "cmp", messageId: nil))
        now += 9 * 60
        XCTAssertFalse(reader.firstTime(campaign: "cmp", messageId: nil))
        XCTAssertTrue(reader.firstTime(campaign: "other", messageId: nil))
        now += 2 * 60
        XCTAssertTrue(reader.firstTime(campaign: "cmp", messageId: nil), "a later push of the same campaign")
        XCTAssertTrue(reader.firstTime(campaign: "cmp", messageId: "m1"))
        now += 2 * 3600
        XCTAssertFalse(reader.firstTime(campaign: "cmp", messageId: "m1"), "a message id is remembered for good")
        XCTAssertTrue(reader.firstTime(campaign: "cmp", messageId: "m1", sendId: "s1"))
        XCTAssertFalse(reader.firstTime(campaign: "cmp", messageId: "m2", sendId: "s1"))
    }

    func testAPushNotFromVelaIsIgnored() async throws {
        let s = try await sdk()
        XCTAssertNil(s.trackPushOpen(["aps": ["alert": "Hi"]]))
        XCTAssertNil(s.trackPushOpen(nil))
        let routeOnly = s.trackPushOpen(["vela_route": "/home", "vela_params": "not json"])
        XCTAssertEqual(routeOnly?.route, "/home")
        XCTAssertEqual(routeOnly?.params.isEmpty, true)
        await s.flush()
        XCTAssertTrue(pushOpens().isEmpty)
    }

    // MARK: consent read-back

    func testConsentIsReadBackWithTheOffersDefault() async throws {
        consentState = "{\"consent\":{\"push\":{\"marketing\":false},\"telegram\":{\"marketing\":true}},\"offers_default_on\":true}"
        let s = try await sdk()
        XCTAssertFalse(s.offersDefaultOn, "not read yet")
        await s.setIdentityToken("signed.token")
        let ok = await s.refreshConsent()
        XCTAssertTrue(ok)
        XCTAssertEqual(sent("/v1/users/consent/state").last?["identity_token"] as? String, "signed.token")
        XCTAssertEqual(s.consentOf("push"), false)
        XCTAssertNil(s.consentOf("telegram"), "unknown channels are ignored")
        XCTAssertTrue(s.offersDefaultOn)
        XCTAssertFalse(s.offersEnabled("push"))
        XCTAssertTrue(s.offersEnabled("whatsapp"), "never asked: the default")
    }

    func testAServerThatDoesNotSendTheDefaultMeansOff() async throws {
        try store.setBool(true, forKey: StorageKeys.offersDefaultOn)
        consentState = "{\"consent\":{\"push\":{\"marketing\":true}}}"
        let s = try await sdk()
        XCTAssertTrue(s.offersDefaultOn, "the last value read is kept on the phone")
        await s.setIdentityToken("signed.token")
        let ok = await s.refreshConsent()
        XCTAssertTrue(ok)
        XCTAssertFalse(s.offersDefaultOn)
        XCTAssertTrue(s.offersEnabled("push"))
        XCTAssertFalse(s.offersEnabled("sms"))
    }

    func testAnAnswerNotDeliveredYetWinsOverTheService() async throws {
        consentState = "{\"consent\":{\"push\":{\"marketing\":true}}}"
        consentStatus = 503
        let s = try await sdk()
        s.setConsent("push", granted: false, policyVersion: "2026-10")
        await s.setIdentityToken("signed.token")
        let ok = await s.refreshConsent()
        XCTAssertTrue(ok)
        XCTAssertEqual(s.consentOf("push"), false)
    }

    func testAReadThatArrivesAfterSignOutIsDropped() async throws {
        consentState = "{\"consent\":{\"push\":{\"marketing\":true}}}"
        let s = try await sdk()
        await s.setIdentityToken("signed.token")
        guard let engine = s.currentEngine() else { return XCTFail("not configured") }
        engine.people.reset() // the person signs out while nothing has been read
        await s.setIdentityToken(nil)
        let ok = await s.refreshConsent()
        XCTAssertFalse(ok, "nobody is signed in")
        XCTAssertNil(s.consentOf("push"))
    }

    func testWithoutAnIdentityNothingIsAsked() async throws {
        let s = try await sdk()
        let ok = await s.refreshConsent()
        XCTAssertFalse(ok)
        XCTAssertTrue(sent("/v1/users/consent/state").isEmpty)
    }

    // MARK: the install id only while tracking is on

    private func linkSdk(trackEvents: Bool) async throws -> VelaLinks {
        FakeURLProtocol.reset { [self] request in
            lock.sync { calls.append(request) }
            switch request.path {
            case "/v1/match": return .reply(200, "{\"matched\":false}")
            case "/v1/links/s/abc": return .reply(200, "{\"code\":\"abc\",\"route\":\"/x\",\"params\":{}}")
            default: return .reply(202, "{}")
            }
        }
        var d = Dependencies()
        d.fetcher = makeFetcher()
        d.store = store
        d.installSource = FakeInstallSource(nil)
        d.matchSignals = { [:] }
        d.observeLifecycle = false
        d.backgroundTasks = nil
        d.flushEvery = 3600
        d.presenter = nil
        var c = Configuration(apiKey: "vl_key", baseUrl: "https://links.x.com")
        c.autoTrack = false
        c.trackEvents = trackEvents
        c.appId = "com.x.app"
        let s = VelaLinks()
        sdks.append(s)
        try await s.configure(c, d)
        XCTAssertTrue(s.handle(url: URL(string: "https://links.x.com/l/s/abc")!))
        await eventually("match and open sent") { !sent("/v1/match").isEmpty && !sent("/v1/open").isEmpty }
        return s
    }

    func testTheInstallIdGoesWithTheMatchAndTheOpenWhileTrackingIsOn() async throws {
        _ = try await linkSdk(trackEvents: true)
        XCTAssertNotNil(sent("/v1/match").first?["iid"])
        XCTAssertNotNil(sent("/v1/open").first?["iid"])
    }

    func testTheInstallIdIsNeverSentWithTrackingOff() async throws {
        _ = try await linkSdk(trackEvents: false)
        XCTAssertNil(sent("/v1/match").first?["iid"])
        XCTAssertNil(sent("/v1/open").first?["iid"])
    }

    func testTheInstallIdIsNeverSentAfterTheSavedOptOut() async throws {
        try store.setBool(true, forKey: StorageKeys.optedOut)
        _ = try await linkSdk(trackEvents: true)
        XCTAssertNil(sent("/v1/match").first?["iid"])
        XCTAssertNil(sent("/v1/open").first?["iid"])
    }

    // MARK: first-launch matching

    func testTheClipboardIsNotReadByDefaultAndSignalsAndTheInstallIdAreSent() async throws {
        let source = FakeInstallSource("vlink:Ab12Cd34Ef")
        let iid = String(repeating: "a", count: 32)
        let m = DeferredMatcher(api: try makeApi(), store: store, source: source,
                                signals: { ["screen_width": 390.0, "screen_height": 844.0, "pixel_ratio": 3.0,
                                            "timezone": "Asia/Kolkata", "language": "te-IN", "os_version": "17.4"] },
                                installId: { iid })
        _ = await m.run()
        XCTAssertEqual(source.reads, 0)
        XCTAssertTrue(source.cleared.isEmpty)
        let body = try XCTUnwrap(sent("/v1/match").first)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["screen_width"] as? Double, 390)
        XCTAssertEqual(body["screen_height"] as? Double, 844)
        XCTAssertEqual(body["pixel_ratio"] as? Double, 3)
        XCTAssertEqual(body["timezone"] as? String, "Asia/Kolkata")
        XCTAssertEqual(body["language"] as? String, "te-IN")
        XCTAssertEqual(body["os_version"] as? String, "17.4")
        XCTAssertEqual(body["iid"] as? String, iid)
        XCTAssertNil(body["token"])
    }

    func testAnInstallIdOfTheWrongShapeIsNotSent() async throws {
        _ = await DeferredMatcher(api: try makeApi(), store: store, source: FakeInstallSource(nil), signals: { [:] },
                                  installId: { "not-hex" }).run()
        XCTAssertNil(sent("/v1/match").first?["iid"])
    }

    func testTheLinkLookupIsSignedAndTheOpenReportCarriesTheInstallId() async throws {
        let api = try makeApi(appId: { "com.x.app" })
        _ = try await api.resolve(slug: "s", code: "abc")
        await api.reportOpen(code: "abc", source: "link", iid: String(repeating: "b", count: 32))
        let lookup = try XCTUnwrap(lock.sync { calls }.first { $0.path == "/v1/links/s/abc" })
        XCTAssertNotNil(lookup.header("X-Api-Key"))
        XCTAssertEqual(lookup.header("X-App-Id"), "com.x.app")
        XCTAssertEqual(sent("/v1/open").first?["iid"] as? String, String(repeating: "b", count: 32))
    }

    func testTheClickIdAndUtmComeFromNewerServersAndOlderAnswersStillWork() async throws {
        FakeURLProtocol.reset { _ in
            .reply(200, "{\"matched\":true,\"method\":\"signals\",\"click_id\":\"clk_1\","
                + "\"utm\":{\"utm_source\":\"whatsapp\",\"utm_campaign\":\"diwali\",\"other\":\"x\"},"
                + "\"link\":{\"code\":\"abc\",\"route\":\"/invite\",\"params\":{}}}")
        }
        let link = await DeferredMatcher(api: try makeApi(), store: MemoryStorage(), source: FakeInstallSource(nil),
                                         signals: { [:] }).run()
        XCTAssertEqual(link?.clickId, "clk_1")
        XCTAssertEqual(link?.utm, ["utm_source": "whatsapp", "utm_campaign": "diwali"])
        FakeURLProtocol.reset { _ in .reply(200, "{\"matched\":true,\"link\":{\"code\":\"abc\",\"route\":\"/invite\"}}") }
        let old = await DeferredMatcher(api: try makeApi(), store: MemoryStorage(), source: FakeInstallSource(nil),
                                        signals: { [:] }).run()
        XCTAssertEqual(old?.route, "/invite")
        XCTAssertNil(old?.clickId)
        XCTAssertEqual(old?.utm, [:])
    }

    func testTheDeviceSignalsArePlainShortValues() async {
        let signals = await DeviceSignals.read()
        XCTAssertTrue(Set(signals.keys).isSubset(of: ["screen_width", "screen_height", "pixel_ratio", "timezone", "language",
                                                      "os_version"]))
        XCTAssertFalse((signals["timezone"] as? String)?.isEmpty ?? true)
    }
}
