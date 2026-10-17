import Foundation

/// A link that opened the app (directly, or after install through deferred matching).
///
/// Treat every field as untrusted input, like any deep link: check ``route`` against the screens you allow before you
/// navigate, and never put secrets in ``params``.
public struct VelaLink {
    /// The short code of the link (the last part of its address).
    public let code: String
    /// The in-app destination you chose when creating the link, for example `/invite`.
    public let route: String
    /// The values you attached when creating the link, for example `["id": "42"]`.
    public let params: [String: Any]
    /// The link's title, if one was set.
    public let title: String?
    /// The campaign name, if one was set.
    public let campaign: String?
    /// True when the link was matched on the first launch after install.
    public let deferred: Bool

    public init(code: String, route: String, params: [String: Any] = [:], title: String? = nil,
                campaign: String? = nil, deferred: Bool = false) {
        self.code = code
        self.route = route
        self.params = params
        self.title = title
        self.campaign = campaign
        self.deferred = deferred
    }

    /// Reads a link from the service's JSON. Returns `nil` instead of failing when the data is not a valid link.
    static func tryParse(_ json: [String: Any], deferred: Bool = false) -> VelaLink? {
        guard let code = json["code"] as? String, let route = json["route"] as? String else { return nil }
        var params: [String: Any] = [:]
        if let raw = json["params"], !(raw is NSNull) {
            guard let dict = raw as? [String: Any] else { return nil }
            params = dict
        }
        func optionalText(_ key: String) -> (ok: Bool, value: String?) {
            guard let raw = json[key], !(raw is NSNull) else { return (true, nil) }
            guard let text = raw as? String else { return (false, nil) }
            return (true, text)
        }
        let title = optionalText("title")
        let campaign = optionalText("campaign")
        guard title.ok, campaign.ok else { return nil }
        return VelaLink(code: code, route: route, params: params, title: title.value, campaign: campaign.value,
                        deferred: deferred)
    }
}

// The params come from JSON (strings, numbers, booleans, arrays and dictionaries of those), so the value is safe to pass around.
extension VelaLink: @unchecked Sendable {}

extension VelaLink: CustomStringConvertible {
    public var description: String { "VelaLink(\(route), \(params), deferred: \(deferred))" }
}

/// What the SDK throws when a call to the Vela Links service fails, or when an argument is not acceptable.
public struct VelaLinksError: Error, LocalizedError, CustomStringConvertible {
    /// The kind of failure.
    public enum Kind: Sendable {
        /// An argument is not acceptable (an empty key, an insecure base URL, params that are not JSON).
        case invalidArgument
        /// The service could not be reached.
        case network
        /// The service did not answer in time.
        case timeout
        /// The service answered with an error status.
        case server
        /// The service answered with something the SDK cannot read, or too much data.
        case badResponse
        /// The service answered with a redirect, which is never followed.
        case redirect
    }

    /// What went wrong, in a short sentence. It never contains the SDK key.
    public let message: String
    /// The HTTP status, when the service answered.
    public let statusCode: Int?
    /// The kind of failure.
    public let kind: Kind

    public init(_ message: String, statusCode: Int? = nil, kind: Kind = .server) {
        self.message = message
        self.statusCode = statusCode
        self.kind = kind
    }

    public var errorDescription: String? { message }
    public var description: String { "VelaLinksError(\(statusCode.map(String.init) ?? "-")): \(message)" }
}

/// A link's address: which app (slug) and which link (code).
public struct LinkAddress: Equatable, Sendable {
    public let slug: String
    public let code: String
}

/// What happened to a batch of events that was sent.
enum EventSendResult: Equatable {
    case sent
    case retry
    case drop
}

/// The events the SDK reports by itself, and the names it keeps for itself.
public enum EventNames {
    /// The first time the app is opened after install.
    public static let firstOpen = "first_open"
    /// A new visit: the app opened after being away for more than 30 minutes.
    public static let sessionStart = "session_start"
    /// A screen was shown.
    public static let screenView = "screen_view"
    /// A purchase, with an amount.
    public static let purchase = "purchase"
}
