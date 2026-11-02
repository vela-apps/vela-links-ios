import Foundation

/// Draws messages. The real one uses UIKit (see `UIKitInAppPresenter`); tests use a fake. It never decides anything: the controller
/// decides when to ask and what to report.
protocol InAppPresenter: AnyObject, Sendable {
    /// Whether now is a good moment: the app is in front, no other presentation is in progress, the keyboard is closed.
    func isCalm() async -> Bool
    /// Loads the picture (or the video's poster) first, so a message whose picture cannot be loaded is never drawn.
    func loadPictures(for message: InAppMessage) async -> Bool
    /// Draws the message and waits for the person to answer. `onShown` is called as soon as it is on the screen, before anything the
    /// person can do with it. Returns `nil` when it could not be drawn at all (then `onShown` was not called).
    func present(_ message: InAppMessage, style: InAppStyle, onShown: @escaping @Sendable () -> Void,
                 onVideoEvent: @escaping @Sendable (String) -> Void) async -> InAppAnswer?
    /// Takes the message off the screen (the SDK was stopped).
    func cancel() async
}

/// Reports what happens to a message that the app draws itself (see ``VelaLinks/setInAppMessageHandler(_:)``).
public final class InAppReporter: @unchecked Sendable {
    private let send: @Sendable (String, Int?) -> Void

    init(_ send: @escaping @Sendable (String, Int?) -> Void) { self.send = send }

    /// Call when the message is on the screen.
    public func markShown() { send("shown", nil) }

    /// Call when the person chose a button (0 or 1). The SDK does not open the button's page: your handler does that.
    public func markClicked(_ button: Int) { send("clicked", button) }

    /// Call when the person closed the message without choosing.
    public func markDismissed() { send("dismissed", nil) }
}

/// Draws a message yourself. Called on the main thread with the message and a reporter to say when it was shown, which button was
/// chosen and when it was closed.
public typealias InAppMessageHandler = @MainActor @Sendable (InAppMessage, InAppReporter) async -> Void
