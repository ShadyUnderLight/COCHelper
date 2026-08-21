import Foundation
import XCTest
@testable import COCHelperCore

/// Issue #231：Capital Raid load-more identity-aware pagination merge。
final class CapitalRaidPaginationMergeTests: XCTestCase {

    private func makeSeason(
        start: String? = "20260701T080000.000Z",
        end: String? = "20260703T080000.000Z",
        state: String? = "ended",
        loot: Int? = 100_000
    ) -> OfficialCapitalRaidSeason {
        OfficialCapitalRaidSeason(
            state: state, startTime: start, endTime: end,
            capitalTotalLoot: loot, raidsCompleted: 6, totalAttacks: 60,
            enemyDistrictsDestroyed: 120, offensiveReward: 5000, defensiveReward: 2500,
            members: nil, attackLog: nil, defenseLog: nil
        )
    }

    private func makePage(
        _ seasons: [OfficialCapitalRaidSeason],
        after: String? = nil
    ) -> OfficialPaginatedPage<OfficialCapitalRaidSeason> {
        OfficialPaginatedPage(items: seasons, before: nil, after: after)
    }

    // MARK: - Case 1: 1 + 1 changed details

    func testLoadMoreOverlapUpdatesSingleSeasonInPlace() {
        let existing = makePage([makeSeason(loot: 100_000)], after: "CURSOR")
        let fetched = makePage([makeSeason(loot: 999_999)], after: "CURSOR2")

        let result = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: existing, fetched: fetched)

        XCTAssertEqual(result.page.items.count, 1)
        XCTAssertEqual(result.page.items[0].capitalTotalLoot, 999_999)
        XCTAssertEqual(result.page.after, "CURSOR2")
        XCTAssertEqual(result.reconciliation, .identityPreserving)
    }

    func testLoadMoreTerminalOverlapUpdatesLastSeasonWithoutAppending() {
        let a = makeSeason(start: "20260701T080000.000Z", end: "20260703T080000.000Z", loot: 100_000)
        let b = makeSeason(start: "20260702T080000.000Z", end: "20260704T080000.000Z", loot: 200_000)
        let c = makeSeason(start: "20260703T080000.000Z", end: "20260705T080000.000Z", loot: 300_000)
        let cPrime = makeSeason(start: "20260703T080000.000Z", end: "20260705T080000.000Z", loot: 999_999)
        let existing = makePage([a, b, c], after: "CURSOR")
        let fetched = makePage([cPrime], after: nil)

        let result = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: existing, fetched: fetched)

        XCTAssertEqual(result.page.items.count, 3)
        XCTAssertEqual(result.page.items[2].capitalTotalLoot, 999_999)
        XCTAssertEqual(result.page.items.map(\.capitalTotalLoot), [100_000, 200_000, 999_999])
        XCTAssertNil(result.page.after)
        XCTAssertEqual(result.reconciliation, .identityPreserving)
    }

    // MARK: - Case 2: duplicate triple with exact anchor

    func testLoadMoreDuplicateTripleWithExactAnchorUpdatesMatchedEntry() {
        let a1 = makeSeason(loot: 100_000)
        let a2 = makeSeason(loot: 100_500)
        let existing = makePage([a1, a2], after: "CURSOR")
        let fetched = makePage([a1, makeSeason(loot: 200_000)], after: "CURSOR2")

        let result = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: existing, fetched: fetched)

        XCTAssertEqual(result.page.items.count, 2)
        XCTAssertEqual(result.page.items[0].capitalTotalLoot, 100_000)
        XCTAssertEqual(result.page.items[1].capitalTotalLoot, 200_000)
        XCTAssertEqual(result.reconciliation, .identityPreserving)
    }

    // MARK: - Case 3: fully ambiguous equal-count overlap

    func testLoadMoreAmbiguousEqualCountOverlapMarksReconciliationAmbiguous() {
        let a1 = makeSeason(loot: 100_000)
        let a2 = makeSeason(loot: 100_500)
        let existing = makePage([a1, a2], after: "CURSOR")
        let fetched = makePage(
            [makeSeason(loot: 102_000), makeSeason(loot: 101_000)],
            after: "CURSOR2"
        )

        let result = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: existing, fetched: fetched)

        XCTAssertEqual(result.page.items.count, 2)
        XCTAssertEqual(result.reconciliation, .ambiguous)
    }

    func testLoadMorePartialDuplicateTripleOverlapFailsClosedWithoutShrinkingToOneToOne() {
        let anchor = makeSeason(start: "20260701T080000.000Z", end: "20260703T080000.000Z", loot: 10_000)
        let k1 = makeSeason(loot: 100_000)
        let k2 = makeSeason(loot: 100_500)
        let d = makeSeason(start: "20260704T080000.000Z", end: "20260706T080000.000Z", loot: 400_000)
        let existing = makePage([anchor, k1, k2], after: "CURSOR")
        let fetched = makePage(
            [makeSeason(loot: 101_000), makeSeason(loot: 102_000), d],
            after: "CURSOR2"
        )

        let result = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: existing, fetched: fetched)

        XCTAssertEqual(result.reconciliation, .ambiguous)
        XCTAssertEqual(result.page.items.count, 4)
        XCTAssertEqual(result.page.items.map(\.capitalTotalLoot), [10_000, 101_000, 102_000, 400_000])
    }

    // MARK: - Case 4: genuine new same-triple occurrence still appends

    func testLoadMoreAppendsGenuineSameTripleOccurrence() {
        let a1 = makeSeason(loot: 100_000)
        let a2 = makeSeason(loot: 100_500)
        let existing = makePage([a1, a2], after: "CURSOR")
        let a3 = makeSeason(loot: 50_000)
        let fetched = makePage([a3], after: "CURSOR2")

        let result = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: existing, fetched: fetched)

        XCTAssertEqual(result.page.items.count, 3)
        XCTAssertEqual(result.page.items[2].capitalTotalLoot, 50_000)
        XCTAssertEqual(result.reconciliation, .identityPreserving)
    }

    // MARK: - Case 5: no-overlap control

    func testLoadMoreNoOverlapAppendsWithoutChangingExistingOrder() {
        let a = makeSeason(start: "20260701T080000.000Z", end: "20260703T080000.000Z", loot: 100_000)
        let b = makeSeason(start: "20260702T080000.000Z", end: "20260704T080000.000Z", loot: 200_000)
        let c = makeSeason(start: "20260703T080000.000Z", end: "20260705T080000.000Z", loot: 300_000)
        let d = makeSeason(start: "20260704T080000.000Z", end: "20260706T080000.000Z", loot: 400_000)
        let existing = makePage([a, b], after: "CURSOR")
        let fetched = makePage([c, d], after: "CURSOR2")

        let result = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: existing, fetched: fetched)

        XCTAssertEqual(result.page.items.map(\.capitalTotalLoot), [100_000, 200_000, 300_000, 400_000])
        XCTAssertEqual(result.page.after, "CURSOR2")
        XCTAssertEqual(result.reconciliation, .identityPreserving)
    }

    func testStalledCursorClearsAfterLikeGenericMerge() {
        let existing = makePage([makeSeason(start: "t1", end: "t2")], after: "CURSOR")
        let fetched = makePage([makeSeason(start: "t3", end: "t4")], after: "CURSOR")

        let result = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: existing, fetched: fetched)

        XCTAssertNil(result.page.after)
    }

    func testPerfFixturesMergeToSeventeenItemsLikeGenericMerge() throws {
        let p1 = try decodePage("perf_capital_raid_page_01")
        let p2 = try decodePage("perf_capital_raid_page_02")
        let p3 = try decodePage("perf_capital_raid_page_03")

        let m12 = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: p1.page, fetched: p2.page).page
        let m123 = CapitalRaidPaginationMerge.mergedLoadMorePage(existing: m12, fetched: p3.page).page

        XCTAssertEqual(m123.items.count, 17)
    }

    private func decodePage(_ name: String) throws -> OfficialCapitalRaidPage {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json"),
            "fixture \(name) 必须存在"
        )
        return try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: Data(contentsOf: url))
    }
}
