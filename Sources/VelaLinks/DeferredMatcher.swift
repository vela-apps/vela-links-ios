import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Where the install token comes from. Replaceable in tests.
protocol InstallSource: AnyObject, Sendable {
    /// The raw text the clipboard holds for this install, or `nil` if there is none. Only text that looks like ours is ever used.
    func readToken() async -> String?
    /// Removes the token once it has been used, so it does not stay on the clipboard. Does nothing when the clipboard was
    /// changed since it was read.
    func clearToken(_ token: String) async
}

/// Reads the real clipboard.
///
/// `hasStrings` is asked first because it never shows iOS's paste notice, so a clipboard without text is never read. The text is
/// read once per try. To clear the token the clipboard is not read a second time: it is cleared only when its change count is
/// still the one seen when the token was read, which means nobody copied anything in between.
final class ClipboardInstallSource: InstallSource, @unchecked Sendable {
    private let lock = NSLock()
    private var changeCountAtRead: Int?

    func readToken() async -> String? {
        #if canImport(UIKit) && !os(watchOS)
        // Read away from the main thread: from iOS 16 reading text copied in another app shows a system "Allow Paste" question,
        // and the reading thread waits for the answer. On the main thread that would freeze the whole app.
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let board = UIPasteboard.general
                guard board.hasStrings, let text = board.string, text.hasPrefix(DeferredMatcher.iosPrefix) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.lock.lock()
                self.changeCountAtRead = board.changeCount
                self.lock.unlock()
                continuation.resume(returning: text)
            }
        }
        #else
        return nil
        #endif
    }

    func clearToken(_ token: String) async {
        #if canImport(UIKit) && !os(watchOS)
        let seen: Int? = lock.sync {
            let value = changeCountAtRead
            changeCountAtRead = nil
            return value
        }
        let board = UIPasteboard.general
        if let seen = seen, board.changeCount == seen { board.string = "" }
        #endif
    }
}

/// Matches the first launch after install to the link tap that led to it (a deferred deep link). Runs until it succeeds, at most
/// three tries.
final class DeferredMatcher: @unchecked Sendable {
    /// The most failed launches before giving up.
    static let maxAttempts = 3
    /// What the link page puts on the iOS clipboard in front of the token.
    static let iosPrefix = "vlink:"

    private let api: LinksApi
    private let store: VelaLinksStorage
    private let source: InstallSource
    private let readClipboard: Bool
    private let signals: @Sendable () async -> [String: Any]
    private let installId: @Sendable () -> String?

    /// `readClipboard` is off by default: links on iPhone go straight to the App Store and no token is copied, so reading would only
    /// show iOS's paste notice. `signals` gives the plain device facts sent with the match (see ``DeviceSignals``), and `installId`
    /// this install's id, so the service remembers which install claimed the tap.
    init(api: LinksApi, store: VelaLinksStorage, source: InstallSource, readClipboard: Bool = false,
         signals: @escaping @Sendable () async -> [String: Any] = DeviceSignals.read,
         installId: @escaping @Sendable () -> String? = { nil }) {
        self.api = api
        self.store = store
        self.source = source
        self.readClipboard = readClipboard
        self.signals = signals
        self.installId = installId
    }

    /// Picks our token out of what the clipboard holds, and nothing else. Returns `nil` when there is none.
    static func extractToken(_ raw: String?) -> String? {
        guard let raw = raw, raw.hasPrefix(iosPrefix) else { return nil }
        return Check.token(String(raw.dropFirst(iosPrefix.count))) ? raw : nil
    }

    /// Returns the matched link, or `nil` (no match, already checked, or a failure that will be retried next launch).
    func run() async -> VelaLink? {
        do {
            if try store.bool(forKey: StorageKeys.deferredChecked) ?? false { return nil }
        } catch {
            return nil
        }
        do {
            let token = readClipboard ? DeferredMatcher.extractToken(await source.readToken()) : nil
            guard let answer = try await api.match(platform: "ios", token: token, signals: await signals(), iid: installId()) else {
                return failed()
            }
            try store.setBool(true, forKey: StorageKeys.deferredChecked)
            // The token is used up whether or not it matched, so it is taken off the clipboard.
            if let token = token { await source.clearToken(token) }
            guard answer["matched"] as? Bool == true, var link = answer["link"] as? [String: Any] else { return nil }
            // newer servers send the click's id and its utm values (a `utm` object) beside the link (`method` may be "signals")
            if link["click_id"] == nil, let click = answer["click_id"] { link["click_id"] = click }
            if let utm = answer["utm"] as? [String: Any] {
                for key in VelaLink.utmKeys where link[key] == nil { if let value = utm[key] { link[key] = value } }
            }
            return VelaLink.tryParse(link, deferred: true)
        } catch {
            return failed() // matching must never break app start-up
        }
    }

    /// Counts a failed try; after `maxAttempts` the check is given up.
    private func failed() -> VelaLink? {
        do {
            let attempts = (try store.int(forKey: StorageKeys.deferredAttempts) ?? 0) + 1
            try store.setInt(attempts, forKey: StorageKeys.deferredAttempts)
            if attempts >= DeferredMatcher.maxAttempts { try store.setBool(true, forKey: StorageKeys.deferredChecked) }
        } catch {
            // storage trouble: try again next launch
        }
        return nil
    }
}

/// Plain facts about the phone that the link page also sees, sent with the first-launch match so the service can tell two taps from
/// the same network apart, under the service's names: `screen_width` and `screen_height` (points, portrait: the short side is the
/// width), `pixel_ratio` (`UIScreen.scale`), `timezone` (IANA), `language` (BCP-47, such as `en-IN`) and `os_version`. None of them
/// identifies a person or a device on its own; a value that cannot be read is left out.
enum DeviceSignals {
    @Sendable static func read() async -> [String: Any] {
        var out: [String: Any] = [:]
        #if canImport(UIKit) && !os(watchOS)
        let facts: (CGSize, CGFloat, String) = await MainActor.run {
            (UIScreen.main.bounds.size, UIScreen.main.scale, UIDevice.current.systemVersion)
        }
        let (a, b) = (Double(facts.0.width), Double(facts.0.height))
        if a > 0, b > 0, a < 10_000, b < 10_000 {
            out["screen_width"] = min(a, b)
            out["screen_height"] = max(a, b)
        }
        if facts.1 > 0, facts.1 < 10 { out["pixel_ratio"] = Double(facts.1) }
        if !facts.2.isEmpty, facts.2.count <= 20 { out["os_version"] = facts.2 }
        #endif
        let zone = TimeZone.current.identifier
        if !zone.isEmpty, zone.count <= 64 { out["timezone"] = zone }
        if let lang = Locale.preferredLanguages.first, !lang.isEmpty, lang.count <= 35 { out["language"] = lang }
        return out
    }
}
