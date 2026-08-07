import XCTest
@testable import COCHelperCore

final class CraftTableProjectionTests: XCTestCase {
    func testRealFixtureProjectsDefenseRowsAndModuleOrder() throws {
        let village = try fixtureVillage()
        let catalog = try XCTUnwrap(CraftTableCatalog.loadBundled())

        let defenses = CraftTableProjection.project(
            village: village,
            catalog: catalog,
            base: .home,
            now: Date(timeIntervalSince1970: 1_785_736_333)
        )

        XCTAssertEqual(defenses.map(\.dataID), [103_000_011, 103_000_012, 103_000_013])
        XCTAssertEqual(defenses.map(\.name), ["火热蜡烛", "英雄猎台", "蛋糕投掷器"])
        XCTAssertEqual(defenses.flatMap(\.modules).count, 9)
        XCTAssertEqual(defenses.first?.modules.map(\.dataID), [102_000_033, 102_000_034, 102_000_035])
        XCTAssertTrue(defenses.flatMap(\.modules).allSatisfy { $0.maxLevel == 10 })
        XCTAssertTrue(defenses.flatMap(\.modules).allSatisfy { $0.status == .recorded })
    }

    func testObservedOrderIsPreservedAndMissingExpectedModuleIsMarkedUnknown() throws {
        let observedModule = AccountItem(
            id: "buildings:0.types.0.modules.0",
            section: "buildings",
            dataID: 102_000_035,
            level: 2
        )
        let upgradingModule = AccountItem(
            id: "buildings:0.types.0.modules.1",
            section: "buildings",
            dataID: 102_000_033,
            level: 1,
            timerSeconds: 100,
            remainingSeconds: 40
        )
        let defense = AccountItem(
            id: "buildings:0.types.0",
            section: "buildings",
            dataID: 103_000_011,
            modules: [observedModule, upgradingModule]
        )
        let root = AccountItem(
            id: "buildings:0",
            section: "buildings",
            dataID: BuildingDisplayCategoryRules.craftTableDataID,
            types: [defense]
        )
        let village = VillageProfile(
            name: "测试村庄",
            accountSnapshot: AccountSnapshot(
                tag: "#TEST",
                capturedAt: nil,
                importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                ageSeconds: nil,
                originalText: "",
                objectSections: ["buildings": [root]],
                numericSections: [:],
                boosts: [:],
                unknownTopLevelKeys: [],
                diagnostics: []
            )
        )
        let catalog = try XCTUnwrap(CraftTableCatalog.loadBundled())

        let modules = try XCTUnwrap(
            CraftTableProjection.project(
                village: village,
                catalog: catalog,
                base: .home,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            ).first?.modules
        )

        XCTAssertEqual(modules.map(\.dataID), [102_000_035, 102_000_033, 102_000_034])
        XCTAssertEqual(modules[0].status, .recorded)
        XCTAssertEqual(modules[1].status, .upgrading)
        XCTAssertEqual(modules[1].nextLevel, 2)
        XCTAssertEqual(modules[2].status, .unknown)
        XCTAssertEqual(modules[2].maxLevel, 10)
        XCTAssertEqual(modules[2].missingReason, "快照未包含该模组")
    }

    func testMissingCatalogDoesNotInventModuleMaxLevel() {
        let module = AccountItem(
            id: "buildings:0.types.0.modules.0",
            section: "buildings",
            dataID: 102_000_033,
            level: 1
        )
        let defense = AccountItem(
            id: "buildings:0.types.0",
            section: "buildings",
            dataID: 103_000_011,
            modules: [module]
        )
        let root = AccountItem(
            id: "buildings:0",
            section: "buildings",
            dataID: BuildingDisplayCategoryRules.craftTableDataID,
            types: [defense]
        )
        let village = VillageProfile(
            name: "测试村庄",
            accountSnapshot: AccountSnapshot(
                tag: nil,
                capturedAt: nil,
                importedAt: Date(),
                ageSeconds: nil,
                originalText: "",
                objectSections: ["buildings": [root]],
                numericSections: [:],
                boosts: [:],
                unknownTopLevelKeys: [],
                diagnostics: []
            )
        )

        let projected = CraftTableProjection.project(village: village, catalog: nil, base: .home)
        XCTAssertEqual(projected.first?.modules.first?.status, .unknown)
        XCTAssertNil(projected.first?.modules.first?.maxLevel)
        XCTAssertEqual(projected.first?.modules.first?.missingReason, "版本化精制台目录未收录该模组")
    }

    func testModuleTimerAdvancesAndReachesReimportState() throws {
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let module = AccountItem(
            id: "buildings:0.types.0.modules.0",
            section: "buildings",
            dataID: 102_000_033,
            level: 1,
            timerSeconds: 120,
            remainingSeconds: 120
        )
        let defense = AccountItem(
            id: "buildings:0.types.0",
            section: "buildings",
            dataID: 103_000_011,
            modules: [module]
        )
        let root = AccountItem(
            id: "buildings:0",
            section: "buildings",
            dataID: BuildingDisplayCategoryRules.craftTableDataID,
            types: [defense]
        )
        let village = VillageProfile(
            name: "测试村庄",
            accountSnapshot: AccountSnapshot(
                tag: "#TEST",
                capturedAt: nil,
                importedAt: importedAt,
                ageSeconds: nil,
                originalText: "",
                objectSections: ["buildings": [root]],
                numericSections: [:],
                boosts: [:],
                unknownTopLevelKeys: [],
                diagnostics: []
            )
        )
        let catalog = try XCTUnwrap(CraftTableCatalog.loadBundled())

        let halfway = try XCTUnwrap(
            CraftTableProjection.project(
                village: village,
                catalog: catalog,
                base: .home,
                now: importedAt.addingTimeInterval(60)
            ).first?.modules.first
        )
        XCTAssertEqual(halfway.remainingSeconds, 60)
        XCTAssertTrue(halfway.isUpgrading)
        XCTAssertFalse(halfway.needsReimport)

        let finished = try XCTUnwrap(
            CraftTableProjection.project(
                village: village,
                catalog: catalog,
                base: .home,
                now: importedAt.addingTimeInterval(120)
            ).first?.modules.first
        )
        XCTAssertEqual(finished.remainingSeconds, 0)
        XCTAssertFalse(finished.isUpgrading)
        XCTAssertTrue(finished.needsReimport)
    }

    private func fixtureVillage() throws -> VillageProfile {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "anonymized_account_snapshot", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let snapshot = try AccountSnapshotImporter.parse(
            String(data: data, encoding: .utf8) ?? "",
            now: Date(timeIntervalSince1970: 1_785_736_333)
        )
        return VillageProfile(name: "fixture", accountSnapshot: snapshot)
    }
}
