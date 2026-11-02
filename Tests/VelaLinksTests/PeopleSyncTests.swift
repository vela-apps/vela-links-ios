import XCTest
@testable import VelaLinks

/// What may be sent about a person, and how it is kept until delivered. Ported from the Flutter SDK's `people_test.dart`.
final class PeopleSyncTests: XCTestCase {
    var service = FakeService()
    var store = MemoryStorage()
    var token: String? = "signed.token"
    var on = true
    var syncs: [PeopleSync] = []

    override func setUp() {
        service = FakeService()
        store = MemoryStorage()
        token = "signed.token"
        on = true
        syncs = []
        service.install()
    }

    /// Stops every sync and waits for a send that was already under way, so it cannot reach the next test's fake service.
    override func tearDown() async throws {
        syncs.forEach { $0.stop() }
        for sync in syncs { await sync.flush() }
    }

    func make() throws -> PeopleSync {
        service.install()
        let sources = PeopleSync.Sources(identity: { [self] in token }, installId: { String(repeating: "a", count: 32) },
                                         enabled: { [self] in on }, platform: "ios", appVersion: { "2.3.1" },
                                         deviceLocale: { "en" })
        let sync = PeopleSync(api: try makeApi(), store: store, sources: sources,
                              options: PeopleSync.Options(debounce: 3600, retryEvery: 3600, soon: 3600))
        syncs.append(sync)
        sync.start()
        return sync
    }

    private func set(_ sync: PeopleSync, _ props: [String: Any?], locale: String? = nil, timezone: String? = nil,
                     quietStart: Int? = nil, quietEnd: Int? = nil) {
        sync.setProperties(props, locale: locale, timezone: timezone, quietStart: quietStart, quietEnd: quietEnd)
    }

    private func consent(_ sync: PeopleSync, _ channel: String, _ granted: Bool, policy: String = "v1",
                         purpose: String = "marketing", source: String = "app_prompt") -> Bool {
        sync.setConsent(channel, granted: granted, policyVersion: policy, purpose: purpose, source: source)
    }

    private func attrs(_ call: [String: Any]) -> [String: AnyHashable] { (call["attrs"] as? [String: AnyHashable]) ?? [:] }

    // MARK: what may be sent about a person

    func testPlainLabelsNumbersAndYesNoPassAndPersonalThingsAreDropped() {
        let clean = PeopleRules.cleanUserProperties([
            "lang": "te", "orders": 3, "uses_business": true, "city": "Hyderabad", "phone": "9848012345",
            "email_x": "a@b.com", "Name": "Asha", "religion": "x", "note": "call 9848012345", "mail": "a@b.com",
            "bad key": 1, "huge": 1e12, "list": [1], "gone": nil,
        ])
        XCTAssertEqual(clean, ["lang": .string("te"), "orders": .int(3), "uses_business": .bool(true),
                               "city": .string("Hyderabad"), "gone": .null])
    }

    func testAtMost20AreKeptAndALanguageCodeIsChecked() {
        var many: [String: Any?] = [:]
        for number in 0..<30 { many["k" + String(number)] = number }
        XCTAssertEqual(PeopleRules.cleanUserProperties(many).count, 20)
        XCTAssertEqual(PeopleRules.cleanLocale("te"), "te")
        XCTAssertEqual(PeopleRules.cleanLocale("hi_IN"), "hi-IN")
        XCTAssertNil(PeopleRules.cleanLocale("zh-Hans-CN"))
        XCTAssertNil(PeopleRules.cleanLocale("not a locale"))
        XCTAssertNil(PeopleRules.cleanLocale("te\n"))
        XCTAssertTrue(PeopleRules.validPolicyVersion("2026-10"))
        XCTAssertFalse(PeopleRules.validPolicyVersion("bad version!"))
        XCTAssertFalse(PeopleRules.validPolicyVersion("2026-10\n"))
    }

    func testNumbersThatLookLikePhonesAndEmailsAreRecognised() {
        XCTAssertTrue(PeopleRules.hasLongNumber("+91 98480 12345"))
        XCTAssertTrue(PeopleRules.hasLongNumber("(040) 2345-6789"))
        XCTAssertFalse(PeopleRules.hasLongNumber("order 12345678"))   // eight digits only
        XCTAssertFalse(PeopleRules.hasLongNumber("1234 abc 5678"))
        XCTAssertTrue(PeopleRules.looksLikeEmail("a@b.com"))
        XCTAssertFalse(PeopleRules.looksLikeEmail("a @b"))
        XCTAssertFalse(PeopleRules.looksLikeEmail("@b"))
        XCTAssertEqual(PeopleRules.cleanValue(3.0), .int(3))
        XCTAssertEqual(PeopleRules.cleanValue(2.5), .double(2.5))
        XCTAssertNil(PeopleRules.cleanValue(Double.nan))
        XCTAssertNil(PeopleRules.cleanValue(String(repeating: "x", count: 61)))
    }

    // MARK: properties

    func testNothingAboutAPersonIsSentWithoutASignedIdentity() async throws {
        token = nil
        let sync = try make()
        set(sync, ["lang": "te"])
        await sync.flush()
        XCTAssertTrue(service.calls.isEmpty)
        token = "signed.token"
        await sync.flush()
        XCTAssertEqual(attrs(try XCTUnwrap(service.to("/v1/users/profile").first)), ["lang": "te"])
    }

    func testTheyAreSentWithTheIdentityTheInstallAndTheAppDetailsCleaned() async throws {
        let sync = try make()
        set(sync, ["lang": "te", "phone": "9848012345"], locale: "te-IN", timezone: "Asia/Kolkata", quietStart: 21, quietEnd: 8)
        await sync.flush()
        let body = try XCTUnwrap(service.to("/v1/users/profile").first)
        XCTAssertEqual(body["identity_token"] as? String, "signed.token")
        XCTAssertEqual(body["iid"] as? String, String(repeating: "a", count: 32))
        XCTAssertEqual(attrs(body), ["lang": "te"])
        XCTAssertEqual(body["locale"] as? String, "te-IN")
        XCTAssertEqual(body["timezone"] as? String, "Asia/Kolkata")
        XCTAssertEqual(body["quiet_start"] as? Int, 21)
        XCTAssertEqual(body["quiet_end"] as? Int, 8)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["app_version"] as? String, "2.3.1")
    }

    func testWithoutALocaleThePhonesLanguageIsSent() async throws {
        let sync = try make()
        set(sync, ["lang": "te"])
        await sync.flush()
        XCTAssertEqual(service.to("/v1/users/profile").first?["locale"] as? String, "en")
    }

    func testOnlyWhatChangedIsSentTheNextTimeAndNothingWhenNothingChanged() async throws {
        let sync = try make()
        set(sync, ["lang": "te", "orders": 1])
        await sync.flush()
        set(sync, ["lang": "te", "orders": 2])
        await sync.flush()
        set(sync, ["lang": "te", "orders": 2])
        await sync.flush()
        XCTAssertEqual(service.to("/v1/users/profile").map(attrs), [["lang": "te", "orders": 1], ["orders": 2]])
    }

    func testABusyServiceKeepsThemAnIdentityRequestKeepsThemARefusalDropsThem() async throws {
        let sync = try make()
        set(sync, ["lang": "te"])
        service.status = 503
        await sync.flush()
        service.status = 403
        service.body = "{\"detail\":\"identity_required\"}"
        await sync.flush()
        XCTAssertEqual(service.count("/v1/users/profile"), 2)
        service.status = 202
        service.body = "{}"
        await sync.flush()
        XCTAssertEqual(service.count("/v1/users/profile"), 3)
        await sync.flush()
        XCTAssertEqual(service.count("/v1/users/profile"), 3) // delivered: nothing waiting
        service.status = 422
        set(sync, ["orders": 5])
        await sync.flush()
        await sync.flush()
        XCTAssertEqual(service.count("/v1/users/profile"), 4) // refused for good: not tried again
    }

    func testWhatWasWaitingSurvivesTheAppBeingClosed() async throws {
        let first = try make()
        token = nil
        set(first, ["lang": "hi"])
        first.drainStorage()
        first.stop()
        token = "signed.token"
        let second = try make()
        await second.flush()
        XCTAssertEqual(service.to("/v1/users/profile").map(attrs), [["lang": "hi"]])
    }

    func testWhatWasDeliveredIsRememberedAcrossARestartSoItIsNotSentTwice() async throws {
        let first = try make()
        set(first, ["lang": "te"])
        first.setPushToken(String(repeating: "f", count: 40), provider: "fcm")
        await first.flush()
        first.drainStorage()
        first.stop()
        let second = try make()
        set(second, ["lang": "te"])
        second.setPushToken(String(repeating: "f", count: 40), provider: "fcm")
        await second.flush()
        XCTAssertEqual(service.count("/v1/users/profile"), 1)
        XCTAssertEqual(service.count("/v1/users/push-token"), 1)
    }

    func testNothingIsKeptOrSentWhileTrackingIsOffAndTurningItOffForgetsWhatWasWaiting() async throws {
        let sync = try make()
        set(sync, ["lang": "te"])
        sync.discard()
        await sync.flush()
        XCTAssertTrue(service.calls.isEmpty)
        on = false
        set(sync, ["lang": "te"])
        sync.setPushToken(String(repeating: "t", count: 30), provider: "fcm")
        XCTAssertTrue(consent(sync, "push", true))
        on = true
        await sync.flush()
        XCTAssertTrue(service.calls.isEmpty)
        // the phone remembers the answer for its own settings screen
        XCTAssertEqual(sync.consentOf("push", purpose: "marketing"), true)
    }

    // MARK: push token

    func testThePushTokenIsSentOnceWithTheProviderAndTheSameTokenIsNotSentAgain() async throws {
        let sync = try make()
        sync.setPushToken("  " + String(repeating: "f", count: 40) + "  ", provider: "fcm")
        await sync.flush()
        sync.setPushToken(String(repeating: "f", count: 40), provider: "fcm")
        await sync.flush()
        let sent = service.to("/v1/users/push-token")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["token"] as? String, String(repeating: "f", count: 40))
        XCTAssertEqual(sent.first?["provider"] as? String, "fcm")
        XCTAssertEqual(sent.first?["identity_token"] as? String, "signed.token")
        XCTAssertEqual(sent.first?["iid"] as? String, String(repeating: "a", count: 32))
        sync.setPushToken(String(repeating: "g", count: 40), provider: "fcm")
        await sync.flush()
        XCTAssertEqual(service.count("/v1/users/push-token"), 2)
    }

    func testABadTokenOrProviderIsIgnored() async throws {
        let sync = try make()
        for (token, provider) in [("short", "fcm"), ("a b " + String(repeating: "c", count: 30), "fcm"),
                                  (String(repeating: "f", count: 40), "sms"), (String(repeating: "f", count: 5000), "apns")] {
            sync.setPushToken(token, provider: provider)
        }
        await sync.flush()
        XCTAssertTrue(service.calls.isEmpty)
    }

    // MARK: signing out and the push token

    func testTheServiceIsToldToForgetTheTokenBeforeAnythingIsCleared() async throws {
        let sync = try make()
        sync.setPushToken(String(repeating: "t", count: 30), provider: "fcm")
        await sync.flush()
        await sync.unlinkPush()
        let removed = try XCTUnwrap(service.to("/v1/users/push-token/remove").first)
        XCTAssertEqual(removed["token"] as? String, String(repeating: "t", count: 30))
        XCTAssertEqual(removed["identity_token"] as? String, "signed.token")
        XCTAssertEqual(removed["iid"] as? String, String(repeating: "a", count: 32))
    }

    func testAPendingTokenIsUnlinkedToo() async throws {
        token = nil
        let sync = try make()
        sync.setPushToken(String(repeating: "p", count: 30), provider: "fcm")
        token = "signed.token"
        await sync.unlinkPush()
        XCTAssertEqual(service.to("/v1/users/push-token/remove").first?["token"] as? String, String(repeating: "p", count: 30))
    }

    func testNothingIsSentWhenNoTokenWasGivenNobodyIsVerifiedOrTrackingIsOff() async throws {
        let sync = try make()
        await sync.unlinkPush()
        sync.setPushToken(String(repeating: "t", count: 30), provider: "fcm")
        await sync.flush()
        token = nil
        await sync.unlinkPush()
        token = "signed.token"
        on = false
        await sync.unlinkPush()
        XCTAssertEqual(service.count("/v1/users/push-token/remove"), 0)
    }

    // MARK: consent

    func testAnswersAreSentInOrderTheLatestPerChannelAndPurposeOnly() async throws {
        let sync = try make()
        XCTAssertTrue(consent(sync, "push", true, policy: "2026-10"))
        XCTAssertTrue(consent(sync, "push", false, policy: "2026-10", source: "settings_toggle"))
        XCTAssertTrue(consent(sync, "inapp", true, policy: "2026-10"))
        XCTAssertTrue(consent(sync, "email", true, policy: "2026-10", purpose: "service"))
        await sync.flush()
        let sent = service.to("/v1/users/consent")
        XCTAssertEqual(sent.map { "\($0["channel"]!)/\($0["purpose"]!)/\($0["granted"]!)/\($0["source"]!)" },
                       ["push/marketing/0/settings_toggle", "inapp/marketing/1/app_prompt", "email/service/1/app_prompt"])
        XCTAssertEqual(sent.first?["policy_version"] as? String, "2026-10")
        XCTAssertEqual(sync.consentOf("push", purpose: "marketing"), false)
        XCTAssertNil(sync.consentOf("sms", purpose: "marketing"))
    }

    func testAWithdrawalTakesEffectOnThePhoneAtOnce() throws {
        let sync = try make()
        XCTAssertTrue(consent(sync, "inapp", true))
        XCTAssertEqual(sync.consentOf("inapp", purpose: "marketing"), true)
        XCTAssertTrue(consent(sync, "inapp", false, source: "settings_toggle"))
        XCTAssertEqual(sync.consentOf("inapp", purpose: "marketing"), false, "no flush needed")
    }

    func testABadChannelPurposeSourceOrPolicyVersionIsRefused() async throws {
        let sync = try make()
        XCTAssertFalse(consent(sync, "fax", true))
        XCTAssertFalse(consent(sync, "push", true, purpose: "ads"))
        XCTAssertFalse(consent(sync, "push", true, source: "reply_stop"))
        XCTAssertFalse(consent(sync, "push", true, policy: "not valid!"))
        await sync.flush()
        XCTAssertTrue(service.calls.isEmpty)
    }

    func testAnAnswerWaitsForAnIdentityAndIsSentWhenOneArrives() async throws {
        token = nil
        let sync = try make()
        _ = consent(sync, "push", true)
        await sync.flush()
        XCTAssertTrue(service.calls.isEmpty)
        token = "signed.token"
        await sync.flush()
        XCTAssertEqual(service.count("/v1/users/consent"), 1)
    }

    func testAnAnswerThatCouldNotBeSentIsKeptAndSentLaterOnlyOnce() async throws {
        let sync = try make()
        _ = consent(sync, "push", true)
        service.status = 503
        await sync.flush()
        service.status = 202
        await sync.flush()
        await sync.flush()
        XCTAssertEqual(service.count("/v1/users/consent"), 2) // one failed try, one delivery
    }

    func testANewPersonOnThePhoneStartsWithNoAnswersAndNothingRememberedAsSent() async throws {
        let sync = try make()
        set(sync, ["lang": "te"])
        _ = consent(sync, "push", true)
        await sync.flush()
        sync.reset()
        XCTAssertNil(sync.consentOf("push", purpose: "marketing"))
        set(sync, ["lang": "te"])
        await sync.flush()
        XCTAssertEqual(service.count("/v1/users/profile"), 2) // the next person gets their own copy
    }
}
