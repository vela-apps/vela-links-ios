import Foundation

/// The phone's language, read from its first preferred language (for example `te-IN` or `zh-Hans-CN`).
enum DeviceLanguage {
    private static var first: [Substring] {
        (Locale.preferredLanguages.first ?? "en").split(whereSeparator: { $0 == "-" || $0 == "_" })
    }

    /// The language only, such as `te`. Messages are chosen by it.
    static func code() -> String { first.first.map { $0.lowercased() } ?? "en" }

    /// The language with the region when there is one, such as `hi-IN`, in the form the service accepts; `nil` if unusual.
    static func locale() -> String? {
        let parts = first
        guard let language = parts.first?.lowercased() else { return nil }
        let region = parts.dropFirst().last.map(String.init).flatMap { $0.count == 2 ? $0.uppercased() : nil }
        return PeopleRules.cleanLocale(region.map { "\(language)-\($0)" } ?? language)
    }
}
