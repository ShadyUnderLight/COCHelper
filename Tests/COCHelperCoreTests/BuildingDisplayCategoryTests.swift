import XCTest
@testable import COCHelperCore

/// Issue #75 工作流 C：展示分类改为从 catalog displayCategory 字段读取（唯一事实源），
/// Swift 白名单已删除。旧白名单穷尽测试（testDefenseMappings/testMilitaryMappings/
/// testWhitelistsAreExhaustiveAndDisjoint 等）随数据化移除；分类知识由
/// validate.py 闭枚举 + bundled 防漏测试（testBundledCatalogClassificationMatchesIntentionalFallback）
/// 双端锁定。
final class BuildingDisplayCategoryTests: XCTestCase {
    // MARK: - 合成目录

    /// 最小合成目录：防御/城墙/军事/精制台 + 兜底（1000001）+ 未知 raw 值（7777777）。
    /// 分类知识完全来自 CatalogItem.displayCategory 字段——本目录即该字段的
    /// 测试事实源，断言与目录数据一一对应。
    private static func makeSyntheticCatalog() -> GameCatalog {
        func item(_ dataID: Int64, _ displayCategory: String?, name: String) -> CatalogItem {
            CatalogItem(
                section: "buildings", category: "buildings", dataID: dataID,
                base: "home", baseMissingReason: nil, name: name, maxLevel: 1,
                icon: nil, levelVisual: nil, displayCategory: displayCategory, levels: []
            )
        }
        return GameCatalog(gameVersion: "test", items: [
            item(1_000_001, nil, name: "大本营"),
            item(1_000_000, "military", name: "兵营"),
            item(1_000_008, "defense", name: "加农炮"),
            item(1_000_010, "walls", name: "城墙"),
            item(1_000_097, "craftTable", name: "精制台"),
            item(7_777_777, "unknownRaw", name: "未知分类"),
        ])
    }

    private var syntheticCatalog: GameCatalog!

    override func setUpWithError() throws {
        syntheticCatalog = Self.makeSyntheticCatalog()
    }

    // MARK: - 分类判定（catalog 驱动）

    func testDefenseFromCatalog() {
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 1000008, base: .home,
                rootParentDataID: nil, catalog: syntheticCatalog
            ),
            .defense
        )
    }

    func testWallsFromCatalog() {
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 1000010, base: .home,
                rootParentDataID: nil, catalog: syntheticCatalog
            ),
            .walls
        )
    }

    func testMilitaryFromCatalog() {
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 1000000, base: .home,
                rootParentDataID: nil, catalog: syntheticCatalog
            ),
            .military
        )
    }

    // MARK: - 精制台

    func testCraftTableParent() {
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 1000097, base: .home,
                rootParentDataID: nil, catalog: syntheticCatalog
            ),
            .craftTable
        )
    }

    func testCraftTableNestedChild() {
        // 嵌套项自身 dataID（types/modules 段）不在目录，必须按根父 dataID 归属
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 103000011, base: .home,
                rootParentDataID: 1000097, catalog: syntheticCatalog
            ),
            .craftTable
        )
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 102000041, base: .home,
                rootParentDataID: 1000097, catalog: syntheticCatalog
            ),
            .craftTable
        )
    }

    // MARK: - 不误判

    func testBuilderBaseNeverCraftTable() {
        // 建筑工人基地 1000097 同名建筑（buildings2）不得归入精制台
        XCTAssertNil(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings2", dataID: 1000097, base: .builder,
                rootParentDataID: nil, catalog: syntheticCatalog
            )
        )
    }

    func testBuilderBaseDefenseNotClassified() {
        XCTAssertNil(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings2", dataID: 1000008, base: .builder,
                rootParentDataID: nil, catalog: syntheticCatalog
            )
        )
    }

    func testWallsNotClassifiedOutsideHomeBuildings() {
        // 构造场景：buildings2 中构造与主世界城墙同 dataID 1000010 的条目
        //（真实目录中夜世界城墙为 buildings2:1000033，buildings2 不存在 1000010；
        // 构造同号是越界测试的最坏情况）→ 不得归入城墙组
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings2", dataID: 1000010, base: .builder, rootParentDataID: nil, catalog: syntheticCatalog
        ))
        // 都城城墙（capital_buildings，dataID 110000002）不越界：非 buildings section 不细分
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "capital_buildings", dataID: 110000002, base: .home, rootParentDataID: nil, catalog: syntheticCatalog
        ))
    }

    func testNonBuildingsSectionNeverClassified() {
        // 即使 catalog 中 1000008 标注 defense，非 buildings section 也不细分
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "traps", dataID: 1000008, base: .home, rootParentDataID: nil, catalog: syntheticCatalog
        ))
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "units", dataID: 1000000, base: .home, rootParentDataID: nil, catalog: syntheticCatalog
        ))
    }

    // MARK: - 兜底

    func testCatalogItemWithoutCategoryFallsThroughToNil() {
        // 1000001 在合成目录中存在但 displayCategory == nil → 兜底（大本营）
        XCTAssertNil(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 1000001, base: .home,
                rootParentDataID: nil, catalog: syntheticCatalog
            )
        )
    }

    func testUnknownIDFallsThroughToNil() {
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 9999999, base: .home, rootParentDataID: nil, catalog: syntheticCatalog
        ))
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 0, base: .home, rootParentDataID: nil, catalog: syntheticCatalog
        ))
    }

    func testNestedChildInheritsParentCategory() {
        // 嵌套项继承根父展示分类：防御父建筑（加农炮 1000008）的后代跟随防御、
        // 军事父建筑（兵营 1000000）的后代跟随军事——否则后代 displayCategory
        // 为 nil 会落兜底组，与父项跨组分裂成孤儿行。
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 103000011, base: .home,
            rootParentDataID: 1000008, catalog: syntheticCatalog
        ), .defense)
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 103000011, base: .home,
            rootParentDataID: 1000000, catalog: syntheticCatalog
        ), .military)
        // 兜底父建筑（大本营 1000001）的后代仍兜底
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 103000011, base: .home,
            rootParentDataID: 1000001, catalog: syntheticCatalog
        ))
    }

    // MARK: - 安全回退（catalog 缺失 / 未知 raw / 旧目录）

    func testCatalogNilFallsBackToNil() {
        // catalog == nil → 除精制台身份回退外全 nil（UI 兜底「建筑与防御」，项目不丢失）
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000008, base: .home, rootParentDataID: nil, catalog: nil
        ))
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 103000011, base: .home,
            rootParentDataID: 1000008, catalog: nil
        ))
    }

    // MARK: - 精制台最小分类回退（评审 P2）

    func testCraftTableFallsBackWhenCatalogMissing() {
        // 主 catalog 不可用时精制台仍分类（#65 CraftTableView 门控依赖）——
        // 身份常量最小回退，不恢复 defense/military 白名单。
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000097, base: .home, rootParentDataID: nil, catalog: nil
        ), .craftTable)
    }

    func testCraftTableFallsBackWhenFieldMissingInCatalog() {
        // 旧目录：1000097 item 存在但 displayCategory 字段缺失（init 默认 nil）→ 回退
        let item = CatalogItem(
            section: "buildings", category: "buildings", dataID: 1_000_097,
            base: "home", baseMissingReason: nil, name: "精制台", maxLevel: 1,
            icon: nil, levelVisual: nil, levels: []
        )
        let legacy = GameCatalog(gameVersion: "old", items: [item])
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000097, base: .home, rootParentDataID: nil, catalog: legacy
        ), .craftTable)
    }

    func testCraftTableFallbackNotAppliedToOtherIDs() {
        // 对照组：非精制台 dataID catalog nil → 不回退
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000008, base: .home, rootParentDataID: nil, catalog: nil
        ))
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000000, base: .home, rootParentDataID: nil, catalog: nil
        ))
    }

    func testCraftTableUnknownRawValueStillFallsBackToNil() {
        // 有值但未知 raw（契约外）→ 仍 nil（纵深防御，不回退——错标由 validate 拦截）
        let item = CatalogItem(
            section: "buildings", category: "buildings", dataID: 1_000_097,
            base: "home", baseMissingReason: nil, name: "精制台", maxLevel: 1,
            icon: nil, levelVisual: nil, displayCategory: "unknownRaw", levels: []
        )
        let catalog = GameCatalog(gameVersion: "test", items: [item])
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000097, base: .home, rootParentDataID: nil, catalog: catalog
        ))
    }

    func testUnknownRawValueFallsBackToNil() {
        // catalog 中 displayCategory 是未知字符串（契约外）→ nil（防御性兜底；
        // catalog 数据已由 validate 闭枚举保证，此处是 Swift 侧纵深防御）。
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 7_777_777, base: .home, rootParentDataID: nil, catalog: syntheticCatalog
        ))
    }

    func testLegacyCatalogWithoutDisplayCategoryFallsBackToNil() {
        // 旧目录：CatalogItem 无 displayCategory 字段（init 默认 nil）→
        // 非精制台全 nil（安全回退）；精制台 1000097 身份回退 .craftTable（评审 P2）。
        let item = CatalogItem(
            section: "buildings", category: "buildings", dataID: 1_000_008,
            base: "home", baseMissingReason: nil, name: "加农炮", maxLevel: 1,
            icon: nil, levelVisual: nil, levels: []
        )
        let legacy = GameCatalog(gameVersion: "old", items: [item])
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000008, base: .home, rootParentDataID: nil, catalog: legacy
        ))
        // 1000097 不在旧目录（item 缺失）→ 身份常量最小回退
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000097, base: .home, rootParentDataID: nil, catalog: legacy
        ), .craftTable)
    }

    // MARK: - bundled 目录防漏（唯一事实源 = catalog）

    /// 防漏机制：bundled 目录 home buildings 中 displayCategory == nil 的 dataID
    /// 必须 == 本测试硬编码的有意兜底集合（40 项，与 Python
    /// display_categories.INTENTIONAL_FALLBACK_DATA_IDS 一致）。新建筑漏分类会
    /// 出现在未分类集 → 测试红 → 人工裁决（补 displayCategory 或扩充兜底集合）。
    func testBundledCatalogClassificationMatchesIntentionalFallback() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let unclassified = Set(
            catalog.items(in: "buildings")
                .filter { $0.base == "home" && $0.displayCategory == nil }
                .map(\.dataID)
        )
        let intentionalFallback: Set<Int64> = [
            1000001, 1000002, 1000003, 1000004, 1000005, 1000015, 1000016, 1000017,
            1000018, 1000022, 1000023, 1000024, 1000025, 1000030, 1000060, 1000061,
            1000062, 1000064, 1000066, 1000069, 1000073, 1000074, 1000075, 1000076,
            1000083, 1000087, 1000088, 1000090, 1000091, 1000092, 1000093, 1000094,
            1000095, 1000096, 1000098, 1000099, 1000100, 1000101, 1000103, 1000104,
        ]
        XCTAssertEqual(
            unclassified.count, intentionalFallback.count,
            "未分类数 = \(unclassified.count)，有意兜底 = \(intentionalFallback.count)"
        )
        XCTAssertEqual(
            unclassified, intentionalFallback,
            "未分类集合与有意兜底不一致：新增 \(unclassified.subtracting(intentionalFallback))，移除 \(intentionalFallback.subtracting(unclassified))——新建筑漏分类需人工裁决"
        )
    }

    /// bundled 目录分类 spot-check：精制台/防御/城墙/军事命中，大本营兜底。
    func testBundledCatalogKnownClassifications() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000097, base: .home, rootParentDataID: nil, catalog: catalog
        ), .craftTable)
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000008, base: .home, rootParentDataID: nil, catalog: catalog
        ), .defense)
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000010, base: .home, rootParentDataID: nil, catalog: catalog
        ), .walls)
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000000, base: .home, rootParentDataID: nil, catalog: catalog
        ), .military)
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 1000001, base: .home, rootParentDataID: nil, catalog: catalog
        ))
    }

    /// 防漏机制（已分类端，评审补强）：bundled 目录 home buildings 中
    /// displayCategory 非 nil 的 dataID 必须 == 本测试硬编码的 33 项已分类集合
    /// （20 defense + 1 walls + 11 military + 1 craftTable，与 Python
    /// display_categories 注册表一致），按值分四个子集合精确断言。与
    /// testBundledCatalogClassificationMatchesIntentionalFallback（未分类端）互补，
    /// 双端锁死：登记表内错标分类（如 1000008→military）在此必红。
    func testBundledCatalogClassifiedSetsMatchIntentionalClassifications() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let classified = catalog.items(in: "buildings")
            .filter { $0.base == "home" && $0.displayCategory != nil }
        let defense = Set(classified.filter { $0.displayCategory == "defense" }.map(\.dataID))
        let walls = Set(classified.filter { $0.displayCategory == "walls" }.map(\.dataID))
        let military = Set(classified.filter { $0.displayCategory == "military" }.map(\.dataID))
        let craftTable = Set(classified.filter { $0.displayCategory == "craftTable" }.map(\.dataID))
        let expectedDefense: Set<Int64> = [
            1000008, 1000009, 1000011, 1000012, 1000013, 1000019,
            1000021, 1000027, 1000028, 1000031, 1000032, 1000067, 1000072,
            1000077, 1000079, 1000084, 1000085, 1000086, 1000089, 1000102,
        ]
        let expectedWalls: Set<Int64> = [1000010]
        let expectedMilitary: Set<Int64> = [
            1000000, 1000006, 1000007, 1000014, 1000020, 1000026, 1000029,
            1000059, 1000068, 1000070, 1000071,
        ]
        let expectedCraftTable: Set<Int64> = [1000097]
        XCTAssertEqual(defense, expectedDefense,
                       "defense 集合不一致：新增 \(defense.subtracting(expectedDefense))，移除 \(expectedDefense.subtracting(defense))")
        XCTAssertEqual(walls, expectedWalls,
                       "walls 集合不一致：新增 \(walls.subtracting(expectedWalls))，移除 \(expectedWalls.subtracting(walls))")
        XCTAssertEqual(military, expectedMilitary,
                       "military 集合不一致：新增 \(military.subtracting(expectedMilitary))，移除 \(expectedMilitary.subtracting(military))")
        XCTAssertEqual(craftTable, expectedCraftTable,
                       "craftTable 集合不一致：\(craftTable)")
        // 四子集互斥 + 全覆盖 = 33 已分类项（73 home − 40 兜底）
        XCTAssertEqual(defense.count + walls.count + military.count + craftTable.count, 33)
    }

    // MARK: - rootID 解析

    func testRootIDParsing() {
        XCTAssertEqual(BuildingDisplayCategoryRules.rootID(of: "buildings:6.types.0.modules.2"), "buildings:6")
        XCTAssertEqual(BuildingDisplayCategoryRules.rootID(of: "buildings:6"), "buildings:6")
        XCTAssertEqual(BuildingDisplayCategoryRules.rootID(of: "traps:0"), "traps:0")
    }

    // MARK: - Property-based（固定种子可复现）

    func testPropertyRulesNeverCrashAndStayInDomain() {
        var rng = SeededRNG(seed: 0x13_37)
        let sections = ["buildings", "buildings2", "traps", "units", "spells", "heroes", "equipment"]
        for _ in 0..<2000 {
            let section = sections[Int(rng.next() % UInt64(sections.count))]
            let dataID = Int64(rng.next() % 2_000_000)
            let base: TrackerBase = rng.next() % 2 == 0 ? .home : .builder
            let nested = rng.next() % 2 == 0
            let rootParent: Int64? = nested ? Int64(rng.next() % 2_000_000) : nil
            let result = BuildingDisplayCategoryRules.displayCategory(
                section: section, dataID: dataID, base: base,
                rootParentDataID: rootParent, catalog: syntheticCatalog
            )
            // 不变量：非 home / 非 buildings 一律 nil
            if section != "buildings" || base != .home {
                XCTAssertNil(result, "\(section)/\(base) 不应细分")
                continue
            }
            // 正方向约束：分类完全由 catalog 驱动——只有合成目录中显式标注的
            // dataID（或其根父）有分类，其余一律 nil（随机 dataID 几乎必然不在目录；
            // 1000001 兜底项与 7777777 未知 raw 项同样归 nil）。
            let effectiveID = rootParent ?? dataID
            let expected: TrackerDisplayCategory? = {
                switch effectiveID {
                case 1_000_008: return .defense
                case 1_000_010: return .walls
                case 1_000_000: return .military
                case 1_000_097: return .craftTable
                default: return nil
                }
            }()
            XCTAssertEqual(result, expected,
                           "dataID \(dataID) rootParent \(String(describing: rootParent)) 分类不符")
        }
    }
}
