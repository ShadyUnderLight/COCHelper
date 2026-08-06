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
