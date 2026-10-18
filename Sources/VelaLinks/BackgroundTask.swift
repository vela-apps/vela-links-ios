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
///
/// `UIApplication.shared` and its background-task methods are marked unavailable to app extensions, and a package that names them
/// does not compile into an extension target. So the application object and the two methods are reached by name at run time,
/// which compiles everywhere and does exactly the same in an app. In an extension there is no application object: no extra time
/// is requested (the send then runs as usual and is kept for next time if it is cut off).
final class UIKitBackgroundTaskRunner: BackgroundTaskRunner, @unchecked Sendable {
    private typealias Begin = @convention(c) (AnyObject, Selector, NSString?, @escaping @convention(block) () -> Void) -> UInt
    private typealias End = @convention(c) (AnyObject, Selector, UInt) -> Void

    private static let beginSelector = NSSelectorFromString("beginBackgroundTaskWithName:expirationHandler:")
    private static let endSelector = NSSelectorFromString("endBackgroundTask:")

    /// The running application, or `nil` in an app extension.
    private static func application() -> AnyObject? {
        guard !Bundle.main.bundlePath.hasSuffix(".appex"),
              let type = NSClassFromString("UIApplication") as? NSObject.Type,
              let shared = type.perform(NSSelectorFromString("sharedApplication")) else { return nil }
        let app = shared.takeUnretainedValue()
        return app.responds(to: beginSelector) && app.responds(to: endSelector) ? app : nil
    }

    func begin(name: String, expiration: @escaping @Sendable () -> Void) -> Int? {
        let start: () -> Int? = {
            guard let app = UIKitBackgroundTaskRunner.application(),
                  let imp = (app as? NSObject)?.method(for: UIKitBackgroundTaskRunner.beginSelector) else { return nil }
            let call = unsafeBitCast(imp, to: Begin.self)
            let id = call(app, UIKitBackgroundTaskRunner.beginSelector, name as NSString, { expiration() })
            // 0 is UIBackgroundTaskIdentifier.invalid
            return id == 0 ? nil : Int(id)
        }
        return Thread.isMainThread ? start() : DispatchQueue.main.sync(execute: start)
    }

    func end(_ token: Int) {
        let finish = {
            guard let app = UIKitBackgroundTaskRunner.application(),
                  let imp = (app as? NSObject)?.method(for: UIKitBackgroundTaskRunner.endSelector) else { return }
            unsafeBitCast(imp, to: End.self)(app, UIKitBackgroundTaskRunner.endSelector, UInt(token))
        }
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
