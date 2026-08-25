import Foundation
import XCTest
@testable import COCHelperCore

/// Issue #253 Phase A：分页累计缓存的保留上限（retention policy）。
///
/// 契约：
/// - 累计列表顺序为最新在前、最旧在后（分页向更旧方向追加）；
/// - 裁剪只删最旧尾部，保头部 → #211 row ID（seq 按 head 计数）对存留行稳定；
/// - 游标（before/after）不属于本地数据，裁剪不得触碰；
/// - 与 #231 overlap 合并组合时：裁剪尾部只可能让 overlap 匹配落在存留
///   后缀上（匹配 → 正确 payload 更新）或完全失配（走 append，追加的条目
///   全部比存留尾部更旧 → 顺序正确、无重复）。
final class CacheRetentionPolicyTests: XCTestCase {

    // MARK: - 纯数组裁剪

    func testTrimUnderLimitReturnsItemsUnchanged() {
        let items = [1, 2, 3]
        XCTAssertEqual(CacheRetentionPolicy.trimmedTail(items: items, limit: 10), [1, 2, 3])
    }

    func testTrimAtExactLimitReturnsItemsUnchanged() {
        let items = Array(0..<10)
        XCTAssertEqual(CacheRetentionPolicy.trimmedTail(items: items, limit: 10), items)
    }

    func testTrimBeyondLimitKeepsHeadDropsOldestTail() {
        // 头部 = 最新；尾部 = 最旧。超限裁尾。
        let items = Array(0..<10)
        XCTAssertEqual(CacheRetentionPolicy.trimmedTail(items: items, limit: 6), [0, 1, 2, 3, 4, 5])
    }

    func testTrimEmptyItemsStaysEmpty() {
        XCTAssertEqual(CacheRetentionPolicy.trimmedTail(items: [Int](), limit: 5), [])
    }

    func testTrimNonPositiveLimitIsNoOp() {
        let items = [1, 2, 3]
        XCTAssertEqual(CacheRetentionPolicy.trimmedTail(items: items, limit: 0), items)
        XCTAssertEqual(CacheRetentionPolicy.trimmedTail(items: items, limit: -1), items)
    }

    // MARK: - 分页包装裁剪（游标必须原样保留）

    func testTrimmedPagePreservesCursors() {
        let page = OfficialPaginatedPage<Int>(
            items: Array(0..<10),
            before: "B1",
            after: "A1"
        )
        let trimmed = CacheRetentionPolicy.trimmedPage(page: page, limit: 4)
        XCTAssertEqual(trimmed.items, [0, 1, 2, 3])
        XCTAssertEqual(trimmed.before, "B1")
        XCTAssertEqual(trimmed.after, "A1")
    }

    func testTrimmedPagePreservesStalledNilCursor() {
        // 游标停滞清空（after == nil）是合并层的终结语义，裁剪不得复活它。
        let page = OfficialPaginatedPage<Int>(items: Array(0..<10), before: nil, after: nil)
        let trimmed = CacheRetentionPolicy.trimmedPage(page: page, limit: 4)
        XCTAssertNil(trimmed.after)
        XCTAssertNil(trimmed.before)
    }

    func testTrimmedPageUnderLimitIsIdentity() {
        let page = OfficialPaginatedPage<Int>(items: [1, 2], before: nil, after: "A")
        let trimmed = CacheRetentionPolicy.trimmedPage(page: page, limit: 10)
        XCTAssertEqual(trimmed, page)
    }

    // MARK: - #211 row identity：裁尾对存留行 ID 稳定

    private func season(_ id: Int) -> OfficialCapitalRaidSeason {
        OfficialCapitalRaidSeason(
            state: "ended", startTime: String(format: "s%03d", id),
            endTime: "e", capitalTotalLoot: nil, raidsCompleted: nil,
            totalAttacks: nil, enemyDistrictsDestroyed: nil,
            offensiveReward: nil, defensiveReward: nil,
            members: nil, attackLog: nil, defenseLog: nil
        )
    }

    func testTrimmedTailKeepsRowIdentityOfSurvivingHead() {
        let seasons = (0..<30).map(season(_:))
        let beforeRows = CapitalRaidRowIdentity.rows(for: seasons)

        let trimmed = CacheRetentionPolicy.trimmedTail(items: seasons, limit: 10)
        let afterRows = CapitalRaidRowIdentity.rows(for: trimmed)

        XCTAssertEqual(afterRows.count, 10)
        // 存留头部行的 ID 与裁剪前完全一致（seq 按 head 计数，删尾不漂移）。
        for (index, row) in afterRows.enumerated() {
            XCTAssertEqual(row.id, beforeRows[index].id, "第 \(index) 行 ID 在裁尾后漂移")
            XCTAssertEqual(row.season, beforeRows[index].season)
        }
    }

    // MARK: - 与 #231 overlap 合并的组合行为

    /// 场景：累计列表被裁尾后，下一次 load-more 的响应完全落在存留尾部
    /// 更旧的一侧（positional overlap 必然失配 → append）。断言顺序正确、
    /// 无重复：被裁掉的旧数据经由服务端翻页合法回归，不算重复行。
    func testMergeAfterTrimAppendsOlderFetchWithoutDuplicates() {
        var existing = (0..<10).map(season(_:))          // s000…s009，头新尾旧
        existing = CacheRetentionPolicy.trimmedTail(items: existing, limit: 6) // s000…s005
        XCTAssertEqual(existing.count, 6)

        // 翻页响应从已裁掉的区域继续（s008 起），与存留尾部 s005 无 positional 对齐。
        let fetched = (8..<12).map(season(_:))
        let result = CapitalRaidPaginationMerge.mergedLoadMoreItems(existing: existing, newPage: fetched)

        XCTAssertEqual(result.items.map { $0.startTime ?? "" },
                       ["s000", "s001", "s002", "s003", "s004", "s005", "s008", "s009", "s010", "s011"],
                       "追加条目必须全部位于存留尾部更旧一侧且保持顺序")
        XCTAssertEqual(result.reconciliation, .identityPreserving)
    }

    /// 场景：裁尾边界恰好被 overlap 横跨——响应前缀匹配存留尾部（s003–s005），
    /// 余下部分（s006、s007）属于上次被裁掉的区域。positional 匹配命中存留段，
    /// merge 结果必须无重复且顺序正确（被裁数据合法回归）。
    func testMergeAfterTrimWithBoundaryStraddlingOverlapIsDuplicateFree() {
        var existing = (0..<10).map(season(_:))
        existing = CacheRetentionPolicy.trimmedTail(items: existing, limit: 6) // s000…s005

        // 响应 = [s003, s004, s005]（匹配存留尾部）+ [s006, s007]（曾裁掉）
        let fetched = (3..<8).map(season(_:))
        let result = CapitalRaidPaginationMerge.mergedLoadMoreItems(existing: existing, newPage: fetched)

        XCTAssertEqual(result.items.map { $0.startTime ?? "" },
                       ["s000", "s001", "s002", "s003", "s004", "s005", "s006", "s007"],
                       "overlap 命中存留段时，merge 必须等价于 dropLast(overlap) + 新页（无重复）")
    }

    // MARK: - 上限常量可审计

    func testPolicyLimitsArePositiveAndAuditable() {
        XCTAssertGreaterThan(CacheRetentionPolicy.maxWarLogItemsPerTag, 0)
        XCTAssertGreaterThan(CacheRetentionPolicy.maxCapitalSeasonsPerTag, 0)
    }
}
