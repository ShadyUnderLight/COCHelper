import Foundation
import XCTest

@testable import COCHelperCore

/// Issue #265 E0-02：canonical JSON encoded bytes 的 golden 冻结（wire-contract-v1.md §WA-2）。
///
/// 期望值冻结在 `Fixtures/canonical-json-expected.json`。样本或期望值漂移时测试失败；
/// 新增样本缺少期望值时，失败消息会输出实测 hex，回填后即完成冻结。
final class CanonicalJSONGoldenTests: XCTestCase {
    private func fixtureData(_ name: String, sourceLine: UInt = #line) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json"),
            "缺少 golden fixture \(name).json",
            line: sourceLine
        )
        return try Data(contentsOf: url)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testCanonicalBytesMatchFrozenExpectations() throws {
        let samplesData = try fixtureData("canonical-json-samples", sourceLine: #line)
        let expectedData = try fixtureData("canonical-json-expected", sourceLine: #line)

        let samplesRoot = try JSONSerialization.jsonObject(with: samplesData, options: [.fragmentsAllowed])
        let rootMap = try XCTUnwrap(samplesRoot as? [String: Any], "样本文件顶层必须是对象")
        let sampleMap = try XCTUnwrap(rootMap["samples"] as? [String: Any], "样本必须位于 samples 键下")
        let expectedContainer = try JSONDecoder().decode(
            [String: [String: String]].self, from: expectedData
        )
        let expectations = try XCTUnwrap(expectedContainer["expectations"], "期望值文件必须含 expectations 键")

        for (id, raw) in sampleMap.sorted(by: { $0.key < $1.key }) {
            let value = try CanonicalJSONValue.fromJSONObject(raw).canonicalized
            let actualHex = hex(value.canonicalData)

            guard let expectedHex = expectations[id] else {
                XCTFail("""
                样本 \(id) 缺少冻结期望值。实测 canonical bytes hex：
                \(actualHex)
                请回填 Tests/Golden/Fixtures/canonical-json-expected.json。
                """)
                continue
            }
            XCTAssertEqual(
                actualHex, expectedHex,
                "样本 \(id) 的 canonical bytes 与冻结期望值不一致——若为有意契约变更，须同步更新 wire-contract-v1.md §WA-2 并说明旧历史 fingerprint 迁移方案"
            )
        }

        XCTAssertEqual(
            Set(expectations.keys), Set(sampleMap.keys),
            "期望值与样本 id 集合必须一致：\(Set(expectations.keys).symmetricDifference(Set(sampleMap.keys)))"
        )
    }

    /// 边界例：canonical bytes 重解析后再次规范化必须幂等（字节级稳定）。
    func testCanonicalBytesRoundTripIsStable() throws {
        let samplesData = try fixtureData("canonical-json-samples", sourceLine: #line)
        let samplesRoot = try JSONSerialization.jsonObject(with: samplesData, options: [.fragmentsAllowed])
        let rootMap = try XCTUnwrap(samplesRoot as? [String: Any], "样本文件顶层必须是对象")
        let sampleMap = try XCTUnwrap(rootMap["samples"] as? [String: Any], "样本必须位于 samples 键下")

        for (id, raw) in sampleMap {
            let canonical = try CanonicalJSONValue.fromJSONObject(raw).canonicalized
            let bytes = canonical.canonicalData
            let reparsed = try CanonicalJSONValue.fromJSONData(bytes)
            XCTAssertEqual(
                reparsed.canonicalized.canonicalData, bytes,
                "样本 \(id) 的 canonical bytes 重解析后必须逐字节稳定"
            )
        }
    }
}
