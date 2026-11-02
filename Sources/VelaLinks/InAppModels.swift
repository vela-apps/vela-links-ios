import Foundation

/// How a message is laid out.
public enum InAppLayout: String, Sendable {
    /// A card rising from the bottom, with the app still visible behind it.
    case bottomSheet = "bottom_sheet"
    /// The picture or video fills the screen; the text and buttons sit over it.
    case fullScreen = "full_screen"

    /// The name the service uses.
    public var wire: String { rawValue }

    /// The layout for a service name, or `nil` for one this version of the SDK cannot draw (that message is then not shown).
    static func fromWire(_ value: Any?) -> InAppLayout? { (value as? String).flatMap(InAppLayout.init(rawValue:)) }
}

/// The picture or video of a message.
public struct InAppMedia: Equatable, Sendable {
    /// True for a short video, false for a picture.
    public let isVideo: Bool
    /// Where the file is.
    public let url: URL
    /// A description for people who cannot see it (read aloud by VoiceOver).
    public let alt: String
    /// The picture's size in pixels, when known.
    public let width: Int?
    public let height: Int?
    /// How long the video is, in seconds.
    public let duration: TimeInterval?
    /// The picture shown first, and instead of the video when it cannot play.
    public let posterUrl: URL?

    public init(isVideo: Bool, url: URL, alt: String, width: Int? = nil, height: Int? = nil, duration: TimeInterval? = nil,
                posterUrl: URL? = nil) {
        self.isVideo = isVideo
        self.url = url
        self.alt = alt
        self.width = width
        self.height = height
        self.duration = duration
        self.posterUrl = posterUrl
    }

    /// The width divided by the height, kept within a range that looks right.
    public var aspect: Double {
        guard let w = width, let h = height, w > 0, h > 0 else { return 4.0 / 3.0 }
        return min(max(Double(w) / Double(h), 0.6), 2.0)
    }
}

/// One button of a message.
public struct InAppButton: @unchecked Sendable {
    /// The words on the button.
    public let label: String
    /// The page of the app it opens, or `nil` for a button that only closes the message.
    public let route: String?
    /// The values that go with ``route`` (text, numbers and booleans, from the service).
    public let params: [String: Any]

    public init(label: String, route: String? = nil, params: [String: Any] = [:]) {
        self.label = label
        self.route = route
        self.params = params
    }

    /// True for a button that just closes the message.
    public var dismisses: Bool { route == nil }
}

/// A message to show: what to say, with what picture, and what the buttons do. Made from the service's answer; anything the SDK
/// does not understand (a layout it cannot draw, an address that is not https) means there is no message.
public struct InAppMessage: Sendable {
    /// The message's id.
    public let id: String
    /// How it is laid out.
    public let layout: InAppLayout
    /// The headline.
    public let title: String
    /// The line under the headline (may be empty).
    public let body: String
    /// The picture or video, or `nil`.
    public let media: InAppMedia?
    /// Up to two buttons.
    public let buttons: [InAppButton]
    /// True for an offer or a nudge, false for a message about something the person asked for.
    public let marketing: Bool
    /// Whether tapping the picture does what the first button does.
    public let mediaTapOpensFirstButton: Bool

    public init(id: String, layout: InAppLayout, title: String, body: String = "", media: InAppMedia? = nil,
                buttons: [InAppButton] = [], marketing: Bool = true, mediaTapOpensFirstButton: Bool = true) {
        self.id = id
        self.layout = layout
        self.title = title
        self.body = body
        self.media = media
        self.buttons = Array(buttons.prefix(2))
        self.marketing = marketing
        self.mediaTapOpensFirstButton = mediaTapOpensFirstButton
    }

    /// Index of the first button that opens a page, if any.
    public var primaryIndex: Int? { buttons.firstIndex { !$0.dismisses } }
}

/// What the person did with a message.
enum InAppAnswer: Equatable {
    /// They chose a button (0 or 1).
    case button(Int)
    /// They closed it without choosing.
    case dismissed
}

// MARK: Reading the service's answer

extension InAppMessage {
    /// Reads the service's answer. Returns `nil` for anything that is not a message this SDK can show.
    static func tryParse(_ raw: Any?, allowUrl: (URL) -> Bool) -> InAppMessage? {
        guard let json = raw as? [String: Any], int(json["schema"]) == 1,
              let layout = InAppLayout.fromWire(json["layout"]),
              let id = json["id"] as? String, let title = json["title"] as? String, !title.isEmpty else { return nil }
        var media: InAppMedia?
        if let rawMedia = json["media"], !(rawMedia is NSNull) {
            guard let parsed = parseMedia(rawMedia, allowUrl) else { return nil } // a picture that cannot be trusted
            media = parsed
        }
        if layout == .fullScreen && media == nil { return nil }
        guard let buttons = parseButtons(json["buttons"]) else { return nil }
        return InAppMessage(id: id, layout: layout, title: title, body: json["body"] as? String ?? "", media: media,
                            buttons: buttons, marketing: json["purpose"] as? String != "service",
                            mediaTapOpensFirstButton: json["media_action"] as? String != "none")
    }

    private static func int(_ any: Any?) -> Int? {
        guard let any = any, case .int(let value)? = JSONScalar.from(any) else { return nil }
        return Int(truncatingIfNeeded: value)
    }

    private static func parseMedia(_ raw: Any, _ allowUrl: (URL) -> Bool) -> InAppMedia? {
        guard let json = raw as? [String: Any], let text = json["url"] as? String, let url = URL(string: text),
              allowUrl(url), let alt = json["alt"] as? String else { return nil }
        var poster: URL?
        if let rawPoster = json["poster_url"], !(rawPoster is NSNull) {
            guard let posterText = rawPoster as? String, let posterUrl = URL(string: posterText), allowUrl(posterUrl) else {
                return nil
            }
            poster = posterUrl
        }
        return InAppMedia(isVideo: json["kind"] as? String == "video", url: url, alt: alt, width: int(json["width"]),
                          height: int(json["height"]), duration: int(json["duration_ms"]).map { Double($0) / 1000 },
                          posterUrl: poster)
    }

    private static func parseButtons(_ raw: Any?) -> [InAppButton]? {
        guard let raw = raw, !(raw is NSNull) else { return [] }
        guard let list = raw as? [Any] else { return nil }
        var out: [InAppButton] = []
        for item in list {
            guard let b = item as? [String: Any], let label = b["label"] as? String else { continue }
            var params: [String: Any] = [:]
            if let rawParams = b["params"], !(rawParams is NSNull) {
                guard let dict = rawParams as? [String: Any] else { return nil }
                params = dict
            }
            let route = b["action"] as? String == "route" ? b["route"] as? String : nil
            out.append(InAppButton(label: label, route: route, params: params))
        }
        return Array(out.prefix(2))
    }
}
