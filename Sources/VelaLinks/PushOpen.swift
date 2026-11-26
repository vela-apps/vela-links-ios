import Foundation

/// What a Vela push carried, handed back by ``VelaLinks/trackPushOpen(_:messageId:)`` so the app can open the right page.
public struct VelaPushOpen: CustomStringConvertible, @unchecked Sendable {
    /// The campaign the push belongs to (`vela_campaign`), or `nil` when it has none.
    public let campaign: String?
    /// The app page to open (`vela_route`, for example `/offers`), or `nil` when the push opens no particular page.
    public let route: String?
    /// The page's fixed values (`vela_params`), empty when there are none.
    public let params: [String: Any]

    public var description: String { "VelaPushOpen(campaign: \(campaign ?? "nil"), route: \(route ?? "nil"), params: \(params))" }
}

/// Reads a push's data and remembers which pushes were already counted, so a push handed over twice (a cold start and the
/// notification-response delegate, or Firebase's `getInitialMessage` and `onMessageOpenedApp`) is counted once in this process.
///
/// A push is known by its `vela_send_id` (one per push sent, added by the service) when the data has one; otherwise by the message id
/// the push service gave it; and when there is neither, the same campaign opened again within ``window`` counts once, so a later push of
/// the same campaign is still counted.
final class PushOpenReader: @unchecked Sendable {
    static let event = "push_open"
    private static let remember = 100
    private static let messageIdKeys = ["gcm.message_id", "google.message_id", "message_id"]
    /// How long an open of a campaign with no send id and no message id hides another open of the same campaign (10 minutes).
    static let window: TimeInterval = 600

    private let lock = NSLock()
    private let now: () -> Date
    private var seen: [(key: String, at: Date)] = []

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// `true` the first time this push is seen in this process, `false` for a repeat. `sendId` wins over `messageId`; with neither,
    /// a repeat is an open of the same `campaign` within ``window``.
    func firstTime(campaign: String, messageId: String?, sendId: String? = nil) -> Bool {
        let at = now()
        return lock.sync {
            let key: String
            if let sendId = sendId, !sendId.isEmpty {
                key = "send|\(sendId)"
            } else if let messageId = messageId, !messageId.isEmpty {
                key = "msg|\(campaign)|\(messageId)"
            } else {
                key = "campaign|\(campaign)"
                if let last = seen.first(where: { $0.key == key }), at.timeIntervalSince(last.at) >= 0,
                   at.timeIntervalSince(last.at) < PushOpenReader.window {
                    return false
                }
                seen.removeAll { $0.key == key } // re-added below as the newest
            }
            if seen.contains(where: { $0.key == key }) { return false }
            seen.append((key, at))
            if seen.count > PushOpenReader.remember { seen.removeFirst(seen.count - PushOpenReader.remember) }
            return true
        }
    }

    /// The id the service gave this one push (`vela_send_id`), or `nil` when the data has none (an older service).
    static func sendId(_ data: [AnyHashable: Any]?) -> String? {
        guard let data = data else { return nil }
        return text(data["vela_send_id"])
    }

    /// The Vela keys of a push's data, or `nil` when the push did not come from Vela.
    static func read(_ data: [AnyHashable: Any]?) -> VelaPushOpen? {
        guard let data = data else { return nil }
        let campaign = text(data["vela_campaign"])
        let route = text(data["vela_route"])
        if campaign == nil && route == nil { return nil }
        return VelaPushOpen(campaign: campaign, route: route, params: params(data["vela_params"]))
    }

    /// The id Firebase gave the message (`gcm.message_id` in the notification's `userInfo`), when there is one.
    static func messageId(_ data: [AnyHashable: Any]?) -> String? {
        guard let data = data else { return nil }
        for key in messageIdKeys { if let value = text(data[key]) { return value } }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value, !(value is NSNull) else { return nil }
        let raw = (value as? String) ?? "\(value)"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func params(_ raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        guard let text = raw as? String, let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object // values that are not JSON are ignored; the page still opens
    }
}
