#if canImport(UIKit) && !os(watchOS)
import UIKit

/// The two layouts, built with Auto Layout.
extension InAppMessageViewController {
    // MARK: Pieces both layouts use

    private func font(_ size: CGFloat, _ weight: UIFont.Weight, _ textStyle: UIFont.TextStyle) -> UIFont {
        let base = style.fontName.flatMap { UIFont(name: $0, size: size) } ?? UIFont.systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
    }

    /// The headline and the line under it.
    private func makeTextStack() -> UIStackView {
        titleLabel.text = message.title
        titleLabel.font = font(26, .heavy, .title1)
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        bodyLabel.text = message.body
        bodyLabel.font = font(16, .regular, .body)
        bodyLabel.numberOfLines = 0
        bodyLabel.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: message.body.isEmpty ? [titleLabel] : [titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }

    /// Up to two buttons: the first is filled, the second is plain words.
    private func makeButtonStack() -> UIStackView {
        buttons = message.buttons.enumerated().map { index, item in
            let button = InAppActionButton(title: item.label, minHeight: index == 0 ? 54 : 48)
            button.label.font = index == 0 ? font(18, .bold, .headline) : font(16, .semibold, .callout)
            button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            return button
        }
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .vertical
        stack.spacing = 6
        stack.isHidden = buttons.isEmpty
        return stack
    }

    private func makeCloseButton() -> InAppRoundButton {
        let button = InAppRoundButton(symbol: "xmark", label: "Close", circleColor: UIColor(white: 1, alpha: 0.9),
                                      tint: UIColor(red: 0.09, green: 0.13, blue: 0.10, alpha: 1))
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton = button
        return button
    }

    private func makeMedia(_ media: InAppMedia, fit: UIView.ContentMode) -> InAppMediaView {
        let media = InAppMediaView(media: media, images: images, fit: fit, reduceMotion: reduceMotion,
                                   onVideoEvent: { [weak self] in self?.onVideoEvent($0) })
        if message.mediaTapOpensFirstButton && message.primaryIndex != nil {
            media.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(mediaTapped)))
            media.imageView.accessibilityTraits = [.image, .button]
        }
        mediaView = media
        return media
    }

    /// The order VoiceOver reads in: the picture, the words, the buttons, then the close mark.
    private func setReadingOrder(_ extras: [Any]) {
        view.accessibilityElements = [mediaView, titleLabel, message.body.isEmpty ? nil : bodyLabel].compactMap { $0 }
            + buttons + [closeButton].compactMap { $0 } + extras
    }

    // MARK: Bottom sheet

    /// A card rising from the bottom. A PNG (a picture with a transparent background) stands up out of the card like a product on a
    /// shelf; any other picture or video fills the top of the card.
    func buildBottomSheet() {
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
        scrim.isAccessibilityElement = false
        let pops = message.media.map { !$0.isVideo && $0.url.path.lowercased().hasSuffix(".png") } ?? false
        let content = UIStackView()
        content.axis = .vertical
        if let media = message.media, !pops {
            let picture = makeMedia(media, fit: .scaleAspectFill)
            picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 1 / CGFloat(media.aspect)).isActive = true
            content.addArrangedSubview(picture)
        }
        let words = UIStackView(arrangedSubviews: [makeTextStack(), makeButtonStack()])
        words.axis = .vertical
        words.spacing = 18
        words.isLayoutMarginsRelativeArrangement = true
        words.layoutMargins = UIEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        sheetWords = words
        content.addArrangedSubview(words)
        if pops { addSpacer(to: content) }

        card.layer.cornerRadius = CGFloat(style.cornerRadius)
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.clipsToBounds = true
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        place(content, in: scroll, card: card)
        if pops, let media = message.media { addPop(media) }
        let close = makeCloseButton()
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)
        NSLayoutConstraint.activate([close.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                                     close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8)])
        setReadingOrder([])
    }

    /// Puts the stack in the scroll view, and the scroll view in the card. The card is as tall as its content, up to 90 percent of
    /// the screen; past that the content scrolls.
    private func place(_ content: UIStackView, in scroll: UIScrollView, card: UIView) {
        for item in [scrim, card] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        [scroll, content].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        card.addSubview(scroll)
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: view.topAnchor), scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor), scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor), card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            card.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.9),
            scroll.topAnchor.constraint(equalTo: card.topAnchor), scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
        let fit = scroll.heightAnchor.constraint(equalTo: content.heightAnchor)
        fit.priority = .defaultHigh
        fit.isActive = true
    }

    /// Space at the top of a card whose picture stands out of it.
    private func addSpacer(to content: UIStackView) {
        let spacer = UIView()
        let height = spacer.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        popSpacer = height
        content.insertArrangedSubview(spacer, at: 0)
    }

    private func addPop(_ media: InAppMedia) {
        let picture = makeMedia(media, fit: .scaleAspectFit)
        picture.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picture)
        let height = picture.heightAnchor.constraint(equalToConstant: 0)
        let bottom = picture.bottomAnchor.constraint(equalTo: card.topAnchor)
        popHeight = height
        popBottom = bottom
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 32),
            picture.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32),
            bottom, height,
        ])
    }

    /// Sizes the standing picture: as tall as the width allows, up to a third of the screen, rising 45 percent above the card.
    func updatePop() {
        guard let media = message.media, let height = popHeight, let spacer = popSpacer else { return }
        let picture = min((view.bounds.width - 64) / CGFloat(media.aspect), view.bounds.height * 0.34)
        let lift = picture * 0.45
        if height.constant != picture || spacer.constant != picture - lift + 8 {
            height.constant = picture
            spacer.constant = picture - lift + 8
            popBottom?.constant = picture - lift // the picture's bottom sits this far below the card's top
        }
    }

    // MARK: Full screen

    /// The picture or video fills the screen; the words and buttons sit over a dark fade at the bottom.
    func buildFullScreen() {
        view.backgroundColor = .black
        scrim.isHidden = true
        card.backgroundColor = .clear
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([card.topAnchor.constraint(equalTo: view.topAnchor),
                                     card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                     card.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        if let media = message.media {
            let picture = makeMedia(media, fit: .scaleAspectFill)
            pin(picture, to: card)
        }
        let fade = UIView()
        fade.isUserInteractionEnabled = false
        let layer = CAGradientLayer()
        layer.colors = [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.9).cgColor]
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        fade.layer.addSublayer(layer)
        gradient = layer
        pin(fade, to: card)

        let words = UIStackView(arrangedSubviews: [makeTextStack(), makeButtonStack()])
        words.axis = .vertical
        words.spacing = 18
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        [scroll, words].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        card.addSubview(scroll)
        scroll.addSubview(words)
        let close = makeCloseButton()
        close.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(close)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -20),
            scroll.topAnchor.constraint(greaterThanOrEqualTo: close.bottomAnchor),
            words.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            words.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            words.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            words.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
        let fit = scroll.heightAnchor.constraint(equalTo: words.heightAnchor)
        fit.priority = .defaultHigh
        fit.isActive = true
        setReadingOrder([])
    }

    private func pin(_ item: UIView, to parent: UIView) {
        item.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(item)
        NSLayoutConstraint.activate([item.topAnchor.constraint(equalTo: parent.topAnchor),
                                     item.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                                     item.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                                     item.trailingAnchor.constraint(equalTo: parent.trailingAnchor)])
    }
}
#endif
