import XCTest
@testable import COCHelperCore

final class AccountSnapshotTests: XCTestCase {
    func testParsesVillageSectionsNestedItemsAndAdjustedTimers() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_600)
        let snapshot = try AccountSnapshotImporter.parse(sampleJSON, now: now)

        XCTAssertEqual(snapshot.tag, "#TESTTAG")
        XCTAssertEqual(snapshot.objectSections["buildings"]?.count, 2)
        XCTAssertEqual(snapshot.objectSections["buildings2"]?.count, 1)
        XCTAssertEqual(snapshot.numericSections["house_parts"], [82_000_000, 82_000_001])
        XCTAssertEqual(snapshot.boosts["clocktower_cooldown"], 24_674)
        XCTAssertEqual(snapshot.objectSections["helpers"]?.first?.helperCooldownSeconds, 2_312)
        XCTAssertEqual(snapshot.objectSections["helpers"]?.first?.remainingHelperCooldownSeconds, 1_712)
        XCTAssertEqual(snapshot.activeItemCount, 3)

        let building = try XCTUnwrap(snapshot.objectSections["buildings"]?.first)
        XCTAssertEqual(building.dataID, 1_000_013)
        XCTAssertEqual(building.remainingSeconds, 3_000)
        XCTAssertEqual(building.count, nil)

        let special = try XCTUnwrap(snapshot.objectSections["buildings"]?.last)
        XCTAssertEqual(special.types.count, 1)
        XCTAssertEqual(special.types[0].modules.count, 1)
        XCTAssertEqual(special.types[0].modules[0].dataID, 102_000_033)
    }

    func testDuplicateRecordsRemainSeparateAndUnknownKeysAreDiagnosed() throws {
        let snapshot = try AccountSnapshotImporter.parse(
            """
            {
              "tag": "#TESTTAG",
              "timestamp": 1700000000,
              "buildings": [
                {"data": 1000000, "lvl": 10, "cnt": 2},
                {"data": 1000000, "lvl": 11, "cnt": 1}
              ],
              "future_field": {"value": true}
            }
            """,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(snapshot.objectSections["buildings"]?.count, 2)
        XCTAssertEqual(snapshot.objectSections["buildings"]?[0].count, 2)
        XCTAssertEqual(snapshot.objectSections["buildings"]?[1].level, 11)
        XCTAssertEqual(snapshot.unknownTopLevelKeys, ["future_field"])
        XCTAssertTrue(snapshot.diagnostics.contains { $0.path == "顶层" && $0.severity == .warning })
        XCTAssertTrue(snapshot.originalText.contains("future_field"))
    }

    func testCodeFenceAndMissingTimestampProduceUsefulDiagnostics() throws {
        let snapshot = try AccountSnapshotImporter.parse(
            """
            ```json
            {"buildings": [{"data": 1000000, "timer": 90}]}
            ```
            """,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(snapshot.objectSections["buildings"]?.first?.remainingSeconds, 90)
        XCTAssertTrue(snapshot.diagnostics.contains { $0.path == "文本" && $0.severity == .info })
        XCTAssertTrue(snapshot.diagnostics.contains { $0.path == "timestamp" && $0.severity == .warning })
    }

    func testInvalidInputFailsClosed() {
        XCTAssertThrowsError(try AccountSnapshotImporter.parse("[1, 2, 3]")) { error in
            XCTAssertEqual(error as? AccountSnapshotImportError, .topLevelMustBeObject)
        }
        XCTAssertThrowsError(try AccountSnapshotImporter.parse("{")) { error in
            guard case .invalidJSON = error as? AccountSnapshotImportError else {
                return XCTFail("expected invalid JSON error")
            }
        }
        XCTAssertThrowsError(try AccountSnapshotImporter.parse("   ")) { error in
            XCTAssertEqual(error as? AccountSnapshotImportError, .emptyInput)
        }
    }

    func testOutOfRangeScientificTimestampFailsWithoutTrap() {
        XCTAssertThrowsError(
            try AccountSnapshotImporter.parse("{\"timestamp\":1e30,\"buildings\":[]}")
        ) { error in
            guard case .invalidJSON = error as? AccountSnapshotImportError else {
                return XCTFail("expected invalid JSON error")
            }
        }
    }

    func testAnonymizedCopiedAccountFixtureMatchesReportedShape() throws {
        let capturedAt: Int64 = 1_785_736_333
        let snapshot = try AccountSnapshotImporter.parse(
            try fixtureText(),
            now: Date(timeIntervalSince1970: TimeInterval(capturedAt + 600))
        )

        XCTAssertEqual(snapshot.tag, "#ANONYMIZED")
        XCTAssertEqual(snapshot.ageSeconds, 600)
        XCTAssertEqual(snapshot.sectionNames.count, 23)
        XCTAssertEqual(snapshot.objectItemCount, 347)
        XCTAssertEqual(snapshot.numericItemCount, 99)
        XCTAssertEqual(snapshot.activeItemCount, 10)
        XCTAssertEqual(snapshot.warningCount, 0)
        XCTAssertEqual(snapshot.objectSections["buildings"]?.count, 49)
        XCTAssertEqual(snapshot.objectSections["buildings2"]?.count, 34)
        XCTAssertEqual(snapshot.objectSections["helpers"]?.first?.helperCooldownSeconds, 2_312)
        XCTAssertEqual(snapshot.objectSections["helpers"]?.first?.remainingHelperCooldownSeconds, 1_712)
        XCTAssertEqual(snapshot.boosts["clocktower_cooldown"], 24_674)
    }

    func testBundledCatalogMapsFixtureIDsToChineseNames() throws {
        let snapshot = try AccountSnapshotImporter.parse(
            try fixtureText(),
            now: Date(timeIntervalSince1970: 1_785_736_933)
        )

        XCTAssertGreaterThan(AccountNameCatalog.bundled.count, 3_000)
        XCTAssertEqual(
            snapshot.objectSections["buildings"]?.first(where: { $0.dataID == 1_000_001 })?.displayName,
            "大本营"
        )
        XCTAssertEqual(
            snapshot.objectSections["heroes"]?.first?.displayName,
            "野蛮人之王"
        )
        XCTAssertEqual(
            snapshot.objectSections["equipment"]?.first?.displayName,
            "野蛮人木偶"
        )
        XCTAssertEqual(
            snapshot.objectSections["obstacles"]?.first?.displayName,
            "7周岁生日惊喜"
        )
        XCTAssertEqual(
            snapshot.allObjectItems.first(where: { $0.dataID == 102_000_033 })?.displayName,
            "火热蜡烛生命值模组"
        )

        let unmapped = snapshot.allObjectItems.filter { $0.displayName == nil }
        XCTAssertTrue(
            unmapped.isEmpty,
            "fixture contains unmapped object IDs: " + unmapped.map { $0.rawIDLabel }.joined(separator: ", ")
        )
        XCTAssertEqual(
            AccountNameCatalog.bundled.name(forNumericSection: "house_parts", dataID: 82_000_000),
            "部落营房地面"
        )
        XCTAssertEqual(
            AccountNameCatalog.bundled.name(forNumericSection: "skins", dataID: 52_000_012),
            "海上蛮王"
        )
        XCTAssertEqual(
            AccountNameCatalog.bundled.name(forNumericSection: "sceneries", dataID: 60_000_005),
            "海上基地"
        )
    }

    func testExpiredCooldownsNormalizeToZeroAndUseTerminalLabels() throws {
        let snapshot = try AccountSnapshotImporter.parse(
            """
            {
              "timestamp": 1700000000,
              "helpers": [{"data": 93000000, "helper_cooldown": 60}],
              "boosts": {"clocktower_cooldown": 60}
            }
            """,
            now: Date(timeIntervalSince1970: 1_700_000_060)
        )

        XCTAssertEqual(snapshot.objectSections["helpers"]?.first?.remainingHelperCooldownSeconds, 0)
        XCTAssertEqual(snapshot.boosts["clocktower_cooldown"], 0)
        XCTAssertEqual(AccountDurationFormatter.label(0), "已结束")
        XCTAssertEqual(AccountDurationFormatter.label(0, zeroLabel: "已就绪"), "已就绪")
        XCTAssertEqual(AccountDurationFormatter.label(59), "不足1分钟")
        XCTAssertEqual(AccountDurationFormatter.label(60), "1分钟")
    }

    func testSnapshotSeparatesMainVillageAndBuilderBaseRecords() throws {
        let snapshot = try AccountSnapshotImporter.parse(
            sampleJSON,
            now: Date(timeIntervalSince1970: 1_700_000_600)
        )

        XCTAssertEqual(snapshot.mainVillageObjectItemCount, 4)
        XCTAssertEqual(snapshot.builderBaseObjectItemCount, 1)
        XCTAssertEqual(snapshot.mainVillageActiveItemCount, 2)
        XCTAssertEqual(snapshot.builderBaseActiveItemCount, 1)
    }

    func testBundledAccountNameCatalogLabelsKnownIDsAndKeepsUnknownIDsAuditable() {
        XCTAssertEqual(AccountNameCatalog.bundled.name(for: "buildings", dataID: 1_000_001), "大本营")
        XCTAssertEqual(AccountNameCatalog.bundled.name(for: "heroes", dataID: 28_000_001), "弓箭女皇")
        XCTAssertNil(AccountNameCatalog.bundled.name(for: "buildings", dataID: 9_999_999))

        let unknown = AccountItem(id: "buildings:0", section: "buildings", dataID: 9_999_999)
        XCTAssertEqual(unknown.nameLabel, "#9999999")
    }

    private func fixtureText() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "anonymized_account_snapshot",
                withExtension: "json"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let sampleJSON = """
    {
      "tag": "#TESTTAG",
      "timestamp": 1700000000,
      "helpers": [{"data": 93000000, "lvl": 8, "helper_cooldown": 2312}],
      "buildings": [
        {"data": 1000013, "lvl": 17, "timer": 3600},
        {"data": 1000097, "types": [{"data": 103000011, "modules": [{"data": 102000033, "lvl": 1}]}]
      }],
      "units": [{"data": 4000123, "lvl": 5, "timer": 7200}],
      "house_parts": [82000000, 82000001],
      "buildings2": [{"data": 1000050, "lvl": 7, "timer": 900}],
      "boosts": {"clocktower_cooldown": 25274}
    }
    """
}
