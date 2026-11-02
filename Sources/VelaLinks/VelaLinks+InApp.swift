import Foundation

/// In-app messages (nudges). The service decides who sees what and when; the SDK draws the message over your app, reports what the
/// person did, and hands a button's page to ``VelaLinks/onLink(_:)`` the way a link that opens the app does.
extension VelaLinks {
    /// Screens where messages never appear, matched from the start of the screen name as reported by `trackScreen` /
    /// `.velaScreen` (for example `["Payment", "Otp"]`). Use it for sign-in, payment and anything the person must not be
    /// interrupted in.
    public func setQuietScreens(_ screens: [String]) {
        runNow { $0.inApp.setQuietScreens(screens) }
    }

    /// Stops messages from appearing for a moment (a payment, a video, a game in progress). Each call needs a
    /// ``resumeMessages()``.
    public func pauseMessages() {
        runNow { $0.inApp.pause() }
    }

    /// Lets messages appear again.
    public func resumeMessages() {
        runNow { $0.inApp.resume() }
    }

    /// Draw messages yourself. By default the SDK draws them; set this and it hands you each message (on the main thread) with a
    /// ``InAppReporter`` to say when it was shown, which button was chosen and when it was closed. Your handler also opens the
    /// button's page itself. Pass `nil` to go back to the SDK's own look.
    public func setInAppMessageHandler(_ handler: InAppMessageHandler?) {
        lock.sync { inAppHandler = handler }
    }
}
