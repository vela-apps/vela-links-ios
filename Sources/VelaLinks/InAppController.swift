import Foundation

/// Decides when to ask the service for a message, hands it to the presenter, and reports what the person did. All the rules (who,
/// how often, which message) are on the service; this only keeps the app calm: never right after a start, never on a screen the app
/// marked as busy, never while paused, never two at once, and after an event or a screen only when the service says a live message
/// waits for it.
final class InAppController: @unchecked Sendable {
    /// The waiting times, in seconds. Tests make them short.
    struct Timing {
        /// How long after a start or a return nothing is shown.
        var settle: TimeInterval = 3
        /// The least time between two asks for the same moment.
        var refetchAfter: TimeInterval = 20
        /// How long the answer to "what is on for this app" is kept.
        var configFor: TimeInterval = 600
        /// How long to wait before trying to read the settings again after a failure.
        var configRetry: TimeInterval = 300
        /// How long the app must have been away for a return to count as a new visit.
        var awayLongEnough: TimeInterval = 300
    }

    /// What the controller asks the rest of the SDK for.
    struct Sources {
        var installId: () -> String?
        var identity: () -> String?
        var sessionId: () -> String
        var enabled: () -> Bool
        var language: () -> String
    }

    static let maxUnsent = 50
    private static let notMoments: Set<String> = [EventNames.firstOpen, EventNames.sessionStart]

    let api: LinksApi
    let sources: Sources
    let presenter: InAppPresenter?
    let style: InAppStyle
    let timing: Timing
    private let handler: () -> InAppMessageHandler?
    private let emit: (VelaLink) -> Void
    let now: () -> Date

    let lock = NSLock()
    private var config: InAppConfig?
    private var configAt: Date?
    private var configFailedAt: Date?
    private var calmAt: Date?
    private var backgroundAt: Date?
    private var showing = false
    private var stopped = false
    private var paused = 0
    private var quiet: [String] = []
    private var screen = ""
    private var asked: [String: Date] = [:]
    private var timer: Task<Void, Never>?
    /// Reports that could not be sent yet (see `InAppController+Reports.swift`).
    var unsent: [HandedOver<[String: Any]>] = []
    var reportChain: Task<Void, Never>?

    init(api: LinksApi, sources: Sources, presenter: InAppPresenter?, style: InAppStyle = InAppStyle(),
         timing: Timing = Timing(), handler: @escaping () -> InAppMessageHandler? = { nil },
         emit: @escaping (VelaLink) -> Void, now: @escaping () -> Date = { Date() }) {
        self.api = api
        self.sources = sources
        self.presenter = presenter
        self.style = style
        self.timing = timing
        self.handler = handler
        self.emit = emit
        self.now = now
    }

    // MARK: Controls

    /// The screens where messages never appear (matched from the start of the name).
    func setQuietScreens(_ screens: [String]) {
        let clean = screens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        lock.sync { quiet = clean }
    }

    /// Stops messages from appearing. Calls add up: each `pause` needs a `resume`.
    func pause() { lock.sync { paused += 1 } }

    /// Lets messages appear again.
    func resume() { lock.sync { if paused > 0 { paused -= 1 } } }

    /// Sets the current screen without asking for anything.
    func noteScreen(_ name: String) { lock.sync { screen = name } }

    // MARK: Moments

    /// The app has just started: ask for the start message once things have settled.
    func onStart() { later("start") }

    /// The app went to the background.
    func onBackground() { lock.sync { backgroundAt = now() } }

    /// The app came back. Only a real absence counts as a new visit.
    func onForeground() {
        let away: Date? = lock.sync {
            let at = backgroundAt
            backgroundAt = nil
            return at
        }
        if let away = away, now().timeIntervalSince(away) < timing.awayLongEnough { return }
        later("resume")
    }

    /// An event or a screen was recorded. The service says which ones a live message waits for; the SDK asks only at those moments.
    func onTracked(_ name: String, isScreen: Bool) {
        if isScreen {
            let waits: Bool = lock.sync {
                screen = name
                return config?.waits(forScreen: name) ?? false
            }
            if waits { later("screen", screen: name, wait: 0) }
        } else if !InAppController.notMoments.contains(name) {
            // before the service has answered nothing is known: wait for the start-up question
            let waits: Bool = lock.sync { config?.waits(forEvent: name) ?? false }
            if waits { later("event", event: name, wait: 0) }
        }
    }

    /// Stops everything and takes a message off the screen.
    func stop() {
        let task: Task<Void, Never>? = lock.sync {
            stopped = true
            let current = timer
            timer = nil
            return current
        }
        task?.cancel()
        if let presenter = presenter { Task { await presenter.cancel() } }
    }

    private func later(_ trigger: String, event: String? = nil, screen: String? = nil, wait: TimeInterval? = nil) {
        lock.sync {
            guard !stopped else { return }
            if trigger == "start" || trigger == "resume" { calmAt = now().addingTimeInterval(timing.settle) }
            let delay = wait ?? timing.settle
            arm(after: delay == 0 ? 0 : delay + 0.2, trigger, event, screen)
        }
    }

    /// Replaces the waiting timer (the caller holds the lock).
    private func arm(after delay: TimeInterval, _ trigger: String, _ event: String?, _ screen: String?) {
        timer?.cancel()
        timer = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.consider(trigger, event: event, screen: screen)
        }
    }

    // MARK: Asking

    /// Whether the app may show a message now: not stopped, not showing one, not paused, tracking on, something to draw with.
    private func mayShow() -> Bool {
        lock.sync { !stopped && !showing && paused == 0 } && sources.enabled() && presenter != nil
    }

    private func inQuietScreen() -> Bool { lock.sync { quiet.contains { screen.hasPrefix($0) } } }

    /// Asks the service for a message for this moment and shows it if there is one and the app is calm.
    func consider(_ trigger: String, event: String? = nil, screen: String? = nil) async {
        guard mayShow(), let presenter = presenter else { return }
        let wait: TimeInterval? = lock.sync {
            guard let until = calmAt, now() < until else { return nil }
            return until.timeIntervalSince(now())
        }
        if let wait = wait {
            lock.sync { arm(after: wait + 0.2, trigger, event, screen) }
            return
        }
        guard !inQuietScreen(), await presenter.isCalm(), startAsking(trigger, event, screen) else { return }
        guard await switchedOn(), let iid = sources.installId() else { return }
        let answer = await api.inAppMessage(query(iid, trigger, event, screen), identityToken: sources.identity())
        guard let message = InAppMessage.tryParse(answer?["message"], allowUrl: allowUrl),
              mayShow(), !inQuietScreen(), await presenter.isCalm() else { return }
        await show(message, presenter)
    }

    /// Notes that this moment is being asked about; `false` when it was asked about a moment ago.
    private func startAsking(_ trigger: String, _ event: String?, _ screen: String?) -> Bool {
        lock.sync {
            let key = "\(trigger)|\(event ?? "")|\(screen ?? "")"
            if let last = asked[key], now().timeIntervalSince(last) < timing.refetchAfter { return false }
            asked[key] = now()
            return true
        }
    }

    /// Whether the service has messages switched on for this app. The settings are kept for ten minutes; after a failed read the
    /// SDK keeps what it had and waits five minutes before reading again.
    private func switchedOn() async -> Bool {
        let moment = now()
        let stale: Bool = lock.sync {
            let old = configAt.map { moment.timeIntervalSince($0) > timing.configFor } ?? true
            let recentlyFailed = configFailedAt.map { moment.timeIntervalSince($0) <= timing.configRetry } ?? false
            return old && !recentlyFailed
        }
        if stale {
            let fresh = await api.config()
            lock.sync {
                if let fresh = fresh {
                    config = InAppConfig(fresh)
                    configAt = moment
                } else {
                    configFailedAt = moment
                }
            }
        }
        return lock.sync { config?.enabled == true }
    }

    private func query(_ iid: String, _ trigger: String, _ event: String?, _ screen: String?) -> [(String, String)] {
        var out = [("iid", iid), ("trigger", trigger)]
        if let event = event { out.append(("event", event)) }
        if let screen = screen, !screen.isEmpty { out.append(("screen", Check.truncated(screen, scalars: 100))) }
        out.append(("lang", sources.language()))
        out.append(("sid", sources.sessionId()))
        out.append(("layouts", "\(InAppLayout.bottomSheet.wire),\(InAppLayout.fullScreen.wire)"))
        return out
    }

    /// Pictures and videos must come over https (plain http only from the service's own host, for local testing), without a login.
    private func allowUrl(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil else { return false }
        let scheme = parts.scheme?.lowercased()
        return scheme == "https" || (scheme == "http" && host == URL(string: api.baseUrl)?.host?.lowercased())
    }

    // MARK: Showing

    private func beginShowing() -> Bool {
        lock.sync {
            if showing || stopped || paused > 0 { return false }
            showing = true
            return true
        }
    }

    private func show(_ message: InAppMessage, _ presenter: InAppPresenter) async {
        guard beginShowing() else { return }
        defer { lock.sync { showing = false } }
        let report = reporter(for: message)
        if let custom = handler() {
            await custom(message, InAppReporter(report))
            return
        }
        guard await presenter.loadPictures(for: message) else { return } // a message whose picture does not load is not shown
        let progress = VideoProgress()
        let answer = await presenter.present(message, style: style, onShown: { report("shown", nil) },
                                             onVideoEvent: { action in
                                                 progress.note(action)
                                                 report(action, nil)
                                             })
        guard let outcome = answer else { return }
        switch outcome {
        case .dismissed:
            report("dismissed", nil)
            if message.media?.isVideo == true && progress.percent < 25 { report("closed_early", nil) }
        case .button(let index):
            report("clicked", index)
            openPage(of: message, button: index)
        }
    }

    /// A button that points at a page of the app opens it the way a link does, without counting it as the link that brought the
    /// person.
    private func openPage(of message: InAppMessage, button index: Int) {
        guard !lock.sync({ stopped }), index >= 0, index < message.buttons.count,
              let route = message.buttons[index].route else { return }
        emit(VelaLink(code: "inapp_" + message.id.prefix(12), route: route, params: message.buttons[index].params,
                      title: message.title, campaign: "inapp"))
    }
}

/// How far a video got, from the progress reports it makes (`video_25`, `video_50` ...).
final class VideoProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var percent: Int { lock.sync { value } }

    func note(_ action: String) {
        guard action.hasPrefix("video_"), action != "video_started", let mark = Int(action.dropFirst(6)) else { return }
        lock.sync { value = mark }
    }
}
