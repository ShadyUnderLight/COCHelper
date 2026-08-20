import Foundation
import XCTest
@testable import COCHelperCore

/// Issue #173 / #205: pasted JSON coverage is declarative only.
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
            XCTAssertFalse(proof.isVerified, "无来源协议时 \(section) 不得为 verified")
            guard case .unavailable = proof else {
                return XCTFail("无来源协议时 \(section) 应为 unavailable,得到 \(proof)")
            }
        }
    }

    func testCoverageDeclarationProducesDeclaredProofForDeclaredSections() throws {
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
            .declared(source: "u.coc", version: "1", expectedCount: 1)
        )
        XCTAssertFalse(proofs["buildings"]?.isVerified ?? true)
        XCTAssertTrue(proofs["buildings"]?.isWellFormedDeclaration ?? false)
        guard case .unavailable = proofs["heroes"] else {
            return XCTFail("未声明的 heroes 应为 unavailable,得到 \(String(describing: proofs["heroes"]))")
        }
    }

    func testPastedVerifiedKindFailsClosedToUnavailable() throws {
        let text = """
        {
          "tag": "#2QJQ8J88",
          "buildings": [{"data": 1, "lvl": 1}],
          "coverage": {
            "buildings": {
              "kind": "verified",
              "source": "u.coc",
              "adapterID": "evil",
              "protocolVersion": "1"
            }
          }
        }
        """
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot(text: text))
        guard case .unavailable = proofs["buildings"] else {
            return XCTFail("粘贴 JSON 的 verified 声明应 fail-closed")
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
            XCTAssertFalse(proofs["buildings"]?.isVerified ?? true)
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

        guard case .unavailable = proofs["buildings"] else {
            return XCTFail("缺字段的声明应 fail-closed,得到 \(String(describing: proofs["buildings"]))")
        }
    }

    func testDeclaredProofWithExpectedCountMismatchIsStillDecodedFidelity() throws {
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
            .declared(source: "u.coc", version: "1", expectedCount: 3)
        )
    }

    func testMarkdownFencedJSONKeepsDeclaredProof() throws {
        let inner = """
        {"tag":"#2QJQ8J88","buildings":[{"data":1,"lvl":1}],
         "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
        """
        let fenced = "```json\n" + inner + "\n```"

        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot(text: fenced))

        XCTAssertEqual(
            proofs["buildings"],
            .declared(source: "u.coc", version: "1", expectedCount: 1),
            "带 code fence 的合法输入不得丢失 coverage 声明"
        )
    }

    func testUnrecognizedProtocolVersionFailsClosedForDeclarations() throws {
        let cases: [(String, String)] = [
            ("unrecognized", "1"),
            ("v1", "1"),
            ("1.2-beta", "1"),
            ("", "1")
        ]
        for (version, source) in cases {
            let proof = SnapshotCoverageProof.declared(
                source: source,
                version: version,
                expectedCount: 1
            )
            XCTAssertFalse(
                proof.isWellFormedDeclaration,
                "不可解析的协议版本 \(version.debugDescription) 不得为 well-formed declaration"
            )
        }

        let validCases: [(String, String)] = [
            ("1", "u.coc"),
            ("1.2", "u.coc"),
            ("1.2.3", "u.coc")
        ]
        for (version, source) in validCases {
            let proof = SnapshotCoverageProof.declared(
                source: source,
                version: version,
                expectedCount: 1
            )
            XCTAssertTrue(proof.isWellFormedDeclaration, "合法语义版本 \(version) 应为 well-formed declaration")
            XCTAssertFalse(proof.isVerified)
        }
    }

    func testBlankSourceAndOverSegmentedVersionFailsClosed() throws {
        let invalid: [(source: String, version: String)] = [
            ("   ", "1"),
            ("\n\t", "1"),
            ("u.coc", "1.2.3.4"),
            ("u.coc", "1.2.3.4.5"),
            ("u.coc", "１"),
            ("u.coc", "1.２.3")
        ]
        for case (let source, let version) in invalid {
            let proof = SnapshotCoverageProof.declared(
                source: source,
                version: version,
                expectedCount: 1
            )
            XCTAssertFalse(
                proof.isWellFormedDeclaration,
                "source=\(source.debugDescription) version=\(version.debugDescription) 不得为 well-formed"
            )
        }

        let valid: [(source: String, version: String)] = [
            ("u.coc", "1"),
            ("u.coc", "1.2"),
            ("u.coc", "1.2.3"),
            ("official-api", "2026.08.13")
        ]
        for case (let source, let version) in valid {
            let proof = SnapshotCoverageProof.declared(
                source: source,
                version: version,
                expectedCount: 1
            )
            XCTAssertTrue(proof.isWellFormedDeclaration)
            XCTAssertFalse(proof.isVerified)
        }
    }

    func testLegacyAuthoritativeWireRoundTripPreservesIntegrityBytes() throws {
        let legacyJSON = """
        {"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SnapshotCoverageProof.self, from: legacyJSON)
        guard case .legacyAuthoritative = decoded else {
            return XCTFail("旧 wire authoritative 应解码为 legacyAuthoritative,得到 \(decoded)")
        }
        XCTAssertFalse(decoded.isVerified)

        let reencoded = try JSONEncoder().encode(decoded)
        let roundtrip = try JSONDecoder().decode(SnapshotCoverageProof.self, from: reencoded)
        XCTAssertEqual(roundtrip, decoded)
        let wire = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        XCTAssertEqual(wire?["kind"] as? String, "authoritative")
    }

    func testPastedDeclarationDoesNotOpenCanonicalCompleteSection() throws {
        let text = """
        {"tag":"#2QJQ8J88","buildings":[{"data":1,"lvl":1}],
         "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
        """
        let snapshot = try AccountSnapshotImporter.parse(text, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(snapshot.unknownTopLevelKeys, [])
        XCTAssertFalse(snapshot.diagnostics.contains {
            $0.path == "顶层" && $0.severity == .warning
                && $0.message.contains("未识别字段")
                && $0.message.contains("coverage")
        })
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot)
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: proofs
        )
        XCTAssertNil(entry.observation.unknownTopLevelFields["coverage"])
        XCTAssertNil(entry.observation.rawTopLevelFields["coverage"])
        XCTAssertFalse(entry.coverage.fields.contains {
            $0.base == .unknown
                && $0.rawSection == "$topLevel"
                && $0.field == "coverage"
        })
        let buildings = try XCTUnwrap(entry.coverage.section(base: .home, rawSection: "buildings"))
        XCTAssertEqual(buildings.proof, .declared(source: "u.coc", version: "1", expectedCount: 1))
        XCTAssertEqual(buildings.completeness, .unavailable)
        XCTAssertFalse(buildings.isComplete)
    }
}
