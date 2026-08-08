import Foundation
import XCTest
@testable import COCHelperCore

/// 分页合并纯函数：累计页语义（lastGood = 累计列表 + 最新游标）与去重。
final class PaginationMergeTests: XCTestCase {
    private typealias Entry = OfficialWarLogEntry

    private func entry(_ id: String) -> Entry {
        Entry(
            result: "win", endTime: "2026\(id)", teamSize: nil, attacksPerMember: nil,
            battleModifier: nil,
            clan: nil, opponent: nil
        )
    }

    // MARK: - mergedItems 去重

    func testMergeAppendsNewItemsWithoutDuplicates() {
        let existing = [entry("01"), entry("02")]
        let newPage = [entry("02"), entry("03")]  // 02 重复

        let merged = PaginationMerge.mergedItems(existing: existing, newPage: newPage)

        XCTAssertEqual(merged.map { $0.endTime }, ["202601", "202602", "202603"],
                       "重复条目不得重复追加")
    }

    func testMergeWithEmptyExistingIsNewPage() {
        let merged = PaginationMerge.mergedItems(existing: [], newPage: [entry("01")])
        XCTAssertEqual(merged.count, 1)
    }

    func testMergeKeepsExistingOrderStable() {
        let existing = [entry("01"), entry("02")]
        let merged = PaginationMerge.mergedItems(existing: existing, newPage: [entry("02"), entry("04"), entry("03")])
        XCTAssertEqual(merged.map { $0.endTime }, ["202601", "202602", "202604", "202603"],
                       "已有顺序保持，新条目按页顺序追加")
    }

    // MARK: - mergedPage 游标语义

    func testFirstPageReplacesEmptyState() {
        let fetched = OfficialPaginatedPage(items: [entry("01")], before: "B", after: "A")
        let merged = PaginationMerge.mergedPage(existing: nil, fetched: fetched)

        XCTAssertEqual(merged, fetched)
        XCTAssertEqual(merged.after, "A")
    }

    func testLoadMoreAppendsAndAdvancesCursor() {
        let existing = OfficialPaginatedPage(items: [entry("01")], before: "B1", after: "A1")
        let fetched = OfficialPaginatedPage(items: [entry("01"), entry("02")], before: "B2", after: "A2")

        let merged = PaginationMerge.mergedPage(existing: existing, fetched: fetched)

        XCTAssertEqual(merged.items.map(\.endTime), ["202601", "202602"])
        XCTAssertEqual(merged.after, "A2", "游标推进到最新响应的 after")
    }

    /// 末页（after nil）合并后 after 为 nil → hasMore 为 false（终止）。
    func testLoadMoreLastPageClearsCursor() {
        let existing = OfficialPaginatedPage(items: [entry("01")], before: "B1", after: "A1")
        let fetched = OfficialPaginatedPage(items: [entry("02")], before: "B2", after: nil)

        let merged = PaginationMerge.mergedPage(existing: existing, fetched: fetched)

        XCTAssertEqual(merged.items.count, 2)
        XCTAssertNil(merged.after)
        XCTAssertFalse(PaginationLogic.hasMore(requestedCursor: "A1", responseAfter: merged.after),
                       "末页后不得再有加载更多")
    }

    /// 游标停滞（服务端返回相同 after）→ after 清空为 nil：无论 UI 的
    /// hasMore 派生方式（requestedCursor nil 或真实游标）都判定终止（防无限）。
    func testStalledCursorStopsPagination() {
        let existing = OfficialPaginatedPage(items: [entry("01")], before: "B", after: "SAME")
        let fetched = OfficialPaginatedPage(items: [entry("02")], before: "B", after: "SAME")

        let merged = PaginationMerge.mergedPage(existing: existing, fetched: fetched)

        XCTAssertNil(merged.after, "游标停滞必须清空 after（视为末页）")
        XCTAssertFalse(PaginationLogic.hasMore(requestedCursor: nil, responseAfter: merged.after),
                       "停滞后 UI 派生（requestedCursor nil）也必须判定无更多")
        XCTAssertFalse(PaginationLogic.hasMore(requestedCursor: "SAME", responseAfter: merged.after))
    }

    // MARK: - property-based

    /// mergedItems 不变量：结果 = 已有（原序）+ 新页中不在已有的（原序）。
    func testMergePropertyBased() {
        var rng = LCG(seed: 0x9A6E)
        for _ in 0..<100 {
            let existingCount = Int.random(in: 0...8, using: &rng)
            let newCount = Int.random(in: 0...8, using: &rng)
            let pool = (0..<20).map { "2026\(String(format: "%02d", $0))" }
            let existing = pool.shuffled(using: &rng).prefix(existingCount).map { entry($0) }
            let newPage = pool.shuffled(using: &rng).prefix(newCount).map { entry($0) }

            let merged = PaginationMerge.mergedItems(existing: existing, newPage: newPage)

            // 不变量 1：已有条目全部保留且相对顺序不变
            let mergedEnds = merged.map { $0.endTime }
            let existingEnds = existing.map { $0.endTime }
            var idx = 0
            for end in existingEnds {
                let found = mergedEnds[idx...].firstIndex(of: end)
                XCTAssertNotNil(found, "已有条目必须保留: \(end ?? "nil")")
                idx = found ?? idx
                idx += 1
            }
            // 不变量 2：新页中**实际追加**的条目（不在已有中）按新页顺序出现
            let appendedEnds = newPage.map { $0.endTime }.filter { !existingEnds.contains($0) }
            let positions = appendedEnds.compactMap { end in mergedEnds.firstIndex(of: end) }
            XCTAssertEqual(positions, positions.sorted(),
                           "新追加条目必须保持新页顺序: \(appendedEnds)")
            // 不变量 3：无重复
            XCTAssertEqual(Set(mergedEnds).count, mergedEnds.count, "不得重复记录")
        }
    }
}
