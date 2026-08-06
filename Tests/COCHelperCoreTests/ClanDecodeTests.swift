import Foundation
import XCTest
@testable import COCHelperCore

/// 读取完整部落 fixture（free function，避免被 @Sendable closure 捕获 self）。
func fullClanFixtureData() -> Data {
    let url = Bundle.module.url(forResource: "official_clan_full", withExtension: "json")!
    return try! Data(contentsOf: url)
}

final class ClanDecodeTests: XCTestCase {
    private func decode(_ data: Data) throws -> OfficialClanSnapshot {
        try JSONDecoder().decode(OfficialClanSnapshot.self, from: data)
    }

    // MARK: - 成功路径

    func testDecodeFullFixture() throws {
        let clan = try decode(fullClanFixtureData())

        XCTAssertEqual(clan.tag, "#CLANANONYMIZED")
        XCTAssertEqual(clan.name, "anonymized-clan")
        XCTAssertEqual(clan.type, "inviteOnly")
        XCTAssertEqual(clan.clanLevel, 12)
        XCTAssertEqual(clan.members, 48)
        XCTAssertEqual(clan.requiredTrophies, 2000)
        XCTAssertEqual(clan.requiredTownHallLevel, 8)
        XCTAssertEqual(clan.requiredBuilderBaseTrophies, 1200)
        XCTAssertEqual(clan.requiredLeagueTier, 5)
        XCTAssertEqual(clan.clanBuilderBasePoints, 12345)
        XCTAssertEqual(clan.clanCapitalPoints, 67890)
        XCTAssertEqual(clan.capitalLeague?.id, 85000006)
        XCTAssertEqual(clan.capitalLeague?.name, "Titan League I")
        XCTAssertEqual(clan.warWins, 250)
        XCTAssertEqual(clan.warLosses, 120)
        XCTAssertEqual(clan.warTies, 10)
        XCTAssertEqual(clan.warWinStreak, 4)
        XCTAssertEqual(clan.isWarLogPublic, true)
        XCTAssertEqual(clan.clanCapital?.capitalHallLevel, 7)
        XCTAssertEqual(clan.labels?.first?.name, "Clan Wars")
        XCTAssertEqual(clan.badgeUrls?["medium"], "https://api-assets.clashofclans.com/badges/200/anonymized.png")
    }

    func testDecodeMinimalFixtureSucceeds() throws {
        let minimalData = try Data(contentsOf: Bundle.module.url(
            forResource: "official_clan_minimal", withExtension: "json"
        )!)
        let clan = try decode(minimalData)

        XCTAssertEqual(clan.tag, "#MINIMALCLAN")
        XCTAssertEqual(clan.name, "minimal-clan")
        XCTAssertEqual(clan.clanLevel, 1)
        XCTAssertEqual(clan.members, 2)
        XCTAssertNil(clan.type)
        XCTAssertNil(clan.warWins)
        XCTAssertNil(clan.clanCapital)
        XCTAssertTrue(clan.unrecognizedKeys.isEmpty)
    }

    func testDecodeEmptyObjectSucceeds() throws {
        let clan = try decode(Data("{}".utf8))

        XCTAssertNil(clan.tag)
        XCTAssertNil(clan.name)
        XCTAssertNil(clan.clanLevel)
        XCTAssertNil(clan.members)
        XCTAssertNil(clan.clanCapital)
        XCTAssertTrue(clan.unrecognizedKeys.isEmpty)
    }

    // MARK: - 审计契约

    /// memberList 是官方字段但首期不解析：必须是已知键，不得进入 unrecognizedKeys。
    func testMemberListIsKnownButDeferred() throws {
        let clan = try decode(fullClanFixtureData())
        XCTAssertFalse(clan.unrecognizedKeys.contains("memberList"),
                       "memberList 是显式声明 deferred 的官方字段，不应作为未知键上报")
    }

    /// 官方新增字段应进入 unrecognizedKeys 供审计。
    func testUnknownOfficialFieldCollected() throws {
        let clan = try decode(fullClanFixtureData())
        XCTAssertTrue(clan.unrecognizedKeys.contains("newOfficialField"))
    }

    /// 其他已知字段（warLeague/chatLanguage/location 等）不得进入 unrecognizedKeys。
    func testKnownKeysNotCollected() throws {
        let clan = try decode(fullClanFixtureData())
        for key in ["tag", "name", "type", "description", "clanLevel", "clanPoints",
                    "clanBuilderBasePoints", "clanCapitalPoints", "capitalLeague",
                    "clanVersusPoints", "requiredTrophies", "requiredTownhallLevel",
                    "requiredTownHallLevel", "requiredBuilderBaseTrophies", "requiredLeagueTier",
                    "warFrequency", "warWinStreak", "warWins", "warTies", "warLosses",
                    "isWarLogPublic", "warLeague", "members", "labels",
                    "requiredVersusTrophies", "chatLanguage", "clanCapital",
                    "badgeUrls", "location", "isFamilyFriendly"] {
            XCTAssertFalse(clan.unrecognizedKeys.contains(key), "\(key) 不应作为未知键上报")
        }
    }

    // MARK: - Round-trip

    func testRoundTripPreservesUnrecognizedKeys() throws {
        let original = try decode(fullClanFixtureData())
        let data = try JSONEncoder().encode(original)
        let decoded = try decode(data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.unrecognizedKeys, original.unrecognizedKeys)
        XCTAssertEqual(decoded.unrecognizedKeys, ["newOfficialField"])
    }

    func testStateRoundTripPersistsOfficialFields() throws {
        let snapshot = try decode(fullClanFixtureData())
        let state = ClanAPIState(
            status: .success,
            clanTag: snapshot.tag,
            lastGood: snapshot,
            unrecognizedKeys: snapshot.unrecognizedKeys
        )

        let decoded = try JSONDecoder().decode(
            ClanAPIState.self,
            from: try JSONEncoder().encode(state)
        )

        XCTAssertEqual(decoded.parserVersion, "clan-snapshot-0.2")
        XCTAssertEqual(decoded.lastGood?.requiredBuilderBaseTrophies, 1200)
        XCTAssertEqual(decoded.lastGood?.requiredLeagueTier, 5)
        XCTAssertEqual(decoded.lastGood?.clanBuilderBasePoints, 12345)
        XCTAssertEqual(decoded.lastGood?.clanCapitalPoints, 67890)
        XCTAssertEqual(decoded.lastGood?.capitalLeague?.name, "Titan League I")
        XCTAssertEqual(decoded.unrecognizedKeys, ["newOfficialField"])
    }

    func testLegacyTownHallKeyDecodesAndEncodesWithOfficialSpelling() throws {
        let legacy = try decode(Data(#"{"requiredTownHallLevel":9}"#.utf8))

        XCTAssertEqual(legacy.requiredTownHallLevel, 9)
        XCTAssertTrue(legacy.unrecognizedKeys.isEmpty)

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)
        ) as? [String: Any]
        XCTAssertEqual(encoded?["requiredTownhallLevel"] as? Int, 9)
        XCTAssertNil(encoded?["requiredTownHallLevel"])
    }
}
