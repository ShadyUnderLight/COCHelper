import Foundation
import XCTest

@testable import COCHelperCore

/// 原始 JSON 源文本的 parser parity golden（Issue #267 / WA-1）。
///
/// `source` 必须是 fixture JSON **字符串**，不能写成 fixture 对象字面量：
/// 否则 `JSONSerialization` 读取 fixture 时就会提前合并 NFC 等价键，测不到 parser。
final class JsonRawSourceGoldenTests: XCTestCase {
    private struct Sample: Decodable {
        let id: String
        let source: String
        let canonicalHex: String
    }

    private struct Reject: Decodable {
        let id: String
        let source: String
    }

    private struct Fixture: Decodable {
        let samples: [Sample]
        let rejects: [Reject]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "json-raw-samples", withExtension: "json")
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testRawSourcesMatchCanonicalJSONValue() throws {
        let fixture = try fixture()
        for sample in fixture.samples {
            let value = try CanonicalJSONValue.fromJSONData(Data(sample.source.utf8)).canonicalized
            XCTAssertEqual(
                hex(value.canonicalData), sample.canonicalHex,
                "样本 \(sample.id) 的 canonical bytes 与冻结期望值不一致"
            )
        }
    }

    func testLoneSurrogatesAreRejected() throws {
        let fixture = try fixture()
        XCTAssertFalse(fixture.rejects.isEmpty, "必须覆盖孤立 surrogate 拒绝例")
        for sample in fixture.rejects {
            XCTAssertThrowsError(
                try CanonicalJSONValue.fromJSONData(Data(sample.source.utf8)),
                "样本 \(sample.id) 必须被 JSONSerialization 拒绝"
            )
        }
    }
}
