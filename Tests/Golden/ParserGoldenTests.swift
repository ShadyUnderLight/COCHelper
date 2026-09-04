import Foundation
import XCTest

@testable import COCHelperCore

/// Issue #265 E0-02：parser 输出的 golden 冻结（wire-contract-v1.md §WA-3/§WA-4/§WA-6）。
/// Issue #304：内容指纹字段已删除；冻结 wire 形状（encodedJSONHex）与业务结构。
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
            let encodedJSONHex: String
        }

        struct HistoryEntryExpectations: Decodable {
            let encodedJSONHex: String
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

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func sortedKeysEncodedJSONHex<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hex(try encoder.encode(value))
    }

    /// AccountSnapshot 持久化 wire 包含 `diagnostics[].id`——每次解析随机生成的
    /// UUID（§WA-5：F3 指纹排除它，但 Codable 持久化形状包含它）。冻结时把该
    /// 唯一已知的非确定性槽位替换为占位符；TS 侧必须把它当作不透明随机值，
    /// 其余字节（JSONEncoder 的 Date/optional omission/键序行为）逐字节锁定。
    private func maskedSnapshotWireHex(_ wireHex: String) throws -> String {
        let chars = Array(wireHex)
        let bytes = stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0..<$0 + 2]), radix: 16)!
        }
        let json = try XCTUnwrap(String(data: Data(bytes), encoding: .utf8))
        let pattern = "\"id\":\"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\""
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(json.startIndex..., in: json)
        let masked = regex.stringByReplacingMatches(in: json, range: range, withTemplate: "\"id\":\"<RANDOM_DIAGNOSTIC_UUID>\"")
        return hex(Data(masked.utf8))
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

    func testAccountSnapshotRepeatedParseProducesEqualBusinessContent() throws {
        let snapshot = try loadGoldenSnapshot()
        let again = try loadGoldenSnapshot()
        XCTAssertEqual(snapshot.objectSections, again.objectSections)
        XCTAssertEqual(snapshot.numericSections, again.numericSections)
        XCTAssertEqual(snapshot.boosts, again.boosts)
        XCTAssertEqual(snapshot.tag, again.tag)
        let expected = try loadExpected().accountSnapshot
        XCTAssertFalse(expected.encodedJSONHex.isEmpty, "期望值未回填")
    }

    /// wire shape 冻结：JSONEncoder(.sortedKeys) 的 encoded bytes（Date 编码策略、
    /// optional omission、键集与键序）。diagnostics[].id 是已知随机槽位，按
    /// maskedSnapshotWireHex 掩码后比较；TS 侧 parity 需逐字节复刻其余行为。
    func testAccountSnapshotEncodedJSONMatchesGolden() throws {
        let snapshot = try loadGoldenSnapshot()
        let expected = try loadExpected().accountSnapshot.encodedJSONHex
        let actual = try maskedSnapshotWireHex(sortedKeysEncodedJSONHex(snapshot))
        XCTAssertFalse(expected.isEmpty, "期望值未回填；实测 masked encoded JSON hex：\n\(actual)")
        XCTAssertEqual(
            actual, expected,
            "AccountSnapshot encoded JSON 与冻结期望值不一致（wire shape 漂移）。实测：\n\(actual)"
        )
    }

    func testHistoryEntryObservationIdentityIsDeterministic() throws {
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
        let again = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: Self.villageID,
            lineageID: Self.lineageID,
            appliedAt: Self.appliedAt,
            snapshotID: Self.snapshotID,
            isBaseline: false,
            baselineReason: nil,
            observationVersion: SnapshotHistorySchema.observation
        )

        XCTAssertEqual(
            SnapshotHistoryCanonicalizer.observationIdentityKey(for: entry.observation),
            SnapshotHistoryCanonicalizer.observationIdentityKey(for: again.observation)
        )
    }

    /// wire shape 冻结：HistoryEntryV1（observation v6 + coverage + 全部版本号）
    /// 经 JSONEncoder(.sortedKeys) 的 encoded bytes。
    func testHistoryEntryEncodedJSONMatchesGolden() throws {
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
        let expected = try loadExpected().historyEntry.encodedJSONHex
        let actual = try sortedKeysEncodedJSONHex(entry)
        XCTAssertFalse(expected.isEmpty, "期望值未回填；实测 encoded JSON hex：\n\(actual)")
        XCTAssertEqual(
            actual, expected,
            "SnapshotHistoryEntry encoded JSON 与冻结期望值不一致（wire shape 漂移）。实测：\n\(actual)"
        )
    }

    /// 负例：篡改 observation 必须被加载校验拒绝；畸形 JSON 必须抛错而非静默成功。
    func testTamperedObservationRejectedAndMalformedJSONThrows() throws {
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

        let tampered = SnapshotHistoryEntry(
            observationVersion: entry.observationVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            rawJSON: entry.rawJSON,
            observation: CanonicalSnapshotObservation(
                schemaVersion: entry.observation.schemaVersion,
                rawTopLevelFields: entry.observation.rawTopLevelFields,
                unknownTopLevelFields: entry.observation.unknownTopLevelFields,
                items: Array(entry.observation.items.dropFirst())
            ),
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
        let envelope = SnapshotHistoryEnvelope(
            entries: [tampered],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: entry.appliedAt)
        )
        XCTAssertThrowsError(try envelope.validated()) { error in
            XCTAssertEqual(
                error as? SnapshotHistoryStoreError,
                .invalidEntry("历史 entry 的 rawJSON 与 observation 不一致。")
            )
        }

        // 负例：非对象顶层与畸形 JSON 必须抛错而非静默成功。
        XCTAssertThrowsError(try AccountSnapshotImporter.parse("[1,2]", now: Self.importedAt))
        XCTAssertThrowsError(try AccountSnapshotImporter.parse("{not json", now: Self.importedAt))
    }
}
