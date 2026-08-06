import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

final class AppModelTrackedClansTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelTrackedClansTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    private func makeModel() throws -> AppModel {
        AppModel(defaults: defaults)
    }

    /// 通过村庄存储注入带官方玩家快照的村庄（与 Issue35/AppModelTests 同构，
    /// 无需网络：isCurrentVillageClan 是纯查询）。
    @MainActor
    private func makeModel(villages: [VillageProfile]) throws -> AppModel {
        let data = try JSONEncoder().encode(villages)
        defaults.set(data, forKey: "coc-helper.villages.v1")
        return AppModel(defaults: defaults)
    }

    /// 带官方玩家快照的村庄：lastGood.clan.tag 决定 currentVillageClanTag。
    private func villageWithOfficialClan(clanTag: String) -> VillageProfile {
        VillageProfile(
            name: "官方村",
            officialAPIState: OfficialAPIState(
                status: .success,
                lastGood: OfficialPlayerSnapshot(
                    tag: "#P", name: "p", townHallLevel: nil, townHallWeaponLevel: nil,
                    builderHallLevel: nil, expLevel: nil, trophies: nil, bestTrophies: nil,
                    warStars: nil, attackWins: nil, defenseWins: nil, builderBaseTrophies: nil,
                    versusBattleWins: nil, legendStatistics: nil,
                    clan: PlayerClan(tag: clanTag, name: "c", clanLevel: nil, badgeUrls: nil),
                    role: nil, warPreference: nil, donations: nil, donationsReceived: nil,
                    clanCapitalContributions: nil, league: nil, builderBaseLeague: nil,
                    achievements: nil, labels: nil, playerHouse: nil,
                    troops: nil, heroes: nil, spells: nil, heroEquipment: nil,
                    unrecognizedKeys: []
                )
            )
        )
    }

    @MainActor
    func testAddTrackedClanSuccess() throws {
        let model = try makeModel()
        let result = model.addTrackedClan(rawTag: "  #2qjq8j88  ", displayName: "我的部落")
        let profile = try XCTUnwrap(result.getSuccess())
        XCTAssertEqual(profile.clanTag, "#2QJQ8J88")
        XCTAssertEqual(profile.displayName, "我的部落")
        XCTAssertEqual(model.trackedClans.count, 1)
    }

    @MainActor
    func testAddTrackedClanInvalidTag() throws {
        let model = try makeModel()
        for bad in ["", "   ", "#", "2QJQ8J88", "#abc-def", nil] {
            let result = model.addTrackedClan(rawTag: bad, displayName: nil)
            guard case .failure(.invalidTag) = result else {
                return XCTFail("\(String(describing: bad)) 应报 invalidTag")
            }
        }
        XCTAssertTrue(model.trackedClans.isEmpty, "非法输入不得产生档案")
    }

    @MainActor
    func testAddTrackedClanDuplicate() throws {
        let model = try makeModel()
        XCTAssertNotNil(model.addTrackedClan(rawTag: "#ABC123", displayName: nil).getSuccess())
        let second = model.addTrackedClan(rawTag: "  #abc123  ", displayName: "别的名字")
        guard case .failure(.duplicate) = second else {
            return XCTFail("重复 tag 应报 duplicate")
        }
        XCTAssertEqual(model.trackedClans.count, 1, "重复添加不得产生重复档案")
        XCTAssertEqual(model.trackedClans[0].displayName, nil, "重复添加不得覆盖原档案")
    }

    @MainActor
    func testAddTrackedClanWhitespaceDisplayNameBecomesNil() throws {
        let model = try makeModel()
        let result = model.addTrackedClan(rawTag: "#AAA111", displayName: "   ")
        XCTAssertEqual(result.getSuccess()?.displayName, nil, "纯空白备注应存为 nil")
    }

    @MainActor
    func testTrackedClansPersistAcrossReload() throws {
        let model = try makeModel()
        _ = model.addTrackedClan(rawTag: "#AAA111", displayName: "甲")
        _ = model.addTrackedClan(rawTag: "#BBB222", displayName: nil)
        let reloaded = AppModel(defaults: defaults)
        XCTAssertEqual(reloaded.trackedClans.map(\.clanTag), ["#AAA111", "#BBB222"])
        XCTAssertEqual(reloaded.trackedClans[0].displayName, "甲")
    }

    @MainActor
    func testTrackedClansEmptyWhenNoStorage() throws {
        let model = try makeModel()
        XCTAssertTrue(model.trackedClans.isEmpty, "旧版本无该 key 必须正常启动为空")
    }

    @MainActor
    func testRemoveTrackedClanKeepsSharedClanStateCache() throws {
        let model = try makeModel()
        _ = model.addTrackedClan(rawTag: "#CCC333", displayName: nil)
        model.seedClanStateForTesting(tag: "#CCC333")
        model.removeTrackedClan(tag: "#CCC333")
        XCTAssertTrue(model.trackedClans.isEmpty)
        XCTAssertNotNil(model.clanState(for: "#CCC333"), "删除跟踪关系必须保留按 Tag 的 API 缓存")
    }

    @MainActor
    func testRemoveTrackedClanIdempotent() throws {
        let model = try makeModel()
        _ = model.addTrackedClan(rawTag: "#DDD444", displayName: nil)
        model.removeTrackedClan(tag: "#DDD444")
        model.removeTrackedClan(tag: "#DDD444")
        model.removeTrackedClan(tag: "#NOT_EXIST")
        XCTAssertTrue(model.trackedClans.isEmpty)
    }

    @MainActor
    func testIsCurrentVillageClan() throws {
        let model = try makeModel()
        XCTAssertFalse(model.isCurrentVillageClan("#XXX999"), "无玩家快照时不应误报")
    }

    @MainActor
    func testIsCurrentVillageClanPositivePath() throws {
        let model = try makeModel(villages: [villageWithOfficialClan(clanTag: "#VILLAGECLAN")])
        XCTAssertEqual(model.currentVillageClanTag, "#VILLAGECLAN")
        XCTAssertTrue(model.isCurrentVillageClan("#VILLAGECLAN"), "玩家快照的部落 tag 应命中")
        XCTAssertFalse(model.isCurrentVillageClan("#OTHER"), "非当前归属 tag 不应命中")
    }

    @MainActor
    func testCorruptTrackedClansStorageDoesNotCrashInit() throws {
        defaults.set(Data("垃圾数据".utf8), forKey: "coc-helper.tracked-clans.v1")
        let model = try makeModel()
        XCTAssertTrue(model.trackedClans.isEmpty, "存储整体损坏应空库启动，不崩溃")
    }
}

private extension Result {
    func getSuccess() -> Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
