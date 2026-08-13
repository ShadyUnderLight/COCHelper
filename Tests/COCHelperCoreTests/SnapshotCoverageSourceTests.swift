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

    func testMarkdownFencedJSONKeepsDeclaredProof() throws {
        // 导入器支持去除 Markdown code fence;adapter 必须用同样的清洗逻辑,
        // 否则合法输入(带 ```json 围栏)会解析失败并把 proof 降级为 unavailable。
        let inner = """
        {"tag":"#2QJQ8J88","buildings":[{"data":1,"lvl":1}],
         "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
        """
        let fenced = "```json\n" + inner + "\n```"

        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot(text: fenced))

        XCTAssertEqual(
            proofs["buildings"],
            .authoritative(source: "u.coc", version: "1", expectedCount: 1),
            "带 code fence 的合法输入不得丢失 coverage 声明"
        )
    }

    func testUnrecognizedProtocolVersionFailsClosedToUnavailable() throws {
        // Issue #173: source version 不可信 → 不得产生 authoritative。
        // version 必须是数字点分语义版本("1"、"1.2");"unrecognized" 等
        // 不可解析版本按 fail-closed 处理。
        let cases: [(String, String)] = [
            ("unrecognized", "1"),
            ("v1", "1"),
            ("1.2-beta", "1"),
            ("", "1")
        ]
        for (version, source) in cases {
            let proof = SnapshotCoverageProof.authoritative(
                source: source,
                version: version,
                expectedCount: 1
            )
            XCTAssertFalse(
                proof.isAuthoritative,
                "不可解析的协议版本 \(version.debugDescription) 不得为 authoritative"
            )
        }

        let validCases: [(String, String)] = [
            ("1", "u.coc"),
            ("1.2", "u.coc"),
            ("1.2.3", "u.coc")
        ]
        for (version, source) in validCases {
            let proof = SnapshotCoverageProof.authoritative(
                source: source,
                version: version,
                expectedCount: 1
            )
            XCTAssertTrue(proof.isAuthoritative, "合法语义版本 \(version) 应为 authoritative")
        }
    }

    func testBlankSourceAndOverSegmentedVersionFailsClosed() throws {
        // 复审 P2:source 纯空白无审计价值、version 超出 1–3 段语义版本
        // 惯例(主.次.补丁)或含非 ASCII 数字,一律 fail-closed。
        let invalid: [(source: String, version: String)] = [
            ("   ", "1"),
            ("\n\t", "1"),
            ("u.coc", "1.2.3.4"),
            ("u.coc", "1.2.3.4.5"),
            ("u.coc", "１"),       // 全角数字不是 ASCII 数字
            ("u.coc", "1.２.3")
        ]
        for case (let source, let version) in invalid {
            let proof = SnapshotCoverageProof.authoritative(
                source: source,
                version: version,
                expectedCount: 1
            )
            XCTAssertFalse(
                proof.isAuthoritative,
                "source=\(source.debugDescription) version=\(version.debugDescription) 不得为 authoritative"
            )
        }

        let valid: [(source: String, version: String)] = [
            ("u.coc", "1"),
            ("u.coc", "1.2"),
            ("u.coc", "1.2.3"),
            ("official-api", "2026.08.13")
        ]
        for case (let source, let version) in valid {
            let proof = SnapshotCoverageProof.authoritative(
                source: source,
                version: version,
                expectedCount: 1
            )
            XCTAssertTrue(proof.isAuthoritative, "合法 source/version 应为 authoritative")
        }
    }
}
