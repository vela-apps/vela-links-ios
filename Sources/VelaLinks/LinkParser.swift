import Foundation

/// Extracts (slug, code) from `https://host/l/{slug}/{code}` or `scheme://l/{slug}/{code}`.
///
/// The `l` must be where Vela Links puts it (the first path segment of a web link, the host of a custom-scheme link), and the
/// values are checked against the characters Vela Links itself produces, so a crafted link such as `myapp://l/../admin` or
/// `https://x/foo/l/a/b` is ignored instead of reaching the service.
func parseLinkURL(_ url: URL) -> LinkAddress? {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let scheme = (parts.scheme ?? "").lowercased()
    let isWeb = scheme == "http" || scheme == "https"
    // Split before decoding, so an encoded slash cannot pass as a separator.
    let segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let rest: [String]
    if isWeb {
        guard segments.count == 3, segments[0] == "l" else { return nil }
        rest = Array(segments.dropFirst())
    } else {
        guard (parts.host ?? "").lowercased() == "l", segments.count == 2 else { return nil }
        rest = segments
    }
    guard let slug = rest[0].removingPercentEncoding, let code = rest[1].removingPercentEncoding else { return nil }
    return Check.slug(slug) && Check.linkCode(code) ? LinkAddress(slug: slug, code: code) : nil
}

/// True when the address carries `s=qr` (the link page adds it for QR scans). The last value wins.
func isQRScan(_ url: URL) -> Bool {
    guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
    return items.last(where: { $0.name == "s" })?.value == "qr"
}
