import XCTest
@testable import VelaLinks

/// When a message is asked for, shown and reported. Ported from the Flutter SDK's `inapp_test.dart` ("when to show").
final class InAppControllerTests: XCTestCase {
    var service = FakeService(inapp: "{\"enabled\":true,\"video\":true}")
    var presenter = FakePresenter()
    var opened = Log()
    var clock = FakeClock()
    var token: String? = "signed.token"
    var handler: InAppMessageHandler?
    var controllers: [InAppController] = []

    override func setUp() {
        service = FakeService(inapp: "{\"enabled\":true,\"video\":true}")
        service.serve(message: messageJSON())
        presenter = FakePresenter()
        opened = Log()
        clock = FakeClock()
        token = "signed.token"
        handler = nil
        controllers = []
        service.install()
    }

    override func tearDown() async throws {
        presenter.release()
        controllers.forEach { $0.stop() }
        for c in controllers { await c.finishReports() }
    }

    private func make(refetch: TimeInterval = 0, screen: String = "x", presenter fake: FakePresenter? = nil,
                      noPresenter: Bool = false, tracking: Bool = true) throws -> InAppController {
        service.install()
        var timing = InAppController.Timing()
        timing.settle = 0
        timing.refetchAfter = refetch
        let c = clock
        let log = opened
        let controller = InAppController(
            api: try makeApi(),
            sources: InAppController.Sources(installId: { String(repeating: "b", count: 32) }, identity: { [self] in token },
                                             sessionId: { "session-0001" }, enabled: { tracking }, language: { "te" }),
            presenter: noPresenter ? nil : (fake ?? presenter), timing: timing, handler: { [self] in handler },
            emit: { link in log.add("\(link.route)|\(link.campaign ?? "")|\(link.params["slug"] ?? "")|\(link.code)") },
            now: { c.date })
        controller.noteScreen(screen)
        controllers.append(controller)
        return controller
    }

    private func settle(_ milliseconds: UInt64 = 120) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }

    // MARK: asking and showing

    func testAsksTheServiceWithWhoWhenWhichLanguageAndWhichLayoutsAndShowsTheAnswer() async throws {
        await try make().consider("event", event: "add_to_cart", screen: "/fresh")
        let q = try XCTUnwrap(service.queries(of: "/v1/inapp/messages").first)
        XCTAssertEqual(q["iid"], String(repeating: "b", count: 32))
        XCTAssertEqual(q["trigger"], "event")
        XCTAssertEqual(q["event"], "add_to_cart")
        XCTAssertEqual(q["screen"], "/fresh")
        XCTAssertEqual(q["sid"], "session-0001")
        XCTAssertEqual(q["lang"], "te")
        XCTAssertEqual(q["layouts"], "bottom_sheet,full_screen")
        let headers = try XCTUnwrap(service.headers(of: "/v1/inapp/messages").first)
        XCTAssertEqual(headers["X-Identity-Token"], "signed.token")
        XCTAssertEqual(headers["X-Api-Key"], "vl_key")
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testTheIdentityHeaderIsLeftOutForSomeoneWhoIsNotSignedIn() async throws {
        token = nil
        await try make().consider("start")
        XCTAssertNil(service.headers(of: "/v1/inapp/messages").first?["X-Identity-Token"])
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testReportsShownThenTheButtonChosenAndOpensThePageItPointsAt() async throws {
        await try make().consider("start")
        await eventually("both reports") { self.service.actions() == ["shown", "clicked"] }
        let reports = service.to("/v1/inapp/events")
        XCTAssertEqual(reports.last?["button"] as? Int, 0)
        XCTAssertEqual(reports.first?["message_id"] as? String, String(repeating: "a", count: 32))
        XCTAssertEqual(reports.first?["sid"] as? String, "session-0001")
        XCTAssertEqual(reports.first?["identity_token"] as? String, "signed.token")
        XCTAssertEqual(reports.first?["iid"] as? String, String(repeating: "b", count: 32))
        XCTAssertEqual(opened.items, ["/fresh|inapp|gpn|inapp_" + String(repeating: "a", count: 12)])
    }

    func testShownIsReportedAsSoonAsTheMessageIsOnTheScreenNotWhenItCloses() async throws {
        presenter.holding = true
        let controller = try make()
        let run = Task { await controller.consider("start") }
        await eventually("shown to be reported while the message is still up") { self.service.actions() == ["shown"] }
        XCTAssertTrue(opened.items.isEmpty)
        presenter.release()
        await run.value
        await eventually("the click") { self.service.actions() == ["shown", "clicked"] }
    }

    func testReportsADismissalAndOpensNothing() async throws {
        presenter.answer = .dismissed
        await try make().consider("start")
        await eventually("reports") { self.service.actions() == ["shown", "dismissed"] }
        XCTAssertTrue(opened.items.isEmpty)
    }

    func testTheDismissButtonReportsAClickAndOpensNothingEither() async throws {
        presenter.answer = .button(1)
        await try make().consider("start")
        await eventually("reports") { self.service.actions() == ["shown", "clicked"] }
        XCTAssertEqual(service.to("/v1/inapp/events").last?["button"] as? Int, 1)
        XCTAssertTrue(opened.items.isEmpty)
    }

    func testAVideoClosedBeforeAQuarterIsReportedAsClosedEarly() async throws {
        let video = "{\"kind\":\"video\",\"url\":\"https://v.test/a.mp4\",\"alt\":\"Clip\",\"poster_url\":\"https://v.test/p.jpg\"}"
        service.serve(message: messageJSON(media: video))
        presenter.answer = .dismissed
        presenter.videoEvents = ["video_started"]
        await try make().consider("start")
        await eventually("reports") { self.service.actions() == ["shown", "video_started", "dismissed", "closed_early"] }
    }

    func testAVideoWatchedPastAQuarterIsNotClosedEarly() async throws {
        let video = "{\"kind\":\"video\",\"url\":\"https://v.test/a.mp4\",\"alt\":\"Clip\",\"poster_url\":\"https://v.test/p.jpg\"}"
        service.serve(message: messageJSON(media: video))
        presenter.answer = .dismissed
        presenter.videoEvents = ["video_started", "video_25", "video_50"]
        await try make().consider("start")
        await eventually("reports") { self.service.actions() == ["shown", "video_started", "video_25", "video_50", "dismissed"] }
    }

    // MARK: staying calm

    func testAsksForNothingWhileTheServiceHasMessagesSwitchedOff() async throws {
        service.serve(inapp: "{\"enabled\":false}")
        await try make().consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testStaysQuietOnScreensTheAppMarkedBusyAndWhilePaused() async throws {
        let busy = try make(screen: "/payment/card")
        busy.setQuietScreens(["/payment", "/otp"])
        await busy.consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0)
        let calm = try make(screen: "/home")
        calm.setQuietScreens(["/payment"])
        calm.pause()
        await calm.consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0)
        calm.resume()
        await calm.consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 1)
    }

    func testPausesAddUpSoEachNeedsItsOwnResume() async throws {
        let c = try make()
        c.pause()
        c.pause()
        c.resume()
        await c.consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0)
        c.resume()
        c.resume() // an extra resume does nothing
        await c.consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 1)
    }

    func testNothingIsAskedOrDrawnWhenTheAppIsNotInFrontOrBusy() async throws {
        presenter.calm = false
        await try make().consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0, "no point asking when nothing can be drawn")
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testAMessageIsNotDrawnIfTheAppStoppedBeingCalmWhileItWasBeingFetched() async throws {
        presenter.calmAnswers = [true, false] // calm before the question, busy when the answer comes
        await try make().consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 1)
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(service.count("/v1/inapp/events"), 0)
    }

    func testNothingIsAskedWhenTrackingIsOffOrThereIsNothingToDrawOn() async throws {
        await try make(tracking: false).consider("start")
        await try make(noPresenter: true).consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0)
        XCTAssertEqual(service.count("/v1/sdk/config"), 0)
    }

    func testAMessageWhoseMediaDoesNotLoadIsNotShownAndNothingIsReported() async throws {
        presenter.picturesLoad = false
        await try make().consider("start")
        await settle()
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(service.count("/v1/inapp/events"), 0)
    }

    func testAMessageItCannotDrawIsIgnored() async throws {
        service.serve(message: messageJSON(layout: "carousel"))
        await try make().consider("start")
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testAnAnswerThatCannotBeReadMeansNoMessage() async throws {
        service.messageStatus = 500
        await try make().consider("start")
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    // MARK: config-driven moments

    func testAsksAfterAnEventOrAScreenOnlyWhenTheServiceSaysAMessageWaitsForIt() async throws {
        service.serve(inapp: "{\"enabled\":true,\"trigger_events\":[\"add_to_cart\"],\"trigger_screens\":[\"/fresh\"]}")
        service.serve(message: nil)
        let c = try make()
        await c.consider("start") // learns what the service waits for
        let before = service.count("/v1/inapp/messages")
        for (name, isScreen) in [("login", false), ("add_to_cart", false), ("/home", true), ("/fresh/checkout", true)] {
            c.onTracked(name, isScreen: isScreen)
            await settle(150)
        }
        let asked = service.queries(of: "/v1/inapp/messages").dropFirst(before).map { "\($0["trigger"] ?? ""):\($0["event"] ?? $0["screen"] ?? "")" }
        XCTAssertEqual(asked, ["event:add_to_cart", "screen:/fresh/checkout"])
    }

    func testAsksAtNoEventOrScreenBeforeItKnowsWhatTheServiceWaitsFor() async throws {
        let c = try make()
        c.onTracked("add_to_cart", isScreen: false)
        c.onTracked("/fresh", isScreen: true)
        await settle(150)
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0)
        XCTAssertEqual(service.count("/v1/sdk/config"), 0)
    }

    func testTheAutomaticEventsAreNeverMoments() async throws {
        let c = try make()
        await c.consider("start") // learns the config (an old service that names no moments)
        service.serve(message: nil)
        let before = service.count("/v1/inapp/messages")
        c.onTracked("first_open", isScreen: false)
        c.onTracked("session_start", isScreen: false)
        await settle(150)
        XCTAssertEqual(service.count("/v1/inapp/messages"), before)
    }

    func testAsksAgainForTheSameMomentOnlyAfterAWhile() async throws {
        let c = try make(refetch: 3600)
        await c.consider("start")
        await c.consider("start")
        await c.consider("resume")
        XCTAssertEqual(service.queries(of: "/v1/inapp/messages").map { $0["trigger"] ?? "" }, ["start", "resume"])
    }

    func testTheServicesSettingsAreKeptForTenMinutes() async throws {
        let c = try make()
        await c.consider("start")
        await c.consider("resume")
        XCTAssertEqual(service.count("/v1/sdk/config"), 1)
        clock.advance(11 * 60)
        await c.consider("event", event: "x")
        XCTAssertEqual(service.count("/v1/sdk/config"), 2)
    }

    func testAFailedReadOfTheSettingsIsNotRepeatedForFiveMinutesAndNothingIsShown() async throws {
        service.configStatus = 500
        let c = try make()
        await c.consider("start")
        await c.consider("resume")
        XCTAssertEqual(service.count("/v1/sdk/config"), 1)
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0)
        clock.advance(6 * 60)
        service.configStatus = 200
        await c.consider("event", event: "x")
        XCTAssertEqual(service.count("/v1/sdk/config"), 2)
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testComingBackAsksOnlyAfterARealAbsence() async throws {
        let c = try make()
        c.onBackground()
        clock.advance(30)
        c.onForeground()
        await settle(150)
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0, "a quick switch to another app is not a new visit")
        c.onBackground()
        clock.advance(6 * 60)
        c.onForeground()
        await eventually("the resume question") { self.service.queries(of: "/v1/inapp/messages").map { $0["trigger"] } == ["resume"] }
    }

    func testTheStartMomentWaitsForTheAppToSettle() async throws {
        service.install()
        var timing = InAppController.Timing()
        timing.settle = 0.3
        let c = InAppController(api: try makeApi(), sources: InAppController.Sources(
            installId: { "b" }, identity: { nil }, sessionId: { "s0000001" }, enabled: { true }, language: { "en" }),
                                presenter: presenter, timing: timing, emit: { _ in })
        controllers.append(c)
        c.onStart()
        await settle(100)
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0)
        await eventually("the start question") { self.service.count("/v1/inapp/messages") == 1 }
    }

    // MARK: never two at once, stopping

    func testNeverTwoAtOnce() async throws {
        presenter.holding = true // the first message stays on the screen
        let c = try make()
        async let first: Void = c.consider("start")
        async let second: Void = c.consider("resume")
        await eventually("the first message to be up") { self.presenter.presented.count == 1 }
        await settle(200)
        XCTAssertEqual(presenter.presented.count, 1)
        presenter.release()
        _ = await (first, second)
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testNothingIsDrawnAfterTheControllerIsStopped() async throws {
        let c = try make()
        c.stop()
        await c.consider("start")
        XCTAssertEqual(service.count("/v1/inapp/messages"), 0)
        await eventually("the screen to be told to let go") { self.presenter.cancelled == 1 }
    }

    // MARK: an app that draws messages itself

    func testAnAppThatDrawsMessagesItselfGetsTheMessageAndAReporter() async throws {
        let got = Log()
        handler = { message, reporter in
            got.add(message.title)
            reporter.markShown()
            reporter.markClicked(0)
        }
        await try make().consider("start")
        await eventually("reports") { self.service.actions() == ["shown", "clicked"] }
        XCTAssertEqual(got.items, ["Fresh sweets"])
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertTrue(opened.items.isEmpty, "the app's own handler opens pages itself")
    }

    func testTheHandlerCanReportADismissal() async throws {
        handler = { _, reporter in
            reporter.markShown()
            reporter.markDismissed()
        }
        await try make().consider("start")
        await eventually("reports") { self.service.actions() == ["shown", "dismissed"] }
    }

    // MARK: reports that could not be sent

    func testAReportThatCouldNotBeSentIsSentLater() async throws {
        service.status = 503
        let c = try make()
        await c.consider("start")
        await settle(200)
        XCTAssertEqual(service.actions(), [])
        service.status = 202
        await c.retryReports()
        await eventually("the reports to arrive in order") { self.service.actions() == ["shown", "clicked"] }
    }

    func testAReportWaitingForAnIdentityIsSentWithTheNewTokenWhenOneArrives() async throws {
        service.status = 403
        service.body = "{\"detail\":\"identity_required\"}"
        token = nil
        let c = try make()
        await c.consider("start")
        await settle(200)
        service.status = 202
        service.body = "{}"
        token = "later.token"
        await c.retryReports()
        await eventually("the reports") { self.service.actions() == ["shown", "clicked"] }
        XCTAssertEqual(service.to("/v1/inapp/events").last?["identity_token"] as? String, "later.token")
    }
}
