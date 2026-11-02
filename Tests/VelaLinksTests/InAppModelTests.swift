import XCTest
@testable import VelaLinks

/// Reading the service's answer: anything the SDK cannot draw or trust means no message.
final class InAppModelTests: XCTestCase {
    private func parse(_ json: String) -> InAppMessage? {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        return InAppMessage.tryParse(object) { $0.scheme == "https" }
    }

    func testAGoodMessageIsUnderstood() throws {
        let m = try XCTUnwrap(parse(messageJSON()))
        XCTAssertEqual(m.title, "Fresh sweets")
        XCTAssertEqual(m.body, "Order today")
        XCTAssertEqual(m.layout, .bottomSheet)
        XCTAssertTrue(m.marketing)
        XCTAssertEqual(m.buttons.map { $0.label }, ["Order now", "Not now"])
        XCTAssertEqual(m.buttons[0].route, "/fresh")
        XCTAssertEqual(m.buttons[0].params["slug"] as? String, "gpn")
        XCTAssertTrue(m.buttons[1].dismisses)
        XCTAssertEqual(try XCTUnwrap(m.media).aspect, 4.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(m.primaryIndex, 0)
        XCTAssertEqual(m.media?.alt, "Sweets")
    }

    func testAnythingThisSDKCannotDrawOrTrustMeansNoMessage() {
        let http = "{\"kind\":\"image\",\"url\":\"http://evil.test/x.png\",\"alt\":\"x\"}"
        let noAlt = "{\"kind\":\"image\",\"url\":\"https://ok.test/x.png\"}"
        let badPoster = "{\"kind\":\"video\",\"url\":\"https://ok.test/x.mp4\",\"alt\":\"x\",\"poster_url\":\"http://evil.test/p.png\"}"
        let cases: [(String, String?)] = [
            ("null", nil), ("\"text\"", nil), ("unknown schema", messageJSON(schema: 2)),
            ("unknown layout", messageJSON(layout: "carousel")), ("an http picture", messageJSON(media: http)),
            ("a picture without a description", messageJSON(media: noAlt)), ("a poster that is not https", messageJSON(media: badPoster)),
            ("an empty title", messageJSON(title: "")), ("a full screen without media", messageJSON(layout: "full_screen", media: "null")),
        ]
        for (name, json) in cases {
            XCTAssertNil(parse(json ?? name), name)
        }
    }

    func testAtMostTwoButtonsAreKeptAndAServiceMessageIsNotMarketing() throws {
        let three = "[{\"label\":\"b0\",\"action\":\"dismiss\"},{\"label\":\"b1\",\"action\":\"dismiss\"},{\"label\":\"b2\",\"action\":\"dismiss\"}]"
        XCTAssertEqual(try XCTUnwrap(parse(messageJSON(buttons: three))).buttons.count, 2)
        XCTAssertFalse(try XCTUnwrap(parse(messageJSON(purpose: "service"))).marketing)
    }

    func testAMessageWithoutMediaOrButtonsIsFine() throws {
        let m = try XCTUnwrap(parse(messageJSON(media: "null", buttons: "[]")))
        XCTAssertNil(m.media)
        XCTAssertTrue(m.buttons.isEmpty)
        XCTAssertNil(m.primaryIndex)
    }

    func testAVideoKeepsItsPosterAndDuration() throws {
        let video = "{\"kind\":\"video\",\"url\":\"https://v.test/a.mp4\",\"alt\":\"Clip\",\"poster_url\":\"https://v.test/p.jpg\",\"duration_ms\":5000}"
        let media = try XCTUnwrap(parse(messageJSON(media: video))?.media)
        XCTAssertTrue(media.isVideo)
        XCTAssertEqual(media.posterUrl?.absoluteString, "https://v.test/p.jpg")
        XCTAssertEqual(media.duration, 5)
    }

    func testWrongShapesInsideAMessageDoNotCrashAndTheMessageIsRefused() {
        XCTAssertNil(parse(messageJSON(buttons: "{\"a\":1}")))
        XCTAssertNil(parse(messageJSON(buttons: "[{\"label\":\"x\",\"action\":\"route\",\"route\":\"/a\",\"params\":[1]}]")))
        XCTAssertNil(parse("{\"schema\":true,\"id\":\"x\"}"))
    }

    func testTheAspectStaysInARangeThatLooksRight() {
        let url = URL(string: "https://x.test/a.png")!
        XCTAssertEqual(InAppMedia(isVideo: false, url: url, alt: "", width: 100, height: 1000).aspect, 0.6)
        XCTAssertEqual(InAppMedia(isVideo: false, url: url, alt: "", width: 1000, height: 100).aspect, 2.0)
        XCTAssertEqual(InAppMedia(isVideo: false, url: url, alt: "").aspect, 4.0 / 3.0, accuracy: 0.001)
    }

    func testTheConfigNamesTheMomentsAMessageWaitsFor() throws {
        func config(_ json: String) throws -> InAppConfig {
            InAppConfig(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]))
        }
        let named = try config("{\"inapp\":{\"enabled\":true,\"trigger_events\":[\"add_to_cart\"],\"trigger_screens\":[\"/fresh\"]}}")
        XCTAssertTrue(named.enabled)
        XCTAssertTrue(named.waits(forEvent: "add_to_cart"))
        XCTAssertFalse(named.waits(forEvent: "login"))
        XCTAssertTrue(named.waits(forScreen: "/fresh/checkout"))
        XCTAssertFalse(named.waits(forScreen: "/home"))
        let old = try config("{\"inapp\":{\"enabled\":true}}")
        XCTAssertTrue(old.waits(forEvent: "anything"))
        XCTAssertFalse(try config("{}").enabled)
    }
}
