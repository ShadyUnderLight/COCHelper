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

    func testBundledLoadPerformanceIsReasonable() throws {
        // 2.9MB 目录解码必须在可接受范围内（启动路径），CI 慢机器留 5s 余量。
        let start = Date()
        XCTAssertNotNil(GameCatalog.loadBundled())
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0, "目录解码耗时 \(elapsed)s 超出启动预算")
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
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: -1, for: barracks))
    }

    func testLevelOneDurationReturnsBuildTimeForBuildings() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barracks = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_000))
        // 建筑系 levels[1] = 0→1 初始建造时长（非 nil）；快照可能出现 level=0 的新建建筑。
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 1, for: barracks), 60)
        // 单位系 levels[1] 恒为初始等级 nil。
        let barbarian = try XCTUnwrap(catalog.item(section: "units", dataID: 4_000_000))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 1, for: barbarian))
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

    /// 随机物品 × 随机目标等级的查表一致性（不承担语义锚点，见下两个测试）。
    func testPropertyDurationLookupMatchesLevelRecords() throws {
        var rng = SeededRNG(seed: 555)
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let sections = ["buildings", "buildings2", "traps", "traps2", "units", "units2",
                        "spells", "heroes", "heroes2", "pets", "equipment", "guardians",
                        "siege_machines"]
        let allItems = sections.flatMap { catalog.items(in: $0) }
        XCTAssertFalse(allItems.isEmpty)
        for _ in 0..<300 {
            let item = allItems[Int.random(in: 0..<allItems.count, using: &rng)]
            let nextLevel = Int.random(in: 1...20, using: &rng)
            let actual = catalog.durationToUpgradeLevel(nextLevel: nextLevel, for: item)
            let expected = item.levels.first(where: { $0.level == nextLevel })?.durationSeconds
            XCTAssertEqual(actual, expected, "\(item.section) \(item.dataID) nextLevel=\(nextLevel)")
        }
    }

    /// 语义锚点：跨 section 硬编码已知真实值（来自 18.400.13 目录，含 #13 验收值）。
    func testDurationKnownValuesAcrossSections() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        func duration(_ section: String, _ dataID: Int64, _ nextLevel: Int) -> Int64? {
            guard let item = catalog.item(section: section, dataID: dataID) else { return nil }
            return catalog.durationToUpgradeLevel(nextLevel: nextLevel, for: item)
        }
        // 建筑系（BuildTime）：levels[N] = 升级到 N 级，levels[1] = 0→1 建造时长。
        XCTAssertEqual(duration("buildings", 1_000_000, 1), 60)      // 兵营 0→1
        XCTAssertEqual(duration("buildings", 1_000_000, 2), 300)      // 兵营 1→2
        XCTAssertEqual(duration("buildings", 1_000_000, 3), 1800)     // 兵营 2→3
        // 单位系（UpgradeTime 已映射）：野蛮人 1→2 = 1800s，满级 12→13 = 1,080,000s（#13 验收值）。
        XCTAssertEqual(duration("units", 4_000_000, 2), 1800)
        XCTAssertEqual(duration("units", 4_000_000, 3), 3600)
        XCTAssertEqual(duration("units", 4_000_000, 13), 1_080_000)
        XCTAssertNil(duration("units", 4_000_000, 1))                  // 初始等级
        // 建筑工人基地（BuildTime 系同样语义）。
        XCTAssertEqual(duration("buildings2", 1_000_033, 1), 0)       // BB 城墙 0→1 = 0s（CSV 空值=0）
        // 装备：所有等级无直接升级时长，必须保持 nil。
        XCTAssertNil(duration("equipment", 90_000_000, 2))
        XCTAssertNil(duration("equipment", 90_000_000, 3))
    }

    /// 非连续等级：等级号保留源表原值（#13 约定），按 level 值查找而非下标。
    func testDurationHandlesNonContiguousLevels() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        // 超级飞龙 units 4000081：levels 从 3 开始（3..8），无 level 1/2 记录。
        let dragon = try XCTUnwrap(catalog.item(section: "units", dataID: 4_000_081))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 2, for: dragon),
                     "无 level 2 记录应返回 nil 而非越界/错位")
        let expectedL3 = dragon.levels.first(where: { $0.level == 3 })?.durationSeconds
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 3, for: dragon), expectedL3)
    }
}
