import Foundation

/// What the service says is switched on for this app (`GET /v1/sdk/config`), and which events and screens a live message waits for.
struct InAppConfig {
    let enabled: Bool
    /// Event names a live message waits for; `nil` when the service does not name them (an older service).
    let triggerEvents: [String]?
    /// Screen name prefixes a live message waits for; `nil` when the service does not name them.
    let triggerScreens: [String]?

    init(_ json: [String: Any]) {
        let inapp = json["inapp"] as? [String: Any]
        enabled = inapp?["enabled"] as? Bool == true
        triggerEvents = InAppConfig.list(inapp?["trigger_events"])
        triggerScreens = InAppConfig.list(inapp?["trigger_screens"])
    }

    private static func list(_ any: Any?) -> [String]? { (any as? [Any])?.compactMap { $0 as? String } }

    /// A service that does not name its moments is asked at every event, within the usual limit on how often.
    func waits(forEvent name: String) -> Bool { triggerEvents?.contains(name) ?? true }

    func waits(forScreen name: String) -> Bool { triggerScreens?.contains { name.hasPrefix($0) } ?? true }
}
