import XCTest
@testable import COCHelperCore

final class BuildingDisplayCategoryTests: XCTestCase {
    // MARK: - 防御建筑

    func testDefenseMappings() {
        for id in [1000008, 1000009, 1000010, 1000011, 1000012, 1000013,
                   1000019, 1000021, 1000027, 1000028, 1000031, 1000032,
                   1000067, 1000072, 1000077, 1000079, 1000084, 1000085,
                   1000086, 1000089, 1000102] {
            XCTAssertEqual(
                BuildingDisplayCategoryRules.displayCategory(
                    section: "buildings", dataID: Int64(id), base: .home, rootParentDataID: nil
                ),
                .defense,
                "dataID \(id) 应为防御建筑"
            )
        }
    }

    // MARK: - 军事设施

    func testMilitaryMappings() {
        for id in [1000000, 1000006, 1000007, 1000014, 1000020, 1000026,
                   1000029, 1000059, 1000068, 1000070, 1000071] {
            XCTAssertEqual(
                BuildingDisplayCategoryRules.displayCategory(
                    section: "buildings", dataID: Int64(id), base: .home, rootParentDataID: nil
                ),
                .military,
                "dataID \(id) 应为军事设施"
            )
        }
    }

    // MARK: - 精制台

    func testCraftTableParent() {
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 1000097, base: .home, rootParentDataID: nil
            ),
            .craftTable
        )
    }

    func testCraftTableNestedChild() {
        // 嵌套项自身 dataID（types/modules 段）不在任何白名单，必须按根父归属
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 103000011, base: .home, rootParentDataID: 1000097
            ),
            .craftTable
        )
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 102000041, base: .home, rootParentDataID: 1000097
            ),
            .craftTable
        )
    }

    // MARK: - 不误判

    func testBuilderBaseNeverCraftTable() {
        // 建筑工人基地 1000097 同名建筑（buildings2）不得归入精制台
        XCTAssertNil(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings2", dataID: 1000097, base: .builder, rootParentDataID: nil
            )
        )
    }

    func testBuilderBaseDefenseNotClassified() {
        XCTAssertNil(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings2", dataID: 1000008, base: .builder, rootParentDataID: nil
            )
        )
    }

    func testNonBuildingsSectionNeverClassified() {
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "traps", dataID: 1000008, base: .home, rootParentDataID: nil
        ))
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "units", dataID: 1000000, base: .home, rootParentDataID: nil
        ))
    }

    // MARK: - 兜底

    func testResourceBuildingsFallThroughToNil() {
        for id in [1000001, 1000002, 1000003, 1000004, 1000005, 1000015, 1000023, 1000024] {
            XCTAssertNil(
                BuildingDisplayCategoryRules.displayCategory(
                    section: "buildings", dataID: Int64(id), base: .home, rootParentDataID: nil
                ),
                "dataID \(id) 应兜底（不细分）"
            )
        }
    }

    func testEventBuildingVariantsFallThroughToNil() {
        // Lv1 加农炮变体（事件建筑）与英雄祭坛按投票结论进兜底
        for id in [1000060, 1000087, 1000088, 1000094, 1000095, 1000096,
                   1000022, 1000025, 1000030, 1000066] {
            XCTAssertNil(
                BuildingDisplayCategoryRules.displayCategory(
                    section: "buildings", dataID: Int64(id), base: .home, rootParentDataID: nil
                ),
                "dataID \(id) 应兜底（事件变体/祭坛）"
            )
        }
    }

    func testUnknownIDFallsThroughToNil() {
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 9999999, base: .home, rootParentDataID: nil
        ))
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 0, base: .home, rootParentDataID: nil
        ))
    }

    func testNestedChildInheritsParentCategory() {
        // 嵌套项继承根父展示分类（评审发现）：防御父建筑（加农炮 1000008）的后代
        // 跟随防御、军事父建筑（兵营 1000000）的后代跟随军事——否则后代 displayCategory
        // 为 nil 会落兜底组，与父项跨组分裂成孤儿行。
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 103000011, base: .home, rootParentDataID: 1000008
        ), .defense)
        XCTAssertEqual(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 103000011, base: .home, rootParentDataID: 1000000
        ), .military)
        // 兜底父建筑（大本营 1000001）的后代仍兜底
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 103000011, base: .home, rootParentDataID: 1000001
        ))
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
                section: section, dataID: dataID, base: base, rootParentDataID: rootParent
            )
            // 不变量：非 home / 非 buildings 一律 nil
            if section != "buildings" || base != .home {
                XCTAssertNil(result, "\(section)/\(base) 不应细分")
            }
            // 正方向约束：home + buildings 平铺且非白名单 → 恒 nil（随机 dataID 几乎必然非白名单）
            if section == "buildings", base == .home, !nested,
               !BuildingDisplayCategoryRules.defenseDataIDs.contains(dataID),
               !BuildingDisplayCategoryRules.militaryDataIDs.contains(dataID),
               dataID != BuildingDisplayCategoryRules.craftTableDataID {
                XCTAssertNil(result, "非白名单 home 建筑 dataID \(dataID) 应兜底")
            }
        }
    }

    // MARK: - 白名单穷尽与不相交

    func testWhitelistsAreExhaustiveAndDisjoint() {
        // 穷尽：白名单必须与规则表源码一致（防手改漏项）；集合比较可鉴别顺序与重复。
        XCTAssertEqual(
            BuildingDisplayCategoryRules.defenseDataIDs,
            Set<Int64>([1000008, 1000009, 1000010, 1000011, 1000012, 1000013,
                        1000019, 1000021, 1000027, 1000028, 1000031, 1000032,
                        1000067, 1000072, 1000077, 1000079, 1000084, 1000085,
                        1000086, 1000089, 1000102])
        )
        XCTAssertEqual(
            BuildingDisplayCategoryRules.militaryDataIDs,
            Set<Int64>([1000000, 1000006, 1000007, 1000014, 1000020, 1000026,
                        1000029, 1000059, 1000068, 1000070, 1000071])
        )
        // 不相交：同一 dataID 不得同时归防御与军事（规则表冲突会静默产生歧义）。
        XCTAssertTrue(BuildingDisplayCategoryRules.defenseDataIDs
            .isDisjoint(with: BuildingDisplayCategoryRules.militaryDataIDs))
    }
}
