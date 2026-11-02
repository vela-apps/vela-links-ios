import Foundation
import XCTest
@testable import VelaLinks

/// A fake service for the people, event and in-app endpoints: records what it was sent and answers with a chosen status.
final class FakeService: @unchecked Sendable {
    struct Call {
        let path: String
        let method: String
        let json: [String: Any]
        let query: [String: String]
        let headers: [String: String]
        let accepted: Bool
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _status = 202
    private var _body = "{}"
    private var _config: String
    private var _configStatus = 200
    private var _message: String = "{\"message\":null}"
    private var _messageStatus = 200

    init(inapp: String = "{\"enabled\":false}") { _config = "{\"schema\":1,\"inapp\":\(inapp)}" }

    var status: Int {
        get { lock.sync { _status } }
        set { lock.sync { _status = newValue } }
    }
    var body: String {
        get { lock.sync { _body } }
        set { lock.sync { _body = newValue } }
    }
    var configStatus: Int {
        get { lock.sync { _configStatus } }
        set { lock.sync { _configStatus = newValue } }
    }
    /// What `/v1/inapp/messages` answers with: a message object, or `nil` for none.
    func serve(message: String?) { lock.sync { _message = "{\"message\":\(message ?? "null")}" } }
    func serve(inapp: String) { lock.sync { _config = "{\"schema\":1,\"inapp\":\(inapp)}" } }
    var messageStatus: Int {
        get { lock.sync { _messageStatus } }
        set { lock.sync { _messageStatus = newValue } }
    }

    var calls: [Call] { lock.sync { _calls } }
    func to(_ path: String) -> [[String: Any]] { calls.filter { $0.path == path }.map { $0.json } }
    func count(_ path: String) -> Int { calls.filter { $0.path == path }.count }
    func headers(of path: String) -> [[String: String]] { calls.filter { $0.path == path }.map { $0.headers } }
    func queries(of path: String) -> [[String: String]] { calls.filter { $0.path == path }.map { $0.query } }
    /// The reports the service accepted, in the order they arrived.
    func actions() -> [String] {
        calls.filter { $0.path == "/v1/inapp/events" && $0.accepted }.compactMap { $0.json["action"] as? String }
    }

    func install() { FakeURLProtocol.reset { [self] in reply($0) } }

    private func reply(_ request: Captured) -> FakeReply {
        var query: [String: String] = [:]
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { query[$0.name] = $0.value }
        var headers: [String: String] = [:]
        request.headers.forEach { headers[$0.key] = $0.value }
        let (status, body, config, configStatus, message, messageStatus) = lock.sync { () -> (Int, String, String, Int, String, Int) in
            _calls.append(Call(path: request.path, method: request.method, json: request.json ?? [:], query: query,
                               headers: headers, accepted: _status < 300))
            return (_status, _body, _config, _configStatus, _message, _messageStatus)
        }
        switch request.path {
        case "/v1/sdk/config": return .reply(configStatus, config)
        case "/v1/inapp/messages": return .reply(messageStatus, message)
        default: return .reply(status, body)
        }
    }
}

/// A fake that stands in for the screen: it records what it was asked to draw and answers as the test says.
final class FakePresenter: InAppPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calm = true
    private var _picturesLoad = true
    private var _answer: InAppAnswer? = .button(0)
    private var _presented: [InAppMessage] = []
    private var _videoEvents: [String] = []
    private var _cancelled = 0
    private var hold: CheckedContinuation<Void, Never>?
    private var _holding = false

    var calm: Bool {
        get { lock.sync { _calm } }
        set { lock.sync { _calm = newValue } }
    }
    var picturesLoad: Bool {
        get { lock.sync { _picturesLoad } }
        set { lock.sync { _picturesLoad = newValue } }
    }
    var answer: InAppAnswer? {
        get { lock.sync { _answer } }
        set { lock.sync { _answer = newValue } }
    }
    /// Events a video would report while the message is on the screen.
    var videoEvents: [String] {
        get { lock.sync { _videoEvents } }
        set { lock.sync { _videoEvents = newValue } }
    }
    var presented: [InAppMessage] { lock.sync { _presented } }
    var cancelled: Int { lock.sync { _cancelled } }
    /// While true, `present` stays on the screen until `release()`.
    var holding: Bool {
        get { lock.sync { _holding } }
        set { lock.sync { _holding = newValue } }
    }

    func release() {
        let waiting = lock.sync { () -> CheckedContinuation<Void, Never>? in
            let c = hold
            hold = nil
            return c
        }
        waiting?.resume()
    }

    /// Answers for the next calls to `isCalm`, one each; after they run out `calm` answers.
    var calmAnswers: [Bool] {
        get { lock.sync { _calmAnswers } }
        set { lock.sync { _calmAnswers = newValue } }
    }
    private var _calmAnswers: [Bool] = []

    func isCalm() async -> Bool {
        lock.sync { _calmAnswers.isEmpty ? _calm : _calmAnswers.removeFirst() }
    }
    func loadPictures(for message: InAppMessage) async -> Bool { picturesLoad }
    func cancel() async { lock.sync { _cancelled += 1 } }

    func present(_ message: InAppMessage, style: InAppStyle, onShown: @escaping @Sendable () -> Void,
                 onVideoEvent: @escaping @Sendable (String) -> Void) async -> InAppAnswer? {
        lock.sync { _presented.append(message) }
        onShown()
        videoEvents.forEach(onVideoEvent)
        if holding { await withCheckedContinuation { c in lock.sync { hold = c } } }
        return answer
    }
}

/// The service's answer for one message.
func messageJSON(layout: String = "bottom_sheet", media: String? = nil, buttons: String? = nil, schema: Int = 1,
                 purpose: String = "marketing", title: String = "Fresh sweets") -> String {
    let defaultMedia = "{\"kind\":\"image\",\"url\":\"https://links.x.com/v1/media/m1/abc.png\",\"alt\":\"Sweets\"," +
        "\"width\":800,\"height\":600,\"poster_url\":null}"
    let defaultButtons = "[{\"label\":\"Order now\",\"action\":\"route\",\"route\":\"/fresh\",\"params\":{\"slug\":\"gpn\"}}," +
        "{\"label\":\"Not now\",\"action\":\"dismiss\"}]"
    return "{\"schema\":\(schema),\"id\":\"\(String(repeating: "a", count: 32))\",\"layout\":\"\(layout)\"," +
        "\"purpose\":\"\(purpose)\",\"title\":\"\(title)\",\"body\":\"Order today\"," +
        "\"media\":\(media ?? defaultMedia),\"media_action\":\"primary\",\"buttons\":\(buttons ?? defaultButtons)}"
}

func makeStore() -> MemoryStorage { MemoryStorage() }
