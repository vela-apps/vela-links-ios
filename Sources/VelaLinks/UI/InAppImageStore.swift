#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Loads and keeps the pictures of messages (and the posters of videos). A picture is loaded before its message is drawn, so a
/// message whose picture does not arrive is not shown at all.
final class InAppImageStore: @unchecked Sendable {
    /// Pictures are at most 2 MB on the service; anything much bigger is not a picture of ours.
    static let maxBytes = 4 * 1024 * 1024

    private let cache = NSCache<NSURL, UIImage>()
    private let fetch: (URL) async -> Data?

    /// `fetch` is for tests; the default loads over the network with a short time limit and no redirects.
    init(timeout: TimeInterval = 5, fetch: ((URL) async -> Data?)? = nil) {
        self.fetch = fetch ?? { await InAppImageStore.download($0, timeout: timeout) }
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func insert(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }

    /// The picture at `url`, or `nil` when it cannot be loaded or is not a picture.
    func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        guard let data = await fetch(url), data.count <= InAppImageStore.maxBytes, let image = UIImage(data: data) else {
            return nil
        }
        insert(image, for: url)
        return image
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func download(_ url: URL, timeout: TimeInterval) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { continuation in
            session.dataTask(with: url) { data, response, _ in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                continuation.resume(returning: ok ? data : nil)
            }.resume()
        }
    }
}
#endif
