import Foundation
import XCTest
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

    /// battleModifier（Hard Mode 战争的官方字段）是已知但 deferred：
    /// 不得进入 unrecognizedKeys，避免有效 Hard Mode 响应误报"未识别字段"。
    func testBattleModifierIsKnownButDeferred() throws {
        let war = try decode(fullClanWarFixtureData())
        XCTAssertFalse(war.unrecognizedKeys.contains("battleModifier"),
                       "battleModifier 是官方已知字段（deferred），不应作为未知键上报")

        // 单独验证：battleModifier 单独出现时也不进审计
        let minimal = try decode(Data(#"{"state":"inWar","battleModifier":"hardMode"}"#.utf8))
        XCTAssertTrue(minimal.unrecognizedKeys.isEmpty)
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

    /// 成员级数组（members）嵌套容忍：官方返回完整成员时不破坏解码，
    /// 首期不解析（deferred），不影响顶层摘要。
    func testDecodeToleratesMemberArrays() throws {
        let war = try decode(fullClanWarFixtureData())
        XCTAssertEqual(war.clan?.attacks, 57, "成员数组存在时顶层摘要仍正确")
    }

    // MARK: - Round-trip

    func testRoundTripPreservesUnrecognizedKeys() throws {
        let original = try decode(fullClanWarFixtureData())
        let decoded = try decode(try JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.unrecognizedKeys, ["newOfficialField"])
    }
}
