#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import UIKit

/// The picture or video of a message. A video plays silently on a loop with a small button to turn the sound on. Its poster picture
/// is shown first, and stays if the video cannot play (a slow network, a broken file) or the phone is set to reduce motion.
@MainActor
final class InAppMediaView: UIView {
    /// The picture (or poster). It is the one thing VoiceOver reads, with the message's description.
    let imageView = UIImageView()
    /// True while a video is on the screen instead of the poster.
    private(set) var isPlayingVideo = false

    private let media: InAppMedia
    private let onVideoEvent: (String) -> Void
    private let playerLayer = AVPlayerLayer()
    private let soundButton = InAppRoundButton(symbol: "speaker.slash.fill", label: "Sound on",
                                               circleColor: UIColor(white: 0, alpha: 0.6), tint: .white)
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var giveUp: DispatchWorkItem?
    private var reported = Set<Int>()
    private var started = false
    private var muted = true

    /// How long a video may take to get ready before the poster is kept.
    static let videoWait: TimeInterval = 6

    init(media: InAppMedia, images: InAppImageStore, fit: UIView.ContentMode, reduceMotion: Bool,
         onVideoEvent: @escaping (String) -> Void) {
        self.media = media
        self.onVideoEvent = onVideoEvent
        super.init(frame: .zero)
        clipsToBounds = true
        imageView.contentMode = fit
        imageView.clipsToBounds = true
        imageView.image = images.cached(media.isVideo ? (media.posterUrl ?? media.url) : media.url)
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = media.alt
        imageView.accessibilityTraits = .image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor), imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor), imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        accessibilityElements = [imageView]
        if media.isVideo && !reduceMotion { openVideo(fit: fit) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    // MARK: Video

    private func openVideo(fit: UIView.ContentMode) {
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: media.url))
        player = queue
        self.looper = looper
        playerLayer.player = queue
        playerLayer.videoGravity = fit == .scaleAspectFit ? .resizeAspect : .resizeAspectFill
        playerLayer.opacity = 0
        layer.insertSublayer(playerLayer, above: imageView.layer)
        statusObservation = looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
            let status = looper.status
            Task { @MainActor in self?.looperChanged(status) }
        }
        let item = DispatchWorkItem { [weak self] in Task { @MainActor in self?.fallBackToPoster() } }
        giveUp = item
        DispatchQueue.main.asyncAfter(deadline: .now() + InAppMediaView.videoWait, execute: item)
    }

    private func looperChanged(_ status: AVPlayerLooper.Status) {
        switch status {
        case .ready: showVideo()
        case .failed, .cancelled: fallBackToPoster()
        default: break
        }
    }

    private func showVideo() {
        guard let player = player, !isPlayingVideo else { return }
        giveUp?.cancel()
        isPlayingVideo = true
        playerLayer.opacity = 1
        player.play()
        addSoundButton()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            Task { @MainActor in self?.progress() }
        }
    }

    private func addSoundButton() {
        soundButton.translatesAutoresizingMaskIntoConstraints = false
        soundButton.addTarget(self, action: #selector(toggleSound), for: .touchUpInside)
        addSubview(soundButton)
        NSLayoutConstraint.activate([
            soundButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            soundButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        accessibilityElements = [imageView, soundButton]
    }

    @objc private func toggleSound() {
        muted.toggle()
        player?.isMuted = muted
        soundButton.update(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           label: muted ? "Sound on" : "Sound off")
        if !muted { onVideoEvent("unmuted") }
    }

    /// Reports the start, and 25, 50, 75 and 100 percent, each once.
    private func progress() {
        guard let player = player, let item = player.currentItem else { return }
        let total = item.duration.seconds
        let position = player.currentTime().seconds
        guard total.isFinite, total > 0, position.isFinite else { return }
        if !started && player.rate > 0 {
            started = true
            onVideoEvent("video_started")
        }
        let done = Int(position * 100 / total)
        for mark in [25, 50, 75] where done >= mark && reported.insert(mark).inserted { onVideoEvent("video_\(mark)") }
        if position >= total - 0.12 && reported.insert(100).inserted { onVideoEvent("video_100") }
    }

    /// The video could not play: keep the poster picture.
    private func fallBackToPoster() {
        guard player != nil else { return }
        stopVideo()
        playerLayer.removeFromSuperlayer()
        soundButton.removeFromSuperview()
        accessibilityElements = [imageView]
    }

    /// Stops the player and everything watching it. Called when the message goes away.
    func stopVideo() {
        giveUp?.cancel()
        statusObservation?.invalidate()
        statusObservation = nil
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer.player = nil
        isPlayingVideo = false
    }
}
#endif
