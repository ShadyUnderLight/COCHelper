import XCTest
@testable import COCHelperCore

/// Issue #16：村庄详情页分组与完成度统计。
final class VillageDetailProjectionTests: XCTestCase {
    // MARK: - Helpers

    private func item(
        id: String = "id",
        category: TrackerCategory? = .buildings,
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
            isNested: false
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

    // MARK: - Property-based 不变量（固定 seed SplitMix64，可复现）

    func testPropertyInvariantsAcrossRandomCollections() {
        var rng = SplitMix64(seed: 0xC0C_16)
        for _ in 0..<500 {
            let items = randomItems(&rng, count: 1 + Int(rng.next() % 30))
            let groups = VillageDetailProjection.groups(from: items)
            let stats = VillageDetailProjection.completionStats(from: items)
            let total = VillageDetailProjection.totalCompletion(from: items)

            XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(), items.map(\.id).sorted())
            // 组内保持输入相对顺序（组间按 sortOrder 重排）
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
