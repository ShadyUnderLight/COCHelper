import Foundation
import XCTest
@testable import COCHelperCore

final class ClanStateStoreTests: XCTestCase {
    // MARK: - merge 语义（换部落旧数据保留）

    func testMergeOnlyOverwritesRequestedTags() {
        let previous = [
            "#OLDCLAN": ClanAPIState(status: .success, clanTag: "#OLDCLAN"),
            "#SHARED": ClanAPIState(status: .success, clanTag: "#SHARED"),
        ]
        let refreshed = [
            "#NEWCLAN": ClanAPIState(status: .success, clanTag: "#NEWCLAN"),
            "#SHARED": ClanAPIState(status: .failed, clanTag: "#SHARED"),
        ]

        let merged = ClanStateStore(states: previous).merging(refreshed)

        XCTAssertNotNil(merged.states["#OLDCLAN"], "未请求的旧部落必须保留")
        XCTAssertEqual(merged.states["#SHARED"]?.status, .failed, "请求过的 tag 被覆盖")
        XCTAssertEqual(merged.states["#NEWCLAN"]?.status, .success)
        XCTAssertEqual(merged.states.count, 3)
    }

    func testMergeWithEmptyRefreshedKeepsEverything() {
        let previous = ["#A": ClanAPIState(status: .success, clanTag: "#A")]
        let merged = ClanStateStore(states: previous).merging([:])
        XCTAssertEqual(merged.states.count, 1)
    }

    // MARK: - 逐条容错解码（一条坏数据不株连全库）

    func testDecodeSkipsCorruptEntry() throws {
        // 第二条 state.status 类型错误（number 而非 string）。
        // 好条目必须包含 ClanAPIState 合成 Codable 的全部必填字段。
        let json = """
        [
            { "#GOOD1": { "status": "success", "clanTag": "#GOOD1", "parserVersion": "clan-snapshot-0.1", "unrecognizedKeys": [] } },
            { "#CORRUPT": { "status": 42, "clanTag": "#CORRUPT" } },
            { "#GOOD2": { "status": "failed", "clanTag": "#GOOD2", "parserVersion": "clan-snapshot-0.1", "unrecognizedKeys": [], "lastErrorReason": "boom" } }
        ]
        """.data(using: .utf8)!

        let store = try JSONDecoder().decode(ClanStateStore.self, from: json)

        XCTAssertEqual(store.states.count, 2, "坏条目必须被跳过，不株连好条目")
        XCTAssertNotNil(store.states["#GOOD1"])
        XCTAssertNotNil(store.states["#GOOD2"])
        XCTAssertNil(store.states["#CORRUPT"])
        XCTAssertEqual(store.states["#GOOD2"]?.status, .failed)
        XCTAssertEqual(store.states["#GOOD2"]?.lastErrorReason, "boom")
    }

    func testDecodeEmptyArrayYieldsEmptyStore() throws {
        let store = try JSONDecoder().decode(ClanStateStore.self, from: Data("[]".utf8))
        XCTAssertTrue(store.states.isEmpty)
    }

    // MARK: - Round-trip

    func testRoundTripPreservesAllStates() throws {
        let store = ClanStateStore(states: [
            "#A": ClanAPIState(status: .success, clanTag: "#A", fetchedAt: Date(timeIntervalSince1970: 1000)),
            "#B": ClanAPIState(status: .failed, clanTag: "#B", lastErrorReason: "x"),
        ])

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ClanStateStore.self, from: data)

        XCTAssertEqual(decoded, store)
        XCTAssertEqual(decoded.states["#A"]?.fetchedAt, Date(timeIntervalSince1970: 1000))
    }

    // MARK: - currentClanTag 派生（最近成功玩家快照 → 部落归属）

    private func playerState(clanTag: String?) -> OfficialAPIState {
        OfficialAPIState(
            status: .success,
            lastGood: OfficialPlayerSnapshot(
                tag: "#P", name: "p", townHallLevel: nil, townHallWeaponLevel: nil,
                builderHallLevel: nil, expLevel: nil, trophies: nil, bestTrophies: nil,
                warStars: nil, attackWins: nil, defenseWins: nil, builderBaseTrophies: nil,
                versusBattleWins: nil, legendStatistics: nil,
                clan: clanTag.map { PlayerClan(tag: $0, name: "c", clanLevel: nil, badgeUrls: nil) },
                role: nil, warPreference: nil, donations: nil, donationsReceived: nil,
                clanCapitalContributions: nil, league: nil, builderBaseLeague: nil,
                achievements: nil, labels: nil, playerHouse: nil,
                troops: nil, heroes: nil, spells: nil, heroEquipment: nil,
                unrecognizedKeys: []
            )
        )
    }

    func testCurrentClanTagFromValidClan() {
        let state = playerState(clanTag: "#CLAN1")
        XCTAssertEqual(state.currentClanTag, "#CLAN1")
    }

    func testCurrentClanTagNormalizesWhitespace() {
        let state = playerState(clanTag: "  #CLAN1  ")
        XCTAssertEqual(state.currentClanTag, "#CLAN1")
    }

    func testCurrentClanTagNilWhenNoClan() {
        let state = playerState(clanTag: nil)
        XCTAssertNil(state.currentClanTag)
    }

    func testCurrentClanTagNilWhenNoLastGood() {
        let state = OfficialAPIState(status: .failed, lastErrorReason: "x")
        XCTAssertNil(state.currentClanTag)
    }

    func testCurrentClanTagNilWhenInvalidFormat() {
        let state = playerState(clanTag: "#lowercase")
        XCTAssertNil(state.currentClanTag)
    }

    func testCurrentClanTagNilWhenEmptyString() {
        let state = playerState(clanTag: "")
        XCTAssertNil(state.currentClanTag)
    }
}
