import Foundation

/// What the app tells Vela Links about the signed-in person: facts (language, plain properties), the phone's push token, and what
/// the person agreed to. Everything is kept on the phone until it has been delivered (so it survives being offline or a restart), is
/// sent only with the signed identity token, and is never sent while tracking is switched off. Nothing here throws into the app.
final class PeopleSync: @unchecked Sendable {
    struct Options {
        /// How long to wait for more changes before sending properties.
        var debounce: TimeInterval = 30
        /// How long to wait before trying again after a failure.
        var retryEvery: TimeInterval = 60
        /// The short wait before sending something that should go out now (a consent answer, a push token, a new identity), so
        /// several changes made together travel together.
        var soon: TimeInterval = 0.2
    }

    /// What the sync asks the rest of the SDK for.
    struct Sources {
        var identity: () -> String?
        var installId: () -> String?
        var enabled: () -> Bool
        var platform: String?
        var appVersion: () -> String?
        var deviceLocale: () -> String?
    }

    private static let maxConsents = 20

    private let api: LinksApi
    private let store: VelaLinksStorage
    private let sources: Sources
    private let options: Options
    private let lock = NSLock()
    private let io = DispatchQueue(label: "in.velaapps.links.people", qos: .utility)
    private let timerQueue = DispatchQueue(label: "in.velaapps.links.people.timer", qos: .utility)

    private var state = PeopleState()
    private var loaded = false
    private var stopped = false
    private var timer: DispatchWorkItem?
    private var running: Task<Void, Never>?

    init(api: LinksApi, store: VelaLinksStorage, sources: Sources, options: Options = Options()) {
        self.api = api
        self.store = store
        self.sources = sources
        self.options = options
    }

    /// Waits until everything handed to the storage queue has been written (used by tests and by shutdown).
    func drainStorage() { io.sync {} }

    /// What is waiting, for tests.
    var snapshot: PeopleState { lock.sync { state } }

    // MARK: Start and stop

    /// Loads what is waiting from the phone and sends it if it can.
    func start() {
        guard let saved = try? PeopleState(store) else { return } // without storage nothing is kept, so nothing is promised
        lock.sync {
            state = saved
            loaded = true
        }
        schedule(after: options.soon)
    }

    /// Stops sending and writes what is left.
    func stop() {
        lock.sync {
            stopped = true
            timer?.cancel()
            timer = nil
        }
        drainStorage()
    }

    // MARK: What the app tells us

    /// Saves the properties (and the optional locale, time zone and quiet hours) to send. Only what changed is sent.
    func setProperties(_ properties: [String: Any?], locale: String?, timezone: String?, quietStart: Int?, quietEnd: Int?) {
        guard sources.enabled() else { return }
        let clean = PeopleRules.cleanUserProperties(properties)
        let language = PeopleRules.cleanLocale(locale)
        lock.sync {
            state.props.merge(clean) { _, new in new }
            if let language = language { state.profile.locale = language }
            if let zone = timezone, zone.unicodeScalars.count <= 40 { state.profile.timezone = zone }
            if let start = quietStart, (0...23).contains(start) { state.profile.quietStart = start }
            if let end = quietEnd, (0...23).contains(end) { state.profile.quietEnd = end }
            saveLocked()
        }
        schedule(after: options.debounce)
    }

    /// Saves the phone's push token to send. A token already delivered is not sent again.
    func setPushToken(_ token: String, provider: String) {
        guard sources.enabled(), PeopleRules.pushProviders.contains(provider),
              let clean = PeopleRules.cleanPushToken(token) else { return }
        let changed: Bool = lock.sync {
            if clean == state.sentPush && state.push == nil { return false }
            state.push = PendingPush(token: clean, provider: provider)
            saveLocked()
            return true
        }
        if changed { schedule(after: options.soon) }
    }

    /// Records what the person agreed to (or withdrew). Returns `false` when the input is not valid.
    func setConsent(_ channel: String, granted: Bool, policyVersion: String, purpose: String, source: String) -> Bool {
        guard ConsentCheck.valid(channel: channel, purpose: purpose, policyVersion: policyVersion, source: source) else {
            return false
        }
        let on = sources.enabled()
        lock.sync {
            state.answers["\(channel)/\(purpose)"] = granted
            if on {
                state.consents.removeAll { $0.channel == channel && $0.purpose == purpose }
                state.consents.append(ConsentAnswer(channel: channel, purpose: purpose, granted: granted,
                                                    policyVersion: policyVersion, source: source))
                if state.consents.count > PeopleSync.maxConsents {
                    state.consents.removeFirst(state.consents.count - PeopleSync.maxConsents)
                }
            }
            saveLocked() // with tracking off the answer is remembered here and not sent
        }
        if on { schedule(after: options.soon) }
        return true
    }

    /// What the person last chose for `channel` on this phone, or `nil` if they were never asked.
    func consentOf(_ channel: String, purpose: String) -> Bool? { lock.sync { state.answers["\(channel)/\(purpose)"] } }

    /// Tracking was switched off: nothing waiting is sent, and it is forgotten.
    func discard() {
        lock.sync {
            state.props = [:]
            state.profile = ProfileFields()
            state.push = nil
            state.consents = []
            timer?.cancel()
            timer = nil
            saveLocked()
        }
    }

    /// The person signs out: asks the service to forget the link between them and this phone's push token, so nothing meant for
    /// them reaches whoever uses the phone next. Call it before `reset()`, while the identity is still there. Best effort: nothing
    /// is sent when no token was ever given, tracking is off, nobody is verified, or there is no install id; a failure is ignored.
    func unlinkPush() async {
        let token = lock.sync { state.push?.token ?? state.sentPush }
        guard let token = token, sources.enabled(), var body = envelope() else { return }
        body["token"] = token
        _ = await api.post("/v1/users/push-token/remove", body)
    }

    /// A new person on this phone: what was sent and what was agreed belong to the last one.
    func reset() {
        discard()
        lock.sync {
            state.sent = [:]
            state.sentPush = nil
            state.answers = [:]
            saveLocked()
        }
    }

    /// Tries to send what is waiting now (the app came back, or an identity arrived).
    func nudge() { schedule(after: options.soon) }

    // MARK: Sending

    private func schedule(after delay: TimeInterval) {
        lock.sync {
            guard !stopped else { return }
            timer?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                Task { await self.flush() }
            }
            timer = item
            timerQueue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// Sends what is waiting, one kind at a time. Safe to call at any moment; overlapping calls share one run.
    func flush() async {
        let task: Task<Void, Never> = lock.sync {
            if let current = running { return current }
            let task = Task {
                await self.run()
                self.lock.sync { self.running = nil }
            }
            running = task
            return task
        }
        await task.value
    }

    private func run() async {
        let ready: Bool = lock.sync { loaded && !stopped }
        guard ready, sources.enabled() else { return }
        // nothing about a person goes out without a verified identity
        guard sources.identity() != nil, sources.installId() != nil else { return }
        let results = [await sendProfile(), await sendPush(), await sendConsents()]
        if results.contains(.retry) { schedule(after: options.retryEvery) }
    }

    /// The body of every call about a person: who the phone is and the proof of who the person is.
    private func envelope() -> [String: Any]? {
        guard let iid = sources.installId(), let token = sources.identity() else { return nil }
        return ["iid": iid, "identity_token": token]
    }

    private func sendProfile() async -> PostResult {
        let work: (changed: [String: JSONScalar], profile: ProfileFields) = lock.sync {
            (state.props.filter { state.sent[$0.key] != $0.value }, state.profile)
        }
        guard !(work.changed.isEmpty && work.profile.isEmpty), var body = envelope() else { return .sent }
        body.merge(work.profile.json) { _, new in new }
        body["attrs"] = work.changed.mapValues { $0.json }
        if let platform = sources.platform { body["platform"] = platform }
        if let version = sources.appVersion() { body["app_version"] = version }
        if let locale = work.profile.locale ?? sources.deviceLocale() { body["locale"] = locale }
        let result = await api.post("/v1/users/profile", body)
        guard result == .sent || result == .drop else { return result }
        lock.sync {
            if result == .sent {
                state.sent.merge(work.changed) { _, new in new }
                state.sent = state.sent.filter { $0.value != .null }
            }
            state.props = state.props.filter { work.changed[$0.key] != $0.value }
            if state.profile == work.profile { state.profile = ProfileFields() }
            saveLocked()
        }
        return result
    }

    private func sendPush() async -> PostResult {
        guard let push = lock.sync({ state.push }), var body = envelope() else { return .sent }
        body["token"] = push.token
        body["provider"] = push.provider
        let result = await api.post("/v1/users/push-token", body)
        guard result == .sent || result == .drop else { return result }
        lock.sync {
            if result == .sent { state.sentPush = push.token }
            if state.push == push { state.push = nil }
            saveLocked()
        }
        return result
    }

    private func sendConsents() async -> PostResult {
        var last = PostResult.sent
        while let answer = lock.sync({ state.consents.first }), var body = envelope() {
            body.merge(answer.json) { _, new in new }
            last = await api.post("/v1/users/consent", body)
            if last == .retry || last == .needsIdentity { return last }
            // sent, or refused for good
            lock.sync {
                if state.consents.first == answer { state.consents.removeFirst() }
                saveLocked()
            }
        }
        return last
    }

    // MARK: Saving

    /// Writes the state in the background. Not saving only means a restart before delivery loses it.
    private func saveLocked() {
        let copy = state
        io.async { [store] in copy.save(to: store) }
    }
}

/// The rules a consent answer must meet before it is kept.
enum ConsentCheck {
    static func valid(channel: String, purpose: String, policyVersion: String, source: String) -> Bool {
        PeopleRules.consentChannels.contains(channel) && PeopleRules.consentPurposes.contains(purpose)
            && PeopleRules.validPolicyVersion(policyVersion) && PeopleRules.consentSources.contains(source)
    }
}
