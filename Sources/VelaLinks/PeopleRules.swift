import Foundation

/// What may be sent about a person, checked on the phone before anything leaves it. The service checks again; this keeps obvious
/// mistakes (a phone number typed as a property, a name, an email) from ever being sent.
enum PeopleRules {
    /// The most properties one person can have.
    static let maxUserProperties = 20

    /// The channels a person can agree to be contacted on.
    static let consentChannels: Set<String> = ["push", "whatsapp", "sms", "email", "inapp"]
    /// The two reasons a message is sent: `marketing` (offers, nudges) or `service` (what the person asked for).
    static let consentPurposes: Set<String> = ["marketing", "service"]
    /// Where an answer was given, as far as the phone can tell.
    static let consentSources: Set<String> = ["app_prompt", "settings_toggle"]
    /// Where a push token comes from.
    static let pushProviders: Set<String> = ["fcm", "apns"]

    /// Property names that name something personal or sensitive are never sent, whatever the value is.
    private static let denied = [
        "phone", "mobile", "email", "mail", "name", "address", "dob", "birth", "aadhaar", "aadhar", "pan", "passport",
        "password", "otp", "card", "account_no", "ifsc", "upi", "religion", "caste", "health", "disease", "salary",
        "income", "balance", "lat", "lon", "gps",
    ]

    /// `^[a-z][a-z0-9_]{0,29}$`, and not a name that sounds personal.
    static func allowedPropertyName(_ key: String) -> Bool {
        let plain = Check.matches(key, length: 1...30, first: { $0 >= 97 && $0 <= 122 }) {
            ($0 >= 97 && $0 <= 122) || Check.isDigit($0) || $0 == 95
        }
        return plain && !denied.contains { key.contains($0) }
    }

    /// The properties that may be sent: allowed names with short plain values. A `null` value means "remove this property".
    /// Anything else is dropped, never sent. At most 20 are kept (in name order, so the same input keeps the same ones).
    static func cleanUserProperties(_ raw: [String: Any?]) -> [String: JSONScalar] {
        var out: [String: JSONScalar] = [:]
        for key in raw.keys.sorted() {
            if out.count >= maxUserProperties { break }
            guard allowedPropertyName(key), let value = cleanValue(raw[key] ?? nil) else { continue }
            out[key] = value
        }
        return out
    }

    /// A plain value: yes/no, a number below a billion, or a short text that does not look like an email or a phone number.
    /// Whole numbers always come out as integers, so `3` and `3.0` count as the same value.
    static func cleanValue(_ any: Any?) -> JSONScalar? {
        guard let scalar = JSONScalar.from(any as Any) else { return nil }
        switch scalar {
        case .null, .bool: return scalar
        case .int(let i): return abs(i) < 1_000_000_000 ? scalar : nil
        case .double(let d):
            guard abs(d) < 1e9 else { return nil }
            return d == d.rounded() ? .int(Int64(d)) : scalar
        case .string(let s):
            let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.unicodeScalars.count <= 60, !looksLikeEmail(text), !hasLongNumber(text) else {
                return nil
            }
            return .string(text)
        }
    }

    /// `\S+@\S+`: an `@` with something that is not a space on both sides.
    static func looksLikeEmail(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for (i, s) in scalars.enumerated() where s == "@" {
            let before = i > 0 && !isSpace(scalars[i - 1])
            let after = i + 1 < scalars.count && !isSpace(scalars[i + 1])
            if before && after { return true }
        }
        return false
    }

    /// `\d[\d\s().\-_]{7,}\d`: nine or more characters from a digit to a digit, made of digits, spaces and phone-number marks.
    static func hasLongNumber(_ text: String) -> Bool {
        var first: Int?
        var last = 0
        var index = 0
        func ends() -> Bool { first.map { last - $0 + 1 >= 9 } ?? false }
        for s in text.unicodeScalars {
            if isDigitScalar(s) {
                if first == nil { first = index }
                last = index
            } else if !(isSpace(s) || "().-_".unicodeScalars.contains(s)) {
                if ends() { return true }
                first = nil
            }
            index += 1
        }
        return ends()
    }

    private static func isSpace(_ s: Unicode.Scalar) -> Bool { s.properties.isWhitespace }
    private static func isDigitScalar(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }

    /// `^[a-z]{2,3}([-_][A-Za-z0-9]{2,8})?$`: a language code the service accepts (`te`, `hi-IN`), with `_` turned into `-`.
    static func cleanLocale(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let bytes = Array(value.utf8)
        func lower(_ b: UInt8) -> Bool { b >= 97 && b <= 122 }
        var language = 0
        while language < bytes.count, lower(bytes[language]) { language += 1 }
        guard (2...3).contains(language) else { return nil }
        if language == bytes.count { return value }
        let rest = bytes[(language + 1)...]
        guard bytes[language] == 45 || bytes[language] == 95, (2...8).contains(rest.count),
              rest.allSatisfy(Check.isAlnum) else { return nil }
        return value.replacingOccurrences(of: "_", with: "-")
    }

    /// `^[A-Za-z0-9._-]{1,20}$`: a version label for the privacy notice the person saw.
    static func validPolicyVersion(_ value: String) -> Bool {
        Check.matches(value, length: 1...20) { Check.isAlnum($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    /// A push token the service accepts: 20 to 4096 characters, no spaces. Returns the trimmed token, or `nil`.
    static func cleanPushToken(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = token.unicodeScalars.count
        guard count >= 20, count <= 4096, !token.unicodeScalars.contains(where: isSpace) else { return nil }
        return token
    }

    /// A signed identity token the service accepts: 1 to 1000 characters, no spaces. Returns the trimmed token, or `nil`.
    static func cleanIdentityToken(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.unicodeScalars.count <= 1000, !token.unicodeScalars.contains(where: isSpace) else {
            return nil
        }
        return token
    }
}
