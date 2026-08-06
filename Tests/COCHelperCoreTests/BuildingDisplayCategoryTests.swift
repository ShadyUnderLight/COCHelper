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

    func testNestedChildOfNonCraftTableFallsThrough() {
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 103000011, base: .home, rootParentDataID: 1000008
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
            XCTAssertTrue(
                result == nil || result == .defense || result == .military || result == .craftTable,
                "非法结果 \(String(describing: result))"
            )
            // 不变量：非 home / 非 buildings 一律 nil
            if section != "buildings" || base != .home {
                XCTAssertNil(result, "\(section)/\(base) 不应细分")
            }
        }
    }
}
