import Foundation

/// A colour, made of red, green, blue and opacity between 0 and 1.
public struct InAppColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a number written in hex, for example `InAppColor(hex: 0x1F6B36)`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    public static let white = InAppColor(hex: 0xFFFFFF)
    public static let black = InAppColor(hex: 0x000000)
}

/// How messages look, so they match the app: colours, corner radius and font. The SDK decides the layout, spacing and accessibility.
public struct InAppStyle: Equatable, Sendable {
    /// The colour of the main button.
    public var accent = InAppColor(hex: 0x1F6B36)
    /// The colour of the words on the main button.
    public var onAccent = InAppColor.white
    /// The background of the card.
    public var surface = InAppColor.white
    /// The headline colour.
    public var text = InAppColor(hex: 0x17211A)
    /// The colour of the line under the headline.
    public var mutedText = InAppColor(hex: 0x4A544C)
    /// The dim layer behind a bottom sheet.
    public var scrim = InAppColor(hex: 0x000000, alpha: 0.6)
    /// How round the corners are, in points.
    public var cornerRadius = 28.0
    /// The font of the words (the app's own, by its PostScript name), or `nil` for the system font.
    public var fontName: String?
    /// Card and text colours used in dark mode; `nil` uses the SDK's dark colours.
    public var darkSurface: InAppColor?
    public var darkText: InAppColor?
    public var darkMutedText: InAppColor?

    public init(accent: InAppColor = InAppColor(hex: 0x1F6B36), onAccent: InAppColor = .white,
                surface: InAppColor = .white, text: InAppColor = InAppColor(hex: 0x17211A),
                mutedText: InAppColor = InAppColor(hex: 0x4A544C), scrim: InAppColor = InAppColor(hex: 0x000000, alpha: 0.6),
                cornerRadius: Double = 28, fontName: String? = nil) {
        self.accent = accent
        self.onAccent = onAccent
        self.surface = surface
        self.text = text
        self.mutedText = mutedText
        self.scrim = scrim
        self.cornerRadius = cornerRadius
        self.fontName = fontName
    }

    /// The version used in dark mode: the app's accent and radius with dark card and text colours.
    public var dark: InAppStyle {
        var out = self
        out.surface = darkSurface ?? InAppColor(hex: 0x1B211D)
        out.text = darkText ?? InAppColor(hex: 0xF2F5F2)
        out.mutedText = darkMutedText ?? InAppColor(hex: 0xB9C2BB)
        return out
    }
}
