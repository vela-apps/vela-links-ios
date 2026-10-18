import Foundation

/// Hand-written checks that behave exactly like the anchored patterns the service uses. (Regular expressions in Foundation let
/// `$` match before a trailing newline, so they are avoided here.)
enum Check {
    static func isLetter(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }
    static func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
    static func isAlnum(_ b: UInt8) -> Bool { isLetter(b) || isDigit(b) }
    static func isHex(_ b: UInt8) -> Bool { isDigit(b) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102) }

    static func matches(_ text: String, length: ClosedRange<Int>, first: ((UInt8) -> Bool)? = nil,
                        rest: (UInt8) -> Bool) -> Bool {
        let bytes = Array(text.utf8)
        guard length.contains(bytes.count), let head = bytes.first else { return false }
        if let first = first, !first(head) { return false }
        return bytes.allSatisfy(rest) // `first` is a subset of `rest` in every pattern used here
    }

    /// `^[A-Za-z][A-Za-z0-9_]{1,39}$`
    static func eventName(_ s: String) -> Bool {
        matches(s, length: 2...40, first: isLetter) { isAlnum($0) || $0 == 95 }
    }

    /// `^[A-Za-z][A-Za-z0-9_]{0,29}$`
    static func propertyKey(_ s: String) -> Bool {
        matches(s, length: 1...30, first: isLetter) { isAlnum($0) || $0 == 95 }
    }

    /// `^[A-Za-z]{3}$`
    static func currency(_ s: String) -> Bool { matches(s, length: 3...3, rest: isLetter) }

    /// `^[A-Za-z0-9_.:\-]{1,64}$`
    static func orderId(_ s: String) -> Bool {
        matches(s, length: 1...64) { isAlnum($0) || $0 == 95 || $0 == 46 || $0 == 58 || $0 == 45 }
    }

    /// `^[A-Fa-f0-9]{8,40}$`
    static func eventId(_ s: String) -> Bool { matches(s, length: 8...40, rest: isHex) }

    /// `^[A-Za-z0-9][A-Za-z0-9-]{0,39}$`
    static func slug(_ s: String) -> Bool {
        matches(s, length: 1...40, first: isAlnum) { isAlnum($0) || $0 == 45 }
    }

    /// `^[A-Za-z0-9]{1,16}$`
    static func linkCode(_ s: String) -> Bool { matches(s, length: 1...16, rest: isAlnum) }

    /// `^[A-Za-z0-9]{6,32}$`
    static func token(_ s: String) -> Bool { matches(s, length: 6...32, rest: isAlnum) }

    /// `^[\x21-\x7E]{1,100}$`
    static func userId(_ s: String) -> Bool { matches(s, length: 1...100) { $0 >= 0x21 && $0 <= 0x7E } }

    /// Keeps only letters, digits and `. _ + -`, at most 20 characters; `nil` when nothing is left.
    static func cleanVersion(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let kept = raw.unicodeScalars.filter { s in
            s.isASCII && (isAlnum(UInt8(s.value)) || s == "." || s == "_" || s == "+" || s == "-")
        }
        let text = String(String.UnicodeScalarView(kept.prefix(20)))
        return text.isEmpty ? nil : text
    }

    /// The first `scalars` Unicode scalars of `text` (the service counts characters that way, not as grapheme clusters).
    static func truncated(_ text: String, scalars: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(scalars)))
    }

    static func randomHex(_ length: Int) -> String {
        let digits = Array("0123456789abcdef")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in digits[Int.random(in: 0..<16, using: &generator)] })
    }
}
