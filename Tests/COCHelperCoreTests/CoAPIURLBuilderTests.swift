import Foundation
import XCTest
@testable import COCHelperCore

final class CoAPIURLBuilderTests: XCTestCase {
    func testTagHashEncodedInPath() {
        let url = CoAPIURLBuilder.endpoint(config: CoAPIConfig(), path: "/players/%23ABC")
        XCTAssertFalse(url.path.contains("#"), "path 不应含裸 #：\(url.path)")
        XCTAssertTrue(url.path.contains("%23ABC"), "path 应含 %23ABC：\(url.path)")
    }

    func testEncodePathComponentConvertsHash() {
        XCTAssertEqual(CoAPIURLBuilder.encodePathComponent("#ABC"), "%23ABC")
    }

    func testEncodePathComponentRoundTrip() {
        let encoded = "/v1/players/" + CoAPIURLBuilder.encodePathComponent("#ABC")
        XCTAssertEqual(encoded.removingPercentEncoding, "/v1/players/#ABC")
    }

    func testEncodePathComponentKeepsSafeChars() {
        XCTAssertEqual(CoAPIURLBuilder.encodePathComponent("ABC123"), "ABC123")
    }

    func testURLHostAndVersion() {
        let url = CoAPIURLBuilder.endpoint(config: CoAPIConfig(), path: "/players/%23ABC")
        XCTAssertEqual(url.host, "api.clashofclans.com")
        XCTAssertTrue(url.path.hasPrefix("/v1/"), "path 应以 /v1/ 开头：\(url.path)")
    }

    func testPathWithoutHashUnaffected() {
        let url = CoAPIURLBuilder.endpoint(config: CoAPIConfig(), path: "/locations")
        XCTAssertEqual(url.path, "/v1/locations")
    }
}
