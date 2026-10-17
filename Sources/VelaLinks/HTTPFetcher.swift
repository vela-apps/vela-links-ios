import Foundation

/// Runs one HTTP request at a time through a private `URLSession`: no redirects, a total time limit, a 1 MB cap on the answer
/// (also when it arrives in chunks), no cookies and no cache. Every failure comes out as a ``VelaLinksError``.
final class HTTPFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxResponseBytes = 1024 * 1024

    private final class State {
        var data = Data()
        var status = 0
        var continuation: CheckedContinuation<(Int, Data), Error>?
        var timeout: DispatchWorkItem?
    }

    private var session: URLSession?
    private let lock = NSLock()
    private var states: [Int: State] = [:]

    /// `configuration` is for tests (a `URLProtocol` that fakes the network); the default is a locked-down ephemeral one.
    init(configuration: URLSessionConfiguration? = nil) {
        super.init()
        let config = configuration ?? HTTPFetcher.defaultConfiguration()
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return config
    }

    /// Lets running requests finish, then releases the session.
    func invalidate() { session?.finishTasksAndInvalidate() }

    func fetch(_ request: URLRequest, timeout: TimeInterval) async throws -> (status: Int, data: Data) {
        var request = request
        request.timeoutInterval = timeout
        let started: (Int, Data) = try await withCheckedThrowingContinuation { continuation in
            guard let session = session else {
                continuation.resume(throwing: VelaLinksError("The Vela Links client is closed", kind: .network))
                return
            }
            let task = session.dataTask(with: request)
            let state = State()
            state.continuation = continuation
            let item = DispatchWorkItem { [weak self, weak task] in
                guard let self = self, let task = task else { return }
                self.fail(task, VelaLinksError("The Vela Links service did not answer in time", kind: .timeout))
            }
            state.timeout = item
            lock.lock()
            states[task.taskIdentifier] = state
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
            task.resume()
        }
        return (started.0, started.1)
    }

    private func finish(_ task: URLSessionTask, with result: Result<(Int, Data), Error>) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state = state, let continuation = state.continuation else { return }
        state.timeout?.cancel()
        state.continuation = nil
        continuation.resume(with: result)
    }

    private func fail(_ task: URLSessionTask, _ error: VelaLinksError) {
        finish(task, with: .failure(error))
        task.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let state = states[dataTask.taskIdentifier]
        state?.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.unlock()
        if response.expectedContentLength > Int64(HTTPFetcher.maxResponseBytes) {
            fail(dataTask, VelaLinksError("The Vela Links service sent too much data", kind: .badResponse))
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let state = states[dataTask.taskIdentifier]
        state?.data.append(data)
        let size = state?.data.count ?? 0
        lock.unlock()
        if size > HTTPFetcher.maxResponseBytes {
            fail(dataTask, VelaLinksError("The Vela Links service sent too much data", kind: .badResponse))
        }
    }

    /// Redirects are never followed: a redirect could carry the SDK key to another host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states[task.taskIdentifier]
        let result: (Int, Data)? = state.map { ($0.status, $0.data) }
        lock.unlock()
        guard result != nil, let status = result?.0, let data = result?.1 else { return }
        if let error = error {
            // Never include the system's text: it can contain the request address. The kind is enough.
            let code = (error as? URLError)?.code
            let text = code == .timedOut ? "The Vela Links service did not answer in time"
                : "Could not reach the Vela Links service"
            finish(task, with: .failure(VelaLinksError(text, kind: code == .timedOut ? .timeout : .network)))
        } else {
            finish(task, with: .success((status, data)))
        }
    }
}
