import Foundation

/// Collects what happens in the app (opens, screens, sign-ups, purchases) and sends it to Vela Links in small batches.
///
/// - All state sits behind one short lock, and saving to storage happens on a background queue, so calling `track` from the main
///   thread never waits for the network or the disk.
/// - Events wait in a queue and are sent every few seconds, when the app goes to the background, or when 20 are waiting. Events that
///   cannot be sent (no network) are kept and retried, for up to a week.
/// - The only identifier is a random id made on first run and kept on the phone. No advertising id, device id or location.
/// - Tracking never throws into the app: bad input is dropped.
final class EventTracker: @unchecked Sendable {
    struct Options {
        var autoTrack = true
        var enabled = true
        var flushEvery: TimeInterval = 15
        var flushAt = 20
        var sessionGap: TimeInterval = 30 * 60
        var identityFlushTimeout: TimeInterval = 5
    }

    private static let sameEvent: TimeInterval = 1
    private static let maxQueue = 200
    private static let maxBatch = 50
    private static let maxAge: TimeInterval = 7 * 24 * 3600

    /// What makes two events "the same" for the one-second debounce.
    private struct EventKey: Hashable {
        let name: String
        let screen: String?
        let properties: [String: JSONScalar]?
        let value: Double?
        let currency: String?
        let orderId: String?
    }

    private let api: LinksApi
    private let store: VelaLinksStorage
    private let platform: String?
    private let rawVersion: String?
    private let now: () -> Date
    private let options: Options
    private let backgroundTasks: BackgroundTaskRunner?
    private var inBackground = false

    private let lock = NSLock()
    private let io = DispatchQueue(label: "in.velaapps.links.storage", qos: .utility)
    private let timerQueue = DispatchQueue(label: "in.velaapps.links.timer", qos: .utility)

    private var queue: [TrackedEvent] = []
    private var enabled: Bool
    private var started = false
    private var storageFailed = false
    private var flushing = false
    private var timer: DispatchWorkItem?
    private var iid: String?
    private var firstLink: String?
    private var lastLink: String?
    private var uid: String?
    private var version: String?
    private var onceDone = Set<String>()
    private var lastEventKey: EventKey?
    private var lastEventAt: Date?
    private var lastScreen: String?
    private var backoff: TimeInterval = 0
    private var override: Bool?
    private var retryAfter: Date?
    /// The batch being sent (or waiting to be sent again), exactly as it was built: same events, same id, same envelope.
    private var inFlight: (events: [TrackedEvent], body: [String: Any])?
    /// `reset()` was called before `start()`: start then makes a new install id and ignores what was saved.
    private var resetBeforeStart = false

    init(api: LinksApi, store: VelaLinksStorage, platform: String?, appVersion: String?, now: @escaping () -> Date,
         options: Options = Options(), backgroundTasks: BackgroundTaskRunner? = nil) {
        self.backgroundTasks = backgroundTasks
        self.api = api
        self.store = store
        self.platform = platform
        self.rawVersion = appVersion
        self.now = now
        self.options = options
        self.enabled = options.enabled
    }

    // MARK: State for callers and tests

    /// Whether events are being collected.
    var isEnabled: Bool { locked { enabled } }

    /// The number of events waiting to be sent.
    var pending: Int { locked { queue.count } }

    /// True while a send is running.
    var isFlushing: Bool { locked { flushing } }

    /// Waits until everything handed to the storage queue has been written (used by tests and by shutdown).
    func drainStorage() { io.sync {} }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Start

    /// Loads what is saved on the phone and starts the automatic events.
    func start() {
        let first: Bool = locked {
            if started { return false }
            started = true
            return true
        }
        guard first else { return }
        do {
            let wasReset = locked { resetBeforeStart }
            let optedOut = try store.bool(forKey: StorageKeys.optedOut) ?? false
            var existing: String? = wasReset ? nil : try store.string(forKey: StorageKeys.iid)
            if wasReset {
                persist { store in
                    for key in [StorageKeys.firstLink, StorageKeys.lastLink, StorageKeys.queue, StorageKeys.userId,
                                StorageKeys.onceDone] { try store.remove(forKey: key) }
                }
            }
            if existing == nil {
                let fresh = Check.randomHex(32)
                existing = fresh
                persist { try $0.setString(fresh, forKey: StorageKeys.iid) }
            }
            let first: String? = wasReset ? nil : try store.string(forKey: StorageKeys.firstLink)
            let last: String? = wasReset ? nil : try store.string(forKey: StorageKeys.lastLink)
            let user: String? = wasReset ? nil : try store.string(forKey: StorageKeys.userId)
            let onceKeys: [String] = wasReset ? [] : try store.strings(forKey: StorageKeys.onceDone) ?? []
            let restored: [TrackedEvent] = wasReset ? [] : try restoreQueue()
            locked {
                enabled = enabled && !optedOut
                if let choice = override {
                    enabled = choice
                    persist { try $0.setBool(!choice, forKey: StorageKeys.optedOut) }
                }
                iid = existing
                resetBeforeStart = false
                firstLink = first
                lastLink = last
                uid = user
                // entries saved by 0.2.0 of the sister SDKs are plain names: they belong to the anonymous person
                for key in onceKeys { onceDone.insert(key.contains("|") ? key : "|" + key) }
                // events tracked before start() were also saved: do not queue those twice
                let alreadyQueued = Set(queue.compactMap { $0.id })
                queue.insert(contentsOf: restored.filter { event in event.id.map { !alreadyQueued.contains($0) } ?? true },
                             at: 0)
                version = Check.cleanVersion(rawVersion)
            }
        } catch {
            // without storage there is no safe install id: collect nothing rather than guess
            locked {
                enabled = false
                storageFailed = true
            }
            return
        }
        if locked({ enabled }) && options.autoTrack { automaticEvents() }
        locked { scheduleLocked() }
    }

    private func restoreQueue() throws -> [TrackedEvent] {
        guard let raw = try store.string(forKey: StorageKeys.queue),
              let list = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [Any] else { return [] }
        let cutoff = now().addingTimeInterval(-EventTracker.maxAge)
        return list.compactMap(TrackedEvent.fromJSON).filter { $0.at > cutoff }
    }

    /// `first_open` once per install, and `session_start` when the app was away for longer than the session gap.
    private func automaticEvents() {
        let moment = now()
        do {
            if !(try store.bool(forKey: StorageKeys.firstOpenSent) ?? false) {
                // Sent once per install, whenever tracking is on: whatever else this install has done (a link check, an earlier
                // launch without consent) does not matter. An event saved before an app kill that never got its flag is still
                // in the restored queue, so it is not queued a second time; and it is marked `once`, so the service keeps one.
                if !locked({ queue.contains { $0.name == EventNames.firstOpen } }) {
                    track(EventNames.firstOpen, once: true)
                }
                // remembered only once the event is safely saved, so an app killed in between still reports it next time
                let snapshot = locked { queue }
                io.async { [store] in
                    try? store.setString(EventTracker.encode(snapshot), forKey: StorageKeys.queue)
                    try? store.setBool(true, forKey: StorageKeys.firstOpenSent)
                }
            }
            let last = try store.int(forKey: StorageKeys.lastActive)
            if let last = last {
                let away = moment.timeIntervalSince(Date(timeIntervalSince1970: Double(last) / 1000))
                if away > options.sessionGap { track(EventNames.sessionStart) }
            } else {
                track(EventNames.sessionStart)
            }
            let ms = Int((moment.timeIntervalSince1970 * 1000).rounded(.down))
            persist { try $0.setInt(ms, forKey: StorageKeys.lastActive) }
        } catch {
            // storage trouble: no automatic events this time
        }
    }

    // MARK: Tracking

    /// Records an event. Invalid input (a bad name, a negative amount) is dropped without any error. With `once` the event is
    /// recorded a single time for this person; `orderId` makes a purchase count once per order. The same event repeated within a
    /// second (a screen rebuilding, a double tap) is counted once.
    func track(_ name: String, properties: [String: Any]? = nil, value: Double? = nil, currency: String? = nil,
               screen: String? = nil, once: Bool = false, orderId: String? = nil, at date: Date? = nil) {
        enum After { case nothing, flushNow }
        let moment = date ?? now()
        let after: After = locked {
            guard enabled else { return .nothing }
            guard let event = TrackedEvent.tryCreate(name, at: moment, screen: screen, properties: properties, value: value,
                                                     currency: currency, id: Check.randomHex(24), once: once,
                                                     orderId: orderId, identity: currentIdentityLocked()) else {
                #if DEBUG
                print("VelaLinks: event \"\(name)\" was ignored (check the name, amount and currency)")
                #endif
                return .nothing
            }
            let onceKey = "\(uid ?? "")|\(name)"
            // first_open is `once` on the wire, but kept out of this saved set: it has its own flag, and a set entry written
            // before the event itself was saved could lose it for good if the app were killed in between
            let remembered = once && name != EventNames.firstOpen
            if remembered && onceDone.contains(onceKey) { return .nothing }
            let key = EventKey(name: name, screen: event.screen, properties: event.properties, value: value,
                               currency: currency, orderId: orderId)
            if !once, key == lastEventKey, let last = lastEventAt, moment.timeIntervalSince(last) < EventTracker.sameEvent {
                return .nothing
            }
            lastEventKey = key
            lastEventAt = moment
            if remembered {
                onceDone.insert(onceKey)
                let keys = Array(onceDone)
                persist { try $0.setStrings(keys, forKey: StorageKeys.onceDone) }
            }
            queue.append(event)
            while queue.count > EventTracker.maxQueue {
                // screen views are the cheapest to lose: keep sign-ups and purchases when the phone has been offline for long
                let cheap = queue.firstIndex { $0.name == EventNames.screenView }
                queue.remove(at: cheap ?? 0)
            }
            saveLocked()
            if queue.count >= options.flushAt { return .flushNow }
            scheduleLocked()
            return .nothing
        }
        if after == .flushNow { Task { await self.flush() } }
    }

    /// Who an event tracked right now belongs to (`nil` before the install id exists).
    private func currentIdentityLocked() -> EventIdentity? {
        iid.map { EventIdentity(iid: $0, uid: uid) }
    }

    /// Records a screen view. The same screen twice in a row is reported once, until another screen is shown.
    func trackScreen(_ name: String, at date: Date? = nil) {
        let repeated: Bool = locked {
            // while tracking is off nothing is reported, so the screen must not be remembered as "already reported"
            guard enabled else { return true }
            if name == lastScreen { return true }
            lastScreen = name
            return false
        }
        if !repeated { track(EventNames.screenView, screen: name, at: date) }
    }

    /// Remembers which link brought this install (the first one) and which link opened the app most recently.
    func noteLink(_ code: String, installSource: Bool) {
        locked {
            guard started, enabled, !storageFailed else { return }
            if firstLink == nil || installSource {
                firstLink = code
                persist { try $0.setString(code, forKey: StorageKeys.firstLink) }
            }
            lastLink = code
            persist { try $0.setString(code, forKey: StorageKeys.lastLink) }
        }
    }

    // MARK: Sending

    private func scheduleLocked() {
        guard timer == nil, !queue.isEmpty, enabled else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.locked { self.timer = nil }
            Task { await self.flush() }
        }
        timer = item
        timerQueue.asyncAfter(deadline: .now() + max(backoff, options.flushEvery), execute: item)
    }

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    /// Sends what is waiting, now. Safe to call at any time; it never throws. After a failed send, calls that only come from new
    /// events wait for the back-off to pass; `force` (used when the app goes to the background) tries anyway.
    func flush(force: Bool = false) async {
        if force {
            // a send that is already running finishes first, so nothing waiting is left behind and two sends never overlap
            while locked({ flushing }) { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        let go: Bool = locked {
            guard !flushing, enabled, !queue.isEmpty, iid != nil else { return false }
            if !force, let wait = retryAfter, now() < wait {
                scheduleLocked()
                return false
            }
            flushing = true
            return true
        }
        guard go else { return }
        while true {
            let next: (batch: [TrackedEvent], body: [String: Any])? = locked {
                guard !queue.isEmpty, enabled else { return nil }
                return nextBatchLocked()
            }
            guard let current = next else { break }
            let result = await api.sendEvents(current.body)
            let stop: Bool = locked {
                if result == .retry {
                    backoff = backoff == 0 ? 30 : min(backoff * 2, 300)
                    retryAfter = now().addingTimeInterval(backoff)
                    return true
                }
                backoff = 0
                retryAfter = nil
                inFlight = nil
                // sent, or refused for good: either way these exact events are done with (the queue may have changed meanwhile)
                queue.removeAll { queued in current.batch.contains { $0 === queued } }
                return false
            }
            if stop { break }
        }
        locked {
            flushing = false
            saveLocked()
            scheduleLocked()
        }
    }

    /// The events to send next, with the body to send. A batch that failed is sent again exactly as it was (same events, same id,
    /// same identity and links), so the service can tell it has already stored it if the first attempt got through but the answer
    /// was lost. A new batch holds the oldest run of events that belong to one identity, so nothing goes out under another
    /// person's id.
    private func nextBatchLocked() -> (batch: [TrackedEvent], body: [String: Any])? {
        if let again = inFlight, again.events.allSatisfy({ event in queue.contains { $0 === event } }) {
            return (again.events, again.body)
        }
        guard let head = queue.first, let owner = head.identity ?? currentIdentityLocked() else { return nil }
        var batch: [TrackedEvent] = []
        for event in queue {
            // an event saved by an earlier version has no owner: it goes with the current identity
            guard batch.count < EventTracker.maxBatch, (event.identity ?? owner) == owner else { break }
            batch.append(event)
        }
        let body = envelopeLocked(batch, Check.randomHex(24), owner)
        inFlight = (batch, body)
        return (batch, body)
    }

    private func envelopeLocked(_ batch: [TrackedEvent], _ bid: String, _ owner: EventIdentity) -> [String: Any] {
        var out: [String: Any] = ["iid": owner.iid, "bid": bid, "events": batch.map { $0.toJSON() }]
        if let uid = owner.uid { out["uid"] = uid }
        if let platform = platform { out["platform"] = platform }
        if let version = version { out["app_version"] = version }
        if let firstLink = firstLink { out["first_link"] = firstLink }
        if let lastLink = lastLink { out["last_link"] = lastLink }
        return out
    }

    // MARK: Saving

    private static func encode(_ events: [TrackedEvent]) -> String {
        let list = events.map { $0.toStoredJSON() }
        guard JSONSerialization.isValidJSONObject(list), let data = try? JSONSerialization.data(withJSONObject: list)
        else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes the queue in the background. Not saving only means events could be lost if the app is killed while offline.
    private func saveLocked() {
        let snapshot = queue
        io.async { [store] in try? store.setString(EventTracker.encode(snapshot), forKey: StorageKeys.queue) }
    }

    /// Runs a storage step on the background queue without ever letting a storage error reach the app.
    private func persist(_ step: @escaping @Sendable (VelaLinksStorage) throws -> Void) {
        io.async { [store] in try? step(store) }
    }

    // MARK: Consent and identity

    /// Turns tracking on or off, for example from a privacy setting or a consent screen. Turning it off also throws away what
    /// was waiting. The choice is remembered on the phone. Turning it on after it was off starts the automatic events
    /// (`first_open` and `session_start`), stamped at that moment.
    func setEnabled(_ value: Bool) async {
        let startAuto: Bool = locked {
            let was = enabled
            if value && storageFailed { return false } // no storage: tracking stays off for this session
            enabled = value
            override = value
            if !value {
                queue.removeAll()
                inFlight = nil
                cancelTimerLocked()
                saveLocked()
            }
            if started { persist { try $0.setBool(!value, forKey: StorageKeys.optedOut) } }
            return value && !was && options.autoTrack && started
        }
        if startAuto { automaticEvents() }
    }

    /// Tells the service who the signed-in person is, using the app's own user id: 1 to 100 visible ASCII characters, no spaces.
    /// `nil` signs them out of the analytics without starting a new identity; use ``reset()`` when the next person should be a
    /// stranger. Events still waiting are sent under the previous identity first.
    func setUserId(_ id: String?) async {
        if let id = id, !Check.userId(id) { return }
        let changes = locked { id != uid }
        if changes { await flushBeforeIdentityChange() }
        locked {
            uid = id
            if started {
                if let id = id {
                    persist { try $0.setString(id, forKey: StorageKeys.userId) }
                } else {
                    persist { try $0.remove(forKey: StorageKeys.userId) }
                }
            }
            scheduleLocked()
        }
    }

    /// Sends what is waiting before the identity changes, so those events are not attributed to the next person (or lost). It
    /// waits a few seconds at most, so a bad connection cannot hold up a sign-out.
    private func flushBeforeIdentityChange() async {
        guard locked({ !queue.isEmpty && enabled && iid != nil }) else { return }
        // in the background the app may be suspended mid-send: ask for time (the hold also ends if the wait times out)
        let hold = locked({ inBackground }) ? backgroundTasks.map { BackgroundTaskHold(runner: $0, name: "VelaLinks identity flush") } : nil
        await Timeout.run(after: options.identityFlushTimeout) {
            await self.flush(force: true) // waits for a send that is already running
        }
        hold?.release()
    }

    /// Forgets this install: what is waiting is sent first (a few seconds at most), then a new random id is made and the saved
    /// links and queue are cleared.
    func reset() async {
        await flushBeforeIdentityChange()
        locked {
            queue.removeAll()
            inFlight = nil
            firstLink = nil
            lastLink = nil
            uid = nil
            lastScreen = nil
            onceDone.removeAll()
            guard started else {
                resetBeforeStart = true // start() makes the new install id and ignores what was saved
                return
            }
            guard !storageFailed else { return }
            persist { store in
                for key in [StorageKeys.firstLink, StorageKeys.lastLink, StorageKeys.queue, StorageKeys.userId,
                            StorageKeys.onceDone] { try store.remove(forKey: key) }
            }
            let fresh = Check.randomHex(32)
            iid = fresh
            persist { try $0.setString(fresh, forKey: StorageKeys.iid) }
        }
    }

    // MARK: App lifecycle

    /// The app went to the background: remember when, and send what is waiting (ignoring any back-off).
    func appDidEnterBackground() {
        locked { inBackground = true }
        guard isEnabled else { return }
        let ms = Int((now().timeIntervalSince1970 * 1000).rounded(.down))
        persist { try $0.setInt(ms, forKey: StorageKeys.lastActive) }
        // the task must start now, while the app is still running; the send then finishes under its protection
        let hold = backgroundTasks.map { BackgroundTaskHold(runner: $0, name: "VelaLinks flush") }
        Task {
            await self.flush(force: true)
            self.drainStorage()
            hold?.release()
        }
    }

    /// The app came back: a visit after a long absence is a new session.
    func appWillEnterForeground() {
        locked { inBackground = false }
        guard isEnabled, options.autoTrack else { return }
        automaticEvents()
    }

    /// Stops the timer and sends what is left.
    func stop() async {
        locked { cancelTimerLocked() }
        await flush(force: true)
        drainStorage()
    }
}

/// Runs an operation but stops waiting for it after a number of seconds (the operation itself is not interrupted).
enum Timeout {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    static func run(after seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once(continuation)
            Task {
                await operation()
                once.resume()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                once.resume()
            }
        }
    }
}
