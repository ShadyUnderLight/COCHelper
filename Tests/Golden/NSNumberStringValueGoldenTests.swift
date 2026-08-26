import Foundation
import XCTest

/// `JSONSerialization` → `NSNumber.stringValue` 的 golden 冻结（Issue #267 / WA-1.2）。
final class NSNumberStringValueGoldenTests: XCTestCase {
    func testFixtureMatchesJSONSerializationStringValue() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "nsnumber-stringvalue", withExtension: "json")
        )
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let stringValues = try XCTUnwrap(root["stringValues"] as? [String: String])

        for (token, expected) in stringValues.sorted(by: { $0.key < $1.key }) {
            let object = try JSONSerialization.jsonObject(
                with: Data(token.utf8),
                options: [.fragmentsAllowed]
            )
            let number = try XCTUnwrap(object as? NSNumber, "token \(token) 必须是 JSON number")
            XCTAssertEqual(number.stringValue, expected, "token \(token)")
        }

        let rejects = try XCTUnwrap(root["rejects"] as? [String])
        XCTAssertFalse(rejects.isEmpty, "必须覆盖 NSDecimal 指数越界拒绝例")
        for token in rejects {
            XCTAssertThrowsError(
                try JSONSerialization.jsonObject(with: Data(token.utf8), options: [.fragmentsAllowed]),
                "token \(token) 必须被 JSONSerialization 拒绝"
            )
        }
    }
}
