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

    // MARK: - leagueTier（2026 排位段位，Issue #71）

    func testDecodesLeagueTierFromFullFixture() throws {
        let snapshot = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullFixtureData)
        let tier = try XCTUnwrap(snapshot.leagueTier)
        // fixture 使用真实段位 ID：105000036 = 传奇杯1（官方静态数据 2026-08）
        XCTAssertEqual(tier.id, 105000036)
        XCTAssertEqual(tier.name, "Legend League")
        XCTAssertEqual(tier.iconUrls?.count, 3)
        XCTAssertEqual(tier.iconUrls?["medium"], "https://api-assets.clashofclans.com/leagues/288/anon.png")
    }

    func testLeagueTierNotCollectedAsUnrecognized() throws {
        // leagueTier 是已知键：加入 fixture 后不得再被收集进 unrecognizedKeys。
        let snapshot = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullFixtureData)
        XCTAssertFalse(snapshot.unrecognizedKeys.contains("leagueTier"))
        // 注意：unrecognizedKeys 的精确集合是故意 pin 的 canary——fixture 新增
        // 未知键或建模 bestVersusTrophies/versusTrophies/futureUnknownField 时
        // 此断言会碎，届时须同步更新（双向防回归：既防合法字段漏收，也防
        // 未知字段误收）。
        XCTAssertEqual(
            snapshot.unrecognizedKeys.sorted(),
            ["bestVersusTrophies", "futureUnknownField", "versusTrophies"]
        )
    }

    func testSnapshotWithoutLeagueTierDecodesToNil() throws {
        // 旧 JSON（无 leagueTier 键）兼容：解码成功且 leagueTier == nil。
        let json = """
        {
          "tag": "#OLDTIER",
          "league": { "id": 29000022, "name": "Champion League II" }
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: json)
        XCTAssertEqual(snapshot.league?.id, 29000022)
        XCTAssertNil(snapshot.leagueTier)
        XCTAssertEqual(snapshot.unrecognizedKeys, [])
    }

    func testLeagueTierCodableRoundTrip() throws {
        let original = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullFixtureData)
        let restored = try JSONDecoder().decode(
            OfficialPlayerSnapshot.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.leagueTier, original.leagueTier)
        XCTAssertEqual(restored.leagueTier?.id, 105000036)
        XCTAssertEqual(restored.leagueTier?.name, "Legend League")
    }

    // MARK: - Codable round-trip（持久化可编码）

    func testSnapshotCodableRoundTrip() throws {
        let original = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullFixtureData)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.unrecognizedKeys.sorted(), original.unrecognizedKeys.sorted())
    }

    // MARK: - 大本营武器等级三态显示契约（Issue #75 工作流 B）

    private func decodeSnapshot(_ json: String) throws -> OfficialPlayerSnapshot {
        try JSONDecoder().decode(
            OfficialPlayerSnapshot.self,
            from: Data(json.utf8)
        )
    }

    /// 官方 `townHallWeaponLevel` 三态（值 / 显式 null / 键缺失）必须可区分。
    func testWeaponLevelThreeStatesDecode() throws {
        // 1) 官方提供有效等级
        let level = try decodeSnapshot(#"{"townHallWeaponLevel": 5}"#)
        XCTAssertEqual(level.townHallWeaponLevel, 5)
        XCTAssertEqual(level.townHallWeaponLevelKeyPresent, true)
        XCTAssertEqual(level.townHallWeaponLevelDisplayState, .level(5))

        // 2) 官方显式 null：武器保留但无等级维度（12–15 本移除等级后官方返回 null，
        //    不能推断为"未建造"——UI 隐藏整行）。
        let explicitNull = try decodeSnapshot(#"{"townHallWeaponLevel": null}"#)
        XCTAssertNil(explicitNull.townHallWeaponLevel)
        XCTAssertEqual(explicitNull.townHallWeaponLevelKeyPresent, true)
        XCTAssertEqual(explicitNull.townHallWeaponLevelDisplayState, .notApplicable)

        // 3) 官方未提供该字段（键缺失）：区别于显式 null。
        let missing = try decodeSnapshot(##"{"tag": "#X"}"##)
        XCTAssertNil(missing.townHallWeaponLevel)
        XCTAssertEqual(missing.townHallWeaponLevelKeyPresent, false)
        XCTAssertEqual(missing.townHallWeaponLevelDisplayState, .notProvided)
    }

    /// S2 旧缓存兼容：旧版产物 JSON 无 marker 键 → presence 默认 true。
    /// 判别：旧版产物恒含 `unrecognizedKeys` 键（本模型 encode 恒写），
    /// 官方原始 JSON 永不含该键——两者由此区分。
    func testLegacyCacheWithoutMarkerDefaultsToPresent() throws {
        // 旧版产物（无 marker 键 + 有 unrecognizedKeys 键）：有武器等级 → 视为 API 显式提供。
        let withWeapon = try decodeSnapshot(#"{"townHallWeaponLevel": 5, "unrecognizedKeys": []}"#)
        XCTAssertEqual(withWeapon.townHallWeaponLevelKeyPresent, true)
        XCTAssertEqual(withWeapon.townHallWeaponLevelDisplayState, .level(5))

        // 旧版产物（无 marker 键 + 无武器键 + 有 unrecognizedKeys 键）→ presence 默认 true →
        // notApplicable。升级零过渡噪音：刷新前隐藏而非"未提供"（旧缓存视为 API 显式 null 语义）。
        let noWeapon = try decodeSnapshot(##"{"tag": "#LEGACY", "unrecognizedKeys": []}"##)
        XCTAssertEqual(noWeapon.townHallWeaponLevelKeyPresent, true)
        XCTAssertEqual(noWeapon.townHallWeaponLevelDisplayState, .notApplicable)
    }

    /// 核心契约：显式 null 与键缺失在持久化（encode → decode）中必须保持区分。
    func testWeaponPresenceRoundTripProperty() throws {
        var rng = SeededRNG(seed: 0x7E_15_B0)
        for iteration in 0..<500 {
            let presence = Bool.random(using: &rng)
            // presence=true 时 value 随机 nil 或 0..<10；presence=false 时 value 恒 nil。
            let value: Int? = presence && Bool.random(using: &rng) ? Int(rng.next() % 10) : nil

            let original = makeWeaponSnapshot(weaponLevel: value, keyPresent: presence)
            let data = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: data)

            XCTAssertEqual(
                restored,
                original,
                "round-trip 不等 (iter=\(iteration) presence=\(presence) value=\(String(describing: value)))"
            )

            // JSON 层验证：marker 恒写；武器键三态与 presence/value 一致。
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any],
                "iter=\(iteration): encode 输出应可解析为字典"
            )
            XCTAssertEqual(
                json["townHallWeaponLevelKeyPresent"] as? Bool,
                presence,
                "iter=\(iteration): marker 键应恒写且等于 presence"
            )
            if presence, let value {
                XCTAssertEqual(
                    json["townHallWeaponLevel"] as? Int,
                    value,
                    "iter=\(iteration): presence=true 且 value 非 nil 时键应为数字"
                )
            } else if presence {
                XCTAssertTrue(
                    json["townHallWeaponLevel"] is NSNull,
                    "iter=\(iteration): presence=true 且 value nil 时键应存在且为显式 null"
                )
            } else {
                XCTAssertNil(
                    json["townHallWeaponLevel"],
                    "iter=\(iteration): presence=false 时不应写武器键"
                )
            }
        }
    }

    /// marker 键是 known key：round-trip 后不得被收集进 unrecognizedKeys。
    func testPresenceKeyNotCollectedAsUnrecognized() throws {
        let original = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullFixtureData)
        let restored = try JSONDecoder().decode(
            OfficialPlayerSnapshot.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertFalse(restored.unrecognizedKeys.contains("townHallWeaponLevelKeyPresent"))
        XCTAssertEqual(restored, original)
    }

    /// parserVersion 递增：0.2 = 开始跟踪 townHallWeaponLevel 键存在性（schema 审计）。
    func testCurrentParserVersionTracksWeaponPresenceTracking() {
        XCTAssertEqual(OfficialAPIState.currentParserVersion, "player-snapshot-0.2")
    }

    /// 构造最小快照（仅武器相关字段参与三态契约）。
    private func makeWeaponSnapshot(weaponLevel: Int?, keyPresent: Bool) -> OfficialPlayerSnapshot {
        OfficialPlayerSnapshot(
            tag: "#W", name: "w",
            townHallLevel: 1, townHallWeaponLevel: weaponLevel,
            townHallWeaponLevelKeyPresent: keyPresent,
            builderHallLevel: 1, expLevel: 1,
            trophies: nil, bestTrophies: nil, warStars: nil, attackWins: nil, defenseWins: nil,
            builderBaseTrophies: nil, versusBattleWins: nil, legendStatistics: nil,
            clan: nil, role: nil, warPreference: nil, donations: nil,
            donationsReceived: nil, clanCapitalContributions: nil,
            league: nil, builderBaseLeague: nil,
            achievements: nil, labels: nil, playerHouse: nil,
            troops: nil, heroes: nil, spells: nil, heroEquipment: nil,
            unrecognizedKeys: []
        )
    }
}
