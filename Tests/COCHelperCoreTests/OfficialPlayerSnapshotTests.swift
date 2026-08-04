import XCTest
@testable import COCHelperCore

final class OfficialPlayerSnapshotTests: XCTestCase {
    private var fullFixtureData: Data {
        let url = Bundle.module.url(forResource: "official_player_full", withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    private var minimalFixtureData: Data {
        let url = Bundle.module.url(forResource: "official_player_minimal", withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    // MARK: - 完整 fixture 解码

    func testDecodesFullPlayerSnapshot() throws {
        let snapshot = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullFixtureData)

        // 身份与进度
        XCTAssertEqual(snapshot.tag, "#ANONYMIZED")
        XCTAssertEqual(snapshot.name, "anonymized-player")
        XCTAssertEqual(snapshot.townHallLevel, 14)
        XCTAssertEqual(snapshot.townHallWeaponLevel, 5)
        XCTAssertEqual(snapshot.builderHallLevel, 9)
        XCTAssertEqual(snapshot.expLevel, 198)

        // 竞技状态
        XCTAssertEqual(snapshot.trophies, 4521)
        XCTAssertEqual(snapshot.bestTrophies, 5102)
        XCTAssertEqual(snapshot.warStars, 1200)
        XCTAssertEqual(snapshot.attackWins, 1900)
        XCTAssertEqual(snapshot.defenseWins, 450)
        XCTAssertEqual(snapshot.builderBaseTrophies, 3100)
        XCTAssertEqual(snapshot.versusBattleWins, 600)

        // 传奇联赛
        let legend = try XCTUnwrap(snapshot.legendStatistics)
        XCTAssertEqual(legend.bestSeason?.id, "2024-06")
        XCTAssertEqual(legend.bestSeason?.rank, 9000)
        XCTAssertEqual(legend.bestSeason?.trophies, 5021)
        XCTAssertEqual(legend.previousSeason?.trophies, 4890)
        XCTAssertEqual(legend.currentSeason?.trophies, 4200)

        // 部落摘要
        let clan = try XCTUnwrap(snapshot.clan)
        XCTAssertEqual(clan.tag, "#CLANANON")
        XCTAssertEqual(clan.name, "anonymized clan")
        XCTAssertEqual(clan.clanLevel, 15)
        XCTAssertEqual(clan.badgeUrls?["medium"], "https://api-assets.clashofclans.com/badges/288/anon.png")
        XCTAssertEqual(snapshot.role, "member")
        XCTAssertEqual(snapshot.warPreference, "out")
        XCTAssertEqual(snapshot.donations, 500)
        XCTAssertEqual(snapshot.donationsReceived, 300)
        XCTAssertEqual(snapshot.clanCapitalContributions, 2000)

        // 联赛
        XCTAssertEqual(snapshot.league?.id, 29000022)
        XCTAssertEqual(snapshot.league?.name, "Champion League II")
        XCTAssertEqual(snapshot.builderBaseLeague?.name, "Legend League")

        // 成就与标签
        XCTAssertEqual(snapshot.achievements?.count, 2)
        XCTAssertEqual(snapshot.achievements?.first?.name, "Nice and Tidy")
        XCTAssertEqual(snapshot.achievements?.first?.village, "home")
        XCTAssertEqual(snapshot.labels?.first?.name, "Friendly Wars")
        XCTAssertEqual(snapshot.labels?.first?.id, 57000023)

        // 玩家小屋
        XCTAssertEqual(snapshot.playerHouse?.elements?.count, 2)
        XCTAssertEqual(snapshot.playerHouse?.elements?.first?.type, "ground")

        // 单位与装备
        XCTAssertEqual(snapshot.troops?.count, 3)
        XCTAssertEqual(snapshot.troops?[0].name, "Barbarian")
        XCTAssertEqual(snapshot.troops?[0].level, 10)
        XCTAssertEqual(snapshot.troops?[0].maxLevel, 11)
        XCTAssertEqual(snapshot.troops?[2].superTroopIsActive, true)
        XCTAssertEqual(snapshot.heroes?.count, 2)
        XCTAssertEqual(snapshot.heroes?[1].village, "builderBase")
        XCTAssertEqual(snapshot.spells?.first?.name, "Lightning Spell")
        XCTAssertEqual(snapshot.heroEquipment?.first?.name, "Eternal Tome")

        // 未识别字段可审计（versusTrophies 等旧字段 + 未来字段）
        let unrecognized = snapshot.unrecognizedKeys.sorted()
        XCTAssertEqual(unrecognized, ["bestVersusTrophies", "futureUnknownField", "versusTrophies"])
    }

    // MARK: - 最小响应

    func testDecodesMinimalPlayerSnapshot() throws {
        let snapshot = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: minimalFixtureData)

        XCTAssertEqual(snapshot.tag, "#MINIMAL")
        XCTAssertEqual(snapshot.name, "minimal-player")
        XCTAssertNil(snapshot.townHallLevel)
        XCTAssertNil(snapshot.clan)
        XCTAssertNil(snapshot.legendStatistics)
        XCTAssertNil(snapshot.troops)
        XCTAssertTrue(snapshot.unrecognizedKeys.isEmpty)
    }

    // MARK: - 部分字段缺失（troops 子字段缺失不破坏解码）

    func testDecodesTroopWithMissingSubfields() throws {
        let json = """
        {
          "tag": "#PARTIAL",
          "troops": [
            { "name": "Barbarian", "level": 10 },
            { "name": "Archer" }
          ]
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: json)
        XCTAssertEqual(snapshot.troops?.count, 2)
        XCTAssertNil(snapshot.troops?[0].maxLevel)
        XCTAssertNil(snapshot.troops?[1].level)
        XCTAssertEqual(snapshot.troops?[1].name, "Archer")
    }

    // MARK: - 空对象与未知字段

    func testDecodesEmptyObjectToAllNil() throws {
        let snapshot = try JSONDecoder().decode(
            OfficialPlayerSnapshot.self,
            from: Data("{}".utf8)
        )
        XCTAssertNil(snapshot.tag)
        XCTAssertNil(snapshot.name)
        XCTAssertNil(snapshot.clan)
        XCTAssertTrue(snapshot.unrecognizedKeys.isEmpty)
    }

    func testUnknownTopLevelFieldsAreCollected() throws {
        let json = """
        {
          "tag": "#UNKNOWN",
          "weirdFutureField": { "a": 1 },
          "anotherUnknown": [1, 2, 3]
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: json)
        XCTAssertEqual(snapshot.tag, "#UNKNOWN")
        XCTAssertEqual(snapshot.unrecognizedKeys.sorted(), ["anotherUnknown", "weirdFutureField"])
    }

    // MARK: - 部分响应容忍（P2 修复）

    func testDecodesPlayerHouseWithMissingElements() throws {
        // elements 缺失/为空对象时仍应解码成功（与"部分字段缺失不破坏解码"契约一致）。
        let json = """
        {
          "tag": "#HOUSE",
          "playerHouse": {}
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: json)
        XCTAssertEqual(snapshot.tag, "#HOUSE")
        XCTAssertEqual(snapshot.playerHouse?.elements, nil)
    }

    func testDecodesPlayerHouseWithElements() throws {
        let json = """
        {
          "tag": "#HOUSE",
          "playerHouse": { "elements": [ { "id": 59000000, "type": "ground", "level": 1 } ] }
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: json)
        XCTAssertEqual(snapshot.playerHouse?.elements?.count, 1)
        XCTAssertEqual(snapshot.playerHouse?.elements?.first?.type, "ground")
    }

    // MARK: - Codable round-trip（持久化可编码）

    func testSnapshotCodableRoundTrip() throws {
        let original = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullFixtureData)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.unrecognizedKeys.sorted(), original.unrecognizedKeys.sorted())
    }
}
