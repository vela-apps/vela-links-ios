import Foundation

/// Where the SDK keeps its small amount of state. The real one is ``UserDefaultsStorage``; tests use memory.
/// Methods may throw: a storage error switches event tracking off for the session instead of reaching the app.
protocol VelaLinksStorage: AnyObject, Sendable {
    func string(forKey key: String) throws -> String?
    func setString(_ value: String, forKey key: String) throws
    func bool(forKey key: String) throws -> Bool?
    func setBool(_ value: Bool, forKey key: String) throws
    func int(forKey key: String) throws -> Int?
    func setInt(_ value: Int, forKey key: String) throws
    func strings(forKey key: String) throws -> [String]?
    func setStrings(_ value: [String], forKey key: String) throws
    func remove(forKey key: String) throws
    func contains(_ key: String) throws -> Bool
}

/// Storage keys, all with the `vela_links.` prefix.
enum StorageKeys {
    static let iid = "vela_links.iid"
    static let queue = "vela_links.queue"
    static let firstLink = "vela_links.first_link"
    static let lastLink = "vela_links.last_link"
    static let optedOut = "vela_links.opted_out"
    static let firstOpenSent = "vela_links.first_open_sent"
    static let lastActive = "vela_links.last_active"
    static let userId = "vela_links.user_id"
    static let onceDone = "vela_links.once_done"
    static let deferredChecked = "vela_links.deferred_checked"
    static let deferredAttempts = "vela_links.deferred_attempts"
}

/// Keeps the state in a `UserDefaults` (the standard one, or a suite of your choice).
final class UserDefaultsStorage: VelaLinksStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults) { self.defaults = defaults }

    func string(forKey key: String) throws -> String? { defaults.string(forKey: key) }
    func setString(_ value: String, forKey key: String) throws { defaults.set(value, forKey: key) }
    func bool(forKey key: String) throws -> Bool? { (defaults.object(forKey: key) as? NSNumber)?.boolValue }
    func setBool(_ value: Bool, forKey key: String) throws { defaults.set(value, forKey: key) }
    func int(forKey key: String) throws -> Int? { (defaults.object(forKey: key) as? NSNumber)?.intValue }
    func setInt(_ value: Int, forKey key: String) throws { defaults.set(value, forKey: key) }
    func strings(forKey key: String) throws -> [String]? { defaults.stringArray(forKey: key) }
    func setStrings(_ value: [String], forKey key: String) throws { defaults.set(value, forKey: key) }
    func remove(forKey key: String) throws { defaults.removeObject(forKey: key) }
    func contains(_ key: String) throws -> Bool { defaults.object(forKey: key) != nil }
}
