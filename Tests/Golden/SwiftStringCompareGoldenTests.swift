import Foundation
import XCTest

/// Swift `String.<` / `==` 的 golden 冻结，供 TypeScript comparator 对照（Issue #267 / WA-2）。
final class SwiftStringCompareGoldenTests: XCTestCase {
    private struct Pair: Decodable {
        let left: String
        let right: String
        let leftLessThanRight: Bool
        let equal: Bool
    }

    private struct Fixture: Decodable {
        let inputKeys: [String]
        let sortedKeys: [String]
        let pairs: [Pair]
    }

    func testFixtureMatchesSwiftStringComparison() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "swift-string-compare", withExtension: "json")
        )
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))

        for pair in fixture.pairs {
            XCTAssertEqual(
                pair.left < pair.right, pair.leftLessThanRight,
                "\(pair.left.debugDescription) < \(pair.right.debugDescription)"
            )
            XCTAssertEqual(
                pair.left == pair.right, pair.equal,
                "\(pair.left.debugDescription) == \(pair.right.debugDescription)"
            )
        }

        XCTAssertEqual(fixture.inputKeys.sorted(), fixture.sortedKeys)
    }
}
