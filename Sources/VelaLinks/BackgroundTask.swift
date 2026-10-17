import Foundation
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// Asks the system for a little extra running time while the app is in the background, so a send is not cut off by suspension.
/// Small on purpose, so tests can replace it.
protocol BackgroundTaskRunner: AnyObject, Sendable {
    /// Starts a background task and returns its token, or `nil` when the system refuses. `expiration` is called if the system
    /// runs out of patience first.
    func begin(name: String, expiration: @escaping @Sendable () -> Void) -> Int?
    /// Ends a task started with `begin`. Called exactly once per token.
    func end(_ token: Int)
}

/// Holds one background task and makes sure it is ended exactly once, whichever happens first: the work finishing or the
/// system's expiration handler.
final class BackgroundTaskHold: @unchecked Sendable {
    private let lock = NSLock()
    private var token: Int?
    private var finished = false
    private let runner: BackgroundTaskRunner

    init(runner: BackgroundTaskRunner, name: String) {
        self.runner = runner
        let started = runner.begin(name: name) { [weak self] in self?.release() }
        lock.sync {
            token = started
            if finished, let started = started { // expired before begin() returned
                token = nil
                runner.end(started)
            }
        }
    }

    /// Ends the task. Safe to call any number of times.
    func release() {
        let toEnd: Int? = lock.sync {
            finished = true
            let t = token
            token = nil
            return t
        }
        if let toEnd = toEnd { runner.end(toEnd) }
    }

    /// Runs `work` while holding background time from `runner` (if any). The task is ended on every path.
    static func run(_ runner: BackgroundTaskRunner?, name: String, _ work: () async -> Void) async {
        guard let runner = runner else {
            await work()
            return
        }
        let hold = BackgroundTaskHold(runner: runner, name: name)
        await work()
        hold.release()
    }
}

#if canImport(UIKit) && !os(macOS) && !os(watchOS)
/// The real thing: `UIApplication.beginBackgroundTask`.
final class UIKitBackgroundTaskRunner: BackgroundTaskRunner, @unchecked Sendable {
    func begin(name: String, expiration: @escaping @Sendable () -> Void) -> Int? {
        let start: () -> Int? = {
            let id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
            return id == .invalid ? nil : id.rawValue
        }
        return Thread.isMainThread ? start() : DispatchQueue.main.sync(execute: start)
    }

    func end(_ token: Int) {
        let finish = { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token)) }
        if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
    }
}
#endif

enum DefaultBackgroundTasks {
    static func make() -> BackgroundTaskRunner? {
        #if canImport(UIKit) && !os(macOS) && !os(watchOS)
        return UIKitBackgroundTaskRunner()
        #else
        return nil
        #endif
    }
}
