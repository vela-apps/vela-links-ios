#if canImport(UIKit) && !os(watchOS)
import UIKit

/// A message drawn on the screen: a bottom sheet or a full screen. It reports what the person did and never decides anything itself.
///
/// - Text follows Dynamic Type, wraps, and scrolls when it does not fit.
/// - Colours follow light and dark mode.
/// - VoiceOver reads the picture's description, the headline, the line, the buttons, then the close mark; the escape gesture
///   (two-finger Z) closes the message.
/// - With "Reduce Motion" on, the message appears without sliding and a video is replaced by its poster.
@MainActor
final class InAppMessageViewController: UIViewController {
    let message: InAppMessage
    let style: InAppStyle
    let images: InAppImageStore
    let reduceMotion: Bool

    /// Called once with what the person did.
    var onAnswer: ((InAppAnswer) -> Void)?
    /// Told how far a video got.
    var onVideoEvent: (String) -> Void = { _ in }

    // The pieces the layouts build (see `InAppMessageViewController+Layouts.swift`).
    let scrim = UIView()
    let card = UIView()
    let titleLabel = UILabel()
    let bodyLabel = UILabel()
    var buttons: [InAppActionButton] = []
    var closeButton: InAppRoundButton?
    var mediaView: InAppMediaView?
    var popHeight: NSLayoutConstraint?
    var popSpacer: NSLayoutConstraint?
    var popBottom: NSLayoutConstraint?
    var sheetWords: UIStackView?
    var gradient: CAGradientLayer?
    private var answered = false

    init(message: InAppMessage, style: InAppStyle, images: InAppImageStore,
         reduceMotion: Bool? = nil) {
        self.message = message
        self.style = style
        self.images = images
        self.reduceMotion = reduceMotion ?? UIAccessibility.isReduceMotionEnabled
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Answering

    /// Closes the message with an answer (only the first one counts).
    func finish(_ answer: InAppAnswer) {
        guard !answered else { return }
        answered = true
        mediaView?.stopVideo()
        onAnswer?(answer)
    }

    @objc func closeTapped() { finish(.dismissed) }

    @objc func scrimTapped() { finish(.dismissed) }

    @objc func buttonTapped(_ sender: InAppActionButton) {
        if let index = buttons.firstIndex(of: sender) { finish(.button(index)) }
    }

    @objc func mediaTapped() {
        if let index = message.primaryIndex { finish(.button(index)) }
    }

    override func accessibilityPerformEscape() -> Bool {
        finish(.dismissed)
        return true
    }

    // MARK: Life of the view

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        switch message.layout {
        case .bottomSheet: buildBottomSheet()
        case .fullScreen: buildFullScreen()
        }
        applyColors()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient?.frame = gradient?.superlayer?.bounds ?? .zero
        updatePop()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // room for the home indicator under the buttons
        sheetWords?.layoutMargins.bottom = 20 + view.safeAreaInsets.bottom
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { applyColors() }
    }

    /// The colours for light or dark mode, set on everything that has one.
    func applyColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let s = dark ? style.dark : style
        let full = message.layout == .fullScreen
        scrim.backgroundColor = UIColor(s.scrim)
        card.backgroundColor = UIColor(s.surface)
        titleLabel.textColor = full ? .white : UIColor(s.text)
        bodyLabel.textColor = full ? UIColor(white: 0.9, alpha: 1) : UIColor(s.mutedText)
        for (index, button) in buttons.enumerated() {
            if index == 0 {
                button.backgroundColor = UIColor(s.accent)
                button.label.textColor = UIColor(s.onAccent)
            } else {
                button.backgroundColor = .clear
                button.label.textColor = full ? .white : UIColor(s.mutedText)
            }
        }
    }

    // MARK: Appearing and leaving

    /// Brings the message on: it slides up (or fades in with Reduce Motion), then VoiceOver is pointed at it.
    func animateIn() {
        view.layoutIfNeeded()
        let sheet = message.layout == .bottomSheet
        if sheet && !reduceMotion { card.transform = CGAffineTransform(translationX: 0, y: view.bounds.height) }
        scrim.alpha = 0
        card.alpha = sheet || !reduceMotion ? 1 : 0
        let show = {
            self.scrim.alpha = 1
            self.card.transform = .identity
            self.card.alpha = 1
        }
        if reduceMotion { show() } else { UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut, animations: show) }
        UIAccessibility.post(notification: .screenChanged, argument: mediaView?.imageView ?? titleLabel)
    }

    /// Takes the message off with a short fade (none with Reduce Motion), then calls `done`.
    func animateOut(_ done: @escaping () -> Void) {
        guard !reduceMotion else { return done() }
        UIView.animate(withDuration: 0.18, animations: { self.view.alpha = 0 }, completion: { _ in done() })
    }
}
#endif
