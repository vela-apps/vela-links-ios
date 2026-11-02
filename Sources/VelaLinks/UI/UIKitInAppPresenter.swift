#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Draws messages in a window of its own that sits above the app's windows, on the scene the person is using. That works the same
/// for UIKit and SwiftUI apps, needs no view controller from the app, and leaves the app's own views and key window alone.
///
/// It never draws while: the app is in the background, another message is on the screen, the keyboard is open, or the app is
/// showing a system alert. A phone with several scenes (iPad) gets the message on the active one.
final class UIKitInAppPresenter: InAppPresenter, @unchecked Sendable {
    // Only touched on the main thread.
    private var current: (window: UIWindow, controller: InAppMessageViewController)?
    private var keyboardVisible = false
    private var observers: [NSObjectProtocol] = []
    private let images: InAppImageStore
    private let windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)

    init(images: InAppImageStore = InAppImageStore()) {
        self.images = images
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                self?.keyboardVisible = true
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                self?.keyboardVisible = false
            },
        ]
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: InAppPresenter

    func isCalm() async -> Bool { await MainActor.run { calmNow() } }

    /// The message's picture (or its video's poster) must load first. A video with no poster cannot fall back, so it is not shown.
    func loadPictures(for message: InAppMessage) async -> Bool {
        guard let media = message.media else { return true }
        guard let url = media.isVideo ? media.posterUrl : media.url else { return false }
        return await withTaskTimeout(seconds: 5) { await self.images.load(url) != nil } ?? false
    }

    func present(_ message: InAppMessage, style: InAppStyle, onShown: @escaping @Sendable () -> Void,
                 onVideoEvent: @escaping @Sendable (String) -> Void) async -> InAppAnswer? {
        await withCheckedContinuation { (continuation: CheckedContinuation<InAppAnswer?, Never>) in
            DispatchQueue.main.async {
                self.draw(message, style, onShown, onVideoEvent) { continuation.resume(returning: $0) }
            }
        }
    }

    func cancel() async {
        await MainActor.run { current?.controller.finish(.dismissed) }
    }

    // MARK: Drawing (main thread)

    /// Whether now is a good moment (the caller is on the main thread).
    @MainActor
    func calmNow() -> Bool {
        guard current == nil, !keyboardVisible, let scene = UIKitApplication.foregroundScene() else { return false }
        return !systemAlertIsShowing(in: scene)
    }

    /// Whether the app's own window is busy presenting or dismissing something, or shows an alert: not a moment to interrupt.
    @MainActor
    private func systemAlertIsShowing(in scene: UIWindowScene) -> Bool {
        var top = scene.windows.first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let controller = top else { return false }
        return controller is UIAlertController || controller.isBeingPresented || controller.isBeingDismissed
    }

    @MainActor
    private func draw(_ message: InAppMessage, _ style: InAppStyle, _ onShown: @escaping @Sendable () -> Void,
                      _ onVideoEvent: @escaping @Sendable (String) -> Void, _ finish: @escaping (InAppAnswer?) -> Void) {
        guard calmNow(), let scene = UIKitApplication.foregroundScene() else { return finish(nil) }
        let controller = InAppMessageViewController(message: message, style: style, images: images)
        controller.onVideoEvent = onVideoEvent
        let window = UIWindow(windowScene: scene)
        window.windowLevel = windowLevel
        window.backgroundColor = .clear
        window.rootViewController = controller
        current = (window, controller)
        controller.onAnswer = { [weak self] answer in
            self?.remove(controller)
            finish(answer)
        }
        window.isHidden = false
        controller.animateIn()
        onShown() // it is on the screen now: reported before anything the person can do with it
    }

    /// Takes the message off. The window goes once it has faded; until then no other message is drawn.
    @MainActor
    private func remove(_ controller: InAppMessageViewController) {
        guard let window = current?.window, current?.controller === controller else { return }
        controller.animateOut { [weak self] in
            window.isHidden = true
            window.rootViewController = nil
            if self?.current?.window === window { self?.current = nil }
        }
    }
}

/// Runs `work` and gives its answer, or `nil` if it takes longer than `seconds` (the work is then left to finish by itself).
func withTaskTimeout<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
#endif
