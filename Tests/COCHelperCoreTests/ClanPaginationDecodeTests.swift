import Foundation
import XCTest
@testable import COCHelperCore

/// 读取 warlog / capital 分页 fixture。
func fullWarLogPageData() -> Data {
    let url = Bundle.module.url(forResource: "official_war_log_page", withExtension: "json")!
    return try! Data(contentsOf: url)
}

func fullCapitalRaidPageData() -> Data {
    let url = Bundle.module.url(forResource: "official_capital_raid_page", withExtension: "json")!
    return try! Data(contentsOf: url)
}

final class ClanPaginationDecodeTests: XCTestCase {
    // MARK: - warlog 页

    func testDecodeWarLogPage() throws {
        let page = try JSONDecoder().decode(OfficialWarLogPage.self, from: fullWarLogPageData())

        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].result, "win")
        XCTAssertEqual(page.items[0].endTime, "20260730T100000.000Z")
        XCTAssertEqual(page.items[0].teamSize, 30)
        XCTAssertEqual(page.items[0].clan?.stars, 95)
        XCTAssertEqual(page.items[0].clan?.destructionPercentage, 100.0)
        XCTAssertEqual(page.items[0].opponent?.name, "anonymized-opponent")
        XCTAssertEqual(page.items[1].result, "lose")
        // 游标来自 paging.cursors（官方层级）
        XCTAssertEqual(page.before, "CURSORBEFORE1")
        XCTAssertEqual(page.after, "CURSORAFTER1")
    }

    /// 末页无游标（paging 缺失或 cursors 缺失）：items 空列表是合法空历史。
    func testDecodeWarLogLastPageWithoutCursors() throws {
        let page = try JSONDecoder().decode(OfficialWarLogPage.self, from: Data(#"{"items":[]}"#.utf8))
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.before)
        XCTAssertNil(page.after)
    }

    // MARK: - warlog 成员明细（Issue #20，与 currentwar 共用 ClanWarMember）

    func testDecodeWarLogEntryMembers() throws {
        let page = try JSONDecoder().decode(OfficialWarLogPage.self, from: fullWarLogPageData())
        let members = try XCTUnwrap(page.items[0].clan?.members)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.name, "anonymized-member")
        XCTAssertEqual(members.first?.townhallLevel, 14)
        XCTAssertEqual(members.first?.mapPosition, 1)
        XCTAssertEqual(members.first?.attacks?.count, 1)
        XCTAssertEqual(members.first?.attacks?.first?.stars, 3)
        XCTAssertEqual(members.first?.attacks?.first?.destructionPercentage, 100)
        XCTAssertEqual(members.first?.opponentAttacks, 1)
        // 第二场战争无 members 键 → nil 容忍
        XCTAssertNil(page.items[1].clan?.members)
    }

    /// items 缺失/null 是**损坏响应**：必须解码失败（保留既有 last-good），
    /// 不得静默当作成功空页覆盖旧数据。
    func testDecodeMissingItemsFails() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(OfficialWarLogPage.self, from: Data("{}".utf8)),
            "items 缺失必须解码失败"
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(OfficialWarLogPage.self, from: Data(#"{"items":null}"#.utf8)),
            "items null 必须解码失败"
        )
    }

    /// paging.cursors 部分缺失（只有 after 无 before）容忍。
    func testDecodePartialCursorsTolerated() throws {
        let page = try JSONDecoder().decode(
            OfficialWarLogPage.self,
            from: Data(#"{"items":[],"paging":{"cursors":{"after":"A1"}}}"#.utf8)
        )
        XCTAssertEqual(page.after, "A1")
        XCTAssertNil(page.before)
    }

    // MARK: - capital raid 页

    func testDecodeCapitalRaidPage() throws {
        let page = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fullCapitalRaidPageData())

        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].state, "ended")
        XCTAssertEqual(page.items[0].startTime, "20260701T080000.000Z")
        XCTAssertEqual(page.items[0].capitalTotalLoot, 123456)
        XCTAssertEqual(page.items[0].raidsCompleted, 6)
        XCTAssertEqual(page.items[0].totalAttacks, 60)
        XCTAssertEqual(page.items[0].enemyDistrictsDestroyed, 120)
        XCTAssertEqual(page.items[0].offensiveReward, 5000)
        XCTAssertEqual(page.items[0].defensiveReward, 2500)
        XCTAssertEqual(page.before, "RAIDCURSORBEFORE1")
        XCTAssertEqual(page.after, "RAIDCURSORAFTER1")
    }

    /// 回归护栏：attackLog/defenseLog 数组存在时，赛季摘要字段仍正确解码
    /// （成员明细本身由 testDecodeCapitalRaidAttackLog/DefenseLog 覆盖）。
    func testDecodeToleratesAttackLogArrays() throws {
        let page = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fullCapitalRaidPageData())
        XCTAssertEqual(page.items[0].capitalTotalLoot, 123456, "attackLog 存在时摘要仍正确")
    }

    /// Issue #199 回归：完整内容身份键在 #197 fixture 累计 17 条下必须唯一。
    /// 旧键（startTime|endTime|state）只有 3 个唯一值（多条不同 capitalTotalLoot
    /// 的记录共享同三元组）→ ForEach identity 碰撞；`stableIdentityKey`
    /// 编码完整赛季内容（含 members/attackLog/defenseLog），必须 17 个全唯一。
    func testIssue199CapitalRaidStableIdentityKeyUniqueAcrossMergedPages() throws {
        let names = ["perf_capital_raid_page_01", "perf_capital_raid_page_02", "perf_capital_raid_page_03"]
        let pages = try names.map { name -> OfficialCapitalRaidPage in
            let url = try XCTUnwrap(
                Bundle.module.url(forResource: name, withExtension: "json"),
                "fixture \(name) 必须存在（#197 perf fixtures）"
            )
            return try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: Data(contentsOf: url))
        }
        let items = pages.flatMap(\.items)
        XCTAssertEqual(items.count, 17, "#197 fixture 合并契约：3 页共 17 条")

        // 回归前提：旧三元组键确实会重复（若 fixture 变化导致该断言失败，
        // 说明旧键已不碰撞，测试前提需同步更新——碰撞场景消失是好事）。
        let legacyKeys = items.map {
            [$0.startTime, $0.endTime, $0.state].compactMap { $0 }.joined(separator: "|")
        }
        XCTAssertLessThan(Set(legacyKeys).count, items.count, "回归前提：startTime|endTime|state 三元组必须存在重复")

        // 完整内容键必须唯一。
        let identityKeys = items.map(\.stableIdentityKey)
        XCTAssertEqual(Set(identityKeys).count, items.count, "stableIdentityKey 在累计分页数据下必须唯一")
        // 同一赛季跨加载（重复解码同一页）键稳定（确定性）。
        let redecoded = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: Data(contentsOf: try XCTUnwrap(
            Bundle.module.url(forResource: "perf_capital_raid_page_01", withExtension: "json")
        )))
        XCTAssertEqual(
            redecoded.items.map(\.stableIdentityKey),
            pages[0].items.map(\.stableIdentityKey),
            "同内容重复解码必须产生相同身份键（确定性）"
        )
    }

    /// Issue #199 回归：字典字段（badgeUrls）插入顺序不同、语义相同 → 键必须相同。
    /// 默认 JSONEncoder 对 Dictionary 迭代顺序不稳定（同键不同插入顺序输出不同
    /// JSON），`.sortedKeys` 是必要防御。
    func testIssue199CapitalRaidStableIdentityKeyIgnoresDictionaryInsertionOrder() throws {
        // 语义相同、仅 badgeUrls 键插入顺序不同的两个赛季（解码后 == 相等）。
        let jsonA = #"{"items":[{"state":"ended","attackLog":[{"defender":{"name":"x","badgeUrls":{"small":"s","medium":"m","large":"l"}},"attackCount":1}]}]}"#
        let jsonB = #"{"items":[{"state":"ended","attackLog":[{"defender":{"name":"x","badgeUrls":{"large":"l","medium":"m","small":"s"}},"attackCount":1}]}]}"#
        let seasonA = try XCTUnwrap(
            try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: Data(jsonA.utf8)).items.first
        )
        let seasonB = try XCTUnwrap(
            try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: Data(jsonB.utf8)).items.first
        )
        XCTAssertEqual(seasonA, seasonB, "回归前提：两个赛季语义必须完全相同")

        // 回归前提：默认编码（无 sortedKeys）对这两个字典确实产生不同输出——
        // 证明测试环境里两个字典迭代顺序不同，能真正拦截旧实现。
        let unsortedA = try JSONEncoder().encode(seasonA)
        let unsortedB = try JSONEncoder().encode(seasonB)
        XCTAssertNotEqual(unsortedA, unsortedB, "回归前提：默认 JSONEncoder 对字典插入顺序敏感")

        // 契约：stableIdentityKey 必须与字典插入顺序无关。
        XCTAssertEqual(seasonA.stableIdentityKey, seasonB.stableIdentityKey)
    }

    // MARK: - 突袭周末成员/攻防日志（Issue #20）

    func testDecodeCapitalRaidMembers() throws {
        let page = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fullCapitalRaidPageData())
        let members = try XCTUnwrap(page.items[0].members)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.tag, "#PLAYERANONYMIZED")
        XCTAssertEqual(members.first?.name, "anonymized-member")
        XCTAssertEqual(members.first?.capitalResourcesLooted, 25000)
        XCTAssertEqual(members.first?.attacks, 6)
        // 第二赛季无 members 键 → nil
        XCTAssertNil(page.items[1].members)
    }

    func testDecodeCapitalRaidAttackLog() throws {
        let page = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fullCapitalRaidPageData())
        let log = try XCTUnwrap(page.items[0].attackLog)
        XCTAssertEqual(log.count, 1)
        let entry = try XCTUnwrap(log.first)
        XCTAssertEqual(entry.defender?.name, "anonymized-raid-clan", "attackLog 条目用 defender")
        XCTAssertEqual(entry.defender?.level, 8)
        XCTAssertEqual(entry.attackCount, 4)
        XCTAssertEqual(entry.districtCount, 5)
        XCTAssertEqual(entry.districtsDestroyed, 1)
        let district = try XCTUnwrap(entry.districts?.first, "摧毁率/掠夺在 districts 内")
        XCTAssertEqual(district.name, "anonymized-district")
        XCTAssertEqual(district.id, 10)
        XCTAssertEqual(district.destructionPercent, 100)
        XCTAssertEqual(district.totalLooted, 20000)
        XCTAssertEqual(district.districtHallLevel, 4)
        // 官方无顶层 looted——类型不存在即编译期保证（模型未声明该属性，
        // 比运行时 nil 断言更强；looted 数据在 districts[].totalLooted）。
        XCTAssertNil(page.items[1].attackLog)
    }

    func testDecodeCapitalRaidDefenseLog() throws {
        let page = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fullCapitalRaidPageData())
        let log = try XCTUnwrap(page.items[0].defenseLog)
        XCTAssertEqual(log.count, 1)
        let entry = try XCTUnwrap(log.first)
        XCTAssertEqual(entry.attacker?.name, "anonymized-raid-clan-2", "defenseLog 条目用 attacker（不是 defender）")
        XCTAssertEqual(entry.attacker?.level, 7)
        XCTAssertEqual(entry.attackCount, 3)
        XCTAssertEqual(entry.districtCount, 5)
        XCTAssertEqual(entry.districtsDestroyed, 0)
        XCTAssertEqual(entry.districts?.first?.name, "anonymized-home-district")
        XCTAssertEqual(entry.districts?.first?.destructionPercent, 40)
        XCTAssertNil(page.items[1].defenseLog)
    }

    /// 成员/日志字段部分缺失（如 defender 只有 name）不破坏解码。
    func testDecodeCapitalRaidLogWithPartialFields() throws {
        let season = try JSONDecoder().decode(
            OfficialCapitalRaidPage.self,
            from: Data(##"{"items":[{"state":"ended","attackLog":[{"defender":{"name":"x"},"attackCount":1,"districts":[{"id":1}]}]}]}"##.utf8)
        )
        XCTAssertEqual(season.items[0].attackLog?.first?.defender?.name, "x")
        XCTAssertNil(season.items[0].attackLog?.first?.districts?.first?.destructionPercent)
    }

    // MARK: - Round-trip

    func testRoundTripWarLogPage() throws {
        let original = try JSONDecoder().decode(OfficialWarLogPage.self, from: fullWarLogPageData())
        let decoded = try JSONDecoder().decode(OfficialWarLogPage.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.after, "CURSORAFTER1")
    }

    func testRoundTripCapitalRaidPage() throws {
        let original = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fullCapitalRaidPageData())
        let decoded = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.after, "RAIDCURSORAFTER1")
    }

    /// 无游标页 round-trip：不产生空的 paging 对象。
    func testRoundTripWithoutCursors() throws {
        let original = try JSONDecoder().decode(OfficialWarLogPage.self, from: Data(#"{"items":[]}"#.utf8))
        let data = try JSONEncoder().encode(original)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("paging"),
                       "无游标时不应编码出空 paging")
        let decoded = try JSONDecoder().decode(OfficialWarLogPage.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
