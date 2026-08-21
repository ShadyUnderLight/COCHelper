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
        clanHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data),
        clanWarHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil,
        clanLogHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil
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

        let defaultWarHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let defaultLogHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        MockURLProtocol.handler = { request in
            if request.url?.path.hasPrefix("/v1/players/") == true {
                return try playerHandler(request)
            }
            if request.url?.path.contains("/currentwar") == true {
                return try (clanWarHandler ?? defaultWarHandler)(request)
            }
            if request.url?.path.contains("/warlog") == true
                || request.url?.path.contains("/capitalraidseasons") == true {
                return try (clanLogHandler ?? defaultLogHandler)(request)
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
            refresher: playerRefresher,
            clanRefresher: clanRefresher,
            clanWarRefresher: clanWarRefresher,
            clanLogClient: clanLogClient,
            historyStore: TestSnapshotHistoryStore()
        )
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

    // MARK: - 当前战争（按需刷新，stage 3b）

    /// 点"查看当前战争"→ 请求当前村庄所属部落的 currentwar；
    /// notInWar 是成功响应（空状态快照存入 lastGood）。
    @MainActor
    func testRefreshCurrentClanWarFetchesCurrentVillageClanWar() async throws {
        let warRecorder = TagRecorder()
        let clanWarHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            warRecorder.record(request.url?.path(percentEncoded: true) ?? "")
            let body = Data(#"{"state":"notInWar"}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        // 玩家/部落 handler 不会被调用（按需语义：战争刷新不联动其他端点）
        let playerHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            XCTFail("战争刷新不应触发玩家请求")
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let clanHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            XCTFail("战争刷新不应触发部落 profile 请求")
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let model = try makeModel(
            playerHandler: playerHandler,
            clanHandler: clanHandler,
            clanWarHandler: clanWarHandler
        )

        // 当前选中村庄 A（部落 #CLANA）
        model.refreshCurrentClanWar()
        await waitUntil { !model.isRefreshingClanWarData }

        XCTAssertEqual(warRecorder.snapshot(), ["/v1/clans/%23CLANA/currentwar"],
                       "战争刷新必须请求当前村庄所属部落的 currentwar")
        XCTAssertEqual(model.currentClanWarState?.status, .success)
        XCTAssertEqual(model.currentClanWarState?.lastGood?.state, "notInWar",
                       "notInWar 是成功空状态，不是失败")
    }

    /// 战争刷新失败保留 last-good；部落/玩家数据不受影响（独立共享层）。
    @MainActor
    func testRefreshCurrentClanWarFailureKeepsLastGood() async throws {
        let clanWarHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }
        let playerHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let clanHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let model = try makeModel(playerHandler: playerHandler, clanHandler: clanHandler, clanWarHandler: clanWarHandler)

        // 第一次成功（notInWar）
        let warRecorder = TagRecorder()
        MockURLProtocol.handler = { request in
            warRecorder.record("war")
            let body = Data(#"{"state":"notInWar"}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        model.refreshCurrentClanWar()
        await waitUntil { !model.isRefreshingClanWarData }
        XCTAssertEqual(model.currentClanWarState?.lastGood?.state, "notInWar")

        // 第二次失败（429）→ 保留上次成功
        MockURLProtocol.handler = clanWarHandler
        model.refreshCurrentClanWar()
        await waitUntil { !model.isRefreshingClanWarData }

        XCTAssertEqual(model.currentClanWarState?.status, .failed)
        XCTAssertEqual(model.currentClanWarState?.lastGood?.state, "notInWar", "失败必须保留 last-good")
        XCTAssertNotNil(model.currentClanWarState?.lastErrorReason)
        // 独立共享层：部落/玩家数据未被触碰
        XCTAssertTrue(model.clanStates.isEmpty)
        XCTAssertEqual(model.currentVillageOfficialState?.lastGood?.clan?.tag, "#CLANA")
    }
}

// MARK: - 战争日志分页（stage 3c）

extension AppModelTests {
    /// 首屏：请求 warlog（无游标 query）→ lastGood 为第一页。
    @MainActor
    func testRefreshWarLogFirstPage() async throws {
        let recorder = TagRecorder()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            recorder.record(request.url?.query(percentEncoded: true) ?? "(no-query)")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullWarLogPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }

        XCTAssertEqual(recorder.snapshot(), ["(no-query)"], "首屏不带游标")
        XCTAssertEqual(model.currentWarLogState?.status, .success)
        XCTAssertEqual(model.currentWarLogState?.lastGood?.items.count, 2)
        XCTAssertEqual(model.currentWarLogState?.lastGood?.after, "CURSORAFTER1")
        XCTAssertTrue(model.currentWarLogHasMore, "有 after 游标 → 可加载更多")
    }

    /// 加载更多：带 after 游标请求 → 合并去重 → 游标推进。
    @MainActor
    func testLoadMoreWarLogMergesAndAdvancesCursor() async throws {
        let recorder = TagRecorder()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            recorder.record(request.url?.query(percentEncoded: true) ?? "(no-query)")
            let body: Data
            if recorder.snapshot().count == 1 {
                body = fullWarLogPageData()  // items 2 条 + after CURSORAFTER1
            } else {
                // 第二页：1 条新 + 1 条与首页重复（验证去重）
                // 注意：重复条目必须与 fixture（official_war_log_page.json 第一场）
                // 结构完全一致（含 members），mergedItems 按 Equatable 全字段去重。
                body = Data("""
                {"items":[
                  {"result":"win","endTime":"20260727T100000.000Z","teamSize":30,"attacksPerMember":2,
                   "clan":{"tag":"#CLANANONYMIZED","name":"anonymized-clan","clanLevel":12,"attacks":60,"stars":95,"destructionPercentage":100.0},
                   "opponent":{"tag":"#OPP2","name":"op2","clanLevel":10,"attacks":50,"stars":70,"destructionPercentage":80.0}},
                  {"result":"win","endTime":"20260730T100000.000Z","teamSize":30,"attacksPerMember":2,
                   "clan":{"tag":"#CLANANONYMIZED","name":"anonymized-clan","badgeUrls":{"medium":"https://api-assets.clashofclans.com/badges/200/anonymized.png"},"clanLevel":12,"attacks":60,"stars":95,"destructionPercentage":100.0,
                   "members":[{"tag":"#PLAYERANONYMIZED","name":"anonymized-member","townhallLevel":14,"mapPosition":1,"attacks":[{"order":1,"attackerTag":"#PLAYERANONYMIZED","defenderTag":"#OPPONENTPLAYERANONYMIZED","stars":3,"destructionPercentage":100,"duration":180}],"opponentAttacks":1,"bestOpponentAttack":{"order":1,"attackerTag":"#OPPONENTPLAYERANONYMIZED","defenderTag":"#PLAYERANONYMIZED","stars":2,"destructionPercentage":85,"duration":175}}]},
                   "opponent":{"tag":"#OPPONENTANONYMIZED","name":"anonymized-opponent","badgeUrls":{"medium":"https://api-assets.clashofclans.com/badges/200/anonymized.png"},"clanLevel":11,"attacks":58,"stars":80,"destructionPercentage":85.0,
                   "members":[]}}
                ],"paging":{"cursors":{"before":"B2","after":"CURSORAFTER2"}}}
                """.utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }
        model.loadMoreCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }

        // 第二次请求带 after 游标
        let queries = recorder.snapshot()
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries[1].contains("after=CURSORAFTER1"), "加载更多必须带游标: \(queries[1])")
        // 合并去重：首页 2 条 + 第二页新增 1 条（1 条重复被跳过）
        XCTAssertEqual(model.currentWarLogState?.lastGood?.items.count, 3, "重复条目不得重复追加")
        XCTAssertEqual(model.currentWarLogState?.lastGood?.after, "CURSORAFTER2", "游标推进")
        XCTAssertTrue(model.currentWarLogHasMore)
    }

    /// 跨 parserVersion 的加载更多：旧缓存条目与新页条目 Equatable 不等，
    /// 合并会残留重复——重建语义：丢弃累计页，重新拉**第一页**（无游标请求），
    /// 保持列表完整与游标停滞保护。
    @MainActor
    func testLoadMoreWarLogWithOlderParserVersionRebuildsFromFirstPage() async throws {
        let recorder = TagRecorder()
        // 预置「旧版本」缓存：parserVersion 0.2 + 第一页（游标 CURSORAFTER1，
        // 旧解析器形态条目——无成员明细）。
        let oldEntry = OfficialWarLogEntry(
            result: "win", endTime: "20260730T100000.000Z", teamSize: 30, attacksPerMember: 2,
            battleModifier: nil,
            clan: ClanWarParticipant(
                tag: "#CLANANONYMIZED", name: "anonymized-clan", badgeUrls: nil, clanLevel: 12,
                attacks: 60, stars: 95, destructionPercentage: 100.0, members: nil
            ),
            opponent: ClanWarParticipant(
                tag: "#OPPONENTANONYMIZED", name: "anonymized-opponent", badgeUrls: nil, clanLevel: 11,
                attacks: 58, stars: 80, destructionPercentage: 85.0, members: nil
            )
        )
        let oldState = ClanWarLogAPIState(
            status: .success,
            clanTag: "#CLANA",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            parserVersion: "clan-war-log-0.2",
            lastGood: OfficialWarLogPage(
                page: OfficialPaginatedPage(items: [oldEntry], before: nil, after: "CURSORAFTER1")
            )
        )
        defaults.set(
            try JSONEncoder().encode(ClanWarLogStateStore(states: ["#CLANA": oldState])),
            forKey: "coc-helper.clan-war-logs.v1"
        )

        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            recorder.record(request.url?.query(percentEncoded: true) ?? "(no-query)")
            // 重建应请求**第一页**（不带 after 游标）：返回新解析器形态的首页。
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, fullWarLogPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.loadMoreCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }

        // 重建：请求不带 after 游标（第一页）
        let queries = recorder.snapshot()
        XCTAssertEqual(queries.count, 1)
        XCTAssertFalse(queries[0].contains("after="), "跨版本重建必须请求第一页（无游标）: \(queries[0])")
        // 结果 = 新首页（fixture 2 条），解析器版本升级，游标为首页 after
        let state = model.currentWarLogState
        XCTAssertEqual(state?.parserVersion, "clan-war-log-0.4", "状态升级到当前解析器版本")
        XCTAssertEqual(state?.lastGood?.items.count, 2, "重建后为完整首页（不残留旧条目）")
        XCTAssertEqual(state?.lastGood?.after, "CURSORAFTER1", "游标取首页值")
        XCTAssertTrue(model.currentWarLogHasMore, "首页有 after → 可继续加载更多")
    }

    /// 末页（after nil）后 hasMore = false，加载更多不发起请求。
    @MainActor
    func testLoadMoreWarLogStopsAtLastPage() async throws {
        let recorder = TagRecorder()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            recorder.record("call-\(recorder.snapshot().count)")
            let body: Data
            if recorder.snapshot().count == 1 {
                body = fullWarLogPageData()
            } else {
                body = Data("{\"items\":[],\"paging\":{\"cursors\":{\"before\":\"B2\"}}}".utf8)  // 末页无 after
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }
        model.loadMoreCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }
        XCTAssertFalse(model.currentWarLogHasMore, "末页后不得再有加载更多")

        // 再点加载更多 → 不发起请求（hasMore 为 false）
        model.loadMoreCurrentWarLog()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.snapshot().count, 2, "hasMore=false 时不得发起请求")
    }

    /// 档案已知日志不公开：预判不发起请求（显式状态由 UI 呈现）。
    @MainActor
    func testRefreshWarLogSkipsWhenKnownNotPublic() async throws {
        let recorder = TagRecorder()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            recorder.record("unexpected-request")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullWarLogPageData())
        }
        // clan profile 返回 isWarLogPublic=false（预判依据）
        let privateClan = Data(##"{"tag":"#CLANANONYMIZED","name":"c","clanLevel":1,"members":1,"isWarLogPublic":false}"##.utf8)
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, privateClan)
            },
            clanLogHandler: logHandler
        )

        // 先获取部落档案（isWarLogPublic=false）
        model.refreshCurrentClan()
        await waitUntil { !model.isRefreshingClanData }

        XCTAssertTrue(model.isCurrentWarLogKnownNotPublic)
        model.refreshCurrentWarLog()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(recorder.snapshot().isEmpty, "已知不公开时不得发起 warlog 请求")
    }
}

// MARK: - stage 3c 复审修复回归

/// 可变的 Sendable 失败开关（@Sendable handler 捕获用）。
private final class FailFlag: @unchecked Sendable {
    var shouldFail = false
}

/// 可变的 Sendable 请求计数器（@Sendable handler 捕获用）。
private final class RequestCounter: @unchecked Sendable {
    var count = 0
}

extension AppModelTests {
    /// 加载更多失败：保留 last-good 与游标，warLogHasMore 仍为 true（可重试），
    /// 重试成功后恢复 .success 并合并新页（Issue #124 验收：
    /// "加载更多失败时保留已有可见记录和 last-good 数据；按钮仍可用于重试"）。
    @MainActor
    func testLoadMoreWarLogFailureKeepsRetryableAndRecovers() async throws {
        let counter = RequestCounter()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            counter.count += 1
            if counter.count == 2 {
                // 第二页：加载更多失败（429）
                return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
            }
            if counter.count == 3 {
                // 重试成功：第二页数据（1 条新 + 1 条与首页重复）
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        {"items":[
                          {"result":"win","endTime":"20260801T100000.000Z","teamSize":30,"attacksPerMember":2,
                           "clan":{"tag":"#CLANANONYMIZED","name":"anonymized-clan","badgeUrls":{"medium":"https://api-assets.clashofclans.com/badges/200/anonymized.png"},"clanLevel":12,"attacks":60,"stars":95,"destructionPercentage":100.0,
                           "members":[{"tag":"#PLAYERANONYMIZED","name":"anonymized-member","townhallLevel":14,"mapPosition":1,"attacks":[{"order":1,"attackerTag":"#PLAYERANONYMIZED","defenderTag":"#OPPONENTPLAYERANONYMIZED","stars":3,"destructionPercentage":100,"duration":180}],"opponentAttacks":1,"bestOpponentAttack":{"order":1,"attackerTag":"#OPPONENTPLAYERANONYMIZED","defenderTag":"#PLAYERANONYMIZED","stars":2,"destructionPercentage":85,"duration":175}}]},
                           "opponent":{"tag":"#OPPONENTANONYMIZED","name":"anonymized-opponent","badgeUrls":{"medium":"https://api-assets.clashofclans.com/badges/200/anonymized.png"},"clanLevel":11,"attacks":58,"stars":80,"destructionPercentage":85.0,
                           "members":[]}}
                        ],"paging":{"cursors":{"before":"B2","after":"CURSORAFTER2"}}}
                        """.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullWarLogPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        // 首屏成功（2 条 + after=CURSORAFTER1）
        model.refreshCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }
        XCTAssertTrue(model.currentWarLogHasMore)

        // 加载更多失败 → last-good 与游标保留，hasMore 仍为 true（可重试）
        model.loadMoreCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }
        XCTAssertEqual(model.currentWarLogState?.status, .failed)
        XCTAssertEqual(model.currentWarLogState?.lastGood?.items.count, 2, "失败保留已累计的 last-good")
        XCTAssertEqual(model.currentWarLogState?.lastGood?.after, "CURSORAFTER1", "失败保留游标")
        XCTAssertTrue(model.currentWarLogHasMore, "失败后仍可重试（Issue #124 验收）")

        // 重试成功 → 恢复 .success 并合并新页
        model.loadMoreCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }
        XCTAssertEqual(model.currentWarLogState?.status, .success)
        XCTAssertEqual(model.currentWarLogState?.lastGood?.items.count, 3, "重试成功后合并新页")
        XCTAssertEqual(model.currentWarLogState?.lastGood?.after, "CURSORAFTER2", "重试成功后游标推进")
    }

    /// 刷新失败保留已累计的 last-good（复审 B1/B2：传 previous 保持契约）。
    @MainActor
    func testRefreshWarLogFailureKeepsAccumulatedLastGood() async throws {
        let failFlag = FailFlag()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            if failFlag.shouldFail {
                return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullWarLogPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        // 首次成功（累计 2 条）
        model.refreshCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }
        XCTAssertEqual(model.currentWarLogState?.lastGood?.items.count, 2)

        // 刷新失败 → last-good 保留（累计页不清空）
        failFlag.shouldFail = true
        model.refreshCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }

        XCTAssertEqual(model.currentWarLogState?.status, .failed)
        XCTAssertEqual(model.currentWarLogState?.lastGood?.items.count, 2,
                       "刷新失败不得清空已累计的 last-good")
        XCTAssertNotNil(model.currentWarLogState?.lastErrorReason)
    }

    /// 预判"不公开"时 force 请求仍可发起（档案过期误判的绕过路径）。
    @MainActor
    func testRefreshWarLogForceBypassesNotPublicPrecheck() async throws {
        let recorder = TagRecorder()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            recorder.record("requested")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullWarLogPageData())
        }
        let privateClan = Data(##"{"tag":"#CLANANONYMIZED","name":"c","clanLevel":1,"members":1,"isWarLogPublic":false}"##.utf8)
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, privateClan)
            },
            clanLogHandler: logHandler
        )

        // 先获取档案（isWarLogPublic=false）
        model.refreshCurrentClan()
        await waitUntil { !model.isRefreshingClanData }
        XCTAssertTrue(model.isCurrentWarLogKnownNotPublic)

        // 普通刷新被预判拦截
        model.refreshCurrentWarLog()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(recorder.snapshot().isEmpty, "预判拦截时不得发起请求")

        // force 绕过预判
        model.refreshCurrentWarLog(force: true)
        await waitUntil { !model.isRefreshingWarLogData }
        XCTAssertEqual(recorder.snapshot().count, 1, "force 必须发起请求")
        XCTAssertEqual(model.currentWarLogState?.status, .success)
    }
}

// MARK: - capital raid 分页（stage 3c 外部复核补充）

extension AppModelTests {
    /// 突袭周末首屏：请求 capitalraidseasons → 状态 success + 条目 + 游标。
    @MainActor
    func testRefreshCapitalFirstPage() async throws {
        let recorder = TagRecorder()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            recorder.record(request.url?.path(percentEncoded: true) ?? "")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullCapitalRaidPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }

        XCTAssertEqual(recorder.snapshot().first, "/v1/clans/%23CLANA/capitalraidseasons")
        XCTAssertEqual(model.currentCapitalState?.status, .success)
        XCTAssertEqual(model.currentCapitalState?.lastGood?.items.count, 2)
        XCTAssertEqual(model.currentCapitalState?.lastGood?.items[0].capitalTotalLoot, 123456)
        XCTAssertEqual(model.currentCapitalState?.lastGood?.after, "RAIDCURSORAFTER1")
        XCTAssertTrue(model.currentCapitalHasMore)
    }

    /// 突袭周末加载更多：游标参数 + 合并去重。
    @MainActor
    func testLoadMoreCapitalMerges() async throws {
        let recorder = TagRecorder()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            recorder.record(request.url?.query(percentEncoded: true) ?? "(no-query)")
            let body: Data
            if recorder.snapshot().count == 1 {
                body = fullCapitalRaidPageData()
            } else {
                body = Data(#"{"items":[{"state":"ended","startTime":"20260617T080000.000Z","endTime":"20260619T080000.000Z","capitalTotalLoot":50000,"raidsCompleted":4,"totalAttacks":40,"enemyDistrictsDestroyed":80,"offensiveReward":3000,"defensiveReward":1000}],"paging":{"cursors":{"before":"B2","after":"RAIDCURSORAFTER2"}}}"#.utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        model.loadMoreCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }

        let queries = recorder.snapshot()
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries[1].contains("after=RAIDCURSORAFTER1"), "加载更多必须带游标: \(queries[1])")
        XCTAssertEqual(model.currentCapitalState?.lastGood?.items.count, 3, "合并去重后 3 条")
        XCTAssertEqual(model.currentCapitalState?.lastGood?.after, "RAIDCURSORAFTER2")
    }

    /// 跨 parserVersion 的突袭周末加载更多：与战争日志同构——重建第一页
    ///（无游标请求），保持列表完整与游标停滞保护。
    @MainActor
    func testLoadMoreCapitalWithOlderParserVersionRebuildsFromFirstPage() async throws {
        let recorder = TagRecorder()
        // 预置「旧版本」缓存：parserVersion 0.2 + 第一页（游标 RAIDCURSORAFTER1，
        // 旧解析器形态条目——无成员明细）。
        let oldSeason = OfficialCapitalRaidSeason(
            state: "ended", startTime: "20260701T080000.000Z", endTime: "20260703T080000.000Z",
            capitalTotalLoot: 123456, raidsCompleted: 6, totalAttacks: 60,
            enemyDistrictsDestroyed: 120, offensiveReward: 5000, defensiveReward: 2500,
            members: nil, attackLog: nil, defenseLog: nil
        )
        let oldState = ClanCapitalAPIState(
            status: .success,
            clanTag: "#CLANA",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            parserVersion: "clan-capital-0.2",
            lastGood: OfficialCapitalRaidPage(
                page: OfficialPaginatedPage(items: [oldSeason], before: nil, after: "RAIDCURSORAFTER1")
            )
        )
        defaults.set(
            try JSONEncoder().encode(ClanCapitalStateStore(states: ["#CLANA": oldState])),
            forKey: "coc-helper.clan-capitals.v1"
        )

        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            recorder.record(request.url?.query(percentEncoded: true) ?? "(no-query)")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, fullCapitalRaidPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.loadMoreCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }

        // 重建：请求不带 after 游标（第一页）
        let queries = recorder.snapshot()
        XCTAssertEqual(queries.count, 1)
        XCTAssertFalse(queries[0].contains("after="), "跨版本重建必须请求第一页（无游标）: \(queries[0])")
        // 结果 = 新首页（fixture 2 条），解析器版本升级，游标为首页 after
        let state = model.currentCapitalState
        XCTAssertEqual(state?.parserVersion, "clan-capital-0.3", "状态升级到当前解析器版本")
        XCTAssertEqual(state?.lastGood?.items.count, 2, "重建后为完整首页（不残留旧条目）")
        XCTAssertEqual(state?.lastGood?.after, "RAIDCURSORAFTER1", "游标取首页值")
        XCTAssertTrue(model.currentCapitalHasMore, "首页有 after → 可继续加载更多")
    }

    /// 突袭周末刷新失败保留 last-good。
    @MainActor
    func testRefreshCapitalFailureKeepsLastGood() async throws {
        let failFlag = FailFlag()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            if failFlag.shouldFail {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullCapitalRaidPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        XCTAssertEqual(model.currentCapitalState?.lastGood?.items.count, 2)

        failFlag.shouldFail = true
        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }

        XCTAssertEqual(model.currentCapitalState?.status, .failed)
        XCTAssertEqual(model.currentCapitalState?.lastGood?.items.count, 2, "失败不得清空累计页")
        XCTAssertEqual(model.currentCapitalState?.lastHTTPStatus, 500)
    }

    /// Issue #221：load more 后旧 row ID 保留，新行 append。
    @MainActor
    func testLoadMoreCapitalPreservesExistingRowIDs() async throws {
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            let body: Data
            if request.url?.query(percentEncoded: true)?.contains("after=") != true {
                body = fullCapitalRaidPageData()
            } else {
                body = Data(#"{"items":[{"state":"ended","startTime":"20260617T080000.000Z","endTime":"20260619T080000.000Z","capitalTotalLoot":50000,"raidsCompleted":4,"totalAttacks":40,"enemyDistrictsDestroyed":80,"offensiveReward":3000,"defensiveReward":1000}],"paging":{"cursors":{"before":"B2","after":"RAIDCURSORAFTER2"}}}"#.utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        let idsAfterFirstPage = model.capitalRaidRows(for: "#CLANA").map(\.id)
        XCTAssertEqual(idsAfterFirstPage.count, 2)

        model.loadMoreCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        let idsAfterLoadMore = model.capitalRaidRows(for: "#CLANA").map(\.id)

        XCTAssertEqual(Array(idsAfterLoadMore.prefix(2)), idsAfterFirstPage)
        XCTAssertEqual(idsAfterLoadMore.count, 3)
    }

    /// Issue #221：刷新失败保留 last-good 时 row state 不变。
    @MainActor
    func testRefreshCapitalFailureKeepsRowIDs() async throws {
        let failFlag = FailFlag()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            if failFlag.shouldFail {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullCapitalRaidPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        let idsBeforeFailure = model.capitalRaidRows(for: "#CLANA").map(\.id)

        failFlag.shouldFail = true
        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }

        XCTAssertEqual(model.capitalRaidRows(for: "#CLANA").map(\.id), idsBeforeFailure)
    }

    /// Issue #221：跨 parser 版本重建时 row generation 改变。
    @MainActor
    func testParserVersionRebuildChangesCapitalRowGeneration() async throws {
        let oldSeason = OfficialCapitalRaidSeason(
            state: "ended", startTime: "20260701T080000.000Z", endTime: "20260703T080000.000Z",
            capitalTotalLoot: 123456, raidsCompleted: 6, totalAttacks: 60,
            enemyDistrictsDestroyed: 120, offensiveReward: 5000, defensiveReward: 2500,
            members: nil, attackLog: nil, defenseLog: nil
        )
        let oldState = ClanCapitalAPIState(
            status: .success,
            clanTag: "#CLANA",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            parserVersion: "clan-capital-0.2",
            lastGood: OfficialCapitalRaidPage(
                page: OfficialPaginatedPage(items: [oldSeason], before: nil, after: "RAIDCURSORAFTER1")
            )
        )
        defaults.set(
            try JSONEncoder().encode(ClanCapitalStateStore(states: ["#CLANA": oldState])),
            forKey: "coc-helper.clan-capitals.v1"
        )

        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            _ = request
            return (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullCapitalRaidPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )
        let idsAfterLoad = model.capitalRaidRows(for: "#CLANA").map(\.id)

        model.loadMoreCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        let idsAfterRebuild = model.capitalRaidRows(for: "#CLANA").map(\.id)

        XCTAssertNotEqual(idsAfterLoad, idsAfterRebuild)
    }

    /// Issue #221：load more 后 refresh 首屏，仍存在的行保留 row ID。
    @MainActor
    func testRefreshAfterLoadMorePreservesPrefixRowIDs() async throws {
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            let query = request.url?.query(percentEncoded: true) ?? ""
            let body: Data
            if query.contains("after=RAIDCURSORAFTER1") {
                body = Data(#"{"items":[{"state":"ended","startTime":"20260617T080000.000Z","endTime":"20260619T080000.000Z","capitalTotalLoot":50000,"raidsCompleted":4,"totalAttacks":40,"enemyDistrictsDestroyed":80,"offensiveReward":3000,"defensiveReward":1000}],"paging":{"cursors":{"before":"B2","after":"RAIDCURSORAFTER2"}}}"#.utf8)
            } else {
                body = fullCapitalRaidPageData()
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        model.loadMoreCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        XCTAssertEqual(model.capitalRaidRows(for: "#CLANA").count, 3)

        let prefixIDs = model.capitalRaidRows(for: "#CLANA").prefix(2).map(\.id)
        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }

        XCTAssertEqual(model.capitalRaidRows(for: "#CLANA").count, 2)
        XCTAssertEqual(model.capitalRaidRows(for: "#CLANA").map(\.id), Array(prefixIDs))
    }

    /// Issue #230：duplicate triple 累计后截短 refresh，无 exact anchor 时不得错复用 prefix row ID。
    @MainActor
    func testRefreshAfterLoadMoreWithDuplicateTripleResetsAmbiguousRowIDs() async throws {
        let duplicateFirstPage = Data(
            #"{"items":[{"state":"ended","startTime":"20260701T080000.000Z","endTime":"20260703T080000.000Z","capitalTotalLoot":100000,"raidsCompleted":6,"totalAttacks":60,"enemyDistrictsDestroyed":120,"offensiveReward":5000,"defensiveReward":2500},{"state":"ended","startTime":"20260701T080000.000Z","endTime":"20260703T080000.000Z","capitalTotalLoot":100500,"raidsCompleted":6,"totalAttacks":60,"enemyDistrictsDestroyed":120,"offensiveReward":5000,"defensiveReward":2500}],"paging":{"cursors":{"after":"RAIDCURSORAFTER1"}}}"#.utf8
        )
        let loadMorePage = Data(
            #"{"items":[{"state":"ended","startTime":"20260617T080000.000Z","endTime":"20260619T080000.000Z","capitalTotalLoot":50000,"raidsCompleted":4,"totalAttacks":40,"enemyDistrictsDestroyed":80,"offensiveReward":3000,"defensiveReward":1000}],"paging":{"cursors":{"before":"B2","after":"RAIDCURSORAFTER2"}}}"#.utf8
        )
        let ambiguousRefreshPage = Data(
            #"{"items":[{"state":"ended","startTime":"20260701T080000.000Z","endTime":"20260703T080000.000Z","capitalTotalLoot":200000,"raidsCompleted":6,"totalAttacks":60,"enemyDistrictsDestroyed":120,"offensiveReward":5000,"defensiveReward":2500}],"paging":{"cursors":{"after":"RAIDCURSORAFTER1"}}}"#.utf8
        )
        final class RefreshMode: @unchecked Sendable {
            var useAmbiguousRefresh = false
        }
        let refreshMode = RefreshMode()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            let query = request.url?.query(percentEncoded: true) ?? ""
            let body: Data
            if refreshMode.useAmbiguousRefresh {
                body = ambiguousRefreshPage
            } else if query.contains("after=RAIDCURSORAFTER1") {
                body = loadMorePage
            } else {
                body = duplicateFirstPage
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        model.loadMoreCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        XCTAssertEqual(model.capitalRaidRows(for: "#CLANA").count, 3)
        let idA = model.capitalRaidRows(for: "#CLANA")[0].id
        let oldIDs = Set(model.capitalRaidRows(for: "#CLANA").map(\.id))

        refreshMode.useAmbiguousRefresh = true
        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }

        XCTAssertEqual(model.capitalRaidRows(for: "#CLANA").count, 1)
        XCTAssertNotEqual(model.capitalRaidRows(for: "#CLANA")[0].id, idA, "截短 refresh 不得把 duplicate A 的 row ID 错给新首屏行")
        XCTAssertTrue(oldIDs.isDisjoint(with: model.capitalRaidRows(for: "#CLANA").map(\.id)), "歧义截短 refresh 应 reset row IDs")
    }

    /// Issue #221：View 重复读取不应触发 reconcile/rebuild。
    @MainActor
    func testRepeatedCapitalRaidRowReadsDoNotRebuild() async throws {
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            _ = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullCapitalRaidPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentCapitalRaid()
        await waitUntil { !model.isRefreshingCapitalData }
        let first = model.capitalRaidRows(for: "#CLANA").map(\.id)
        let second = model.capitalRaidRows(for: "#CLANA").map(\.id)
        XCTAssertEqual(first, second)
    }
}

// MARK: - P1-3 端到端（外部复核补充）

extension AppModelTests {
    /// malformed 响应（items 缺失）走完 refresher 链路：failed + 保留 last-good，
    /// 不得当作成功空页覆盖持久化数据。
    @MainActor
    func testRefreshWarLogMalformedResponseKeepsLastGood() async throws {
        let failFlag = FailFlag()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            if failFlag.shouldFail {
                // 200 但 items 缺失（损坏响应）
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("{}".utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullWarLogPageData())
        }
        let model = try makeModel(
            playerHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanHandler: { _ in (HTTPURLResponse(url: URL(string: "https://x/")!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data()) },
            clanLogHandler: logHandler
        )

        model.refreshCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }
        XCTAssertEqual(model.currentWarLogState?.lastGood?.items.count, 2)

        failFlag.shouldFail = true
        model.refreshCurrentWarLog()
        await waitUntil { !model.isRefreshingWarLogData }

        XCTAssertEqual(model.currentWarLogState?.status, .failed)
        XCTAssertEqual(model.currentWarLogState?.lastGood?.items.count, 2,
                       "malformed 响应不得清空已累计的 last-good")
        XCTAssertTrue(model.currentWarLogState?.lastErrorReason?.contains("响应解析失败") == true,
                      "malformed 应显示解析失败原因")
    }
}
