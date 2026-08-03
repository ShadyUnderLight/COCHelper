import XCTest
@testable import COCHelperCore

final class UpgradeTrackerTests: XCTestCase {
    func testActiveRecordsShowInferredNextLevelAndLiveRemainingTime() throws {
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try AccountSnapshotImporter.parse(
            """
            {
              "tag": "#TRACKER",
              "timestamp": 1700000000,
              "buildings": [
                {"data": 1000008, "lvl": 10, "timer": 3600},
                {"data": 1000009, "lvl": 15}
              ],
              "buildings2": [
                {"data": 1000050, "lvl": 6, "timer": 900}
              ],
              "decos": [{"data": 18000000, "cnt": 1}]
            }
            """,
            now: importedAt
        )

        let records = UpgradeTracker.records(
            from: snapshot,
            base: .home,
            at: Date(timeIntervalSince1970: 1_700_000_600)
        )
        let cannon = try XCTUnwrap(records.first(where: { $0.dataID == 1_000_008 }))

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(cannon.name, "加农炮")
        XCTAssertEqual(cannon.currentLevel, 10)
        XCTAssertEqual(cannon.inferredTargetLevel, 11)
        XCTAssertEqual(cannon.levelLabel, "10 → 11")
        XCTAssertEqual(cannon.remainingSeconds, 3_000)
        XCTAssertTrue(cannon.isUpgrading)
        XCTAssertFalse(records.contains { $0.dataID == 18_000_000 })
        XCTAssertEqual(snapshot.ageSeconds, 0)
        XCTAssertEqual(snapshot.objectSections["buildings2"]?.first?.timerSeconds, 900)
        XCTAssertEqual(snapshot.objectSections["buildings2"]?.first?.remainingSeconds, 900)
        XCTAssertEqual(snapshot.importedAt, importedAt)
        let builderRecords = UpgradeTracker.records(from: snapshot, base: .builder, at: importedAt)
        XCTAssertEqual(builderRecords.count, 1)
        XCTAssertEqual(builderRecords.first?.dataID, 1_000_050)
        XCTAssertEqual(builderRecords.first?.remainingSeconds, 900)
        XCTAssertTrue(builderRecords.first?.isUpgrading == true)
    }

    func testActiveRecordsSortByRemainingTimeAndKeepDuplicateLevelRows() throws {
        let snapshot = try AccountSnapshotImporter.parse(
            """
            {
              "buildings": [
                {"data": 1000008, "lvl": 10, "cnt": 2},
                {"data": 1000008, "lvl": 11, "cnt": 1, "timer": 120},
                {"data": 1000009, "lvl": 15, "timer": 3600}
              ]
            }
            """,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let records = UpgradeTracker.records(from: snapshot, base: .home, at: Date(timeIntervalSince1970: 1_700_000_000))
        let active = UpgradeTracker.activeRecords(from: snapshot, base: .home, at: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.filter { $0.dataID == 1_000_008 }.count, 2)
        XCTAssertEqual(records.first(where: { $0.currentLevel == 10 })?.countLabel, "×2")
        XCTAssertEqual(active.map(\.dataID), [1_000_008, 1_000_009])
        XCTAssertEqual(active.first?.levelLabel, "11 → 12")
    }

    func testActiveRecordsAggregateAllVillagesByRemainingTime() throws {
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstSnapshot = try AccountSnapshotImporter.parse(
            """
            {
              "tag": "#FIRST",
              "timestamp": 1700000000,
              "buildings": [{"data": 1000008, "lvl": 10, "timer": 300}]
            }
            """,
            now: importedAt
        )
        let secondSnapshot = try AccountSnapshotImporter.parse(
            """
            {
              "tag": "#SECOND",
              "timestamp": 1700000000,
              "buildings": [{"data": 1000008, "lvl": 11, "timer": 100}]
            }
            """,
            now: importedAt
        )

        let villages = [
            VillageProfile(name: "第一村", accountSnapshot: firstSnapshot),
            VillageProfile(name: "第二村", accountSnapshot: secondSnapshot)
        ]

        let active = UpgradeTracker.activeRecords(from: villages, at: importedAt)

        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(active.map(\.villageName), ["第二村", "第一村"])
        XCTAssertEqual(active.map(\.remainingSeconds), [100, 300])
        XCTAssertEqual(active.map(\.upgrade.levelLabel), ["11 → 12", "10 → 11"])
        XCTAssertEqual(active.map(\.base), [.home, .home])
        XCTAssertEqual(active.map(\.villageTag), ["#SECOND", "#FIRST"])
    }

    func testOldVillageStorageDecodesWithoutPlannerInput() throws {
        let data = Data(
            """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "name": "旧村庄",
              "input": {"tasks": [], "researchTasks": []},
              "accountSnapshot": null,
              "createdAt": 0,
              "updatedAt": 0
            }
            """.utf8
        )

        let profile = try JSONDecoder().decode(VillageProfile.self, from: data)

        XCTAssertEqual(profile.name, "旧村庄")
        XCTAssertNil(profile.accountSnapshot)
        XCTAssertFalse(profile.hasImportedData)
    }
}
