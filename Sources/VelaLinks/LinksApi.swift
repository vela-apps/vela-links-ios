import Foundation

/// The only code that talks to the Vela Links API. It adds the API key, applies a time limit, refuses redirects, and turns every
/// failure into a ``VelaLinksError`` (or `nil` for "not found"), so callers never deal with raw network errors.
final class LinksApi: @unchecked Sendable {
    let apiKey: String
    let baseUrl: String
    let timeout: TimeInterval
    private let fetcher: HTTPFetcher
    private let appId: (() -> String?)?

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "10.0.2.2"]

    /// `baseUrl` must be https (http only for a local development server).
    init(apiKey: String, baseUrl: String, fetcher: HTTPFetcher, timeout: TimeInterval = 10,
         appId: (() -> String?)? = nil) throws {
        self.apiKey = apiKey
        self.baseUrl = try LinksApi.normaliseBaseUrl(baseUrl)
        self.fetcher = fetcher
        self.timeout = timeout
        self.appId = appId
    }

    /// Accepts `https://host` (a trailing slash is dropped). Plain http is only allowed for a local development server, so a
    /// mistake can never send the API key over an unencrypted connection in a real build.
    static func normaliseBaseUrl(_ raw: String) throws -> String {
        let reason = "baseUrl must be a plain https:// address (http:// only for localhost), with no user name, query or #"
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && loopbackHosts.contains(host))
        else { throw VelaLinksError(reason, kind: .invalidArgument) }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let port = parts.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(path)"
    }

    private func headers() -> [String: String] {
        var out = ["X-Api-Key": apiKey, "Content-Type": "application/json"]
        // the id is an extra check; never block the app because it could not be read
        if let id = appId?(), !id.isEmpty { out["X-App-Id"] = id }
        return out
    }

    /// One call to the service. A `signed` call carries the key and app id; the public link lookup carries neither.
    private func call(_ method: String, _ path: String, json: Any? = nil, signed: Bool = true) async throws
        -> (status: Int, data: Data) {
        guard let url = URL(string: baseUrl + path) else {
            throw VelaLinksError("The request address is not valid", kind: .invalidArgument)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if signed { headers().forEach { request.setValue($1, forHTTPHeaderField: $0) } }
        if let json = json {
            guard JSONSerialization.isValidJSONObject(json),
                  let body = try? JSONSerialization.data(withJSONObject: json)
            else {
                throw VelaLinksError("params must only contain values that can be written as JSON",
                                     kind: .invalidArgument)
            }
            request.httpBody = body
        }
        let (status, data) = try await fetcher.fetch(request, timeout: timeout)
        if status >= 300 && status < 400 {
            throw VelaLinksError("The Vela Links service answered with an unexpected redirect", statusCode: status,
                                 kind: .redirect)
        }
        return (status, data)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Creates a link and returns its short URL.
    func createLink(_ body: [String: Any]) async throws -> String {
        let (status, data) = try await call("POST", "/v1/links", json: body)
        guard status == 201 else {
            throw VelaLinksError(LinksApi.detail(status, data), statusCode: status, kind: .server)
        }
        guard let url = LinksApi.object(data)?["url"] as? String, !url.isEmpty else {
            throw VelaLinksError("The Vela Links service sent an unexpected answer", kind: .badResponse)
        }
        return url
    }

    /// Looks a link up. Returns `nil` when it does not exist, has expired, or the answer cannot be read.
    func resolve(slug: String, code: String) async throws -> VelaLink? {
        let (status, data) = try await call("GET", "/v1/links/\(LinksApi.encode(slug))/\(LinksApi.encode(code))",
                                            signed: false)
        guard status == 200, let object = LinksApi.object(data) else { return nil }
        return VelaLink.tryParse(object)
    }

    /// First-launch matching. Returns the parsed answer, or `nil` when the service could not give one (try again next launch).
    func match(platform: String, token: String?) async throws -> [String: Any]? {
        var body: [String: Any] = ["platform": platform]
        if let token = token { body["token"] = token }
        let (status, data) = try await call("POST", "/v1/match", json: body)
        return status == 200 ? LinksApi.object(data) : nil
    }

    /// Sends one batch of in-app events. `.retry` means try again later (no network, busy, a server problem, a refused key);
    /// `.drop` means the service will never accept this batch.
    func sendEvents(_ body: [String: Any]) async -> EventSendResult {
        do {
            let (status, _) = try await call("POST", "/v1/events", json: body)
            if status == 202 || status == 200 { return .sent }
            let retryable = [401, 403, 408, 429].contains(status) || status >= 500
            return retryable ? .retry : .drop
        } catch let error as VelaLinksError where error.kind == .invalidArgument {
            return .drop // a batch that cannot be written as JSON can never be sent
        } catch {
            return .retry
        }
    }

    /// Tells the service the app was opened by this link. Never throws: analytics must not affect the app.
    func reportOpen(code: String, source: String) async {
        _ = try? await call("POST", "/v1/open", json: ["code": code, "source": source])
    }

    private static func detail(_ status: Int, _ data: Data) -> String {
        if let text = object(data)?["detail"] as? String, text.count <= 300 { return text }
        return "Request failed (\(status))"
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
