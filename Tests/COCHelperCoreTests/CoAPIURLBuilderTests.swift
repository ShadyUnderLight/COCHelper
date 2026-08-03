import Foundation
import XCTest
@testable import COCHelperCore

final class CoAPIURLBuilderTests: XCTestCase {
    func testTagHashEncodedInPath() {
        let url = CoAPIURLBuilder.endpoint(config: CoAPIConfig(), path: "/players/#ABC")
        XCTAssertEqual(url.path(percentEncoded: true), "/v1/players/%23ABC", "原始 # 应被单层编码为 %23")
        XCTAssertNil(url.fragment, "# 不应被解析成 fragment 分隔符")
        XCTAssertFalse(url.absoluteString.contains("#"), "URL 字符串不应含裸 #：\(url.absoluteString)")
        XCTAssertEqual(url.path, "/v1/players/#ABC", "解码后应还原原始 tag")
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
        let url = CoAPIURLBuilder.endpoint(config: CoAPIConfig(), path: "/players/#ABC")
        XCTAssertEqual(url.host, "api.clashofclans.com")
        XCTAssertTrue(url.path(percentEncoded: true).hasPrefix("/v1/"), "path 应以 /v1/ 开头：\(url.path(percentEncoded: true))")
    }

    func testPathWithoutHashUnaffected() {
        let url = CoAPIURLBuilder.endpoint(config: CoAPIConfig(), path: "/locations")
        XCTAssertEqual(url.path, "/v1/locations")
    }
}
