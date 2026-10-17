import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The notifications the SDK listens to for the app going to the background and coming back.
enum Lifecycle {
    #if canImport(UIKit) && !os(watchOS)
    static let didEnterBackground = UIApplication.didEnterBackgroundNotification
    static let willEnterForeground = UIApplication.willEnterForegroundNotification
    #else
    static let didEnterBackground = Notification.Name("VelaLinks.didEnterBackground")
    static let willEnterForeground = Notification.Name("VelaLinks.willEnterForeground")
    #endif
}

/// The validated settings of one `configure` call.
struct Configuration {
    var apiKey: String
    var baseUrl: String
    var slug: String?
    var matchDeferred = true
    var reportOpens = true
    var trackEvents = true
    var autoTrack = true
    var requestTimeout: TimeInterval = 10
    var appId: String?
}

/// Replaceable parts, for tests.
struct Dependencies {
    var fetcher: HTTPFetcher?
    var store: VelaLinksStorage?
    var installSource: InstallSource?
    var now: () -> Date = { Date() }
    var notificationCenter: NotificationCenter = .default
    var observeLifecycle = true
    var appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    var flushEvery: TimeInterval = 15
    var flushAt = 20
    var backgroundTasks: BackgroundTaskRunner? = DefaultBackgroundTasks.make()
}

private final class ObserverTokens: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
}

/// One running configuration: the API client, the tracker and the deferred matcher.
final class Engine: @unchecked Sendable {
    let api: LinksApi
    let tracker: EventTracker
    let matcher: DeferredMatcher
    let slug: String?
    let reportOpens: Bool
    private let fetcher: HTTPFetcher
    private let ownsFetcher: Bool
    private let center: NotificationCenter
    private let observers = ObserverTokens()
    private let lock = NSLock()
    private var disposed = false
    private var background: [Task<Void, Never>] = []

    init(config: Configuration, deps: Dependencies, store: VelaLinksStorage) throws {
        let fetcher = deps.fetcher ?? HTTPFetcher()
        let explicitId = config.appId
        api = try LinksApi(apiKey: config.apiKey, baseUrl: config.baseUrl, fetcher: fetcher,
                           timeout: config.requestTimeout,
                           appId: { explicitId ?? Bundle.main.bundleIdentifier })
        self.fetcher = fetcher
        ownsFetcher = deps.fetcher == nil
        slug = config.slug
        reportOpens = config.reportOpens
        center = deps.notificationCenter
        var options = EventTracker.Options()
        options.autoTrack = config.autoTrack
        options.enabled = config.trackEvents
        options.flushEvery = deps.flushEvery
        options.flushAt = deps.flushAt
        tracker = EventTracker(api: api, store: store, platform: "ios", appVersion: deps.appVersion, now: deps.now,
                               options: options, backgroundTasks: deps.backgroundTasks)
        matcher = DeferredMatcher(api: api, store: store, source: deps.installSource ?? ClipboardInstallSource())
        if deps.observeLifecycle { observe() }
    }

    var isDisposed: Bool { lock.lock(); defer { lock.unlock() }; return disposed }

    private func observe() {
        let tracker = self.tracker
        observers.tokens = [
            center.addObserver(forName: Lifecycle.didEnterBackground, object: nil, queue: nil) { _ in
                tracker.appDidEnterBackground()
            },
            center.addObserver(forName: Lifecycle.willEnterForeground, object: nil, queue: nil) { _ in
                tracker.appWillEnterForeground()
            },
        ]
    }

    /// Runs a piece of background work that `idle()` can wait for.
    func spawn(_ work: @escaping @Sendable () async -> Void) {
        let task = Task { await work() }
        lock.lock()
        background.append(task)
        lock.unlock()
    }

    /// Waits for background work started so far (used by tests).
    func idle() async {
        let tasks = lock.sync { background }
        for task in tasks { await task.value }
    }

    /// Stops listening, sends what is left and releases the network session.
    func stop() async {
        lock.sync { disposed = true }
        observers.tokens.forEach { center.removeObserver($0) }
        observers.tokens = []
        await tracker.stop()
        if ownsFetcher { fetcher.invalidate() }
    }
}

extension NSLock {
    /// Runs `body` while holding the lock. A plain (non-async) function, so it can be used from async code.
    @discardableResult
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
