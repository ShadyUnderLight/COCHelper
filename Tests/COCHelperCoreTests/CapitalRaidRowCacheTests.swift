import Foundation
import XCTest
@testable import COCHelperCore

/// Issue #221：突袭周末 row identity 生命周期缓存契约测试。
final class CapitalRaidRowCacheTests: XCTestCase {

    // MARK: - helpers

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"), "fixture \(name) 必须存在")
        return try Data(contentsOf: url)
    }

    private func decodePage(_ name: String) throws -> OfficialCapitalRaidPage {
        try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fixtureData(name))
    }

    private func makeSeason(
        start: String? = "20260701T080000.000Z",
        end: String? = "20260703T080000.000Z",
        state: String? = "ended",
        loot: Int? = 100000,
        members: [CapitalRaidSeasonMember]? = nil
    ) -> OfficialCapitalRaidSeason {
        OfficialCapitalRaidSeason(
            state: state, startTime: start, endTime: end,
            capitalTotalLoot: loot, raidsCompleted: 6, totalAttacks: 60,
            enemyDistrictsDestroyed: 120, offensiveReward: 5000, defensiveReward: 2500,
            members: members, attackLog: nil, defenseLog: nil
        )
    }

    private func makePage(_ seasons: [OfficialCapitalRaidSeason], after: String? = nil) -> OfficialCapitalRaidPage {
        OfficialCapitalRaidPage(page: OfficialPaginatedPage(items: seasons, before: nil, after: after))
    }

    private func tripleKey(_ season: OfficialCapitalRaidSeason) -> String {
        CapitalRaidRowIdentity.tripleKey(for: season)
    }

    // MARK: - lifecycle

    func testSameOrderDetailUpdatePreservesIDs() {
        let cache = CapitalRaidRowCache()
        let a = makeSeason(loot: 100_000)
        let b = makeSeason(start: "20260702T080000.000Z", end: "20260704T080000.000Z", loot: 200_000)
        let pageA = makePage([a, b])
        cache.apply(.initial(page: pageA))
        let idsBefore = cache.rows.map(\.id)

        let aPrime = makeSeason(loot: 999_999)
        let pageAPrime = makePage([aPrime, b])
        cache.apply(.refreshSuccess(page: pageAPrime))

        XCTAssertEqual(cache.rows.map(\.id), idsBefore)
        XCTAssertEqual(cache.rows[0].season.capitalTotalLoot, 999_999)
        XCTAssertEqual(cache.generation, 1)
    }

    func testLoadMoreAppendsWithoutChangingOldIDs() {
        let cache = CapitalRaidRowCache()
        let a = makeSeason(loot: 100_000)
        let b = makeSeason(start: "20260702T080000.000Z", end: "20260704T080000.000Z", loot: 200_000)
        let firstPage = makePage([a, b], after: "CURSOR")
        cache.apply(.initial(page: firstPage))
        let oldIDs = cache.rows.map(\.id)

        let c = makeSeason(start: "20260703T080000.000Z", end: "20260705T080000.000Z", loot: 300_000)
        let merged = makePage([a, b, c], after: "CURSOR2")
        cache.apply(.loadMoreSuccess(page: merged))

        XCTAssertEqual(Array(cache.rows.map(\.id).prefix(2)), oldIDs)
        XCTAssertEqual(cache.rows.count, 3)
        XCTAssertTrue(cache.rows[2].id.hasSuffix("#0"))
    }

    func testIncrementalLoadMoreMatchesOneShotSemanticsForUniqueTriples() throws {
        let p1 = try decodePage("perf_capital_raid_page_01")
        let p2 = try decodePage("perf_capital_raid_page_02")
        let p3 = try decodePage("perf_capital_raid_page_03")

        let incremental = CapitalRaidRowCache()
        incremental.apply(.initial(page: p1))
        let m12 = PaginationMerge.mergedPage(existing: p1.page, fetched: p2.page)
        incremental.apply(.loadMoreSuccess(page: OfficialCapitalRaidPage(page: m12)))
        let m123 = PaginationMerge.mergedPage(existing: m12, fetched: p3.page)
        incremental.apply(.loadMoreSuccess(page: OfficialCapitalRaidPage(page: m123)))

        let oneShot = CapitalRaidRowCache()
        oneShot.apply(.initial(page: OfficialCapitalRaidPage(page: m123)))

        XCTAssertEqual(
            Set(incremental.rows.map(\.id)),
            Set(oneShot.rows.map(\.id)),
            "无歧义累计路径的 triple#seq 语义应一致"
        )
    }

    func testRefreshSamePageDoesNotChangeGeneration() {
        let cache = CapitalRaidRowCache()
        let page = makePage([makeSeason()])
        cache.apply(.initial(page: page))
        let generation = cache.generation
        cache.apply(.refreshSuccess(page: page))
        XCTAssertEqual(cache.generation, generation)
    }

    func testDuplicateTripleInsertionResetsGeneration() {
        let cache = CapitalRaidRowCache()
        let shared = tripleKey(makeSeason())
        let a = makeSeason(loot: 100_000)
        let b = makeSeason(loot: 100_500)
        cache.apply(.initial(page: makePage([a, b])))
        let generationBefore = cache.generation
        let oldIDs = Set(cache.rows.map(\.id))

        let n = makeSeason(loot: 50_000)
        cache.apply(.refreshSuccess(page: makePage([n, a, b])))

        XCTAssertGreaterThan(cache.generation, generationBefore)
        XCTAssertTrue(cache.rows[0].id.contains(shared))
        XCTAssertFalse(oldIDs.contains(cache.rows[0].id), "新插入行不得复用旧 ID")
    }

    func testDuplicateTriplePureReorderPreservesIdentityViaAnchors() {
        let cache = CapitalRaidRowCache()
        let a = makeSeason(loot: 100_000)
        let b = makeSeason(loot: 100_500)
        cache.apply(.initial(page: makePage([a, b])))
        let idA = cache.rows[0].id
        let idB = cache.rows[1].id
        let generationBefore = cache.generation

        cache.apply(.refreshSuccess(page: makePage([b, a])))

        XCTAssertEqual(cache.generation, generationBefore, "payload 未变的纯重排可通过锚点安全匹配")
        XCTAssertEqual(cache.rows[0].id, idB)
        XCTAssertEqual(cache.rows[1].id, idA)
    }

    func testDuplicateReorderWithDetailChangesResetsGeneration() {
        let cache = CapitalRaidRowCache()
        let a = makeSeason(loot: 100_000)
        let b = makeSeason(loot: 200_000)
        cache.apply(.initial(page: makePage([a, b])))
        let idA = cache.rows[0].id
        let idB = cache.rows[1].id
        let generationBefore = cache.generation

        let bPrime = makeSeason(loot: 201_000)
        let aPrime = makeSeason(loot: 101_000)
        cache.apply(.refreshSuccess(page: makePage([bPrime, aPrime])))

        XCTAssertGreaterThan(cache.generation, generationBefore)
        XCTAssertNotEqual(cache.rows[0].id, idA, "B' 不得得到 A 的旧 ID")
        XCTAssertNotEqual(cache.rows[1].id, idB, "A' 不得得到 B 的旧 ID")
    }

    func testIdenticalDuplicateThenOneDetailChangesResetsGeneration() {
        let cache = CapitalRaidRowCache()
        let a1 = makeSeason(loot: 100_000)
        let a2 = makeSeason(loot: 100_000)
        cache.apply(.initial(page: makePage([a1, a2])))
        let oldIDs = Set(cache.rows.map(\.id))
        let generationBefore = cache.generation

        let aPrime = makeSeason(loot: 101_000)
        cache.apply(.refreshSuccess(page: makePage([aPrime, a2])))

        XCTAssertGreaterThan(cache.generation, generationBefore)
        XCTAssertTrue(oldIDs.isDisjoint(with: cache.rows.map(\.id)), "分化后不得复用上一 generation 的任何旧 ID")
    }

    func testUniqueTripleReorderPreservesIdentity() {
        let cache = CapitalRaidRowCache()
        let a = makeSeason(start: "20260701T080000.000Z", end: "20260703T080000.000Z", loot: 100_000)
        let b = makeSeason(start: "20260702T080000.000Z", end: "20260704T080000.000Z", loot: 200_000)
        cache.apply(.initial(page: makePage([a, b])))
        let idA = cache.rows[0].id
        let idB = cache.rows[1].id
        let generationBefore = cache.generation

        cache.apply(.refreshSuccess(page: makePage([b, a])))

        XCTAssertEqual(cache.generation, generationBefore)
        XCTAssertEqual(cache.rows[0].id, idB)
        XCTAssertEqual(cache.rows[1].id, idA)
    }

    func testDuplicatePageDoesNotAddRows() throws {
        let cache = CapitalRaidRowCache()
        let p1 = try decodePage("perf_capital_raid_page_01")
        cache.apply(.initial(page: p1))
        let before = cache.rows
        cache.apply(.loadMoreSuccess(page: p1))
        XCTAssertEqual(cache.rows.map(\.id), before.map(\.id))
    }

    func testCursorStallKeepsRowState() {
        let cache = CapitalRaidRowCache()
        let season = makeSeason(start: "t1", end: "t2")
        let existing = OfficialPaginatedPage(items: [season], before: nil, after: "CURSOR")
        cache.apply(.initial(page: OfficialCapitalRaidPage(page: existing)))
        let before = cache.rows

        let fetched = OfficialPaginatedPage(items: [season], before: nil, after: "CURSOR")
        let merged = PaginationMerge.mergedPage(existing: existing, fetched: fetched)
        cache.apply(.loadMoreSuccess(page: OfficialCapitalRaidPage(page: merged)))

        XCTAssertEqual(cache.rows.map(\.id), before.map(\.id))
        XCTAssertNil(merged.after)
    }

    func testFailureRetainKeepsRowState() {
        let cache = CapitalRaidRowCache()
        let page = makePage([makeSeason()])
        cache.apply(.initial(page: page))
        let before = cache.rows
        let buildCount = cache.buildCount
        cache.apply(.failureRetain)
        XCTAssertEqual(cache.rows.map(\.id), before.map(\.id))
        XCTAssertEqual(cache.buildCount, buildCount)
    }

    func testParserRebuildCreatesNewGeneration() {
        let cache = CapitalRaidRowCache()
        let page = makePage([makeSeason()])
        cache.apply(.initial(page: page))
        let generationBefore = cache.generation
        cache.apply(.parserRebuild(page: page))
        XCTAssertGreaterThan(cache.generation, generationBefore)
    }

    func testRepeatedRowReadsDoNotRebuild() {
        let cache = CapitalRaidRowCache()
        let page = makePage([makeSeason()])
        cache.apply(.initial(page: page))
        let buildAfterUpdate = cache.buildCount
        _ = cache.rows
        _ = cache.rows
        XCTAssertEqual(cache.buildCount, buildAfterUpdate)
    }

    func testRefreshAfterLoadMorePreservesPrefixIDs() {
        let cache = CapitalRaidRowCache()
        let a = makeSeason(start: "20260701T080000.000Z", end: "20260703T080000.000Z", loot: 100_000)
        let b = makeSeason(start: "20260702T080000.000Z", end: "20260704T080000.000Z", loot: 200_000)
        let c = makeSeason(start: "20260703T080000.000Z", end: "20260705T080000.000Z", loot: 300_000)
        let d = makeSeason(start: "20260704T080000.000Z", end: "20260706T080000.000Z", loot: 400_000)
        cache.apply(.initial(page: makePage([a, b], after: "CURSOR")))
        cache.apply(.loadMoreSuccess(page: makePage([a, b, c, d], after: nil)))
        XCTAssertEqual(cache.rows.count, 4)
        let idA = cache.rows[0].id
        let idB = cache.rows[1].id
        let generationBefore = cache.generation

        let aPrime = makeSeason(start: "20260701T080000.000Z", end: "20260703T080000.000Z", loot: 111_111)
        let bPrime = makeSeason(start: "20260702T080000.000Z", end: "20260704T080000.000Z", loot: 222_222)
        cache.apply(.refreshSuccess(page: makePage([aPrime, bPrime], after: "CURSOR")))

        XCTAssertEqual(cache.generation, generationBefore, "首屏 refresh 不应仅因列表缩短而 bump generation")
        XCTAssertEqual(cache.rows.count, 2)
        XCTAssertEqual(cache.rows[0].id, idA)
        XCTAssertEqual(cache.rows[1].id, idB)
        XCTAssertEqual(cache.rows[0].season.capitalTotalLoot, 111_111)
    }

    func testViewDoesNotCallRowIdentityBuilder() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fallbackURLs = [
            projectRoot.appendingPathComponent("Sources/COCHelper/CapitalRaidCardView.swift"),
            URL(fileURLWithPath: "Sources/COCHelper/CapitalRaidCardView.swift"),
        ]
        var checked = false
        for url in fallbackURLs where FileManager.default.fileExists(atPath: url.path) {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("CapitalRaidRowIdentity.rows(for:"))
            XCTAssertFalse(text.contains("stableIdentityKey"))
            XCTAssertTrue(text.contains("capitalRaidRows(for:"))
            checked = true
            break
        }
        XCTAssertTrue(checked)
    }
}
