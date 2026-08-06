import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

/// 可用部落档案 JSON（字段以 AppModelTests 现有 clan 响应为准）。
/// free function：避免被 @Sendable closure 捕获 self。
private func trackedClanJSON(tag: String) -> Data {
    Data("""
    {"tag":"\(tag)","name":"测试部落","clanLevel":3,"members":5,
     "type":"open","requiredTrophies":0,"warWins":10,"warLosses":2,
     "warTies":0,"warWinStreak":1,"isWarLogPublic":true,"badgeUrls":{}}
    """.utf8)
}

/// 带导入快照的村庄档案（officialTag 有效）。仿 AppModelTests.makeModel。
private func trackedClanTestSnapshot(_ tag: String) -> AccountSnapshot {
    AccountSnapshot(
        tag: tag, capturedAt: nil, importedAt: Date(), ageSeconds: nil,
        originalText: "{}", objectSections: [:], numericSections: [:],
        boosts: [:], unknownTopLevelKeys: [], diagnostics: []
    )
}

/// 带部落归属的玩家官方状态（构造 lastGood + clan）。仿 AppModelTests。
private func trackedClanTestPlayerState(clanTag: String) -> OfficialAPIState {
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

/// Issue #41：AppModel 按显式 Tag 的部落刷新入口（手动部落）。
///
/// 村庄入口（villageID 版）转发到 tag 版，共享同一状态层（clanStates 等）
/// 与防重入守卫（isRefreshingClanData 等）。本类验证 tag 版 API 的请求路径、
/// 排队语义、共享状态，村庄转发由既有 AppModelTests（全绿）作回归闸门。
final class AppModelTrackedClanRefreshTests: XCTestCase {
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
        suiteName = "AppModelTrackedClanRefreshTests-\(UUID().uuidString)"
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

    /// 复刻 AppModelTests.makeModel 的注入方式：MockURLProtocol 按端点路径
    /// 路由到各 handler，所有 client 用 protocolClasses 会话 + 假 token
    ///（CoAPIConfig(maxRetryCount: 0) 保持请求原子性）。
    /// 本类测试不涉及玩家端点，未注入 playerRefresher。
    @MainActor
    private func makeModel(
        clanHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data),
        clanLogHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil,
        clanWarHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil
    ) throws -> AppModel {
        let defaultWarHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let defaultLogHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        MockURLProtocol.handler = { request in
            if request.url?.path.contains("/currentwar") == true {
                return try (clanWarHandler ?? defaultWarHandler)(request)
            }
            if request.url?.path.contains("/warlog") == true
                || request.url?.path.contains("/capitalraidseasons") == true {
                return try (clanLogHandler ?? defaultLogHandler)(request)
            }
            return try clanHandler(request)
        }
        let clanRefresher = ClanRefresher(client: CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession()
        ) { "fake-token" })
        let clanWarRefresher = ClanWarRefresher(client: CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession()
        ) { "fake-token" })
        let clanLogClient = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession()
        ) { "fake-token" }
        return AppModel(
            defaults: defaults,
            clanRefresher: clanRefresher,
            clanWarRefresher: clanWarRefresher,
            clanLogClient: clanLogClient
        )
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

    // MARK: - 按 Tag 刷新部落档案

    /// tag 版刷新部落档案：只请求该 tag，状态按 tag 写入共享层。
    @MainActor
    func testRefreshClanByTagRequestsThatTag() async throws {
        let recorder = TagRecorder()
        let model = try makeModel(clanHandler: { request in
            recorder.record(request.url?.path(percentEncoded: true) ?? "")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    trackedClanJSON(tag: "#ABC123"))
        })
        model.refreshClan(tag: "#ABC123")
        await waitUntil { model.clanState(for: "#ABC123") != nil }

        let state = try XCTUnwrap(model.clanState(for: "#ABC123"))
        XCTAssertEqual(state.status, .success)
        XCTAssertEqual(state.lastGood?.tag, "#ABC123")
        XCTAssertEqual(recorder.snapshot(), ["/v1/clans/%23ABC123"], "必须只请求显式 tag 的部落档案")
    }

    /// 占用时第二个同 tag 请求排队补跑（不丢弃、不发起第二个并行请求）。
    /// 新语义（B1 修复）：忙时排队记录 tag 本身，补跑重请求该 tag，不再
    /// 退化为村庄全量联动。村庄 A 归属 #VILLAGE1 但不影响补跑集合。
    /// 请求序列 = [手动 tag, 手动 tag 补跑]——既能区分"并行重复请求"（两次
    /// 并发重叠），也能区分"忙时丢弃"（丢弃语义只有 1 次请求，测试变红）。
    @MainActor
    func testRefreshClanByTagWhileBusyQueuesAndCompletes() async throws {
        let villages = [VillageProfile(
            name: "A",
            accountSnapshot: trackedClanTestSnapshot("#A"),
            officialAPIState: trackedClanTestPlayerState(clanTag: "#VILLAGE1")
        )]
        defaults.set(try JSONEncoder().encode(villages), forKey: "coc-helper.villages.v1")

        let recorder = TagRecorder()
        let model = try makeModel(clanHandler: { request in
            recorder.record(request.url?.path(percentEncoded: true) ?? "")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    trackedClanJSON(tag: "#QUEUE99"))
        })
        model.refreshClan(tag: "#QUEUE99")
        model.refreshClan(tag: "#QUEUE99") // 占用时第二个排队（不丢弃）
        await waitUntil {
            !model.isRefreshingClanData && model.clanState(for: "#QUEUE99")?.status == .success
        }

        XCTAssertEqual(model.clanState(for: "#QUEUE99")?.status, .success)
        // 排队语义：第二个请求不得在第一个在途时并行发出；第一个完成后补跑
        // 排队 tag 本身。若第二个请求被丢弃 → 只有 1 条；若并行重发 → 两次
        // 请求在时间上重叠（队列内同时存在两个在途批次）。
        XCTAssertEqual(recorder.snapshot(),
                       ["/v1/clans/%23QUEUE99", "/v1/clans/%23QUEUE99"],
                       "占用时排队记录 tag，补跑必须重请求该 tag（不得静默丢弃）")
    }

    /// 村庄批量刷新在途时手动 tag 排队：补跑必须请求手动 tag（不得只补村庄全量）。
    /// 回归 B1：旧实现忙时补跑 refreshAllClans 只含村庄 tags，手动 tag 被静默吞掉
    /// （无请求、无错误、无补跑，测试会因等待条件超时而红）。
    @MainActor
    func testManualTagQueuedDuringVillageBatchIsNotLost() async throws {
        let villages = [VillageProfile(
            name: "A",
            accountSnapshot: trackedClanTestSnapshot("#A"),
            officialAPIState: trackedClanTestPlayerState(clanTag: "#VILLAGE1")
        )]
        defaults.set(try JSONEncoder().encode(villages), forKey: "coc-helper.villages.v1")

        let recorder = TagRecorder()
        let model = try makeModel(clanHandler: { request in
            recorder.record(request.url?.path(percentEncoded: true) ?? "")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    trackedClanJSON(tag: "#MANUAL99"))
        })
        model.refreshAllClans()            // 村庄批量在途（请求 #VILLAGE1）
        model.refreshClan(tag: "#MANUAL99") // 忙时排队：必须补跑，不得静默丢弃
        await waitUntil {
            !model.isRefreshingClanData && model.clanState(for: "#MANUAL99")?.status == .success
        }

        XCTAssertEqual(model.clanState(for: "#MANUAL99")?.status, .success)
        XCTAssertTrue(recorder.snapshot().contains("/v1/clans/%23MANUAL99"),
                      "村庄批量在途时手动 tag 排队，补跑必须请求手动 tag（不被静默丢弃）")
    }

    /// 手动入口与村庄入口共享同一状态层：手动刷新后村庄路径读到同一状态，
    /// 村庄刷新后 tag 路径读到同一状态。
    @MainActor
    func testManualAndVillageRefreshShareState() async throws {
        // 村庄 A 带玩家快照（归属 #SHARED1），仿 AppModelTests.makeModel 构造。
        let villages = [VillageProfile(
            name: "A",
            accountSnapshot: trackedClanTestSnapshot("#A"),
            officialAPIState: trackedClanTestPlayerState(clanTag: "#SHARED1")
        )]
        defaults.set(try JSONEncoder().encode(villages), forKey: "coc-helper.villages.v1")

        let recorder = TagRecorder()
        let model = try makeModel(clanHandler: { request in
            recorder.record("clan-request")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    trackedClanJSON(tag: "#SHARED1"))
        })
        let villageID = try XCTUnwrap(model.villages.first?.id)
        XCTAssertEqual(model.officialClanTag(for: villageID), "#SHARED1")

        // 手动入口刷新 → 村庄路径（currentClanState）必须读到同一共享状态
        model.refreshClan(tag: "#SHARED1")
        await waitUntil { model.clanState(for: "#SHARED1")?.status == .success }
        XCTAssertEqual(model.currentClanState?.status, .success, "村庄路径必须读到手动刷新写入的共享状态")
        XCTAssertEqual(model.currentClanState?.lastGood?.tag, "#SHARED1")
        XCTAssertEqual(model.clanState(for: "#SHARED1"), model.currentClanState,
                       "手动与村庄路径读同一字典条目")

        // 村庄入口刷新 → tag 路径读到同一状态（转发语义）
        model.refreshClan(villageID: villageID)
        await waitUntil { !model.isRefreshingClanData }
        XCTAssertEqual(model.clanState(for: "#SHARED1")?.status, .success, "村庄入口刷新后 tag 路径状态一致")
        XCTAssertEqual(model.clanState(for: "#SHARED1"), model.currentClanState)
        XCTAssertEqual(recorder.snapshot().count, 2, "手动 + 村庄各一次请求（共享状态不产生重复请求）")
    }

    // MARK: - 按 Tag 刷新战争日志 / 资本赛季 / 当前战争

    /// tag 版战争日志首屏：请求 warlog 端点，成功写入按 tag 状态。
    @MainActor
    func testRefreshWarLogByTag() async throws {
        let logRecorder = TagRecorder()
        let model = try makeModel(
            clanHandler: { _ in
                (HTTPURLResponse(url: URL(string: "https://api.clashofclans.com/v1/clans/%23X/warlog")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"items\":[]}".utf8))
            },
            clanLogHandler: { request in
                logRecorder.record(request.url?.path(percentEncoded: true) ?? "")
                return (HTTPURLResponse(url: URL(string: "https://api.clashofclans.com/v1/clans/%23X/warlog")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"items\":[]}".utf8))
            }
        )
        model.refreshWarLog(tag: "#WARLOG1")
        await waitUntil { model.warLogState(for: "#WARLOG1") != nil }

        XCTAssertNotNil(model.warLogState(for: "#WARLOG1"))
        XCTAssertEqual(model.warLogState(for: "#WARLOG1")?.status, .success)
        XCTAssertEqual(logRecorder.snapshot(), ["/v1/clans/%23WARLOG1/warlog"], "必须请求显式 tag 的 warlog")
    }

    /// tag 版资本赛季首屏：请求 capitalraidseasons 端点，成功写入按 tag 状态。
    @MainActor
    func testRefreshCapitalRaidByTag() async throws {
        let logRecorder = TagRecorder()
        let model = try makeModel(
            clanHandler: { _ in
                (HTTPURLResponse(url: URL(string: "https://api.clashofclans.com/v1/clans/%23X/capitalraidseasons")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"items\":[]}".utf8))
            },
            clanLogHandler: { request in
                logRecorder.record(request.url?.path(percentEncoded: true) ?? "")
                return (HTTPURLResponse(url: URL(string: "https://api.clashofclans.com/v1/clans/%23X/capitalraidseasons")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"items\":[]}".utf8))
            }
        )
        model.refreshCapitalRaid(tag: "#CAP1")
        await waitUntil { model.capitalState(for: "#CAP1") != nil }

        XCTAssertNotNil(model.capitalState(for: "#CAP1"))
        XCTAssertEqual(model.capitalState(for: "#CAP1")?.status, .success)
        XCTAssertEqual(logRecorder.snapshot(), ["/v1/clans/%23CAP1/capitalraidseasons"],
                       "必须请求显式 tag 的 capitalraidseasons")
    }

    /// tag 版当前战争：请求 currentwar 端点，notInWar 是成功空状态。
    @MainActor
    func testRefreshClanWarByTag() async throws {
        let warRecorder = TagRecorder()
        let model = try makeModel(
            clanHandler: { _ in
                (HTTPURLResponse(url: URL(string: "https://api.clashofclans.com/v1/clans/%23X/currentwar")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"state\":\"notInWar\"}".utf8))
            },
            clanLogHandler: nil,
            clanWarHandler: { request in
                warRecorder.record(request.url?.path(percentEncoded: true) ?? "")
                return (HTTPURLResponse(url: URL(string: "https://api.clashofclans.com/v1/clans/%23X/currentwar")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"state\":\"notInWar\"}".utf8))
            }
        )
        model.refreshClanWar(tag: "#WAR1")
        await waitUntil { model.clanWarState(for: "#WAR1") != nil }

        XCTAssertEqual(model.clanWarState(for: "#WAR1")?.status, .success)
        XCTAssertEqual(model.clanWarState(for: "#WAR1")?.lastGood?.state, "notInWar",
                       "notInWar 是成功空状态，不是失败")
        XCTAssertEqual(warRecorder.snapshot(), ["/v1/clans/%23WAR1/currentwar"], "必须请求显式 tag 的 currentwar")
    }
}
