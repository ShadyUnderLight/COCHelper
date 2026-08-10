import Foundation
import XCTest
import COCHelperApp
@testable import COCHelperCore

/// 读取完整战争 fixture（free function，避免被 @Sendable closure 捕获 self）。
func fullClanWarFixtureData() -> Data {
    let url = Bundle.module.url(forResource: "official_clan_war_full", withExtension: "json")!
    return try! Data(contentsOf: url)
}

final class ClanWarDecodeTests: XCTestCase {
    private func decode(_ data: Data) throws -> OfficialClanWarSnapshot {
        try JSONDecoder().decode(OfficialClanWarSnapshot.self, from: data)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json")!)
    }

    // MARK: - 成功路径

    func testDecodeFullInWarFixture() throws {
        let war = try decode(fullClanWarFixtureData())

        XCTAssertEqual(war.state, "inWar")
        XCTAssertEqual(war.teamSize, 30)
        XCTAssertEqual(war.attacksPerMember, 2)
        XCTAssertEqual(war.preparationStartTime, "20260804T080000.000Z")
        XCTAssertEqual(war.endTime, "20260806T100000.000Z")
        XCTAssertEqual(war.clan?.tag, "#CLANANONYMIZED")
        XCTAssertEqual(war.clan?.attacks, 57)
        XCTAssertEqual(war.clan?.stars, 88)
        XCTAssertEqual(war.clan?.destructionPercentage, 91.2)
        XCTAssertEqual(war.clan?.clanLevel, 12)
        XCTAssertEqual(war.opponent?.name, "anonymized-opponent")
        XCTAssertEqual(war.opponent?.stars, 82)
        // 官方新增字段进入审计
        XCTAssertEqual(war.unrecognizedKeys, ["newOfficialField"])
    }

    /// Issue #95 验收标准第 3 条闭环：战争 fixture 的 clanLevel（我方 12 /
    /// 对方 11）经 ClanDisplayFormat.clanLevelLabel 必须输出部落等级文案，
    /// 而非"X级大本营"。本测试把 fixture → 解码 → 文案连成一条链路：
    /// fixture 值变更或格式化回归都会在此失败（此前 fixture 解码断言与
    /// 格式化断言相互独立，未验证两者连接）。
    func testWarFixtureClanLevelRendersAsClanLevelLabel() throws {
        let war = try decode(fullClanWarFixtureData())
        XCTAssertEqual(ClanDisplayFormat.clanLevelLabel(war.clan?.clanLevel), "部落等级 12")
        XCTAssertEqual(ClanDisplayFormat.clanLevelLabel(war.opponent?.clanLevel), "部落等级 11")
        // nil 缺失契约：participantRow 的 if-let 渲染分支依赖 label 返回 nil
        XCTAssertNil(ClanDisplayFormat.clanLevelLabel(nil))
    }

    /// battleModifier（Hard Mode 战争的官方字段）解码保存原始值，
    /// 且不得进入 unrecognizedKeys（known key 审计豁免）。
    func testBattleModifierDecodesFromFullFixture() throws {
        let war = try decode(fullClanWarFixtureData())
        XCTAssertEqual(war.battleModifier, "hardMode", "fixture 带 hardMode，应保存原始值")
        XCTAssertFalse(war.unrecognizedKeys.contains("battleModifier"),
                       "battleModifier 是官方已知字段，不应作为未知键上报")
    }

    /// 未知非空 battleModifier（未来官方值域）必须容错：解码成功、保留原始值、
    /// 不进 unrecognizedKeys（known key 审计豁免）。
    func testDecodeUnknownBattleModifierPreserved() throws {
        let war = try decode(Data(#"{"state":"inWar","battleModifier":"futureX"}"#.utf8))
        XCTAssertEqual(war.state, "inWar")
        XCTAssertEqual(war.battleModifier, "futureX", "未知值原样保留（可审计 fallback）")
        XCTAssertTrue(war.unrecognizedKeys.isEmpty)
    }

    /// battleModifier 缺失或显式 null 都是合法响应：解码为 nil（非战争/普通战争）。
    func testDecodeMissingOrNullBattleModifierYieldsNil() throws {
        let missing = try decode(Data(#"{"state":"inWar"}"#.utf8))
        XCTAssertNil(missing.battleModifier)

        let explicitNull = try decode(Data(#"{"state":"inWar","battleModifier":null}"#.utf8))
        XCTAssertNil(explicitNull.battleModifier, "显式 null 与缺失等价")
        XCTAssertTrue(explicitNull.unrecognizedKeys.isEmpty)
    }

    /// 编码契约：battleModifier 为 nil 时不输出该键（持久化体积不膨胀）。
    func testEncodeOmitsNilBattleModifier() throws {
        let war = OfficialClanWarSnapshot(
            state: "inWar", teamSize: nil, attacksPerMember: nil,
            preparationStartTime: nil, startTime: nil, endTime: nil, warStartTime: nil,
            battleModifier: nil, clan: nil, opponent: nil, unrecognizedKeys: []
        )
        let json = String(data: try JSONEncoder().encode(war), encoding: .utf8)!
        XCTAssertFalse(json.contains("battleModifier"), "nil battleModifier 不应编码")
    }

    /// notInWar 是合法的成功响应（空状态，不是失败）。
    func testDecodeNotInWarSucceeds() throws {
        let war = try decode(fixture("official_clan_war_notinwar"))

        XCTAssertEqual(war.state, "notInWar")
        XCTAssertNil(war.teamSize)
        XCTAssertNil(war.clan)
        XCTAssertNil(war.opponent)
        XCTAssertTrue(war.unrecognizedKeys.isEmpty)
    }

    /// warEnded 无 preparationStartTime 等部分字段缺失时不破坏解码。
    func testDecodeWarEndedWithPartialFields() throws {
        let war = try decode(fixture("official_clan_war_ended"))

        XCTAssertEqual(war.state, "warEnded")
        XCTAssertNil(war.preparationStartTime, "warEnded 无 preparationStartTime，应容忍缺失")
        XCTAssertEqual(war.warStartTime, "20260728T100000.000Z")
        XCTAssertEqual(war.clan?.stars, 95)
        XCTAssertEqual(war.clan?.destructionPercentage, 100.0)
    }

    func testDecodeEmptyObjectSucceeds() throws {
        let war = try decode(Data("{}".utf8))
        XCTAssertNil(war.state)
        XCTAssertNil(war.clan)
        XCTAssertTrue(war.unrecognizedKeys.isEmpty)
    }

    /// 回归护栏：members 已被解析时，顶层摘要（attacks）仍保持正确。
    func testDecodeToleratesMemberArrays() throws {
        let war = try decode(fullClanWarFixtureData())
        XCTAssertEqual(war.clan?.attacks, 57, "成员数组存在时顶层摘要仍正确")
    }

    // MARK: - 成员级攻击表（Issue #20）

    /// 成员级攻击表解码：full fixture 每方 1 名成员（官方 ClanWarMember 形态：
    /// townhallLevel 小写 h、attacks 为攻击数组、opponentAttacks 为次数）。
    func testDecodeClanWarMembers() throws {
        let war = try decode(fullClanWarFixtureData())

        let clanMembers = try XCTUnwrap(war.clan?.members, "clan.members 应被解析")
        XCTAssertEqual(clanMembers.count, 1)
        let member = try XCTUnwrap(clanMembers.first)
        XCTAssertEqual(member.tag, "#PLAYERANONYMIZED")
        XCTAssertEqual(member.name, "anonymized-member")
        XCTAssertEqual(member.townhallLevel, 13, "官方字段名 townhallLevel（小写 h）")
        XCTAssertEqual(member.mapPosition, 1)
        XCTAssertEqual(member.attacks?.count, 1, "attacks 是攻击数组")
        XCTAssertEqual(member.attacks?.first?.stars, 3)
        XCTAssertEqual(member.attacks?.first?.destructionPercentage, 100)
        XCTAssertEqual(member.attacks?.first?.order, 1)
        XCTAssertEqual(member.attacks?.first?.attackerTag, "#PLAYERANONYMIZED")
        XCTAssertEqual(member.attacks?.first?.defenderTag, "#OPPONENTPLAYERANONYMIZED")
        XCTAssertEqual(member.attacks?.first?.duration, 180)
        XCTAssertEqual(member.opponentAttacks, 2, "opponentAttacks 为被攻击次数（整数）")
        XCTAssertEqual(member.bestOpponentAttack?.stars, 2)
        XCTAssertEqual(member.bestOpponentAttack?.destructionPercentage, 85)

        let opponentMembers = try XCTUnwrap(war.opponent?.members)
        XCTAssertEqual(opponentMembers.count, 1)
        XCTAssertEqual(opponentMembers.first?.townhallLevel, 12)
        XCTAssertEqual(opponentMembers.first?.attacks?.first?.defenderTag, "#PLAYERANONYMIZED")
    }

    /// 无 members 键（warEnded 等）容忍：成员为 nil，不影响摘要。
    func testDecodeWithoutMembersTolerated() throws {
        let war = try decode(fixture("official_clan_war_ended"))
        XCTAssertNil(war.clan?.members)
        XCTAssertEqual(war.clan?.stars, 95)
    }

    /// 成员字段部分缺失（仅 tag+name）不破坏解码。
    func testDecodeMemberWithPartialFields() throws {
        let war = try decode(Data(##"{"clan":{"members":[{"tag":"#A","name":"x"}]}}"##.utf8))
        XCTAssertEqual(war.clan?.members?.first?.tag, "#A")
        XCTAssertNil(war.clan?.members?.first?.townhallLevel)
        XCTAssertTrue(war.unrecognizedKeys.isEmpty, "clan 是已知键，嵌套内容不进顶层审计")
    }

    /// 编码省略 nil 字段：非 nil 的成员数组编码为 `[{}]`（元素字段全省略），
    /// 合成 Codable 的 encodeIfPresent 保证持久化体积不膨胀。
    func testEncodeOmitsNilMemberFields() throws {
        let war = OfficialClanWarSnapshot(
            state: "inWar", teamSize: nil, attacksPerMember: nil,
            preparationStartTime: nil, startTime: nil, endTime: nil, warStartTime: nil,
            battleModifier: nil,
            clan: ClanWarParticipant(
                tag: "#A", name: nil, badgeUrls: nil, clanLevel: nil,
                attacks: nil, stars: nil, destructionPercentage: nil,
                members: [ClanWarMember(
                    tag: nil, name: nil, mapPosition: nil, townhallLevel: nil,
                    attacks: nil, opponentAttacks: nil, bestOpponentAttack: nil
                )]
            ),
            opponent: nil,
            unrecognizedKeys: []
        )
        let json = String(data: try JSONEncoder().encode(war), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"members\":[{}]"), "非 nil 成员数组编码为空对象元素")
        XCTAssertFalse(json.contains("\"townhallLevel\""), "成员字段全 nil 不应编码")
        XCTAssertFalse(json.contains("\"mapPosition\""), "成员字段全 nil 不应编码")
    }

    // MARK: - Round-trip

    func testRoundTripPreservesUnrecognizedKeys() throws {
        let original = try decode(fullClanWarFixtureData())
        let decoded = try decode(try JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.unrecognizedKeys, ["newOfficialField"])
    }

    /// Round-trip：full fixture 的 battleModifier 编解码后保持（不再静默丢弃）。
    func testRoundTripPreservesBattleModifier() throws {
        let original = try decode(fullClanWarFixtureData())
        XCTAssertEqual(original.battleModifier, "hardMode")

        let decoded = try decode(try JSONEncoder().encode(original))
        XCTAssertEqual(decoded.battleModifier, "hardMode")
        XCTAssertEqual(decoded, original)
    }
}
