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
        XCTAssertTrue(
            defenses.allSatisfy { $0.availability == .permanent },
            "103000011...013 在 lifecycle 声明中为 permanent，接线后不得推断为未配置"
        )
    }

    func testOfficialBundledPhaseMarksHistoricalDefenseEnded() throws {
        let defense = AccountItem(
            id: "buildings:0.types.0",
            section: "buildings",
            dataID: 103_000_009
        )
        let root = AccountItem(
            id: "buildings:0",
            section: "buildings",
            dataID: BuildingDisplayCategoryRules.craftTableDataID,
            types: [defense]
        )
        let village = VillageProfile(
            name: "历史快照",
            accountSnapshot: AccountSnapshot(
                tag: "#HISTORY",
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
        let phases = SeasonalPhaseTable.loadBundled(version: GameCatalog.defaultBundledVersion)

        let projected = CraftTableProjection.project(
            village: village,
            catalog: catalog,
            base: .home,
            seasonalPhases: phases,
            now: Date(timeIntervalSince1970: 1_785_600_000)
        )

        XCTAssertEqual(
            projected.first?.availability,
            .seasonal(
                phaseID: "crafted-defenses-2026-04-sound-of-clash",
                phaseName: "Crafted Defenses: Builder Base Goes Metal",
                status: .ended
            )
        )
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

    // MARK: - Issue #98 lifecycle: availability 接线

    /// 精工防御快照（单防御，无模组）：dataID 用 103000008（bundled 声明
    /// seasonalCandidate；测试目录自行声明 lifecycle，不依赖 bundled 数据）。
    private func makeDefenseVillage(defense dataID: Int64) -> VillageProfile {
        let defense = AccountItem(
            id: "buildings:0.types.0",
            section: "buildings",
            dataID: dataID
        )
        let root = AccountItem(
            id: "buildings:0",
            section: "buildings",
            dataID: BuildingDisplayCategoryRules.craftTableDataID,
            types: [defense]
        )
        return VillageProfile(
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
    }

    /// 单防御测试目录（lifecycle 由用例注入；显式 init 是 Task 3 前置修复——
    /// 合成 memberwise init 对 let 默认值省略参数，无法显式传 lifecycle）。
    private func makeDefenseCatalog(lifecycle: CatalogLifecycle?) -> CraftTableCatalog {
        CraftTableCatalog(
            schemaVersion: 1, gameVersion: "18.400.13", buildTag: "test",
            defenses: [CraftTableDefenseSpec(
                dataID: 103_000_008, name: "测试防御", sourceName: "test",
                specialAbility: "", moduleIDs: [], totalModuleLevelThresholds: [],
                lifecycle: lifecycle
            )],
            modules: []
        )
    }

    /// 验收 5：普通防御（catalog 声明 permanent）→ .permanent（空表也不降级）。
    func testDefensePermanentLifecycle() {
        let projected = CraftTableProjection.project(
            village: makeDefenseVillage(defense: 103_000_008),
            catalog: makeDefenseCatalog(lifecycle: .permanent),
            base: .home,
            seasonalPhases: .empty,
            now: Date(timeIntervalSince1970: 1_500)
        )
        XCTAssertEqual(projected.first?.availability, .permanent)
    }

    /// 验收：seasonalCandidate + 阶段表命中 + now 注入活动期 → .seasonal(status: .active)。
    func testDefenseSeasonalCandidatePhaseHit() {
        let table = SeasonalPhaseTable(schemaVersion: 1, phases: [
            SeasonalPhase(
                phaseID: "crafted-defenses-test", name: "测试季",
                from: Date(timeIntervalSince1970: 1_000), until: Date(timeIntervalSince1970: 2_000),
                itemKeys: ["buildings:103000008"]),
        ])
        let projected = CraftTableProjection.project(
            village: makeDefenseVillage(defense: 103_000_008),
            catalog: makeDefenseCatalog(lifecycle: .seasonalCandidate),
            base: .home,
            seasonalPhases: table,
            now: Date(timeIntervalSince1970: 1_500)
        )
        XCTAssertEqual(
            projected.first?.availability,
            .seasonal(phaseID: "crafted-defenses-test", phaseName: "测试季", status: .active))
    }

    /// 验收 6：lifecycle nil（旧目录）+ 阶段表未命中 → .unconfigured
    ///（与 VillageCatalogProjection 的 lifecycle nil 语义一致，不漂移）。
    func testDefenseWithoutLifecycleMissReturnsUnconfigured() {
        let projected = CraftTableProjection.project(
            village: makeDefenseVillage(defense: 103_000_008),
            catalog: makeDefenseCatalog(lifecycle: nil),
            base: .home,
            seasonalPhases: .empty,
            now: Date(timeIntervalSince1970: 1_500)
        )
        XCTAssertEqual(projected.first?.availability, .unconfigured)
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
