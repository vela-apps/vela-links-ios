import XCTest
@testable import VelaLinks

final class LinkParserTests: XCTestCase {
    private func parse(_ s: String) -> LinkAddress? { URL(string: s).flatMap(parseLinkURL) }

    func testReadsHttpsAndCustomSchemeLinks() {
        XCTAssertEqual(parse("https://links.x.com/l/my-day/Ab3xK9q"), LinkAddress(slug: "my-day", code: "Ab3xK9q"))
        XCTAssertEqual(parse("myday://l/my-day/Ab3xK9q"), LinkAddress(slug: "my-day", code: "Ab3xK9q"))
        XCTAssertEqual(parse("https://my-day.links.x.com/l/my-day/abc?s=qr"), LinkAddress(slug: "my-day", code: "abc"))
    }

    func testIgnoresAddressesThatAreNotLinks() {
        XCTAssertNil(parse("https://links.x.com/other/path"))
        XCTAssertNil(parse("https://links.x.com/l/only-one"))
        XCTAssertNil(parse("myday://settings"))
    }

    func testRejectsValuesVelaLinksNeverProduces() {
        XCTAssertNil(parse("myday://l/../admin"))
        XCTAssertNil(parse("myday://l/my-day/ab%2F..%2Fx"))
        XCTAssertNil(parse("https://x.com/l/my-day/" + String(repeating: "a", count: 40)))
        XCTAssertNil(parse("https://x.com/l/-bad/abc"))
        XCTAssertNil(parse("https://x.com/l/my%20day/abc"))
        XCTAssertNil(parse("https://x.com/l/my-day/abc%0A"))
    }

    func testTheLMustBeWhereVelaLinksPutsIt() {
        XCTAssertNil(parse("https://x.com/foo/l/my-day/abc"))
        XCTAssertNil(parse("myapp://evil/l/my-day/abc"))
        XCTAssertNil(parse("https://x.com/l/my-day/abc/extra"))
        XCTAssertNil(parse("myapp://l/my-day/abc/extra"))
        XCTAssertEqual(parse("https://x.com/l/my-day/abc"), LinkAddress(slug: "my-day", code: "abc"))
    }

    func testQRMarker() {
        XCTAssertTrue(isQRScan(URL(string: "https://x.com/l/s/abc?s=qr")!))
        XCTAssertFalse(isQRScan(URL(string: "https://x.com/l/s/abc?s=share")!))
        XCTAssertFalse(isQRScan(URL(string: "https://x.com/l/s/abc")!))
    }

    func testParseThroughThePublicAPI() {
        XCTAssertEqual(VelaLinks.parse(url: URL(string: "myday://l/my-day/Ab3xK9q")!),
                       LinkAddress(slug: "my-day", code: "Ab3xK9q"))
        XCTAssertNil(VelaLinks.parse(url: URL(string: "https://links.x.com/other/path")!))
    }
}
