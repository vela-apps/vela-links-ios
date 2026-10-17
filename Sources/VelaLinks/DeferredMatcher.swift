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
        return await MainActor.run { () -> String? in
            let board = UIPasteboard.general
            guard board.hasStrings else { return nil }
            guard let text = board.string, text.hasPrefix(DeferredMatcher.iosPrefix) else { return nil }
            self.lock.lock()
            self.changeCountAtRead = board.changeCount
            self.lock.unlock()
            return text
        }
        #else
        return nil
        #endif
    }

    func clearToken(_ token: String) async {
        #if canImport(UIKit) && !os(watchOS)
        await MainActor.run {
            self.lock.lock()
            let seen = self.changeCountAtRead
            self.changeCountAtRead = nil
            self.lock.unlock()
            let board = UIPasteboard.general
            if let seen = seen, board.changeCount == seen { board.string = "" }
        }
        #endif
    }
}

/// Matches the first launch after install to the link tap that led to it (a deferred deep link). Runs until it succeeds, at most
/// three tries.
final class DeferredMatcher: @unchecked Sendable {
    /// The most failed launches before giving up. Each try reads the clipboard, which can show a paste notice.
    static let maxAttempts = 3
    /// What the link page puts on the iOS clipboard in front of the token.
    static let iosPrefix = "vlink:"

    private let api: LinksApi
    private let store: VelaLinksStorage
    private let source: InstallSource

    init(api: LinksApi, store: VelaLinksStorage, source: InstallSource) {
        self.api = api
        self.store = store
        self.source = source
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
            let token = DeferredMatcher.extractToken(await source.readToken())
            guard let answer = try await api.match(platform: "ios", token: token) else { return failed() }
            try store.setBool(true, forKey: StorageKeys.deferredChecked)
            // The token is used up whether or not it matched, so it is taken off the clipboard.
            if let token = token { await source.clearToken(token) }
            guard answer["matched"] as? Bool == true, let link = answer["link"] as? [String: Any] else { return nil }
            return VelaLink.tryParse(link, deferred: true)
        } catch {
            return failed() // matching must never break app start-up
        }
    }

    /// Counts a failed try; after `maxAttempts` the check is given up so the clipboard is not read launch after launch.
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
