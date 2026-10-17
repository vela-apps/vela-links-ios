import XCTest
@testable import VelaLinks

final class FakeBackgroundRunner: BackgroundTaskRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var next = 1
    private(set) var begun: [Int] = []
    private(set) var ended: [Int] = []
    private var handlers: [Int: @Sendable () -> Void] = [:]
    var refuse = false

    func begin(name: String, expiration: @escaping @Sendable () -> Void) -> Int? {
        lock.sync {
            if refuse { return nil }
            let id = next
            next += 1
            begun.append(id)
            handlers[id] = expiration
            return id
        }
    }
    func end(_ token: Int) { lock.sync { ended.append(token) } }
    func expire(_ token: Int) { let h = lock.sync { handlers[token] }; h?() }
    var open: [Int] { lock.sync { begun.filter { !ended.contains($0) } } }
    var begunCount: Int { lock.sync { begun.count } }
    var endedCount: Int { lock.sync { ended.count } }
}

final class BackgroundTaskTests: XCTestCase {
    let runner = FakeBackgroundRunner()
    var trackers: [EventTracker] = []

    func tracker(_ server: EventServer) throws -> EventTracker {
        server.install()
        var o = EventTracker.Options()
        o.autoTrack = false
        o.flushEvery = 3600
        o.identityFlushTimeout = 1
        let t = EventTracker(api: try makeApi(), store: MemoryStorage(), platform: "ios", appVersion: nil,
                             now: { Date() }, options: o, backgroundTasks: runner)
        t.start()
        trackers.append(t)
        return t
    }

    func testTheBackgroundFlushRunsUnderABackgroundTaskThatIsEnded() async throws {
        let server = EventServer()
        let t = try tracker(server)
        t.track("signup")
        t.appDidEnterBackground()
        XCTAssertEqual(runner.begunCount, 1) // started synchronously, before the app can be suspended
        await eventually("the flush") { server.names == ["signup"] && self.runner.endedCount == 1 }
        XCTAssertTrue(runner.open.isEmpty)
    }

    func testTheTaskIsEndedEvenWhenTheSendFails() async throws {
        let server = EventServer(503)
        let t = try tracker(server)
        t.track("signup")
        t.appDidEnterBackground()
        await eventually("the task to end") { self.runner.endedCount == 1 }
        XCTAssertEqual(t.pending, 1)
    }

    func testTheExpirationHandlerEndsTheTaskOnlyOnce() async throws {
        FakeURLProtocol.reset { _ in .hang }
        let t = try tracker(EventServer())
        FakeURLProtocol.reset { _ in .hang }
        t.track("signup")
        t.appDidEnterBackground()
        XCTAssertEqual(runner.open.count, 1)
        runner.expire(1)
        XCTAssertEqual(runner.endedCount, 1)
        runner.expire(1) // the system calling twice, or the work ending later, must not end it again
        XCTAssertEqual(runner.endedCount, 1)
    }

    func testNoTaskIsLeftOpenWhenTheSystemRefusesOrThereIsNothingToSend() async throws {
        runner.refuse = true
        let server = EventServer()
        let t = try tracker(server)
        t.track("signup")
        t.appDidEnterBackground()
        await eventually("the flush") { server.names == ["signup"] }
        XCTAssertEqual(runner.endedCount, 0)
        XCTAssertTrue(runner.open.isEmpty)
        runner.refuse = false
        t.appDidEnterBackground() // empty queue: the task still starts and ends
        await eventually("the task to end") { self.runner.endedCount == 1 && self.runner.begunCount == 1 }
    }

    func testAnExpirationBeforeBeginReturnsStillEndsTheTask() {
        final class Eager: BackgroundTaskRunner, @unchecked Sendable {
            var ended: [Int] = []
            func begin(name: String, expiration: @escaping @Sendable () -> Void) -> Int? { expiration(); return 7 }
            func end(_ token: Int) { ended.append(token) }
        }
        let eager = Eager()
        _ = BackgroundTaskHold(runner: eager, name: "x")
        XCTAssertEqual(eager.ended, [7])
    }

    func testIdentityChangeInTheBackgroundHoldsATaskAndInTheForegroundDoesNot() async throws {
        let server = EventServer()
        let t = try tracker(server)
        t.track("one_event")
        await t.setUserId("user_a") // foreground
        XCTAssertEqual(runner.begunCount, 0)
        t.track("two_event")
        t.appDidEnterBackground()
        await eventually("background flush") { self.runner.endedCount == 1 }
        t.track("three_event")
        await t.setUserId("user_b") // background
        XCTAssertEqual(runner.begunCount, 2)
        await eventually("ended") { self.runner.open.isEmpty }
        t.appWillEnterForeground()
        t.track("four_event")
        await t.reset()
        XCTAssertEqual(runner.begunCount, 2)
    }

    func testHoldRunWithoutARunnerJustRunsTheWork() async {
        var ran = false
        await BackgroundTaskHold.run(nil, name: "x") { ran = true }
        XCTAssertTrue(ran)
    }
}
