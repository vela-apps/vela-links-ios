import Foundation
import XCTest
@testable import VelaLinks

/// A clock the tests move by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_792_238_400)) { current = start } // 2026-10-17 12:00 UTC
    var date: Date { lock.sync { current } }
    func advance(_ seconds: TimeInterval) { lock.sync { current = current.addingTimeInterval(seconds) } }
    var ms: Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}

struct StorageFailure: Error {}

/// Storage in memory. `failing` makes every call throw, to test the "storage is broken" path.
final class MemoryStorage: VelaLinksStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    var failing = false

    private func get(_ key: String) throws -> Any? {
        try lock.sync {
            if failing { throw StorageFailure() }
            return values[key]
        }
    }
    private func put(_ value: Any?, _ key: String) throws {
        try lock.sync {
            if failing { throw StorageFailure() }
            values[key] = value
        }
    }
    func string(forKey key: String) throws -> String? { try get(key) as? String }
    func setString(_ value: String, forKey key: String) throws { try put(value, key) }
    func bool(forKey key: String) throws -> Bool? { try get(key) as? Bool }
    func setBool(_ value: Bool, forKey key: String) throws { try put(value, key) }
    func int(forKey key: String) throws -> Int? { try get(key) as? Int }
    func setInt(_ value: Int, forKey key: String) throws { try put(value, key) }
    func strings(forKey key: String) throws -> [String]? { try get(key) as? [String] }
    func setStrings(_ value: [String], forKey key: String) throws { try put(value, key) }
    func remove(forKey key: String) throws { try put(nil, key) }
    func contains(_ key: String) throws -> Bool { try get(key) != nil }
}

struct Captured {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data

    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    var path: String { url.path }
    func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

enum FakeReply {
    case reply(Int, String)
    case chunks(Int, [Data])
    case fail(Error)
    case hang
    case redirect(String)
}

/// Fakes the network under a real `URLSession`: no sockets are opened.
final class FakeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((Captured) -> FakeReply)?
    nonisolated(unsafe) static var requests: [Captured] = []
    private static let lock = NSLock()
    private var cancelled = false

    static func reset(_ handler: ((Captured) -> FakeReply)?) {
        lock.sync {
            self.handler = handler
            requests = []
        }
    }
    static var seen: [Captured] { lock.sync { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { cancelled = true }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k] = v }
        let captured = Captured(url: request.url ?? URL(fileURLWithPath: "/"), method: request.httpMethod ?? "",
                                headers: headers, body: body)
        let handler = FakeURLProtocol.lock.sync { () -> ((Captured) -> FakeReply)? in
            FakeURLProtocol.requests.append(captured)
            return FakeURLProtocol.handler
        }
        guard let url = request.url, let reply = handler?(captured) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch reply {
        case .hang:
            return
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .reply(let status, let text):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .chunks(let status, let chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks where !cancelled { client?.urlProtocol(self, didLoad: chunk) }
            if !cancelled { client?.urlProtocolDidFinishLoading(self) }
        case .redirect(let location):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": location])!
            if let target = URL(string: location) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

func makeFetcher() -> HTTPFetcher {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeURLProtocol.self]
    return HTTPFetcher(configuration: config)
}

func makeApi(base: String = "https://links.x.com", timeout: TimeInterval = 2, appId: (() -> String?)? = nil,
             key: String = "vl_key") throws -> LinksApi {
    try LinksApi(apiKey: key, baseUrl: base, fetcher: makeFetcher(), timeout: timeout, appId: appId)
}

/// A fake events endpoint: records the batches it accepts.
final class EventServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: Int
    private var _batches: [[String: Any]] = []
    private var _hits = 0
    init(_ status: Int = 202) { _status = status }
    var status: Int {
        get { lock.sync { _status } }
        set { lock.sync { _status = newValue } }
    }
    var batches: [[String: Any]] { lock.sync { _batches } }
    var hits: Int { lock.sync { _hits } }

    var names: [String] {
        batches.flatMap { ($0["events"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
    }

    func reply(_ request: Captured) -> FakeReply {
        guard request.path == "/v1/events" else { return .reply(404, "{}") }
        let code = lock.sync { () -> Int in
            _hits += 1
            return _status
        }
        if code >= 500 || code == 429 { return .reply(code, "{}") }
        if let json = request.json { lock.sync { _batches.append(json) } }
        return .reply(code, "{\"accepted\":1,\"rejected\":0}")
    }

    func install() { FakeURLProtocol.reset { [self] in reply($0) } }
}

/// Polls until `condition` holds (or fails after a few seconds).
func eventually(_ message: String = "condition", timeout: TimeInterval = 5, file: StaticString = #filePath,
                line: UInt = #line, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("timed out waiting for \(message)", file: file, line: line)
}

func expectThrows<T>(_ message: String = "", file: StaticString = #filePath, line: UInt = #line,
                     _ body: () async throws -> T) async -> VelaLinksError? {
    do {
        _ = try await body()
        XCTFail("expected an error \(message)", file: file, line: line)
        return nil
    } catch let error as VelaLinksError {
        return error
    } catch {
        XCTFail("expected a VelaLinksError, got \(error)", file: file, line: line)
        return nil
    }
}

let linkJSON = "{\"code\":\"abc\",\"route\":\"/x\",\"params\":{}}"

final class FakeInstallSource: InstallSource, @unchecked Sendable {
    let raw: String?
    private let lock = NSLock()
    private var _reads = 0
    private var _cleared: [String] = []
    init(_ raw: String?) { self.raw = raw }
    var reads: Int { lock.sync { _reads } }
    var cleared: [String] { lock.sync { _cleared } }
    func readToken() async -> String? {
        lock.sync { _reads += 1 }
        return raw
    }
    func clearToken(_ token: String) async { lock.sync { _cleared.append(token) } }
}
