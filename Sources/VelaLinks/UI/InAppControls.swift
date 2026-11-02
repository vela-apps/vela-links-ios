#if canImport(UIKit) && !os(watchOS)
import UIKit

/// A button made of a label that wraps, so a long word list or the biggest Dynamic Type size makes it taller instead of cutting
/// the words (a plain `UIButton` does not size multi-line titles well). Rounded like a pill.
final class InAppActionButton: UIControl {
    let label = UILabel()

    init(title: String, minHeight: CGFloat) {
        super.init(frame: .zero)
        label.text = title
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, 28)
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }
}

/// A round mark on the corner of a message that closes it: a 48 point target around a 36 point circle.
final class InAppRoundButton: UIControl {
    private let circle = UIView()
    private let icon = UIImageView()

    init(symbol: String, label: String, circleColor: UIColor, tint: UIColor) {
        super.init(frame: .zero)
        circle.backgroundColor = circleColor
        circle.layer.cornerRadius = 18
        circle.isUserInteractionEnabled = false
        circle.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = tint
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(circle)
        circle.addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 48), heightAnchor.constraint(equalToConstant: 48),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor), circle.centerYAnchor.constraint(equalTo: centerYAnchor),
            circle.widthAnchor.constraint(equalToConstant: 36), circle.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor), icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Swaps the mark and the words VoiceOver reads (the sound button changes with the sound).
    func update(symbol: String, label: String) {
        icon.image = UIImage(systemName: symbol)
        accessibilityLabel = label
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }
}
#endif
