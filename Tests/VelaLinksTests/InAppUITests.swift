#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import UIKit
import XCTest
@testable import VelaLinks

/// How a message looks and what it reports. Ported from the Flutter SDK's `inapp_test.dart` ("how it looks"). These run on an iOS
/// simulator (`xcodebuild test`); `swift test` on a Mac skips them because UIKit is not there.
@MainActor
final class InAppUITests: XCTestCase {
    private let size = CGSize(width: 390, height: 844)
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
    }

    // MARK: building blocks

    private func message(layout: String = "bottom_sheet", media: String? = nil) throws -> InAppMessage {
        let object = try JSONSerialization.jsonObject(with: Data(messageJSON(layout: layout, media: media).utf8))
        return try XCTUnwrap(InAppMessage.tryParse(object) { _ in true })
    }

    private func pictureStore(_ url: String = "https://links.x.com/v1/media/m1/abc.png") -> InAppImageStore {
        let store = InAppImageStore { _ in nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6))
        store.insert(renderer.image { UIColor.systemOrange.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 6)) },
                     for: URL(string: url)!)
        return store
    }

    /// Puts the controller in a window of the size of a phone and lays it out.
    private func show(_ message: InAppMessage, style: InAppStyle = InAppStyle(), reduceMotion: Bool = false,
                      images: InAppImageStore? = nil, size custom: CGSize? = nil) -> InAppMessageViewController {
        let controller = InAppMessageViewController(message: message, style: style, images: images ?? pictureStore(),
                                                    reduceMotion: reduceMotion)
        let window = UIWindow(frame: CGRect(origin: .zero, size: custom ?? size))
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func labels(in view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    private func texts(in view: UIView) -> [String] { labels(in: view).compactMap { $0.text } }

    /// Taps a control the way a finger would. (`sendActions` goes through `UIApplication`, which a test with no app does not have,
    /// so the actions are performed directly.)
    private func tap(_ control: UIControl?) {
        guard let control = control else { return XCTFail("no such control") }
        for target in control.allTargets {
            for name in control.actions(forTarget: target, forControlEvent: .touchUpInside) ?? [] {
                _ = (target as? NSObject)?.perform(Selector(name), with: control)
            }
        }
    }

    private func answers(of controller: InAppMessageViewController) -> Log {
        let log = Log()
        controller.onAnswer = { answer in
            switch answer {
            case .button(let index): log.add("button \(index)")
            case .dismissed: log.add("dismissed")
            }
        }
        return log
    }

    private func color(_ color: UIColor?, in controller: UIViewController) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color?.resolvedColor(with: controller.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map { ($0 * 255).rounded() }
    }

    /// Like `show`, but inside a parent that gives the message the trait collection a person's settings would (text size).
    private func showWithTraits(_ message: InAppMessage, _ traits: UITraitCollection, size custom: CGSize)
        -> InAppMessageViewController {
        let controller = InAppMessageViewController(message: message, style: InAppStyle(), images: pictureStore(),
                                                    reduceMotion: false)
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(origin: .zero, size: custom))
        window.rootViewController = parent
        window.isHidden = false
        windows.append(window)
        parent.addChild(controller)
        controller.view.frame = parent.view.bounds
        parent.view.addSubview(controller.view)
        controller.didMove(toParent: parent)
        parent.setOverrideTraitCollection(traits, forChild: controller)
        controller.view.layoutIfNeeded()
        return controller
    }

    // MARK: a bottom sheet

    func testABottomSheetShowsTheHeadlineTheLineThePictureAndBothButtons() throws {
        let controller = show(try message())
        let words = texts(in: controller.view)
        XCTAssertTrue(words.contains("Fresh sweets"))
        XCTAssertTrue(words.contains("Order today"))
        XCTAssertTrue(words.contains("Order now"))
        XCTAssertTrue(words.contains("Not now"))
        XCTAssertEqual(controller.mediaView?.imageView.accessibilityLabel, "Sweets")
        XCTAssertTrue(controller.mediaView?.imageView.accessibilityTraits.contains(.image) == true)
        XCTAssertEqual(controller.closeButton?.accessibilityLabel, "Close")
        XCTAssertNotNil(controller.mediaView?.imageView.image, "the preloaded picture is drawn")
        XCTAssertEqual(controller.card.frame.maxY, controller.view.bounds.maxY, accuracy: 1, "the card sits at the bottom")
    }

    func testChoosingTheFirstButtonAnswersZeroTheSecondAnswersOne() throws {
        let first = show(try message())
        let log = answers(of: first)
        tap(first.buttons[1])
        XCTAssertEqual(log.items, ["button 1"])
        let second = show(try message())
        let again = answers(of: second)
        tap(second.buttons[0])
        XCTAssertEqual(again.items, ["button 0"])
    }

    func testTheCloseMarkTheScrimAndTheEscapeGestureCloseItWithoutChoosingAndOnlyTheFirstAnswerCounts() throws {
        let a = show(try message())
        let one = answers(of: a)
        tap(a.closeButton)
        tap(a.buttons[0])
        XCTAssertEqual(one.items, ["dismissed"])
        let b = show(try message())
        let two = answers(of: b)
        b.scrimTapped()
        XCTAssertEqual(two.items, ["dismissed"])
        let c = show(try message())
        let three = answers(of: c)
        XCTAssertTrue(c.accessibilityPerformEscape())
        XCTAssertEqual(three.items, ["dismissed"])
    }

    func testTappingThePictureDoesWhatTheFirstButtonDoes() throws {
        let c = show(try message())
        let log = answers(of: c)
        c.mediaTapped()
        XCTAssertEqual(log.items, ["button 0"])
    }

    func testAnAnswerLeavesTheCardOnScreenForTheCallerToTakeAwayAndStopsAnyVideo() throws {
        let c = show(try message())
        _ = answers(of: c)
        c.finish(.dismissed)
        XCTAssertNotNil(c.card.superview, "the presenter removes the window; the view does not vanish by itself")
    }

    // MARK: a full screen

    func testAFullScreenShowsItsTextOverThePictureAndItsButtons() throws {
        let c = show(try message(layout: "full_screen"))
        let words = texts(in: c.view)
        XCTAssertTrue(words.contains("Fresh sweets"))
        XCTAssertTrue(words.contains("Order now"))
        XCTAssertEqual(c.mediaView?.frame.size, c.view.bounds.size, "the picture fills the screen")
        let log = answers(of: c)
        tap(c.closeButton)
        XCTAssertEqual(log.items, ["dismissed"])
    }

    func testAFullScreensButtonsAnswerLikeASheets() throws {
        let c = show(try message(layout: "full_screen"))
        let log = answers(of: c)
        tap(c.buttons[0])
        XCTAssertEqual(log.items, ["button 0"])
    }

    // MARK: accessibility

    func testTheBiggestTextSizeStillFitsInBothLayoutsOnASmallPhone() throws {
        let small = CGSize(width: 320, height: 568)
        let huge = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        for layout in ["bottom_sheet", "full_screen"] {
            let c = showWithTraits(try message(layout: layout), huge, size: small)
            XCTAssertGreaterThan(try XCTUnwrap(c.titleLabel.font).pointSize, 26 * 1.8, "\(layout): the headline grew")
            XCTAssertEqual(c.titleLabel.numberOfLines, 0, "\(layout): words wrap instead of being cut")
            XCTAssertTrue(c.buttons.allSatisfy { $0.label.numberOfLines == 0 && $0.label.font.pointSize > 16 })
            if layout == "bottom_sheet" {
                XCTAssertLessThanOrEqual(c.card.frame.height, small.height * 0.9 + 1, "the card never covers the whole screen")
            }
            XCTAssertTrue(c.buttons.allSatisfy { $0.bounds.height >= 48 })
            let scroll = try XCTUnwrap(c.view.firstScrollView())
            XCTAssertGreaterThanOrEqual(scroll.contentSize.height, scroll.bounds.height - 1, "\(layout): what does not fit scrolls")
        }
    }

    func testTextIsReadInOrderPictureHeadlineLineButtonsClose() throws {
        let c = show(try message())
        let order = try XCTUnwrap(c.view.accessibilityElements as? [NSObject])
        XCTAssertTrue(order.first === c.mediaView)
        XCTAssertTrue(order[1] === c.titleLabel)
        XCTAssertTrue(order[2] === c.bodyLabel)
        XCTAssertTrue(order.last === c.closeButton)
        XCTAssertTrue(c.view.accessibilityViewIsModal)
        XCTAssertTrue(c.titleLabel.accessibilityTraits.contains(.header))
        XCTAssertTrue(c.buttons.allSatisfy { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel != nil })
    }

    func testTheColoursFollowLightAndDarkMode() throws {
        let style = InAppStyle()
        let light = show(try message())
        light.overrideUserInterfaceStyle = .light
        light.view.layoutIfNeeded()
        XCTAssertEqual(color(light.card.backgroundColor, in: light), color(UIColor(style.surface), in: light))
        let dark = show(try message())
        dark.overrideUserInterfaceStyle = .dark
        dark.view.layoutIfNeeded()
        XCTAssertEqual(color(dark.card.backgroundColor, in: dark), color(UIColor(style.dark.surface), in: dark))
        XCTAssertEqual(color(dark.titleLabel.textColor, in: dark), color(UIColor(style.dark.text), in: dark))
        XCTAssertNotEqual(color(dark.card.backgroundColor, in: dark), color(light.card.backgroundColor, in: light))
    }

    func testTheAppsStyleIsUsedForTheMainButtonAndTheFont() throws {
        var style = InAppStyle(accent: InAppColor(hex: 0xC2185B), onAccent: .white, cornerRadius: 12, fontName: "Georgia")
        style.darkSurface = InAppColor(hex: 0x101010)
        let c = show(try message(), style: style)
        XCTAssertEqual(color(c.buttons[0].backgroundColor, in: c), [194, 24, 91])
        XCTAssertEqual(c.card.layer.cornerRadius, 12)
        XCTAssertTrue(c.titleLabel.font.fontName.lowercased().contains("georgia"))
        XCTAssertEqual(style.dark.surface, InAppColor(hex: 0x101010))
    }

    // MARK: pictures and video

    func testAPictureWithATransparentBackgroundStandsOutOfTheSheet() throws {
        let png = "{\"kind\":\"image\",\"url\":\"https://links.x.com/v1/media/m1/abc.png\",\"alt\":\"Sweets\",\"width\":800,\"height\":600}"
        let jpeg = "{\"kind\":\"image\",\"url\":\"https://links.x.com/v1/media/m1/abc.jpg\",\"alt\":\"Sweets\",\"width\":800,\"height\":600}"
        let pops = show(try message(media: png))
        XCTAssertNotNil(pops.popHeight)
        XCTAssertGreaterThan(pops.mediaView?.frame.height ?? 0, 100)
        XCTAssertLessThan(pops.mediaView?.convert(CGPoint.zero, to: pops.view).y ?? 1000, pops.card.frame.minY + 1,
                          "it rises above the card")
        let flat = show(try message(media: jpeg), images: pictureStore("https://links.x.com/v1/media/m1/abc.jpg"))
        XCTAssertNil(flat.popHeight)
        XCTAssertEqual(flat.mediaView?.frame.width ?? 0, flat.card.frame.width, accuracy: 1, "it fills the top of the card")
    }

    private func videoMessage() throws -> InAppMessage {
        let video = "{\"kind\":\"video\",\"url\":\"https://v.test/a.mp4\",\"alt\":\"Clip\",\"poster_url\":\"https://v.test/p.jpg\",\"duration_ms\":5000}"
        return try message(media: video)
    }

    func testAVideoFallsBackToItsPosterWhenMotionIsReduced() throws {
        let poster = "https://v.test/p.jpg"
        let c = show(try videoMessage(), reduceMotion: true, images: pictureStore(poster))
        XCTAssertFalse(try XCTUnwrap(c.mediaView).isPlayingVideo)
        XCTAssertNotNil(c.mediaView?.imageView.image, "the poster, not a player")
        XCTAssertFalse(c.mediaView?.layer.sublayers?.contains { $0 is AVPlayerLayer } ?? false)
        XCTAssertEqual(c.mediaView?.imageView.accessibilityLabel, "Clip")
    }

    func testAVideoThatCannotPlayKeepsItsPoster() async throws {
        let media = InAppMedia(isVideo: true, url: URL(fileURLWithPath: "/nonexistent/clip.mp4"), alt: "Clip",
                               posterUrl: URL(string: "https://v.test/p.jpg"))
        let m = InAppMessage(id: String(repeating: "a", count: 32), layout: .bottomSheet, title: "T", media: media)
        let c = show(m, images: pictureStore("https://v.test/p.jpg"))
        let view = try XCTUnwrap(c.mediaView)
        let end = Date().addingTimeInterval(10)
        while Date() < end, view.layer.sublayers?.contains(where: { $0 is AVPlayerLayer }) == true {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(view.isPlayingVideo)
        XCTAssertFalse(view.layer.sublayers?.contains { $0 is AVPlayerLayer } ?? false, "the player was taken away")
        XCTAssertNotNil(view.imageView.image)
    }

    // MARK: loading pictures and drawing

    func testAMessageWhosePictureCannotBeLoadedIsNotDrawn() async throws {
        let fails = UIKitInAppPresenter(images: InAppImageStore { _ in nil })
        let ok = await fails.loadPictures(for: try message())
        XCTAssertFalse(ok)
        let works = UIKitInAppPresenter(images: InAppImageStore { _ in
            UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        })
        let loaded = await works.loadPictures(for: try message())
        XCTAssertTrue(loaded)
    }

    func testAVideoWithoutAPosterIsNotDrawnAndAMessageWithoutMediaNeedsNoPicture() async throws {
        let presenter = UIKitInAppPresenter(images: InAppImageStore { _ in nil })
        let noPoster = InAppMessage(id: String(repeating: "a", count: 32), layout: .bottomSheet, title: "T",
                                    media: InAppMedia(isVideo: true, url: URL(string: "https://v.test/a.mp4")!, alt: "x"))
        let videoOk = await presenter.loadPictures(for: noPoster)
        XCTAssertFalse(videoOk)
        let plain = InAppMessage(id: String(repeating: "a", count: 32), layout: .bottomSheet, title: "T")
        let plainOk = await presenter.loadPictures(for: plain)
        XCTAssertTrue(plainOk)
    }

    func testAPictureIsCheckedForSizeAndKind() async throws {
        let big = InAppImageStore { _ in Data(count: InAppImageStore.maxBytes + 1) }
        let tooBig = await big.load(URL(string: "https://x.test/a.png")!)
        XCTAssertNil(tooBig)
        let junk = InAppImageStore { _ in Data("not a picture".utf8) }
        let notAPicture = await junk.load(URL(string: "https://x.test/a.png")!)
        XCTAssertNil(notAPicture)
    }

    func testNothingIsDrawnWhenThereIsNoActiveSceneToDrawOn() async throws {
        let presenter = UIKitInAppPresenter(images: pictureStore())
        let calm = await presenter.isCalm()
        guard !calm else { throw XCTSkip("this test host has an active scene, so there is no 'no scene' case to check") }
        let shown = Counter()
        let answer = await presenter.present(try message(), style: InAppStyle(), onShown: { shown.bump() }, onVideoEvent: { _ in })
        XCTAssertNil(answer)
        XCTAssertEqual(shown.value, 0, "shown is not reported for a message that was never drawn")
    }
}

private extension UIView {
    func firstScrollView() -> UIScrollView? {
        (self as? UIScrollView) ?? subviews.lazy.compactMap { $0.firstScrollView() }.first
    }
}
#endif
