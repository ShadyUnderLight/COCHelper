import XCTest
@testable import COCHelperCore

/// Issue #16：村庄详情页分组与完成度统计。
final class VillageDetailProjectionTests: XCTestCase {
    // MARK: - Helpers

    private func item(
        id: String = "id",
        category: TrackerCategory? = .buildings,
        displayCategory: TrackerDisplayCategory? = nil,
        nested: Bool = false,
        status: VillageItemStatus = .complete,
        level: Int? = 3,
        maxLevel: Int? = 10,
        isUpgrading: Bool = false,
        nextLevel: Int? = nil
    ) -> VillageItemState {
        let effectiveNext = nextLevel ?? (isUpgrading ? level.map { $0 + 1 } : nil)
        return VillageItemState(
            id: id,
            section: "buildings",
            dataID: 1,
            base: .home,
            name: "item-" + id,
            category: category,
            currentLevel: level,
            count: 1,
            timerSeconds: isUpgrading ? 3600 : nil,
            remainingSeconds: isUpgrading ? 1800 : nil,
            nextLevel: effectiveNext,
            nextLevelDurationSeconds: isUpgrading ? 3600 : nil,
            maxLevel: maxLevel,
            status: status,
            missingReason: nil,
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: nested,
            displayCategory: displayCategory
        )
    }

    private func stat(_ c: VillageCategoryCompletion) -> (known: Int, completed: Int, unknown: Int) {
        (c.knownCount, c.completedCount, c.unknownCount)
    }

    // MARK: - 分组

    func testGroupsPreserveOrderAndItems() {
        let a = item(id: "a", category: .traps, status: .complete)
        let b = item(id: "b", category: .buildings, status: .maxed)
        let c = item(id: "c", category: nil, status: .unavailable)
        let items = [a, b, c]
        let groups = VillageDetailProjection.groups(from: items)
        // 稳定分组：无丢失、无重复（组间按 sortOrder 重排，flatten 顺序 ≠ 输入顺序）
        XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(), items.map(\.id).sorted())
        // 组内保持输入相对顺序：每组 == 输入中同 category 的子序列
        for group in groups {
            XCTAssertEqual(group.items, items.filter { $0.category == group.category })
        }
    }

    func testGroupsOrderBySortOrderWithOtherLast() {
        let a = item(id: "a", category: .troops)
        let b = item(id: "b", category: .buildings)
        let c = item(id: "c", category: nil)
        let groups = VillageDetailProjection.groups(from: [a, b, c])
        XCTAssertEqual(groups.map(\.category), [.buildings, .troops, nil])
    }

    func testGroupIDsUniqueAndStable() {
        let items = (0..<20).map { item(id: "i\($0)", category: [TrackerCategory?]([.buildings, .traps, .heroes, nil])[$0 % 4]) }
        let groups = VillageDetailProjection.groups(from: items)
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(), items.map(\.id).sorted())
    }

    func testGroupItemsShareCategory() {
        let items = (0..<10).map { item(id: "i\($0)", category: $0 % 2 == 0 ? .spells : nil) }
        for group in VillageDetailProjection.groups(from: items) {
            XCTAssertTrue(group.items.allSatisfy { $0.category == group.category })
        }
    }

    // MARK: - 完成度（穷举 status × level/maxLevel 组合）

    func testCompletionCountsByStatus() {
        let cases: [(VillageItemStatus, (Int, Int, Int))] = [
            (.complete, (1, 0, 0)),
            (.maxed, (1, 1, 0)),
            (.upgrading, (1, 0, 0)),
            (.unknown, (0, 0, 1)),
            (.unavailable, (0, 0, 1)),
        ]
        for (status, expected) in cases {
            let level = 3, maxLevel = 10
            let it = item(status: status, level: level, maxLevel: maxLevel,
                          isUpgrading: status == .upgrading,
                          nextLevel: status == .upgrading ? level + 1 : nil)
            let total = VillageDetailProjection.totalCompletion(from: [it])
            XCTAssertTrue(stat(total) == expected, "status=\(status), got \(stat(total))")
        }
    }

    func testMaxedWithoutMaxLevelCountsUnknown() {
        let it = item(status: .maxed, level: 10, maxLevel: nil)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertTrue(stat(total) == (0, 0, 1), "got \(stat(total))")
    }

    func testUpgradingBeyondMaxIsVersionMismatchUnknown() {
        let it = item(status: .upgrading, level: 10, maxLevel: 10, isUpgrading: true, nextLevel: 11)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertTrue(stat(total) == (0, 0, 1), "got \(stat(total))")
    }

    func testUpgradingAtMaxBoundaryIsKnown() {
        let it = item(status: .upgrading, level: 9, maxLevel: 10, isUpgrading: true, nextLevel: 10)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertTrue(stat(total) == (1, 0, 0), "got \(stat(total))")
    }

    func testNilLevelCountsUnknown() {
        let it = item(status: .complete, level: nil, maxLevel: 10)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertTrue(stat(total) == (0, 0, 1), "got \(stat(total))")
    }

    func testUpgradingWithoutMaxLevelCountsUnknown() {
        // 目录未命中但计时中（上游可达：upgrading 分支独立于目录）
        let it = item(status: .upgrading, level: 3, maxLevel: nil, isUpgrading: true, nextLevel: 4)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertTrue(stat(total) == (0, 0, 1), "got \(stat(total))")
    }

    func testUpgradingWithoutLevelCountsUnknown() {
        // malformed 记录：计时中但等级未知（上游可达）
        let it = item(status: .upgrading, level: nil, maxLevel: 10, isUpgrading: true, nextLevel: nil)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertTrue(stat(total) == (0, 0, 1), "got \(stat(total))")
    }

    func testAvailableCountsUnknown() {
        // available：目录存在但快照无记录（投影层不产出，防御未来目录遍历接入）
        let it = item(status: .available, level: 3, maxLevel: 10)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertTrue(stat(total) == (0, 0, 1), "got \(stat(total))")
    }

    func testTotalEqualsSumOfCategoryStats() {
        let items = [
            item(id: "a", category: .buildings, status: .maxed),
            item(id: "b", category: .buildings, status: .complete),
            item(id: "c", category: .troops, status: .unknown, maxLevel: nil),
            item(id: "d", category: nil, status: .unavailable),
        ]
        let stats = VillageDetailProjection.completionStats(from: items)
        let total = VillageDetailProjection.totalCompletion(from: items)
        XCTAssertEqual(total.knownCount, stats.reduce(0) { $0 + $1.knownCount })
        XCTAssertEqual(total.completedCount, stats.reduce(0) { $0 + $1.completedCount })
        XCTAssertEqual(total.unknownCount, stats.reduce(0) { $0 + $1.unknownCount })
    }

    func testCompletionRatio() {
        let full = VillageDetailProjection.totalCompletion(from: [item(status: .maxed)])
        XCTAssertEqual(full.completionRatio, 1.0)
        let half = VillageDetailProjection.totalCompletion(
            from: [item(id: "a", status: .maxed), item(id: "b", status: .complete)])
        XCTAssertEqual(half.completionRatio ?? -1, 0.5, accuracy: 0.0001)
        let none = VillageDetailProjection.totalCompletion(from: [item(status: .unknown, maxLevel: nil)])
        XCTAssertNil(none.completionRatio)
    }

    // MARK: - 目录不可用/版本不匹配（issue #16：不纳入可确认完成度）

    func testCompletionAllUnknownWhenCatalogUnusable() {
        // 目录版本不匹配（或不可用）时：即使 maxed/complete 项齐全，
        // 也不得产生可确认分母（旧目录 maxLevel 不可信）。
        let items = [
            item(id: "a", status: .maxed),
            item(id: "b", status: .complete),
        ]
        let total = VillageDetailProjection.totalCompletion(from: items, catalogIsUsable: false)
        XCTAssertTrue(stat(total) == (0, 0, 2), "got \(stat(total))")
        XCTAssertNil(total.completionRatio, "版本不匹配时不得显示百分比")
    }

    func testCompletionStatsAllUnknownWhenCatalogUnusable() {
        let items = [
            item(id: "a", status: .maxed),
            item(id: "b", status: .complete),
            item(id: "c", status: .unknown, maxLevel: nil),
        ]
        let stats = VillageDetailProjection.completionStats(from: items, catalogIsUsable: false)
        for s in stats {
            XCTAssertEqual(s.knownCount, 0, "分类 \(s.id) 不得计入分母")
            XCTAssertEqual(s.completedCount, 0)
            XCTAssertEqual(s.unknownCount, s.unknownCount)
        }
        XCTAssertEqual(stats.reduce(0) { $0 + $1.unknownCount }, 3)
        XCTAssertEqual(stats.reduce(0) { $0 + $1.knownCount }, 0)
    }

    func testCompletionRatioNilWhenCatalogUnusableEvenWithMaxedItems() {
        let items = [item(status: .maxed)]
        let total = VillageDetailProjection.totalCompletion(from: items, catalogIsUsable: false)
        XCTAssertNil(total.completionRatio)
    }

    func testCatalogUsableDefaultMaintainsExistingBehavior() {
        // 默认参数 true：现有调用（升级总览等）行为不变。
        let total = VillageDetailProjection.totalCompletion(from: [item(status: .maxed)])
        XCTAssertEqual(total.knownCount, 1)
        XCTAssertEqual(total.completedCount, 1)
    }

    // MARK: - isFullyMaxed（issue #53：全部可确认且已满级）

    func testIsFullyMaxedTrueWhenAllMaxed() {
        let single = VillageDetailProjection.totalCompletion(from: [item(status: .maxed)])
        XCTAssertTrue(single.isFullyMaxed, "单 maxed 应为满级")
        let both = VillageDetailProjection.totalCompletion(
            from: [item(id: "a", status: .maxed), item(id: "b", status: .maxed)])
        XCTAssertTrue(both.isFullyMaxed, "全部 maxed 应为满级")
    }

    func testIsFullyMaxedFalseWhenOneComplete() {
        let total = VillageDetailProjection.totalCompletion(
            from: [item(id: "a", status: .maxed), item(id: "b", status: .complete)])
        XCTAssertFalse(total.isFullyMaxed, "存在未满级 known 项不得判满级")
    }

    func testIsFullyMaxedFalseWhenOneUpgrading() {
        // 升级中：status == .upgrading（remainingSeconds > 0）→ 不算完成。
        let total = VillageDetailProjection.totalCompletion(from: [
            item(id: "a", status: .maxed),
            item(id: "b", status: .upgrading, level: 3, maxLevel: 10, isUpgrading: true, nextLevel: 4),
        ])
        XCTAssertFalse(total.isFullyMaxed, "upgrading 项不得判满级")
    }

    func testIsFullyMaxedFalseWhenFinishedTimerNeedsReimport() {
        // 计时结束待重新导入（timerSeconds != nil && remainingSeconds == 0）：
        // 快照 level 仍是升级前等级（未更新）→ status 非 .maxed → 不算完成。
        // item() helper 无法构造此形态（timer 字段由 isUpgrading 硬编码），直接构造。
        let needsReimport = VillageItemState(
            id: "b",
            section: "buildings",
            dataID: 1,
            base: .home,
            name: "item-b",
            category: .buildings,
            currentLevel: 3,
            count: 1,
            timerSeconds: 3600,
            remainingSeconds: 0,
            nextLevel: nil,
            nextLevelDurationSeconds: nil,
            maxLevel: 10,
            status: .complete,
            missingReason: nil,
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: false,
            displayCategory: nil
        )
        XCTAssertTrue(needsReimport.needsReimport, "前置：构造形态确为待重新导入")
        let total = VillageDetailProjection.totalCompletion(from: [
            item(id: "a", status: .maxed),
            needsReimport,
        ])
        XCTAssertFalse(total.isFullyMaxed, "计时结束待重新导入项不得判满级")
    }

    func testIsFullyMaxedFalseWhenUnknownPresent() {
        // 关键负向：completedCount == knownCount 但 unknownCount > 0。
        // completionRatio 可达 1.0，但 isFullyMaxed 刻意更严格，不得判满级。
        let total = VillageDetailProjection.totalCompletion(from: [
            item(id: "a", status: .maxed),
            item(id: "b", status: .maxed),
            item(id: "c", status: .unknown, maxLevel: nil),
        ])
        XCTAssertTrue(stat(total) == (2, 2, 1), "got \(stat(total))")
        XCTAssertEqual(total.completionRatio, 1.0, "前置：completionRatio == 1.0 是可达的")
        XCTAssertFalse(total.isFullyMaxed, "unknown > 0 时不得判满级")
    }

    func testIsFullyMaxedFalseWhenCatalogUnusable() {
        // 目录不可用/版本不匹配：knownCount 恒为 0 → 不得判满级（total 与分类一致）。
        let items = [item(id: "a", status: .maxed), item(id: "b", status: .maxed)]
        let total = VillageDetailProjection.totalCompletion(from: items, catalogIsUsable: false)
        XCTAssertTrue(stat(total) == (0, 0, 2), "got \(stat(total))")
        XCTAssertFalse(total.isFullyMaxed)
        let stats = VillageDetailProjection.completionStats(from: items, catalogIsUsable: false)
        XCTAssertTrue(stats.allSatisfy { !$0.isFullyMaxed }, "分类 stats 也不得判满级")
    }

    func testIsFullyMaxedFalseWhenNoKnownItems() {
        let empty = VillageDetailProjection.totalCompletion(from: [])
        XCTAssertFalse(empty.isFullyMaxed, "空分类不得判满级")
        let unknownOnly = VillageDetailProjection.totalCompletion(from: [item(status: .unknown, maxLevel: nil)])
        XCTAssertFalse(unknownOnly.isFullyMaxed, "无可确认项不得判满级")
    }

    func testIsFullyMaxedTotalAndCategoryShareContract() {
        let allMaxed = [
            item(id: "a", category: .buildings, status: .maxed),
            item(id: "b", category: .traps, status: .maxed),
        ]
        let total1 = VillageDetailProjection.totalCompletion(from: allMaxed)
        let stats1 = VillageDetailProjection.completionStats(from: allMaxed)
        XCTAssertTrue(total1.isFullyMaxed)
        XCTAssertTrue(stats1.allSatisfy(\.isFullyMaxed), "全 maxed 时各分类 stats 也应为满级")

        let mixed = [
            item(id: "a", category: .buildings, status: .maxed),
            item(id: "b", category: .buildings, status: .complete),
        ]
        let total2 = VillageDetailProjection.totalCompletion(from: mixed)
        let stats2 = VillageDetailProjection.completionStats(from: mixed)
        XCTAssertFalse(total2.isFullyMaxed)
        XCTAssertTrue(stats2.allSatisfy { !$0.isFullyMaxed }, "混合分类（maxed + complete 同组）不得判满级")
    }

    func testPropertyIsFullyMaxedConservation() {
        var rng = SplitMix64(seed: 0x53_53)
        for round in 0..<600 {
            // 前 300 轮普通桶（category/other），后 300 轮混入 display 桶
            //（defense/military/craftTable，category 恒 .buildings），覆盖 #37 拆分路径。
            let items = round < 300
                ? randomItems(&rng, count: 1 + Int(rng.next() % 30))
                : randomDisplayItems(&rng, count: 1 + Int(rng.next() % 30))
            let stats = VillageDetailProjection.completionStats(from: items)
            let total = VillageDetailProjection.totalCompletion(from: items)

            // 不变量 1：total.isFullyMaxed ⟺ 所有非空分类 stats 均 isFullyMaxed。
            // known/unknown/completed 在分类间是加法拆分；空分类 stats = (0,0,0) → false。
            let nonEmptyStats = stats.filter { $0.knownCount > 0 || $0.unknownCount > 0 }
            let allCategoriesFullyMaxed = !nonEmptyStats.isEmpty && nonEmptyStats.allSatisfy(\.isFullyMaxed)
            XCTAssertEqual(
                total.isFullyMaxed, allCategoriesFullyMaxed,
                "total=\(stat(total)) stats=\(stats.map(stat))"
            )

            // 不变量 2：isFullyMaxed ⟹ completionRatio == 1.0（单向蕴含；
            // 反例合法：unknown > 0 时 ratio 可能 == 1.0 但 isFullyMaxed == false）。
            if total.isFullyMaxed {
                XCTAssertEqual(total.completionRatio, 1.0)
            }

            // 不变量 3（oracle）：isFullyMaxed 必须与文档契约逐字等价——
            // 防谓词被削弱（去掉 unknownCount == 0 / knownCount > 0）后
            // 不变量 1 因 total/stats 共享同一谓词而同步翻转、无法检出。
            let oracle = total.knownCount > 0 && total.unknownCount == 0
                && total.completedCount == total.knownCount
            XCTAssertEqual(total.isFullyMaxed, oracle, "total=\(stat(total))")
            for s in stats {
                let sOracle = s.knownCount > 0 && s.unknownCount == 0
                    && s.completedCount == s.knownCount
                XCTAssertEqual(s.isFullyMaxed, sOracle, "stats id=\(s.id) \(stat(s))")
            }
        }
    }

    // MARK: - 嵌套归父（issue #24：嵌套 types/modules 归入根父的「类型/模块」区域）

    func testFlatItemsStandAloneWithNoChildren() {
        let a = item(id: "buildings:0")
        let b = item(id: "buildings:1")
        let rows = VillageDetailProjection.parentedRows(from: [a, b])
        XCTAssertEqual(rows.map(\.id), ["buildings:0", "buildings:1"])
        XCTAssertTrue(rows.allSatisfy { $0.children.isEmpty })
    }

    func testNestedItemAttachesToRootParent() {
        let parent = item(id: "heroes:0")
        let child = item(id: "heroes:0.modules.0", nested: true)
        let rows = VillageDetailProjection.parentedRows(from: [parent, child])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.item.id, "heroes:0")
        XCTAssertEqual(rows.first?.children.map(\.id), ["heroes:0.modules.0"])
    }

    func testDeepNestedAttachesToNearestFlatAncestor() {
        // 真实快照形态：buildings:5.types.0.modules.2 的根父是 buildings:5
        // （types 层自身也是嵌套项，继续上溯到非嵌套祖先）。
        let parent = item(id: "buildings:5")
        let type = item(id: "buildings:5.types.0", nested: true)
        let module = item(id: "buildings:5.types.0.modules.2", nested: true)
        let rows = VillageDetailProjection.parentedRows(from: [parent, type, module])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.item.id, "buildings:5")
        XCTAssertEqual(
            rows.first?.children.map(\.id).sorted(),
            ["buildings:5.types.0", "buildings:5.types.0.modules.2"]
        )
    }

    func testAggregatedParentPrefixNormalized() {
        // 聚合后父项 id 带 agg: 前缀，匹配子项父 path 时必须归一化忽略。
        let parent = item(id: "agg:buildings:5")
        let child = item(id: "buildings:5.types.0", nested: true)
        let rows = VillageDetailProjection.parentedRows(from: [parent, child])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.children.map(\.id), ["buildings:5.types.0"])
    }

    func testNestedWithoutParentFallsBackToStandaloneRow() {
        // 根父不在输入中（防御性：父项被过滤）→ 子项独立成行，信息不丢失。
        let orphan = item(id: "heroes:0.modules.0", nested: true)
        let rows = VillageDetailProjection.parentedRows(from: [orphan])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "heroes:0.modules.0")
        XCTAssertTrue(rows.first?.children.isEmpty == true)
    }

    func testNestedItemItselfWithAggPrefix() {
        // 非升级嵌套项也会被聚合 → id 带 agg: 前缀；归一化后仍应挂到根父。
        let parent = item(id: "heroes:0")
        let child = item(id: "agg:heroes:0.modules.0", nested: true)
        let rows = VillageDetailProjection.parentedRows(from: [parent, child])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.children.map(\.id), ["agg:heroes:0.modules.0"])
    }

    func testParentedRowsPreserveInputOrderAndConservation() {
        let items = [
            item(id: "buildings:0"),
            item(id: "buildings:0.types.0", nested: true),
            item(id: "buildings:1"),
            item(id: "heroes:0.modules.0", nested: true), // 孤儿嵌套项
            item(id: "buildings:0.types.0.modules.1", nested: true),
        ]
        let rows = VillageDetailProjection.parentedRows(from: items)
        // 信息守恒：每行 item + children 恰好覆盖输入，无丢失无重复。
        let all = rows.flatMap { [$0.item] + $0.children }
        XCTAssertEqual(all.count, items.count)
        XCTAssertEqual(Set(all.map(\.id)), Set(items.map(\.id)))
        // 行（非嵌套项与孤儿）保持输入相对顺序；children 保持输入相对顺序。
        XCTAssertEqual(rows.map(\.item.id), ["buildings:0", "buildings:1", "heroes:0.modules.0"])
        XCTAssertEqual(
            rows[0].children.map(\.id),
            ["buildings:0.types.0", "buildings:0.types.0.modules.1"]
        )
    }

    // MARK: - Real fixture 集成（issue #24）

    func testUpgradingAndAggregatedParentCoexistChildrenOnFirstOnly() {
        // 同归一化父 id 两个平铺行并存：升级记录（id 无 agg:）单独保留 + 非升级
        // 聚合记录（id 带 agg:）。两行都必须保留，children 只挂输入中先出现的行。
        let upgrading = item(id: "buildings:6", isUpgrading: true)
        let aggregated = item(id: "agg:buildings:6")
        let child = item(id: "buildings:6.types.0", nested: true)
        let rows = VillageDetailProjection.parentedRows(from: [upgrading, aggregated, child])
        XCTAssertEqual(rows.count, 2, "升级行与聚合行都保留")
        XCTAssertEqual(rows[0].item.id, "buildings:6")
        XCTAssertEqual(rows[0].children.map(\.id), ["buildings:6.types.0"], "children 挂到先出现的行")
        XCTAssertEqual(rows[1].item.id, "agg:buildings:6")
        XCTAssertTrue(rows[1].children.isEmpty, "children 不得重复挂到后出现的同归一化行")
    }

    func testChildBeforeParentStillAttaches() {
        // 输入倒序：子项先出现、父项后出现——仍正确挂载（parentedRows 不依赖输入顺序，
        // 先收集再输出）。回归防护：若实现退化为「遍历时即时匹配已见父项」会漏挂。
        let child = item(id: "heroes:0.modules.0", nested: true)
        let parent = item(id: "heroes:0")
        let rows = VillageDetailProjection.parentedRows(from: [child, parent])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.item.id, "heroes:0")
        XCTAssertEqual(rows.first?.children.map(\.id), ["heroes:0.modules.0"])
    }

    func testOrphanKeepsInputPosition() {
        // P3（外部 review）：孤儿嵌套项必须保持输入顺序原位成行，
        // 不得统一追加到列表末尾（doc 承诺「行保持输入相对顺序」）。
        let orphan = item(id: "heroes:0.modules.0", nested: true) // 输入第 1 位
        let parent = item(id: "buildings:0")
        let child = item(id: "buildings:0.types.0", nested: true)
        let rows = VillageDetailProjection.parentedRows(from: [orphan, parent, child])
        XCTAssertEqual(rows.map(\.item.id), ["heroes:0.modules.0", "buildings:0"], "孤儿应在输入原位，而非末尾")
        XCTAssertEqual(rows[1].children.map(\.id), ["buildings:0.types.0"])
    }

    func testRealFixtureNestedItemsGroupUnderRootParent() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "anonymized_account_snapshot", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let snapshot = try AccountSnapshotImporter.parse(String(data: data, encoding: .utf8) ?? "")
        let village = VillageProfile(
            name: "测试村庄",
            accountSnapshot: AccountSnapshot(
                tag: "#TEST",
                capturedAt: nil,
                importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                ageSeconds: nil,
                originalText: "",
                objectSections: snapshot.objectSections,
                numericSections: [:],
                boosts: [:],
                unknownTopLevelKeys: [],
                diagnostics: []
            )
        )
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: GameCatalog.loadBundled(),
            base: .home,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let tracked = projection.items.filter { $0.status != .unavailable }
        // Issue #37：精制台（buildings:6 / dataID 1000097）已从 .buildings 拆到独立展示分类组。
        let craftGroup = try XCTUnwrap(
            VillageDetailProjection.groups(from: tracked).first { $0.displayCategory == .craftTable }
        )
        let rows = VillageDetailProjection.parentedRows(from: craftGroup.items)
        // fixture：buildings:1000097（精制台）3 types × 3 modules = 12 个嵌套后代。
        // 父项与嵌套项均非升级 → 聚合后 id 带 agg: 前缀，正好覆盖归一化路径。
        let craftTable = try XCTUnwrap(
            rows.first { Self.normalizeAggPrefix($0.item.id) == "buildings:6" },
            "根父行 buildings:6 应存在"
        )
        XCTAssertEqual(craftTable.children.count, 12, "全部 12 个嵌套后代应归入根父行")
        XCTAssertTrue(craftTable.children.allSatisfy(\.isNested))
        // 所有嵌套项都有归属：craftTable 组无孤儿嵌套行。
        let orphans = rows.filter { $0.item.isNested }
        XCTAssertTrue(orphans.isEmpty, "精制台组内嵌套项不应独立成行")
    }

    // MARK: - Issue #37 展示分类分组

    func testGroupsSplitBuildingsIntoDisplayCategories() {
        let items = [
            item(id: "def1", category: .buildings, displayCategory: .defense),
            item(id: "def2", category: .buildings, displayCategory: .defense),
            item(id: "mil1", category: .buildings, displayCategory: .military),
            item(id: "craft", category: .buildings, displayCategory: .craftTable),
            item(id: "fallback", category: .buildings),  // 兜底：资源/大本营等
            item(id: "trap", category: .traps),
            item(id: "other", category: nil, status: .unavailable),
        ]
        let groups = VillageDetailProjection.groups(from: items)
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        XCTAssertEqual(byID["defense"]?.items.map(\.id), ["def1", "def2"])
        XCTAssertEqual(byID["military"]?.items.map(\.id), ["mil1"])
        XCTAssertEqual(byID["craftTable"]?.items.map(\.id), ["craft"])
        XCTAssertEqual(byID["buildings"]?.items.map(\.id), ["fallback"])
        XCTAssertEqual(byID["traps"]?.items.map(\.id), ["trap"])
        // 守恒：分组 flatten 不丢不重
        XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(), items.map(\.id).sorted())
    }

    func testGroupsOrderDisplayCategoriesFirst() {
        let items = [
            item(id: "trap", category: .traps),
            item(id: "craft", category: .buildings, displayCategory: .craftTable),
            item(id: "def", category: .buildings, displayCategory: .defense),
            item(id: "b", category: .buildings),  // 兜底
        ]
        let groups = VillageDetailProjection.groups(from: items)
        XCTAssertEqual(groups.map(\.id), ["defense", "craftTable", "buildings", "traps"])
    }

    func testCompletionStatsConserveAcrossDisplaySplit() throws {
        let items = [
            item(id: "def", category: .buildings, displayCategory: .defense, status: .maxed),
            item(id: "mil", category: .buildings, displayCategory: .military, status: .complete),
            item(id: "fb", category: .buildings, status: .unknown, maxLevel: nil),
            item(id: "trap", category: .traps, status: .complete),
        ]
        let stats = VillageDetailProjection.completionStats(from: items)
        let total = VillageDetailProjection.totalCompletion(from: items)
        XCTAssertEqual(total.knownCount, stats.reduce(0) { $0 + $1.knownCount })
        XCTAssertEqual(total.completedCount, stats.reduce(0) { $0 + $1.completedCount })
        XCTAssertEqual(total.unknownCount, stats.reduce(0) { $0 + $1.unknownCount })
        // 注意：tuple 不遵循 Equatable（SE-0283 未实现），拆为两个独立断言。
        let defense = try XCTUnwrap(stats.first { $0.displayCategory == .defense })
        XCTAssertEqual(defense.knownCount, 1)
        XCTAssertEqual(defense.completedCount, 1)
    }

    func testCraftTableGroupParentedRowsStillNest() throws {
        // 精制台父项 + 3 types × 3 modules（id 索引路径格式）
        let children: [VillageItemState] = (0..<12).map { idx in
            item(id: "buildings:0.types.\(idx / 3).modules.\(idx % 3)",
                 category: .buildings, displayCategory: .craftTable, nested: true,
                 status: .unknown, level: nil, maxLevel: nil)
        }
        let parent = item(id: "buildings:0", category: .buildings, displayCategory: .craftTable)
        let groups = VillageDetailProjection.groups(from: [parent] + children)
        let craft = try XCTUnwrap(groups.first { $0.displayCategory == .craftTable })
        let rows = VillageDetailProjection.parentedRows(from: craft.items)
        let root = try XCTUnwrap(rows.first { $0.item.id == "buildings:0" })
        XCTAssertEqual(root.children.count, 12)
    }

    func testMatchesCategoryFilterExcludesDisplayGroups() {
        // 回归（评审 blocker）：display 组的 category 恒为 .buildings 仅作归属提示，
        // 点「建筑与防御」chip 若按 category 匹配会误含防御/军事/精制台全部展示组，
        // 与 chip 计数（已排除 display 组）矛盾。
        let display = VillageDetailGroup(category: .buildings, displayCategory: .defense, items: [])
        let fallback = VillageDetailGroup(category: .buildings, displayCategory: nil, items: [])
        let traps = VillageDetailGroup(category: .traps, displayCategory: nil, items: [])
        XCTAssertTrue(VillageDetailProjection.matchesCategoryFilter(fallback, category: .buildings))
        XCTAssertFalse(VillageDetailProjection.matchesCategoryFilter(display, category: .buildings),
                       "display 组不得命中 buildings 筛选")
        XCTAssertFalse(VillageDetailProjection.matchesCategoryFilter(traps, category: .buildings))
        XCTAssertTrue(VillageDetailProjection.matchesCategoryFilter(traps, category: .traps))
    }

    // MARK: - Property-based：展示分类随机输入不变量

    func testPropertyDisplayCategoryGroupsConserveItems() {
        var rng = SeededRNG(seed: 0xAB_CD)
        let displayCats: [TrackerDisplayCategory?] = [.defense, .military, .craftTable, nil]
        for _ in 0..<200 {
            let items = (0..<Int(rng.next() % 40)).map { idx in
                let dc = displayCats[Int(rng.next() % UInt64(displayCats.count))]
                let category: TrackerCategory? = (dc == nil && rng.next() % 3 == 0) ? nil : .buildings
                return item(id: "i\(idx)", category: category, displayCategory: dc,
                            status: rng.next() % 2 == 0 ? .complete : .maxed)
            }
            let groups = VillageDetailProjection.groups(from: items)
            XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(), items.map(\.id).sorted())
            XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
            for group in groups {
                if let dc = group.displayCategory {
                    XCTAssertTrue(group.items.allSatisfy { $0.displayCategory == dc })
                } else if let c = group.category {
                    XCTAssertTrue(group.items.allSatisfy { $0.displayCategory == nil && $0.category == c })
                } else {
                    XCTAssertTrue(group.items.allSatisfy { $0.category == nil })
                }
            }
        }
    }

    // MARK: - Property-based 不变量（固定 seed SplitMix64，可复现）

    func testPropertyParentedRowsInvariants() {
        var rng = SplitMix64(seed: 0x24_24)
        for _ in 0..<500 {
            let (items, orphanIDs) = randomParentedItems(&rng, count: 1 + Int(rng.next() % 30))
            let rows = VillageDetailProjection.parentedRows(from: items)
            // 1. 信息守恒：输入每个 item 恰好出现一次（行 item + children）。
            let all = rows.flatMap { [$0.item] + $0.children }
            XCTAssertEqual(all.count, items.count)
            XCTAssertEqual(Set(all.map(\.id)), Set(items.map(\.id)))
            // 2. 平铺项（非嵌套）children 必空；子项必为嵌套项；孤儿独立成行且无子项。
            for row in rows {
                if row.item.isNested {
                    XCTAssertTrue(orphanIDs.contains(row.item.id), "独立成行的嵌套项必为生成器标记的孤儿")
                    XCTAssertTrue(row.children.isEmpty, "嵌套孤儿应独立成行且无子项")
                } else {
                    XCTAssertTrue(row.children.allSatisfy(\.isNested))
                }
            }
            // 3. 每个子项是父项的后代：规范化（去 agg:）后子 id 以父 id + "." 开头。
            for row in rows {
                let parentID = Self.normalizeAggPrefix(row.item.id)
                for child in row.children {
                    let childID = Self.normalizeAggPrefix(child.id)
                    XCTAssertNotEqual(childID, parentID)
                    XCTAssertTrue(
                        childID.hasPrefix(parentID + "."),
                        "child \(childID) 应为 \(parentID) 的后代"
                    )
                }
            }
            // 4. 输入顺序稳定：行 = 平铺项 + 孤儿，均按输入顺序（孤儿原位成行，
            //    不得统一追加到末尾——P3 回归防护）。
            let rowItemsInInputOrder = items.filter { !$0.isNested || orphanIDs.contains($0.id) }.map(\.id)
            XCTAssertEqual(rows.map(\.item.id), rowItemsInInputOrder)
            // 5. 孤儿 ≠ 任何平铺项的 children（孤儿的根父不在输入中）。
            let allChildrenIDs = rows.flatMap(\.children).map(\.id)
            XCTAssertTrue(orphanIDs.isDisjoint(with: Set(allChildrenIDs)))
        }
    }

    private static func normalizeAggPrefix(_ id: String) -> String {
        id.hasPrefix("agg:") ? String(id.dropFirst(4)) : id
    }

    private func randomParentedItems(_ rng: inout SplitMix64, count: Int) -> ([VillageItemState], Set<String>) {
        var items: [VillageItemState] = []
        var orphanIDs = Set<String>()
        var rootIDs: [String] = []
        func isDuplicate(_ id: String) -> Bool {
            items.contains { Self.normalizeAggPrefix($0.id) == Self.normalizeAggPrefix(id) }
        }
        while items.count < count {
            let roll = rng.next() % 10
            if roll < 6 || rootIDs.isEmpty {
                // 新的根项（平铺）；约 1/4 带 agg: 前缀（聚合场景）。
                let agg = (rng.next() % 4 == 0) ? "agg:" : ""
                let id = agg + "sect:" + String(rng.next() % 12)
                guard !isDuplicate(id) else { continue }
                items.append(item(id: id))
                rootIDs.append(Self.normalizeAggPrefix(id))
            } else if roll == 6 {
                // 孤儿嵌套项：根父使用不存在的 sect:99（永不作为根生成），
                // 覆盖「父项被过滤」回退路径。深度随机（types/modules 两层）。
                let depth = rng.next() % 3
                let childID: String
                switch depth {
                case 0: childID = "sect:99.types." + String(rng.next() % 6)
                case 1: childID = "sect:99.modules." + String(rng.next() % 6)
                default: childID = "sect:99.types." + String(rng.next() % 6) + ".modules." + String(rng.next() % 6)
                }
                guard !isDuplicate(childID) else { continue }
                items.append(item(id: childID, nested: true))
                orphanIDs.insert(childID)
            } else {
                // 挂嵌套子项到随机根项：types 或 modules 或 types+modules 两层。
                let root = rootIDs[Int(rng.next() % UInt64(rootIDs.count))]
                let depth = rng.next() % 3
                let childID: String
                switch depth {
                case 0: childID = root + ".types." + String(rng.next() % 6)
                case 1: childID = root + ".modules." + String(rng.next() % 6)
                default: childID = root + ".types." + String(rng.next() % 6) + ".modules." + String(rng.next() % 6)
                }
                guard !isDuplicate(childID) else { continue }
                items.append(item(id: childID, nested: true))
            }
        }
        return (items, orphanIDs)
    }

    func testPropertyInvariantsAcrossRandomCollections() {
        var rng = SplitMix64(seed: 0xC0C_16)
        for _ in 0..<500 {
            let items = randomItems(&rng, count: 1 + Int(rng.next() % 30))
            let groups = VillageDetailProjection.groups(from: items)
            let stats = VillageDetailProjection.completionStats(from: items)
            let total = VillageDetailProjection.totalCompletion(from: items)

            XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(), items.map(\.id).sorted())
            // 组内保持输入相对顺序（组间按 sortOrder 重排）
            // 前置条件：该生成器不产生 displayCategory（issue #37 拆分后此断言仅对无细分项成立）
            for group in groups {
                XCTAssertEqual(group.items, items.filter { $0.category == group.category })
            }
            let known = stats.reduce(0) { $0 + $1.knownCount }
            let unknown = stats.reduce(0) { $0 + $1.unknownCount }
            XCTAssertEqual(known + unknown, items.count)
            let completed = stats.reduce(0) { $0 + $1.completedCount }
            XCTAssertLessThanOrEqual(completed, known)
            let maxedItems = items.filter { $0.status == .maxed }
            XCTAssertEqual(completed, maxedItems.count)
            let unknownStatusItems = items.filter {
                $0.status == .unknown || $0.status == .unavailable || $0.status == .available
            }
            // 版本不匹配（upgrading 且 next > max）计入 unknown，与 unknown/unavailable/available 同属 unknown
            let versionMismatchItems = items.filter {
                $0.isUpgrading && ($0.nextLevel ?? 0) > ($0.maxLevel ?? Int.max)
            }
            XCTAssertEqual(unknown, unknownStatusItems.count + versionMismatchItems.count)
            XCTAssertEqual(total.knownCount, known)
            XCTAssertEqual(total.completedCount, completed)
            XCTAssertEqual(total.unknownCount, unknown)
            XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        }
    }

    private func randomItems(_ rng: inout SplitMix64, count: Int) -> [VillageItemState] {
        (0..<count).map { i in
            let statusRoll = rng.next() % 6
            let status: VillageItemStatus
            switch statusRoll {
            case 0: status = .complete
            case 1: status = .maxed
            case 2: status = .upgrading
            case 3: status = .unknown
            case 4: status = .unavailable
            default: status = .available
            }
            // 投影层可达约束（VillageCatalogProjection doc）：unknown/unavailable 目录未
            // 命中或类别不支持 → maxLevel 必 nil；其余状态目录命中 → level/maxLevel 非 nil
            // （available 由投影不产出，此处仅防御性构造 level/maxLevel 齐全）。
            let isCatalogHit = status != .unknown && status != .unavailable
            let level: Int? = Int(rng.next() % 20)
            let maxLevel: Int? = isCatalogHit ? Int(rng.next() % 20) : nil
            let isUpgrading = status == .upgrading
            let nextLevel: Int? = isUpgrading ? level.map { l in
                (maxLevel != nil && rng.next() % 5 == 0) ? l + 2 : l + 1
            } : nil
            let cats: [TrackerCategory?] = [.buildings, .traps, .troops, .spells,
                .siegeMachines, .heroes, .equipment, .pets, .guardians, nil]
            let category = cats[Int(rng.next() % UInt64(cats.count))]
            return item(id: "r\(i)", category: category, status: status,
                        level: level, maxLevel: maxLevel,
                        isUpgrading: isUpgrading, nextLevel: nextLevel)
        }
    }

    /// 带 display 桶（defense/military/craftTable）的随机生成器（issue #53 property 覆盖）。
    /// display 项 category 恒 .buildings（与投影层 #37 契约一致），其余同 randomItems。
    private func randomDisplayItems(_ rng: inout SplitMix64, count: Int) -> [VillageItemState] {
        (0..<count).map { i in
            let statusRoll = rng.next() % 6
            let status: VillageItemStatus
            switch statusRoll {
            case 0: status = .complete
            case 1: status = .maxed
            case 2: status = .upgrading
            case 3: status = .unknown
            case 4: status = .unavailable
            default: status = .available
            }
            let isCatalogHit = status != .unknown && status != .unavailable
            let level: Int? = Int(rng.next() % 20)
            let maxLevel: Int? = isCatalogHit ? Int(rng.next() % 20) : nil
            let isUpgrading = status == .upgrading
            let nextLevel: Int? = isUpgrading ? level.map { l in
                (maxLevel != nil && rng.next() % 5 == 0) ? l + 2 : l + 1
            } : nil
            // 60% 概率 display 桶（category 恒 .buildings），40% 普通 category/other。
            if rng.next() % 5 < 3 {
                let dcs: [TrackerDisplayCategory?] = [.defense, .military, .craftTable, nil]
                let dc = dcs[Int(rng.next() % UInt64(dcs.count))]
                return item(id: "d\(i)", category: .buildings, displayCategory: dc,
                            status: status, level: level, maxLevel: maxLevel,
                            isUpgrading: isUpgrading, nextLevel: nextLevel)
            } else {
                let cats: [TrackerCategory?] = [.buildings, .traps, .troops, .spells,
                    .siegeMachines, .heroes, .equipment, .pets, .guardians, nil]
                let category = cats[Int(rng.next() % UInt64(cats.count))]
                return item(id: "r\(i)", category: category, status: status,
                            level: level, maxLevel: maxLevel,
                            isUpgrading: isUpgrading, nextLevel: nextLevel)
            }
        }
    }
}

/// 可复现 PRNG（SplitMix64），替代 SwiftCheck 的 property-based 测试。
fileprivate struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
