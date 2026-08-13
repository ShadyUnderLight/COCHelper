import Foundation
import XCTest
@testable import COCHelperCore

/// Issue #173: 真实导入接入可审计的 section coverage proof。
///
/// 来源契约:账号 JSON 顶层可选的 `coverage` 字段声明各 section 的
/// 完整性证明(格式为 `SnapshotCoverageProof` 的 Codable 编码)。
/// 没有声明、声明无效或未提及的 section 一律 fail-closed 为
/// `unavailable`,禁止根据数组存在/空数组/目录猜测完整性。
final class SnapshotCoverageSourceTests: XCTestCase {
    private func snapshot(text: String) -> AccountSnapshot {
        AccountSnapshot(
            tag: "#2QJQ8J88",
            capturedAt: nil,
            importedAt: Date(timeIntervalSince1970: 1),
            ageSeconds: nil,
            originalText: text,
            objectSections: [:],
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
    }

    private func realAccountJSON() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "anonymized_account_snapshot", withExtension: "json")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testRealAccountJSONWithoutCoverageDeclarationIsUnavailable() throws {
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot(text: try realAccountJSON()))

        for section in SnapshotHistoryKnownSections.all.sorted() {
            guard let proof = proofs[section] else {
                return XCTFail("缺少 section 的 proof: \(section)")
            }
            XCTAssertFalse(proof.isAuthoritative, "无来源协议时 \(section) 不得为 authoritative")
            guard case .unavailable = proof else {
                return XCTFail("无来源协议时 \(section) 应为 unavailable,得到 \(proof)")
            }
        }
    }

    func testCoverageDeclarationProducesAuthoritativeProofForDeclaredSections() throws {
        let text = """
        {
          "tag": "#2QJQ8J88",
          "buildings": [{"data": 1, "lvl": 1}],
          "heroes": [{"data": 2, "lvl": 2}],
          "coverage": {
            "buildings": {
              "kind": "authoritative",
              "source": "u.coc",
              "version": "1",
              "expectedCount": 1
            }
          }
        }
        """
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot(text: text))

        XCTAssertEqual(
            proofs["buildings"],
            .authoritative(source: "u.coc", version: "1", expectedCount: 1)
        )
        // 未提及的 section 保持 fail-closed。
        guard case .unavailable = proofs["heroes"] else {
            return XCTFail("未声明的 heroes 应为 unavailable,得到 \(String(describing: proofs["heroes"]))")
        }
    }

    func testExplicitUnavailableProofInCoverageFieldIsPassedThrough() throws {
        let text = """
        {
          "tag": "#2QJQ8J88",
          "buildings": [],
          "coverage": {
            "buildings": {
              "kind": "unavailable",
              "reason": "来源导出中断，不保证完整。"
            }
          }
        }
        """
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot(text: text))

        XCTAssertEqual(
            proofs["buildings"],
            .unavailable(reason: "来源导出中断，不保证完整。")
        )
    }

    func testInvalidCoverageFieldFailsClosedToUnavailable() throws {
        let cases = [
            "{\"tag\":\"#2QJQ8J88\",\"buildings\":[],\"coverage\":\"full\"}",
            "{\"tag\":\"#2QJQ8J88\",\"buildings\":[],\"coverage\":[1,2]}",
            "{\"tag\":\"#2QJQ8J88\",\"buildings\":[],\"coverage\":true}"
        ]
        for text in cases {
            let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot(text: text))
            guard case .unavailable = proofs["buildings"] else {
                return XCTFail("无效 coverage 字段应 fail-closed,得到 \(String(describing: proofs["buildings"]))")
            }
            XCTAssertFalse(proofs["buildings"]?.isAuthoritative ?? false)
        }
    }

    func testMalformedSectionEntryFailsClosed() throws {
        let text = """
        {
          "tag": "#2QJQ8J88",
          "buildings": [{"data": 1}],
          "coverage": {
            "buildings": {"kind": "authoritative"}
          }
        }
        """
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot(text: text))

        // 缺少 source/version 的 authoritative 声明不可解码为合法 proof → unavailable。
        guard case .unavailable = proofs["buildings"] else {
            return XCTFail("缺字段的 authoritative 声明应 fail-closed,得到 \(String(describing: proofs["buildings"]))")
        }
    }

    func testAuthoritativeProofWithExpectedCountMismatchIsStillDecodedFidelity() throws {
        // adapter 忠实解码来源声明;expectedCount 与 observed 不一致时的
        // partial 降级发生在 canonicalizer(canonicalize 时校验)。
        let text = """
        {
          "tag": "#2QJQ8J88",
          "buildings": [{"data": 1}, {"data": 2}],
          "coverage": {
            "buildings": {
              "kind": "authoritative",
              "source": "u.coc",
              "version": "1",
              "expectedCount": 3
            }
          }
        }
        """
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot(text: text))

        XCTAssertEqual(
            proofs["buildings"],
            .authoritative(source: "u.coc", version: "1", expectedCount: 3)
        )
    }
}
