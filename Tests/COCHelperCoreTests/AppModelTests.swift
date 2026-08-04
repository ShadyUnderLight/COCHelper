import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

/// P1 回归测试：单村庄玩家刷新完成后，部落联动必须作用于**发起村庄**，
/// 而非当前选中村庄（刷新期间切换村庄不得误刷新）。
///
/// 注意：类级不标 @MainActor——XCTest 的 setUp/tearDown 是 nonisolated
/// override，访问隔离属性会产生 Swift 6 严格并发 warning；改为在需要
/// 操作 AppModel（@MainActor）的测试方法与 helper 上单独标注。
final class AppModelTests: XCTestCase {
    /// 线程安全的请求记录器（同步方法内使用锁，避免 async 上下文锁限制）。
    private final class TagRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var tags: [String] = []

        func record(_ tag: String) {
            lock.lock()
            tags.append(tag)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return tags
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        // 按 suite 名清理测试域（UserDefaults 无公开 suiteName getter，
        // 由 setUp 记录；避免每次运行泄漏一个 plist）。
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    /// 带部落归属的玩家官方状态（构造 lastGood + clan）。
    private func playerState(clanTag: String) -> OfficialAPIState {
        OfficialAPIState(
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
    }

    @MainActor
    private func makeModel(
        playerHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data),
        clanHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> AppModel {
        // 两个村庄：A 在 #CLANA，B 在 #CLANB（带导入快照使 officialTag 有效，
        // 否则玩家刷新会走 skipped 分支，无法触发网络请求与联动）。
        func snapshot(_ tag: String) -> AccountSnapshot {
            AccountSnapshot(
                tag: tag, capturedAt: nil, importedAt: Date(), ageSeconds: nil,
                originalText: "{}", objectSections: [:], numericSections: [:],
                boosts: [:], unknownTopLevelKeys: [], diagnostics: []
            )
        }
        let villages = [
            VillageProfile(name: "A", accountSnapshot: snapshot("#A"), officialAPIState: playerState(clanTag: "#CLANA")),
            VillageProfile(name: "B", accountSnapshot: snapshot("#B"), officialAPIState: playerState(clanTag: "#CLANB")),
        ]
        let data = try JSONEncoder().encode(villages)
        defaults.set(data, forKey: "coc-helper.villages.v1")

        MockURLProtocol.handler = { request in
            if request.url?.path.hasPrefix("/v1/players/") == true {
                return try playerHandler(request)
            }
            return try clanHandler(request)
        }
        let playerRefresher = OfficialPlayerRefresher(client: CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession()
        ) { "fake-token" })
        let clanRefresher = ClanRefresher(client: CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession()
        ) { "fake-token" })
        return AppModel(defaults: defaults, refresher: playerRefresher, clanRefresher: clanRefresher)
    }

    private func response(_ status: Int, url: URL, body: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("等待条件超时")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - P1：切换村庄后联动刷新发起村庄

    /// 刷新村庄 A 的玩家数据期间切换到村庄 B：
    /// - A 的玩家快照落地后，必须刷新 **A** 的部落（#CLANA）
    /// - 不得刷新 B 的部落（#CLANB）
    @MainActor
    func testSingleRefreshCascadesToOriginatingVillageAfterSwitch() async throws {
        let playerHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             fullPlayerFixtureData())
        }
        // clan handler 记录收到的部落 tag
        let clanRecorder = TagRecorder()
        let clanHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            let path = request.url?.path ?? ""
            let raw = path.replacingOccurrences(of: "/v1/clans/", with: "")
                .replacingOccurrences(of: "%23", with: "#")
            clanRecorder.record(raw)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullClanFixtureData())
        }

        let model = try makeModel(playerHandler: playerHandler, clanHandler: clanHandler)

        // 发起村庄 A 的玩家刷新，随后立即切换到村庄 B（结果落地前）
        model.refreshOfficialPlayer()
        model.selectVillage(id: model.villages[1].id)

        // 等待玩家刷新 + 部落联动全部完成
        await waitUntil { !model.isRefreshingOfficialData && !model.isRefreshingClanData }

        let tags = clanRecorder.snapshot()

        // 玩家刷新后 A 的归属来自 mock 响应（fixture clan #CLANANON），
        // 联动必须刷新它；#CLANB 是当前选中村庄 B 的初始构造 tag，绝不能出现。
        XCTAssertEqual(tags, ["#CLANANON"],
                       "必须刷新发起村庄 A 刷新后的部落（#CLANANON），不得刷新当前选中的 B（#CLANB）: \(tags)")
        XCTAssertNotNil(model.clanStates["#CLANANON"], "A 的部落状态应存在")
        XCTAssertNil(model.clanStates["#CLANB"], "B 的部落不应被误刷新")
    }

    /// 联动刷新失败时不丢弃 A 的 last-good（既有契约在联动路径上保持）。
    @MainActor
    func testSingleRefreshFailureDoesNotCascadeClanRefresh() async throws {
        let playerHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            // 玩家请求失败（断网/429 场景）
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }
        let clanRecorder = TagRecorder()
        let clanHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            clanRecorder.record("clan-request")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullClanFixtureData())
        }

        let model = try makeModel(playerHandler: playerHandler, clanHandler: clanHandler)

        model.refreshOfficialPlayer()
        await waitUntil { !model.isRefreshingOfficialData }

        XCTAssertEqual(clanRecorder.snapshot().count, 0, "玩家刷新失败不得触发部落联动（避免限流边界放大请求面）")
        XCTAssertEqual(model.currentVillageOfficialState?.status, .failed)
    }
}
