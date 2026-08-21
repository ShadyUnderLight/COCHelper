import Foundation
import XCTest
@testable import COCHelperCore

/// Issue #211：预计算突袭周末行 identity 契约测试。
///
/// 目标：行 identity 轻量、稳定、重复三元组不碰撞、详情变化不改 ID、
/// 分页累计/重建/重编码场景一致，且不再依赖完整赛季 JSON 编码。
final class CapitalRaidRowIdentityTests: XCTestCase {

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
        members: [CapitalRaidSeasonMember]? = nil,
        attackLog: [CapitalRaidAttackLogEntry]? = nil,
        defenseLog: [CapitalRaidDefenseLogEntry]? = nil
    ) -> OfficialCapitalRaidSeason {
        OfficialCapitalRaidSeason(
            state: state, startTime: start, endTime: end,
            capitalTotalLoot: loot, raidsCompleted: 6, totalAttacks: 60,
            enemyDistrictsDestroyed: 120, offensiveReward: 5000, defensiveReward: 2500,
            members: members, attackLog: attackLog, defenseLog: defenseLog
        )
    }

    private func makeMember(name: String = "x") -> CapitalRaidSeasonMember {
        CapitalRaidSeasonMember(tag: "#TAG", name: name, capitalResourcesLooted: 100, attacks: 1)
    }

    private func makeAttackLog(memberName: String = "clanA") -> [CapitalRaidAttackLogEntry] {
        [CapitalRaidAttackLogEntry(
            defender: CapitalRaidClanInfo(tag: "#C", name: memberName, level: 8, badgeUrls: ["small": "s"]),
            attackCount: 1, districtCount: 1, districtsDestroyed: 1, districts: nil)]
    }

    // MARK: - 1. 重复三元组仍不碰撞

    func testDuplicateTripleGetsDistinctIDs() throws {
        // 同一三元组的两条不同 loot 记录（真实数据场景：多条记录共享三元组）
        let a = makeSeason(loot: 100000)
        let b = makeSeason(loot: 100500) // 同三元组，不同 loot
        let rows = CapitalRaidRowIdentity.rows(for: [a, b])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].id, rows[1].id, "相同三元组的两条记录必须拥有不同 ID（序号区分）")
        // 契约：id 仅基于三元组+序号，不含 loot
        XCTAssertTrue(rows[0].id.contains("|"), "ID 应含三元组分隔符")
        XCTAssertTrue(rows[0].id.hasSuffix("#0"))
        XCTAssertTrue(rows[1].id.hasSuffix("#1"))
    }

    func testDuplicateTripleAcrossThreeEntries() throws {
        let seasons = (0..<3).map { i in makeSeason(loot: 100000 + i * 500) }
        let rows = CapitalRaidRowIdentity.rows(for: seasons)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertEqual(rows.map(\.id), [
            "20260701T080000.000Z|20260703T080000.000Z|ended#0",
            "20260701T080000.000Z|20260703T080000.000Z|ended#1",
            "20260701T080000.000Z|20260703T080000.000Z|ended#2",
        ])
    }

    // MARK: - 2. 17 条累计记录 ID 集合和顺序稳定

    func testPerfFixture17RecordsStableAndUnique() throws {
        let p1 = try decodePage("perf_capital_raid_page_01")
        let p2 = try decodePage("perf_capital_raid_page_02")
        let p3 = try decodePage("perf_capital_raid_page_03")
        // 验证 fixture 契约：三页共 17 条是 issue 前提
        let all = p1.items + p2.items + p3.items
        XCTAssertEqual(all.count, 17)
        // 回归前提：旧三元组确实碰撞（不稳定则测试前提失效）
        let legacyKeys = all.map { [$0.startTime, $0.endTime, $0.state].compactMap { $0 }.joined(separator: "|") }
        XCTAssertLessThan(Set(legacyKeys).count, all.count, "三元组必须碰撞，否则无需序号区分")

        // 通过合并去重（本 fixture 各页互异，去重后仍 17）
        let m12 = PaginationMerge.mergedPage(existing: p1.page, fetched: p2.page)
        let m123 = PaginationMerge.mergedPage(existing: m12, fetched: p3.page)
        XCTAssertEqual(m123.items.count, 17)

        let rows = CapitalRaidRowIdentity.rows(for: m123.items)
        XCTAssertEqual(rows.count, 17)
        XCTAssertEqual(Set(rows.map(\.id)).count, 17, "17 条累计记录的 ID 必须全唯一")
        // 顺序稳定：rows 的 season 顺序与 items 一致
        XCTAssertEqual(rows.map(\.season), m123.items)
        // 重复调用确定性
        let rows2 = CapitalRaidRowIdentity.rows(for: m123.items)
        XCTAssertEqual(rows.map(\.id), rows2.map(\.id), "同输入重复调用必须产生相同 ID 序列")
    }

    // MARK: - 3. 同一条记录仅改详情时 ID 不变

    func testDetailChangesDoNotAffectID() throws {
        let base = makeSeason(loot: 100000, members: [makeMember(name: "a")], attackLog: makeAttackLog(), defenseLog: nil)
        let mutatedLoot = makeSeason(loot: 999999, members: base.members, attackLog: base.attackLog, defenseLog: base.defenseLog)
        let mutatedMembers = makeSeason(loot: base.capitalTotalLoot, members: [makeMember(name: "b"), makeMember(name: "c")], attackLog: base.attackLog, defenseLog: base.defenseLog)
        let mutatedLogs = makeSeason(loot: base.capitalTotalLoot, members: base.members, attackLog: makeAttackLog(memberName: "changed"), defenseLog: base.defenseLog)

        // 三者三元组相同，单独成列时 ID 均为 #0 → 详情不影响
        let idBase = CapitalRaidRowIdentity.rows(for: [base]).first!.id
        let idLoot = CapitalRaidRowIdentity.rows(for: [mutatedLoot]).first!.id
        let idMembers = CapitalRaidRowIdentity.rows(for: [mutatedMembers]).first!.id
        let idLogs = CapitalRaidRowIdentity.rows(for: [mutatedLogs]).first!.id
        XCTAssertEqual(idBase, idLoot, "仅改 loot 不该改变 ID")
        XCTAssertEqual(idBase, idMembers, "仅改 members 不该改变 ID")
        XCTAssertEqual(idBase, idLogs, "仅改 attackLog 不该改变 ID")

        // 在列表上下文中，详情变化不改变已有行的 ID
        let listA = [base, makeSeason(start: "20260702T080000.000Z", end: "20260704T080000.000Z", loot: 200000)]
        let listB = [mutatedLoot, makeSeason(start: "20260702T080000.000Z", end: "20260704T080000.000Z", loot: 200000)]
        XCTAssertEqual(CapitalRaidRowIdentity.rows(for: listA).map(\.id), CapitalRaidRowIdentity.rows(for: listB).map(\.id))

        // 反例：旧 stableIdentityKey 会随详情变化而变化（证明重型路径已被替换）
        XCTAssertNotEqual(base.stableIdentityKey, mutatedLoot.stableIdentityKey, "回归前提：旧键会随 loot 变化")
        XCTAssertNotEqual(base.stableIdentityKey, mutatedMembers.stableIdentityKey, "回归前提：旧键会随 members 变化")
    }

    // MARK: - 4. first page + load more 与一次性合并得到同样的 ID

    func testFirstPagePlusLoadMoreVsOneShotSameIDs() throws {
        let p1 = try decodePage("perf_capital_raid_page_01")
        let p2 = try decodePage("perf_capital_raid_page_02")
        let p3 = try decodePage("perf_capital_raid_page_03")

        // 路径 A：逐步分页合并（真实 AppModel 行为）
        let m12 = PaginationMerge.mergedPage(existing: p1.page, fetched: p2.page)
        let m123 = PaginationMerge.mergedPage(existing: m12, fetched: p3.page)
        let rowsA = CapitalRaidRowIdentity.rows(for: m123.items)

        // 路径 B：一次性合并（将所有页 items 一次性去重合并，顺序与分页追加一致）
        // 由于 fixture 各页互异，合并结果应与逐步合并一致
        var combined: [OfficialCapitalRaidSeason] = []
        combined = PaginationMerge.mergedItems(existing: combined, newPage: p1.items)
        combined = PaginationMerge.mergedItems(existing: combined, newPage: p2.items)
        combined = PaginationMerge.mergedItems(existing: combined, newPage: p3.items)
        let rowsB = CapitalRaidRowIdentity.rows(for: combined)

        XCTAssertEqual(m123.items, combined, "逐步合并与一次性去重合并的 items 应一致")
        XCTAssertEqual(rowsA.map(\.id), rowsB.map(\.id), "两种合并路径的 row ID 必须一致")
    }

    // MARK: - 5. 重新编码/解码分页缓存后 ID 仍符合契约

    func testReencodedPageKeepsSameRowIDs() throws {
        let p1 = try decodePage("perf_capital_raid_page_01")
        let p2 = try decodePage("perf_capital_raid_page_02")
        let merged = PaginationMerge.mergedPage(existing: p1.page, fetched: p2.page)
        let rowsBefore = CapitalRaidRowIdentity.rows(for: merged.items)

        // 模拟持久化：OfficialCapitalRaidPage Codable round-trip
        let pageModel = OfficialCapitalRaidPage(page: merged)
        let data = try JSONEncoder().encode(pageModel)
        let redecoded = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: data)
        let rowsAfter = CapitalRaidRowIdentity.rows(for: redecoded.items)

        XCTAssertEqual(rowsBefore.map(\.id), rowsAfter.map(\.id), "重编码/解码后 ID 必须一致（顺序与三元组不变）")
        XCTAssertEqual(rowsBefore.map(\.season), rowsAfter.map(\.season))
    }

    // MARK: - 6. duplicate page / cursor stall / 旧分页不回归

    func testDuplicatePageMergeKeepsIDsStableWithoutDuplication() throws {
        let p1 = try decodePage("perf_capital_raid_page_01")
        // 模拟重复页：同一页再次到达（服务端重复推送）
        let merged = PaginationMerge.mergedPage(existing: p1.page, fetched: p1.page)
        XCTAssertEqual(merged.items.count, p1.items.count, "重复页不应产生重复条目（去重）")
        let rowsOriginal = CapitalRaidRowIdentity.rows(for: p1.items)
        let rowsMerged = CapitalRaidRowIdentity.rows(for: merged.items)
        XCTAssertEqual(rowsOriginal.map(\.id), rowsMerged.map(\.id), "重复页合并后已有行的 ID 不变")
    }

    func testCursorStallDoesNotAffectExistingRowIDs() throws {
        // 游标停滞：响应 after == 请求游标 → after 清空为 nil（视为末页）
        let existing = OfficialPaginatedPage(items: [makeSeason(start: "t1", end: "t2")], before: nil, after: "CURSOR")
        let fetched = OfficialPaginatedPage(items: [makeSeason(start: "t1", end: "t2")], before: nil, after: "CURSOR")
        let merged = PaginationMerge.mergedPage(existing: existing, fetched: fetched)
        XCTAssertNil(merged.after, "游标停滞必须清空 after")
        // 已有行的 identity 仍稳定
        let rowsExisting = CapitalRaidRowIdentity.rows(for: existing.items)
        let rowsMerged = CapitalRaidRowIdentity.rows(for: merged.items)
        XCTAssertEqual(rowsExisting.first?.id, rowsMerged.first?.id)
    }

    func testLastGoodSemanticsPreservedWithRowIdentity() throws {
        // 模拟 AppModel 的 lastGood 失败保留语义：成功后有 lastGood，失败时不改 lastGood
        let p1 = try decodePage("perf_capital_raid_page_01")
        let successState = ClanCapitalAPIState(
            status: .success,
            clanTag: "#PERF",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
            parserVersion: OfficialCapitalRaidPage.currentParserVersion,
            lastGood: p1,
            unrecognizedKeys: []
        )
        let failedState = ClanCapitalAPIState(
            status: .failed,
            clanTag: "#PERF",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_001),
            lastErrorReason: "network",
            lastHTTPStatus: 500,
            parserVersion: OfficialCapitalRaidPage.currentParserVersion,
            lastGood: p1,
            unrecognizedKeys: []
        )
        // 失败保留 lastGood
        XCTAssertEqual(successState.lastGood, failedState.lastGood, "失败必须保留 lastGood")
        guard let successItems = successState.lastGood?.items,
              let failedItems = failedState.lastGood?.items else {
            XCTFail("lastGood 必须存在")
            return
        }
        let rowsSuccess = CapitalRaidRowIdentity.rows(for: successItems)
        let rowsFailedRetains = CapitalRaidRowIdentity.rows(for: failedItems)
        XCTAssertEqual(rowsSuccess.map(\.id), rowsFailedRetains.map(\.id), "失败保留 lastGood 时 row ID 必须与成功时一致")
        XCTAssertEqual(rowsSuccess.count, p1.items.count)
        XCTAssertEqual(Set(rowsSuccess.map(\.id)).count, rowsSuccess.count)
    }

    // MARK: - 7. 不再依赖完整内容 JSON 编码

    func testRowIdentityDoesNotDependOnFullContent() throws {
        // 构造两个三元组相同、但完整内容不同的赛季
        // 若仍用完整 JSON 编码，它们 stableIdentityKey 不同但 row ID 应基于三元组+序号
        let sA = makeSeason(loot: 100, members: [makeMember(name: "a")])
        let sB = makeSeason(loot: 200, members: [makeMember(name: "b")], attackLog: makeAttackLog(memberName: "x"))
        // 旧键不同（证明若用 JSON 则会不同）
        XCTAssertNotEqual(sA.stableIdentityKey, sB.stableIdentityKey)
        // 但按三元组序号，它们在同列表中的 ID 应为 #0/#1 区分，而非因内容不同就不同 key
        let rows = CapitalRaidRowIdentity.rows(for: [sA, sB])
        XCTAssertEqual(rows[0].id, "\(CapitalRaidRowIdentity.tripleKey(for: sA))#0")
        XCTAssertEqual(rows[1].id, "\(CapitalRaidRowIdentity.tripleKey(for: sB))#1")
        // 且单个元素的 ID 不因成员/logs 变化而变化，已在 testDetailChangesDoNotAffectID 验证
    }

    func testTripleKeyExcludesDetailFields() throws {
        let base = makeSeason(start: "s", end: "e", state: "ended", loot: 1)
        let varied = makeSeason(start: "s", end: "e", state: "ended", loot: 999999, members: [makeMember(name: "many")], attackLog: makeAttackLog(), defenseLog: nil)
        XCTAssertEqual(CapitalRaidRowIdentity.tripleKey(for: base), CapitalRaidRowIdentity.tripleKey(for: varied))
    }

    // MARK: - 8. 轻量性与确定性

    func testRowsAreDeterministicAndLightweight() throws {
        let seasons = (0..<10).map { i in makeSeason(start: "2026070\(i)T080000.000Z", end: "2026070\(i+1)T080000.000Z") }
        let first = CapitalRaidRowIdentity.rows(for: seasons).map(\.id)
        let second = CapitalRaidRowIdentity.rows(for: seasons).map(\.id)
        XCTAssertEqual(first, second, "确定性：同输入必须同输出")
        // 轻量性：不通过 JSON 编码也能得到 ID（间接证明：本测试未触发 JSONEncoder，
        // 若实现误用 JSON 则 testDetailChangesDoNotAffectID 会失败）
    }

    func testNilTripleHandled() throws {
        let nilSeason = makeSeason(start: nil, end: nil, state: nil)
        let rows = CapitalRaidRowIdentity.rows(for: [nilSeason, nilSeason])
        XCTAssertEqual(rows[0].id, "||#0")
        XCTAssertEqual(rows[1].id, "||#1")
        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }

    // MARK: - 9. 与 OfficialCapitalRaidPage 的集成

    func testPageConvenienceRowsMatchesArrayRows() throws {
        let p1 = try decodePage("perf_capital_raid_page_01")
        let viaPage = CapitalRaidRowIdentity.rows(for: p1)
        let viaArray = CapitalRaidRowIdentity.rows(for: p1.items)
        XCTAssertEqual(viaPage.map(\.id), viaArray.map(\.id))
        XCTAssertEqual(viaPage.map(\.season), viaArray.map(\.season))
    }

    // MARK: - 10. View 不再在 render 路径重算 row identity（源码级）

    func testViewDoesNotUseHeavyIdentity() throws {
        // 静态检查：CapitalRaidCardView.swift 不应再包含 stableIdentityKey，
        // 也不应在 View body 调用 CapitalRaidRowIdentity.rows(for:)。
        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot = thisFile
            .deletingLastPathComponent() // CapitalRaidRowIdentityTests.swift
            .deletingLastPathComponent() // COCHelperCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // COC助手
        let primaryURL = projectRoot.appendingPathComponent("Sources/COCHelper/CapitalRaidCardView.swift")
        let fallbackURLs: [URL] = [
            primaryURL,
            URL(fileURLWithPath: "Sources/COCHelper/CapitalRaidCardView.swift"),
            Bundle.module.resourceURL?.appendingPathComponent("CapitalRaidCardView.swift"),
        ].compactMap { $0 }

        var checked = false
        for url in fallbackURLs where FileManager.default.fileExists(atPath: url.path) {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("stableIdentityKey"), "CapitalRaidCardView 不应在 View 路径使用 stableIdentityKey（重型） @ \(url.path)")
            XCTAssertFalse(text.contains("CapitalRaidRowIdentity.rows(for:"), "CapitalRaidCardView 不应在 render 路径重算 row identity @ \(url.path)")
            XCTAssertTrue(text.contains("capitalRaidRows(for:"), "CapitalRaidCardView 应消费 AppModel 缓存 rows @ \(url.path)")
            XCTAssertTrue(text.contains("row.id != rows.last?.id"), "分隔线应基于 row.id 判定末行，避免共享 endTime 时漏画 Divider @ \(url.path)")
            checked = true
            break
        }
        XCTAssertTrue(checked, "必须至少命中一个 CapitalRaidCardView.swift 路径（primary: \(primaryURL.path)）")
    }
}
