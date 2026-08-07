import AppKit
import XCTest
@testable import COCHelperCore

final class OfficialPlayerCardIconTests: XCTestCase {
    func testBundledIconsExistAndDecode() throws {
        XCTAssertEqual(OfficialPlayerCardIcon.allCases.count, 3)

        for icon in OfficialPlayerCardIcon.allCases {
            let url = try XCTUnwrap(icon.bundledURL(), "缺少 \(icon.rawValue).png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNotNil(NSImage(contentsOf: url), "无法解码 \(url.path)")
        }
    }

    func testUnknownIconResourceReturnsNil() {
        XCTAssertNil(Bundle.module.url(forResource: "official_player_missing", withExtension: "png"))
    }
}
