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
        XCTAssertEqual(snapshot.boosts["clocktower_cooldown"], 25_274)
        XCTAssertEqual(snapshot.objectSections["helpers"]?.first?.helperCooldownSeconds, 2_312)
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
