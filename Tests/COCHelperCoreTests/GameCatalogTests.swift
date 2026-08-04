import XCTest
@testable import COCHelperCore

final class GameCatalogTests: XCTestCase {
    func testLoadBundledDecodesRealCatalog() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        XCTAssertEqual(catalog.gameVersion, "18.400.13")
        XCTAssertGreaterThan(catalog.items(in: "buildings").count, 0)
        XCTAssertNotNil(catalog.item(section: "units", dataID: 4_000_000)) // 野蛮人
        XCTAssertNotNil(catalog.item(section: "buildings", dataID: 1_000_000)) // 兵营
    }

    func testLoadBundledUnknownVersionReturnsNil() {
        XCTAssertNil(GameCatalog.loadBundled(version: "99.0.0"))
    }

    func testBundledLoadPerformanceIsReasonable() {
        // 2.9MB 目录不得阻塞启动：用 measure 记录基线，CI 慢机器上有余量。
        measure { _ = GameCatalog.loadBundled() }
    }

    func testItemLookupUsesExactSectionAndDataID() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        XCTAssertNil(catalog.item(section: "units", dataID: 1_000_000))
        XCTAssertNil(catalog.item(section: "buildings2", dataID: 1_000_000))
    }

    func testBuildingDurationIsBuildToLevelSemantics() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barracks = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_000))
        // 兵营 level 2 dur=300s：从 1 升 2 的完整时长 = levels[nextLevel=2]
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 2, for: barracks), 300)
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 3, for: barracks), 1800)
    }

    func testUnitDurationIsUpgradeFromLevelSemantics() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barbarian = try XCTUnwrap(catalog.item(section: "units", dataID: 4_000_000))
        // 目录生成时已统一：levels[N] = 升级到 N 级。野蛮人升到 2 级 = 1800s（从 1 升 2）。
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 2, for: barbarian), 1800)
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 3, for: barbarian), 3600)
        // 满级 13 级时长 = 1,080,000s（#13 验收值：从 12 升 13）。
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 13, for: barbarian), 1_080_000)
    }

    func testDurationNilWhenLevelRecordMissing() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barracks = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_000))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 999, for: barracks))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 0, for: barracks))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 1, for: barracks))
    }

    func testEquipmentDurationStaysNil() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let puppet = try XCTUnwrap(catalog.item(section: "equipment", dataID: 90_000_000))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 4, for: puppet))
    }

    func testCatalogItemIDAndLevelIDsAreStable() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let item = try XCTUnwrap(catalog.item(section: "heroes", dataID: 28_000_000))
        XCTAssertEqual(item.id, "heroes:28000000")
        XCTAssertEqual(item.levels.map(\.id).first, "1")
    }

    func testMaxLevelAndNameFromCatalog() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barbarian = try XCTUnwrap(catalog.item(section: "units", dataID: 4_000_000))
        XCTAssertEqual(barbarian.name, "野蛮人")
        XCTAssertEqual(barbarian.maxLevel, 13)
    }

    // MARK: - Property-based

    /// 时长查询必须统一：levels[N].durationSeconds = 升级到 N 级的时长（随机物品 × 随机目标等级）。
    /// 覆盖主村与建筑工人基地全部 section，验证统一语义。
    func testPropertyDurationSemanticsMatchTableType() throws {
        var rng = SeededRNG(seed: 555)
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let sections = ["buildings", "buildings2", "traps", "traps2", "units", "units2",
                        "spells", "heroes", "heroes2", "pets", "equipment", "guardians",
                        "siege_machines"]
        let allItems = sections.flatMap { catalog.items(in: $0) }
        XCTAssertFalse(allItems.isEmpty)
        for _ in 0..<300 {
            let item = allItems[Int.random(in: 0..<allItems.count, using: &rng)]
            let nextLevel = Int.random(in: 2...20, using: &rng)
            let actual = catalog.durationToUpgradeLevel(nextLevel: nextLevel, for: item)
            let expected = item.levels.first(where: { $0.level == nextLevel })?.durationSeconds
            XCTAssertEqual(actual, expected, "\(item.section) \(item.dataID) nextLevel=\(nextLevel)")
        }
    }
}
