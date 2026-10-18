import Foundation

/// Carries a value the app handed over (event properties, the app's own link handlers) to another thread. The SDK only reads it
/// there, once, and never shares it with anything else.
private struct HandedOver<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Cancels a registration made with ``VelaLinks/onLink(_:)``.
public final class VelaLinkObservation: @unchecked Sendable {
    private let onCancel: () -> Void
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    /// Stops the handler from being called. Handlers stay registered until you call this.
    public func cancel() { onCancel() }
}

/// Entry point of the SDK.
///
/// ```swift
/// try await VelaLinks.configure(apiKey: "vl_...", baseUrl: "https://api.links.velaapps.in")
/// VelaLinks.shared.onLink { link in router.open(link.route) }
/// VelaLinks.shared.track("signup")
/// ```
///
/// `VelaLinks.shared` always exists. Calls to the tracking methods made before `configure` has finished are kept in order (up to
/// 100) and run when it finishes; they never crash and never throw.
public final class VelaLinks: @unchecked Sendable {
    /// The one SDK object an app uses.
    public static let shared = VelaLinks()

    init() {}

    private typealias Operation = @Sendable (Engine) async -> Void

    private let lock = NSLock()
    private var engine: Engine?
    private var gate: Task<Void, Never>?
    private var queuedOperations: [Operation] = []
    private var draining = false
    private var pendingLink: VelaLink?
    /// A link address handed over before `configure` finished: resolved as soon as the engine is installed.
    private var pendingURL: URL?
    private var handlers: [UUID: (VelaLink) -> Void] = [:]
    private var continuations: [UUID: AsyncStream<VelaLink>.Continuation] = [:]
    private var lastIncoming: URL?
    private var lastIncomingAt: Date?
    private var deferredTask: Task<Void, Never>?
    private static let maxQueuedOperations = 100

    // MARK: Start

    /// Starts the SDK: on the first launch after install it tries to match the install to the link that led to it. Calling it
    /// again replaces the running configuration.
    ///
    /// - Parameters:
    ///   - apiKey: the SDK key from the dashboard.
    ///   - baseUrl: a plain https address (http only for localhost).
    ///   - slug: your app's slug: when set, links that belong to any other app are ignored.
    ///   - matchDeferred: look for the install token on the first launch.
    ///   - reportOpens: tell the service when a link opens the app.
    ///   - trackEvents: turns in-app events on or off as a whole (start with `false` until the person has agreed).
    ///   - autoTrack: report `first_open` and `session_start` by itself.
    ///   - requestTimeout: the longest any network call may take, in seconds.
    ///   - appId: the bundle id sent with every signed call; read from the app when `nil`.
    ///   - userDefaults: where the SDK keeps its state; pass your own suite if you share data with extensions.
    /// - Throws: ``VelaLinksError`` with kind `.invalidArgument` for an empty key or an invalid base URL.
    public static func configure(apiKey: String, baseUrl: String, slug: String? = nil, matchDeferred: Bool = true,
                                 reportOpens: Bool = true, trackEvents: Bool = true, autoTrack: Bool = true,
                                 requestTimeout: TimeInterval = 10, appId: String? = nil,
                                 userDefaults: UserDefaults = .standard) async throws {
        var config = Configuration(apiKey: apiKey, baseUrl: baseUrl)
        config.slug = slug
        config.matchDeferred = matchDeferred
        config.reportOpens = reportOpens
        config.trackEvents = trackEvents
        config.autoTrack = autoTrack
        config.requestTimeout = requestTimeout
        config.appId = appId
        var deps = Dependencies()
        deps.store = UserDefaultsStorage(userDefaults)
        try await shared.configure(config, deps)
    }

    /// True once `configure` has finished.
    public var isConfigured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return engine != nil
    }

    func configure(_ config: Configuration, _ deps: Dependencies) async throws {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VelaLinksError("apiKey must not be empty", kind: .invalidArgument)
        }
        // checked here, before anything running is touched
        _ = try LinksApi.normaliseBaseUrl(config.baseUrl)
        let store = deps.store ?? UserDefaultsStorage(.standard)
        // calls to configure run one after another, so two at once cannot leave a half-closed engine behind
        let work: Task<Void, Error> = lock.sync {
            let previous = gate
            // the settings hold the app's own closures (test doubles, a clock); they are only read by the one install
            let settings = HandedOver((config, deps, store))
            let task = Task<Void, Error> {
                await previous?.value
                try await self.install(settings.value.0, settings.value.1, settings.value.2)
            }
            gate = Task { _ = try? await task.value }
            return task
        }
        try await work.value
    }

    private func install(_ config: Configuration, _ deps: Dependencies, _ store: VelaLinksStorage) async throws {
        let fresh = try Engine(config: config, deps: deps, store: store)
        let old: Engine? = lock.sync {
            let previous = engine
            engine = nil
            deferredTask?.cancel()
            return previous
        }
        await old?.stop()
        fresh.tracker.start()
        let (hasQueued, stashed): (Bool, URL?) = lock.sync {
            engine = fresh
            let queued = !queuedOperations.isEmpty && !draining
            if queued { draining = true }
            let url = pendingURL
            pendingURL = nil
            return (queued, url)
        }
        if hasQueued { drain() }
        // a link that opened the app before the SDK was ready: resolve it now (the 2-second repeat filter already ran when it
        // arrived, and listeners or the pending-link slot get it like any other link)
        if let url = stashed { Task { _ = await self.resolve(url: url) } }
        if config.matchDeferred {
            let task = Task { [weak self] in
                guard let link = await fresh.matcher.run() else { return }
                self?.emit(link, from: fresh)
            }
            lock.sync { deferredTask = task }
        }
    }

    /// Waits for the deferred-link check started by the last `configure` (used by tests).
    func waitForDeferredCheck() async {
        let task = lock.sync { deferredTask }
        await task?.value
    }

    func currentEngine() -> Engine? {
        lock.lock()
        defer { lock.unlock() }
        return engine
    }

    /// Stops the SDK: sends what is waiting, stops listening and ends the `links` streams.
    public func shutdown() {
        lock.lock()
        let old = engine
        engine = nil
        deferredTask?.cancel()
        let streams = Array(continuations.values)
        continuations.removeAll()
        pendingURL = nil
        lock.unlock()
        streams.forEach { $0.finish() }
        if let old = old { Task { await old.stop() } }
    }

    /// Stops the SDK and waits until what was waiting has been sent and saved.
    func shutdownAndWait() async {
        let old: Engine? = lock.sync {
            let previous = engine
            engine = nil
            deferredTask?.cancel()
            return previous
        }
        await old?.stop()
    }

    // MARK: Calls made before configure has finished

    private func run(_ operation: @escaping Operation, direct: (Engine) -> Void) {
        lock.lock()
        if let engine = engine, queuedOperations.isEmpty, !draining {
            lock.unlock()
            direct(engine)
            return
        }
        if queuedOperations.count < VelaLinks.maxQueuedOperations { queuedOperations.append(operation) }
        lock.unlock()
    }

    private func runAsync(_ operation: @escaping Operation) async {
        let direct: Engine? = lock.sync {
            if let engine = engine, queuedOperations.isEmpty, !draining { return engine }
            if queuedOperations.count < VelaLinks.maxQueuedOperations { queuedOperations.append(operation) }
            return nil
        }
        if let engine = direct { await operation(engine) }
    }

    private func nextQueued() -> (Engine, Operation)? {
        lock.sync {
            guard !queuedOperations.isEmpty, let engine = engine else {
                draining = false
                return nil
            }
            return (engine, queuedOperations.removeFirst())
        }
    }

    private func drain() {
        Task {
            while let (engine, next) = self.nextQueued() { await next(engine) }
        }
    }

    // MARK: Events

    /// Records something that happened in the app, for example `track("signup")` or
    /// `track("share", properties: ["channel": "whatsapp"])`.
    ///
    /// `name` uses letters, digits and `_` (2 to 40 characters, starting with a letter). `properties` may hold up to 10 short
    /// values (text, numbers, booleans); do not put personal data in them. Events are sent in the background. This never
    /// throws and never blocks: an invalid event is ignored. With `once` the event is recorded a single time for the person.
    public func track(_ name: String, properties: [String: Any]? = nil, once: Bool = false) {
        let at = Date()
        let props = HandedOver(properties)
        run({ $0.tracker.track(name, properties: props.value, once: once, at: at) },
            direct: { $0.tracker.track(name, properties: props.value, once: once) })
    }

    /// Records a purchase with its `amount`, for example `trackPurchase(499, currency: "INR")`. Pass your `orderId` and an order
    /// is counted once, even if this is called twice for it.
    public func trackPurchase(_ amount: Double, currency: String = "INR", orderId: String? = nil,
                              properties: [String: Any]? = nil) {
        let at = Date()
        let props = HandedOver(properties)
        run({ $0.tracker.track(EventNames.purchase, properties: props.value, value: amount, currency: currency,
                               orderId: orderId, at: at) },
            direct: { $0.tracker.track(EventNames.purchase, properties: props.value, value: amount, currency: currency,
                                       orderId: orderId) })
    }

    /// Records that a screen was shown. The same screen twice in a row is reported once, until another screen is shown.
    public func trackScreen(_ name: String) {
        let at = Date()
        run({ $0.tracker.trackScreen(name, at: at) }, direct: { $0.tracker.trackScreen(name) })
    }

    /// Turns event tracking on or off, for example after asking for consent. The choice is remembered. Turning it off also
    /// discards events that were waiting; turning it on starts `first_open` and `session_start`.
    public func setTrackingEnabled(_ enabled: Bool) async {
        await runAsync { await $0.tracker.setEnabled(enabled) }
    }

    /// Whether events are being collected right now (`false` before `configure` has finished).
    public var trackingEnabled: Bool { currentEngine()?.tracker.isEnabled ?? false }

    /// Call after sign-in with your own user id (not an email or phone number): 1 to 100 visible ASCII characters, no spaces.
    /// Anything else is ignored. `nil` signs out of the analytics without starting a new identity. Events still waiting are
    /// sent under the previous identity first. From non-async code use `Task { await VelaLinks.shared.setUserId(id) }`.
    public func setUserId(_ id: String?) async {
        await runAsync { await $0.tracker.setUserId(id) }
    }

    /// Starts a new anonymous identity, for example when a person signs out. Earlier activity is not linked to the next person.
    public func resetUser() async {
        await runAsync { await $0.tracker.reset() }
    }

    /// Sends any waiting events now. Events are also sent by themselves every 15 seconds, when 20 are waiting, and when the app
    /// goes to the background.
    public func flush() async {
        await runAsync { await $0.tracker.flush() }
    }

    // MARK: Links

    /// Extracts (slug, code) from `https://host/l/{slug}/{code}` or `scheme://l/{slug}/{code}`; `nil` for anything else.
    public static func parse(url: URL) -> LinkAddress? { parseLinkURL(url) }

    /// Registers a handler for links that open the app (called on the main thread). Handlers stay registered until you cancel
    /// the returned observation. A link that arrived before any handler or stream was registered is available from
    /// ``consumePendingLink()``.
    @discardableResult
    public func onLink(_ handler: @escaping (VelaLink) -> Void) -> VelaLinkObservation {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return VelaLinkObservation { [weak self] in
            self?.lock.lock()
            self?.handlers[id] = nil
            self?.lock.unlock()
        }
    }

    /// The same links as an `AsyncStream`: `for await link in VelaLinks.shared.links { ... }`. Each access makes a new stream.
    public var links: AsyncStream<VelaLink> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    /// Returns the most recent link that no listener has handled yet, once.
    public func consumePendingLink() -> VelaLink? {
        lock.lock()
        defer { lock.unlock() }
        let link = pendingLink
        pendingLink = nil
        return link
    }

    /// Hands a URL from the system to the SDK: call it from `scene(_:openURLContexts:)`, `application(_:open:options:)` or
    /// SwiftUI's `.onOpenURL`. Returns `true` when the URL has the shape of a Vela link (it is then resolved in the background
    /// and delivered to `onLink` / `links`). The same address arriving again within 2 seconds is ignored, because iOS can hand
    /// the link that opened the app over twice.
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard parseLinkURL(url) != nil else { return false }
        let moment = Date()
        lock.lock()
        let repeated = lastIncoming == url && (lastIncomingAt.map { moment.timeIntervalSince($0) < 2 } ?? false)
        if !repeated {
            lastIncoming = url
            lastIncomingAt = moment
        }
        // not configured yet: keep the newest address (one) and resolve it when `configure` finishes
        let waiting = !repeated && engine == nil
        if waiting { pendingURL = url }
        lock.unlock()
        if !repeated && !waiting { Task { _ = await self.resolve(url: url) } }
        return true
    }

    /// Hands a Universal Link to the SDK: call it from `scene(_:continue:)`, `application(_:continue:restorationHandler:)` or
    /// SwiftUI's `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`. Returns `true` when it was a Vela link.
    @discardableResult
    public func handle(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else {
            return false
        }
        return handle(url: url)
    }

    /// Resolves a link URL, delivers it to listeners and returns it. Returns `nil` for an unknown, expired or malformed link,
    /// a link of another app (see `slug`), and when the service cannot be reached.
    @discardableResult
    public func resolve(url: URL) async -> VelaLink? {
        guard let engine = currentEngine(), !engine.isDisposed, let address = parseLinkURL(url) else { return nil }
        if let mine = engine.slug, address.slug.lowercased() != mine.lowercased() { return nil } // another app's link
        do {
            guard let link = try await engine.api.resolve(slug: address.slug, code: address.code) else { return nil }
            emit(link, from: engine)
            if engine.reportOpens {
                let source = isQRScan(url) ? "qr" : "link"
                engine.spawn { await engine.api.reportOpen(code: link.code, source: source) }
            }
            return link
        } catch {
            return nil
        }
    }

    /// Creates a short link that opens `route` in the app with `params` (values must be writable as JSON) and returns its
    /// address.
    /// - Throws: ``VelaLinksError`` when the service cannot be reached or refuses the request, and `.invalidArgument` for an
    ///   empty route, params that are not JSON, or when `configure` has not been called.
    public func createLink(route: String, params: [String: Any] = [:], title: String? = nil, description: String? = nil,
                           imageUrl: String? = nil, fallbackUrl: String? = nil, campaign: String? = nil,
                           expiresInHours: Int? = nil) async throws -> String {
        guard !route.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VelaLinksError("route must not be empty", kind: .invalidArgument)
        }
        guard let engine = currentEngine() else {
            throw VelaLinksError("Call VelaLinks.configure first", kind: .invalidArgument)
        }
        var body: [String: Any] = ["route": route, "params": params]
        if let title = title { body["title"] = title }
        if let description = description { body["description"] = description }
        if let imageUrl = imageUrl { body["image_url"] = imageUrl }
        if let fallbackUrl = fallbackUrl { body["fallback_url"] = fallbackUrl }
        if let campaign = campaign { body["campaign"] = campaign }
        if let hours = expiresInHours { body["expires_in_hours"] = hours }
        return try await engine.api.createLink(body)
    }

    func emit(_ link: VelaLink, from engine: Engine) {
        guard !engine.isDisposed else { return }
        engine.tracker.noteLink(link.code, installSource: link.deferred)
        lock.lock()
        let listeners = Array(handlers.values)
        let streams = Array(continuations.values)
        // a listener has it now; do not keep an old copy to be read later
        pendingLink = listeners.isEmpty && streams.isEmpty ? link : nil
        lock.unlock()
        streams.forEach { $0.yield(link) }
        if !listeners.isEmpty {
            let handed = HandedOver(listeners)
            DispatchQueue.main.async { handed.value.forEach { $0(link) } }
        }
    }
}
