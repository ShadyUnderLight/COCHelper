import Foundation
import XCTest

@testable import COCHelperCore

/// Issue #265 E0-02：parser 输出与 fingerprint 的 golden 冻结（wire-contract-v1.md §WA-3/§WA-4/§WA-6）。
///
/// 所有时间输入显式钉死（importedAt 走 reference-date 域、capturedAt 走 Unix epoch 域，
/// 即 §WA-4 的双纪元区分）。期望值冻结在 `Fixtures/parser_golden_expected.json`；
/// 首次运行或契约变更时，失败消息输出实测值用于回填。
final class ParserGoldenTests: XCTestCase {
    /// importedAt = epoch 1_785_836_333（= capturedAt + 100_000 秒，ageSeconds 恰为 100000）。
    private static let importedAt = Date(timeIntervalSinceReferenceDate: 807_529_133)
    private static let appliedAt = Date(timeIntervalSinceReferenceDate: 807_629_133)
    private static let villageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let lineageID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private struct ExpectedFingerprints: Decodable {
        struct AccountSnapshotExpectations: Decodable {
            let contentFingerprint: String
        }

        struct HistoryEntryExpectations: Decodable {
            let canonicalFingerprint: String
            let integrityFingerprint: String
        }

        let accountSnapshot: AccountSnapshotExpectations
        let historyEntry: HistoryEntryExpectations
    }

    private func loadGoldenSnapshot() throws -> AccountSnapshot {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "account_snapshot_golden", withExtension: "json")
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        return try AccountSnapshotImporter.parse(text, now: Self.importedAt)
    }

    private func loadExpected() throws -> ExpectedFingerprints {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "parser_golden_expected", withExtension: "json")
        )
        return try JSONDecoder().decode(ExpectedFingerprints.self, from: Data(contentsOf: url))
    }

    /// 正例 + 时间双纪元边界：解析结构必须精确匹配冻结事实。
    func testAccountSnapshotGoldenStructureAndTimeDomains() throws {
        let snapshot = try loadGoldenSnapshot()

        XCTAssertEqual(snapshot.tag, "#GOLDEN01")
        XCTAssertEqual(snapshot.capturedAt, Date(timeIntervalSince1970: 1_785_736_333))
        XCTAssertEqual(snapshot.importedAt, Self.importedAt)
        XCTAssertEqual(snapshot.ageSeconds, 100_000)
        // §WA-1.4：未知顶层键收集且排序。
        XCTAssertEqual(snapshot.unknownTopLevelKeys, ["golden_unknown_field"])
        // §WA-6c：dataID 经三级解析；units2 是 canonical 化的重复 section 后缀。
        XCTAssertEqual(snapshot.objectSections["buildings"]?.count, 2)
        XCTAssertEqual(snapshot.objectSections["units"]?.count, 1)
        XCTAssertEqual(snapshot.objectSections["units2"]?.count, 1)
        XCTAssertTrue(snapshot.numericSections.isEmpty)
    }

    func testAccountSnapshotContentFingerprintMatchesGolden() throws {
        let snapshot = try loadGoldenSnapshot()
        let expected = try loadExpected().accountSnapshot.contentFingerprint
        XCTAssertFalse(expected.isEmpty, "期望值未回填；实测 contentFingerprint：\n\(snapshot.contentFingerprint)")
        XCTAssertEqual(
            snapshot.contentFingerprint, expected,
            "contentFingerprint 与冻结期望值不一致。实测：\n\(snapshot.contentFingerprint)"
        )
    }

    func testHistoryEntryV6FingerprintsMatchGolden() throws {
        let snapshot = try loadGoldenSnapshot()
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: Self.villageID,
            lineageID: Self.lineageID,
            appliedAt: Self.appliedAt,
            snapshotID: Self.snapshotID,
            isBaseline: false,
            baselineReason: nil,
            observationVersion: SnapshotHistorySchema.observation
        )
        let expected = try loadExpected().historyEntry

        if expected.canonicalFingerprint.isEmpty || expected.integrityFingerprint.isEmpty {
            XCTFail("""
            期望值未回填。实测：
            canonicalFingerprint = \(entry.canonicalFingerprint)
            integrityFingerprint = \(entry.integrityFingerprint)
            """)
            return
        }
        XCTAssertEqual(entry.canonicalFingerprint, expected.canonicalFingerprint)
        XCTAssertEqual(entry.integrityFingerprint, expected.integrityFingerprint)
    }

    /// 负例：指纹格式门 + 完整性敏感性（任一字段变化必须改变 integrityFingerprint）。
    func testFingerprintFormatGuardsAndIntegritySensitivity() throws {
        let snapshot = try loadGoldenSnapshot()
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: Self.villageID,
            lineageID: Self.lineageID,
            appliedAt: Self.appliedAt,
            snapshotID: Self.snapshotID,
            isBaseline: false,
            baselineReason: nil,
            observationVersion: SnapshotHistorySchema.observation
        )

        for fingerprint in [
            snapshot.contentFingerprint, entry.canonicalFingerprint, entry.integrityFingerprint,
        ] {
            XCTAssertEqual(fingerprint.count, 71, "fingerprint 必须是 sha256: + 64 hex")
            XCTAssertTrue(fingerprint.hasPrefix("sha256:"), "fingerprint 必须带 sha256: 前缀")
        }

        let mutated = SnapshotHistoryEntry(
            observationVersion: entry.observationVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt.addingTimeInterval(1),
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: entry.canonicalFingerprint,
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
        XCTAssertNotEqual(
            mutated.integrityFingerprint, entry.integrityFingerprint,
            "appliedAt 变化必须改变 integrityFingerprint（§WA-3 F2 全量材料）"
        )

        // 负例：非对象顶层与畸形 JSON 必须抛错而非静默成功。
        XCTAssertThrowsError(try AccountSnapshotImporter.parse("[1,2]", now: Self.importedAt))
        XCTAssertThrowsError(try AccountSnapshotImporter.parse("{not json", now: Self.importedAt))
    }
}
