import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

/// Issue #35 Task 1：AppModel 按村庄 / 部落 ID 的官方数据显式接口。
///
/// 验收核心：页面必须始终以当前 villageID 为数据来源，刷新期间切换村庄不得串村。
/// 本文件覆盖：
/// - by-ID 读取路由隔离（A/B 村庄不串、不存在 ID → nil）；
/// - by-ID 刷新切村写回（发起村庄更新、当前选中村庄不受影响、部落联动仍走发起村庄）；
/// - 部落四层共享字典按 tag 路由（同 tag 共享同一份、不同 tag 各自）；
/// - officialClanTag / clanStatusUnknown 派生语义（lastGood nil / clan 缺失 / tag 无效 / 换部落）；
/// - officialTag(for:) 派生语义（规范化 / 无效 tag / 无快照 → nil，与选中村庄一致）；
/// - property-based 一致性（随机村庄列表 + 随机状态，50 轮）。
///
/// 注意：类级不标 @MainActor（setUp/tearDown 是 nonisolated override）；
/// 需要操作 AppModel 的测试方法与 helper 单独标注。
final class Issue35VillageIDRoutingTests: XCTestCase {
    /// 线程安全的请求记录器（与 AppModelTests 同构）。
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
        suiteName = "Issue35VillageIDRoutingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    private func snapshot(_ tag: String) -> AccountSnapshot {
        AccountSnapshot(
            tag: tag, capturedAt: nil, importedAt: Date(), ageSeconds: nil,
            originalText: "{}", objectSections: [:], numericSections: [:],
            boosts: [:], unknownTopLevelKeys: [], diagnostics: []
        )
    }

    /// 带部落归属的玩家官方状态（lastGood 存在）。
    private func playerState(clanTag: String?, status: OfficialAPIRequestStatus = .success) -> OfficialAPIState {
        OfficialAPIState(
            status: status,
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

    private func clanSnapshot(tag: String, isWarLogPublic: Bool? = nil) -> OfficialClanSnapshot {
        OfficialClanSnapshot(
            tag: tag, name: "c", type: nil, description: nil, clanLevel: nil, badgeUrls: nil,
            members: nil, requiredTrophies: nil, requiredTownHallLevel: nil,
            warWins: nil, warLosses: nil, warTies: nil, warWinStreak: nil,
            isWarLogPublic: isWarLogPublic,
            labels: nil, clanCapital: nil, unrecognizedKeys: []
        )
    }

    private func warSnapshot(state: String) -> OfficialClanWarSnapshot {
        OfficialClanWarSnapshot(
            state: state, teamSize: nil, attacksPerMember: nil,
            preparationStartTime: nil, startTime: nil, endTime: nil,
            warStartTime: nil, clan: nil, opponent: nil, unrecognizedKeys: []
        )
    }

    @MainActor
    private func makeModel(
        villages: [VillageProfile],
        playerHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil,
        clanHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil,
        clanWarHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil,
        clanLogHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil
    ) throws -> AppModel {
        let data = try JSONEncoder().encode(villages)
        defaults.set(data, forKey: "coc-helper.villages.v1")

        let notFound: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        MockURLProtocol.handler = { request in
            if request.url?.path.hasPrefix("/v1/players/") == true {
                return try (playerHandler ?? notFound)(request)
            }
            if request.url?.path.contains("/currentwar") == true {
                return try (clanWarHandler ?? notFound)(request)
            }
            if request.url?.path.contains("/warlog") == true
                || request.url?.path.contains("/capitalraidseasons") == true {
                return try (clanLogHandler ?? notFound)(request)
            }
            return try (clanHandler ?? notFound)(request)
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

    /// 从部落端点请求路径提取 clan tag（`/v1/clans/%23TAG/currentwar` → `#TAG`）。
    private static func clanTag(from request: URLRequest) -> String {
        let path = request.url?.path ?? ""
        return path
            .replacingOccurrences(of: "/v1/clans/", with: "")
            .replacingOccurrences(of: "/currentwar", with: "")
            .replacingOccurrences(of: "/warlog", with: "")
            .replacingOccurrences(of: "/capitalraidseasons", with: "")
            .replacingOccurrences(of: "%23", with: "#")
    }

    // MARK: - 随机生成（property-based）

    /// 随机部落 tag 形态：nil（无部落）/ 有效 / 各类无效（无 #、小写、空、仅 #）。
    private func randomClanTagOption() -> String? {
        switch Int.random(in: 0..<6) {
        case 0: return nil
        case 1: return "#C" + randomValidTagSuffix()
        case 2: return "no-hash-prefix"
        case 3: return "#lowercase"
        case 4: return ""
        case 5: return "#"
        default: return nil
        }
    }

    private func randomValidTagSuffix() -> String {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let length = Int.random(in: 1...8)
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// 随机官方玩家状态：随机 status + 随机 lastGood 有无 + 随机部落形态。
    private func randomPlayerState() -> OfficialAPIState {
        let statuses: [OfficialAPIRequestStatus] = [.never, .loading, .success, .failed, .skipped]
        let status = statuses.randomElement()!
        if Bool.random() {
            return playerState(clanTag: randomClanTagOption(), status: status)
        }
        return OfficialAPIState(status: status, lastGood: nil)
    }

    // MARK: - 路由隔离

    /// 两个村庄（不同状态、不同部落）各自路由：officialState(for:) 必须返回
    /// 对应村庄的状态；随机不存在的 ID 返回 nil，不崩溃。
    @MainActor
    func testOfficialStateRoutesByVillageID() throws {
        let stateA = playerState(clanTag: "#CLANA")
        let stateB = OfficialAPIState(status: .failed, lastErrorReason: "模拟失败", lastGood: nil)
        let villages = [
            VillageProfile(name: "A", accountSnapshot: snapshot("#A"), officialAPIState: stateA),
            VillageProfile(name: "B", accountSnapshot: snapshot("#B"), officialAPIState: stateB),
        ]
        let model = try makeModel(villages: villages)

        XCTAssertEqual(model.officialState(for: villages[0].id), stateA, "A 的 ID 必须路由到 A 的状态")
        XCTAssertEqual(model.officialState(for: villages[1].id), stateB, "B 的 ID 必须路由到 B 的状态")
        XCTAssertNotEqual(model.officialState(for: villages[0].id), stateB, "A 与 B 的状态不得串读")
        XCTAssertNil(model.officialState(for: UUID()), "不存在的 ID 必须返回 nil（不崩溃）")

        XCTAssertEqual(model.officialClanTag(for: villages[0].id), "#CLANA")
        XCTAssertNil(model.officialClanTag(for: villages[1].id), "无 lastGood → 无部落归属")
        XCTAssertFalse(model.clanStatusUnknown(for: villages[0].id), "有 lastGood → 非 unknown")
        XCTAssertTrue(model.clanStatusUnknown(for: villages[1].id), "无 lastGood → unknown")
        XCTAssertTrue(model.clanStatusUnknown(for: UUID()), "不存在 ID → unknown（与从未抓取一致）")
    }

    // MARK: - 刷新切村写回

    /// 对 A 调 refreshOfficialPlayer(villageID: A.id)，请求在途时切换到 B：
    /// - 完成后 A 的官方状态更新（新部落 #CLANANON）；
    /// - B（当前选中）的状态保持原样，不被 A 的结果覆盖；
    /// - 部落联动刷新 A 刷新后的部落（#CLANANON），不得刷新 B 的 #CLANB。
    @MainActor
    func testRefreshOfficialPlayerByIDWritesBackToOriginatingVillage() async throws {
        let playerHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             fullPlayerFixtureData())
        }
        let clanRecorder = TagRecorder()
        let clanHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            let path = request.url?.path ?? ""
            let raw = path.replacingOccurrences(of: "/v1/clans/", with: "")
                .replacingOccurrences(of: "%23", with: "#")
            clanRecorder.record(raw)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullClanFixtureData())
        }

        let stateA = playerState(clanTag: "#CLANA")
        let stateB = playerState(clanTag: "#CLANB")
        let villages = [
            VillageProfile(name: "A", accountSnapshot: snapshot("#A"), officialAPIState: stateA),
            VillageProfile(name: "B", accountSnapshot: snapshot("#B"), officialAPIState: stateB),
        ]
        let model = try makeModel(villages: villages, playerHandler: playerHandler, clanHandler: clanHandler)

        // 发起村庄 A 的刷新，请求在途时立即切换到 B
        model.refreshOfficialPlayer(villageID: model.villages[0].id)
        model.selectVillage(id: model.villages[1].id)

        await waitUntil { !model.isRefreshingOfficialData && !model.isRefreshingClanData }

        // A（发起村庄）写回新快照
        XCTAssertEqual(model.officialState(for: model.villages[0].id)?.status, .success)
        XCTAssertEqual(model.officialClanTag(for: model.villages[0].id), "#CLANANON",
                       "A 刷新后必须反映新快照的部落")
        // B（当前选中）完全不受影响
        XCTAssertEqual(model.officialState(for: model.villages[1].id), stateB,
                       "切换后的当前村庄 B 不得被 A 的刷新结果覆盖")
        XCTAssertEqual(model.officialClanTag(for: model.villages[1].id), "#CLANB")
        // 部落联动必须刷新 A 刷新后的部落（#CLANANON），不得刷新当前选中的 B
        XCTAssertEqual(clanRecorder.snapshot(), ["#CLANANON"],
                       "联动必须作用于发起村庄 A 的部落，而非当前选中的 B: \(clanRecorder.snapshot())")
    }

    // MARK: - 部落按 ID 刷新路由（war/log/capital）

    /// refreshClanWar(villageID:) 的 tag 来源是发起村庄 A（#CLANANON）：
    /// 发起后立即切换到当前选中 B（#CLANB），请求仍打到 #CLANANON，
    /// 结果写入 #CLANANON 键，B 的部落不受影响。
    @MainActor
    func testRefreshClanWarByIDRoutesToOriginatingVillageTag() async throws {
        let warRecorder = TagRecorder()
        let clanWarHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            warRecorder.record(Self.clanTag(from: request))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"state":"notInWar"}"#.utf8))
        }
        let villages = [
            VillageProfile(name: "A", accountSnapshot: snapshot("#A"), officialAPIState: playerState(clanTag: "#CLANANON")),
            VillageProfile(name: "B", accountSnapshot: snapshot("#B"), officialAPIState: playerState(clanTag: "#CLANB")),
        ]
        let model = try makeModel(villages: villages, clanWarHandler: clanWarHandler)

        // 发起村庄 A 的战争刷新，请求在途时切换到 B
        model.refreshClanWar(villageID: model.villages[0].id)
        model.selectVillage(id: model.villages[1].id)

        await waitUntil { !model.isRefreshingClanWarData }

        XCTAssertEqual(warRecorder.snapshot(), ["#CLANANON"],
                       "战争刷新必须请求发起村庄 A 的部落，而非当前选中的 B: \(warRecorder.snapshot())")
        XCTAssertEqual(model.clanWarState(for: "#CLANANON")?.status, .success)
        XCTAssertEqual(model.clanWarState(for: "#CLANANON")?.lastGood?.state, "notInWar")
        XCTAssertNil(model.clanWarState(for: "#CLANB"), "B 的部落战争数据不得被写入")
    }

    /// refreshWarLog(villageID:) 同语义：请求打发起村庄 A 的部落（#CLANANON），
    /// 结果写入 #CLANANON 的 war log 键。
    @MainActor
    func testRefreshWarLogByIDRoutesToOriginatingVillageTag() async throws {
        let logRecorder = TagRecorder()
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            logRecorder.record(Self.clanTag(from: request))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullWarLogPageData())
        }
        let villages = [
            VillageProfile(name: "A", accountSnapshot: snapshot("#A"), officialAPIState: playerState(clanTag: "#CLANANON")),
            VillageProfile(name: "B", accountSnapshot: snapshot("#B"), officialAPIState: playerState(clanTag: "#CLANB")),
        ]
        let model = try makeModel(villages: villages, clanLogHandler: logHandler)

        model.refreshWarLog(villageID: model.villages[0].id)
        model.selectVillage(id: model.villages[1].id)

        await waitUntil { !model.isRefreshingWarLogData }

        XCTAssertEqual(logRecorder.snapshot(), ["#CLANANON"],
                       "战争日志刷新必须请求发起村庄 A 的部落，而非当前选中的 B: \(logRecorder.snapshot())")
        XCTAssertEqual(model.warLogState(for: "#CLANANON")?.status, .success)
        XCTAssertEqual(model.warLogState(for: "#CLANANON")?.lastGood?.items.count, 2)
        XCTAssertNil(model.warLogState(for: "#CLANB"), "B 的部落 war log 不得被写入")
    }

    /// refreshCapitalRaid(villageID:) 同语义：请求打发起村庄 A 的部落（#CLANANON），
    /// 结果写入 #CLANANON 的 capital 键。
    @MainActor
    func testRefreshCapitalRaidByIDRoutesToOriginatingVillageTag() async throws {
        let capitalRecorder = TagRecorder()
        let capitalHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            capitalRecorder.record(Self.clanTag(from: request))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullCapitalRaidPageData())
        }
        let villages = [
            VillageProfile(name: "A", accountSnapshot: snapshot("#A"), officialAPIState: playerState(clanTag: "#CLANANON")),
            VillageProfile(name: "B", accountSnapshot: snapshot("#B"), officialAPIState: playerState(clanTag: "#CLANB")),
        ]
        let model = try makeModel(villages: villages, clanLogHandler: capitalHandler)

        model.refreshCapitalRaid(villageID: model.villages[0].id)
        model.selectVillage(id: model.villages[1].id)

        await waitUntil { !model.isRefreshingCapitalData }

        XCTAssertEqual(capitalRecorder.snapshot(), ["#CLANANON"],
                       "资本赛季刷新必须请求发起村庄 A 的部落，而非当前选中的 B: \(capitalRecorder.snapshot())")
        XCTAssertEqual(model.capitalState(for: "#CLANANON")?.status, .success)
        XCTAssertEqual(model.capitalState(for: "#CLANANON")?.lastGood?.items.count, 2)
        XCTAssertNil(model.capitalState(for: "#CLANB"), "B 的部落 capital 数据不得被写入")
    }

    // MARK: - 部落按 tag 共享

    /// 部落四层共享字典按 clan tag 路由：同部落两个村庄共享同一份；
    /// 不同 tag 各自；不存在的 tag 返回 nil。
    @MainActor
    func testClanSharedStatesKeyedByTag() throws {
        let sameTag = "#CLANSAME"
        let otherTag = "#CLANOTHER"

        let clanSame = ClanAPIState(status: .success, clanTag: sameTag,
                                    lastGood: clanSnapshot(tag: sameTag, isWarLogPublic: false))
        let clanOther = ClanAPIState(status: .success, clanTag: otherTag,
                                     lastGood: clanSnapshot(tag: otherTag, isWarLogPublic: true))
        let warSame = ClanWarAPIState(status: .success, clanTag: sameTag,
                                      lastGood: warSnapshot(state: "inWar"))
        let logSame = ClanWarLogAPIState(status: .success, clanTag: sameTag, lastGood: OfficialWarLogPage(
            page: OfficialPaginatedPage(items: [], before: nil, after: "CURSOR1")
        ))
        let logOther = ClanWarLogAPIState(status: .success, clanTag: otherTag, lastGood: OfficialWarLogPage(
            page: OfficialPaginatedPage(items: [], before: nil, after: nil)
        ))
        let capSame = ClanCapitalAPIState(status: .success, clanTag: sameTag, lastGood: OfficialCapitalRaidPage(
            page: OfficialPaginatedPage(items: [], before: nil, after: "RAIDCURSOR1")
        ))
        defaults.set(try JSONEncoder().encode(ClanStateStore(states: [sameTag: clanSame, otherTag: clanOther])),
                     forKey: "coc-helper.clans.v1")
        defaults.set(try JSONEncoder().encode(ClanWarStateStore(states: [sameTag: warSame])),
                     forKey: "coc-helper.clan-wars.v1")
        defaults.set(try JSONEncoder().encode(ClanWarLogStateStore(states: [sameTag: logSame, otherTag: logOther])),
                     forKey: "coc-helper.clan-war-logs.v1")
        defaults.set(try JSONEncoder().encode(ClanCapitalStateStore(states: [sameTag: capSame])),
                     forKey: "coc-helper.clan-capitals.v1")

        // 两个村庄属于同一部落
        let villages = [
            VillageProfile(name: "A1", accountSnapshot: snapshot("#A1"), officialAPIState: playerState(clanTag: sameTag)),
            VillageProfile(name: "A2", accountSnapshot: snapshot("#A2"), officialAPIState: playerState(clanTag: sameTag)),
        ]
        let model = try makeModel(villages: villages)

        // 同部落村庄 → 派生同一 tag → 命中同一共享条目
        XCTAssertEqual(model.officialClanTag(for: villages[0].id), sameTag)
        XCTAssertEqual(model.officialClanTag(for: villages[1].id), sameTag)
        XCTAssertEqual(model.clanState(for: sameTag), clanSame, "同 tag 必须返回共享字典中的同一份")
        XCTAssertEqual(
            model.clanState(for: model.officialClanTag(for: villages[0].id)!),
            model.clanState(for: model.officialClanTag(for: villages[1].id)!),
            "同部落两个村庄必须共享同一条目"
        )

        // 不同 tag → 各自条目
        XCTAssertEqual(model.clanState(for: otherTag), clanOther)
        XCTAssertNotEqual(model.clanState(for: sameTag), clanOther, "不同部落的状态不得串读")

        // 不存在的 tag → 四层均 nil
        XCTAssertNil(model.clanState(for: "#MISSING"))
        XCTAssertNil(model.clanWarState(for: "#MISSING"))
        XCTAssertNil(model.warLogState(for: "#MISSING"))
        XCTAssertNil(model.capitalState(for: "#MISSING"))

        // 四层 by-tag 读取
        XCTAssertEqual(model.clanWarState(for: sameTag), warSame)
        XCTAssertEqual(model.warLogState(for: sameTag), logSame)
        XCTAssertEqual(model.capitalState(for: sameTag), capSame)

        // 派生辅助：不公开预判 / 分页 hasMore
        XCTAssertTrue(model.isWarLogKnownNotPublic(for: sameTag), "isWarLogPublic=false → 已知不公开")
        XCTAssertFalse(model.isWarLogKnownNotPublic(for: otherTag), "isWarLogPublic=true → 非不公开")
        XCTAssertFalse(model.isWarLogKnownNotPublic(for: "#MISSING"), "无部落档案 → 非不公开")
        XCTAssertTrue(model.warLogHasMore(for: sameTag), "有 after 游标 → hasMore")
        XCTAssertFalse(model.warLogHasMore(for: otherTag), "无 after 游标 → 非 hasMore")
        XCTAssertFalse(model.warLogHasMore(for: "#MISSING"), "无状态 → 非 hasMore")
        XCTAssertTrue(model.capitalHasMore(for: sameTag), "有 after 游标 → hasMore")
        XCTAssertFalse(model.capitalHasMore(for: "#MISSING"), "无状态 → 非 hasMore")
    }

    // MARK: - 派生语义

    /// officialClanTag / clanStatusUnknown 派生规则：
    /// - lastGood nil → unknown true、clanTag nil；
    /// - lastGood 存在但 clan 缺失 → unknown false、clanTag nil；
    /// - lastGood.clan.tag 无效 → clanTag nil；
    /// - 新快照新 clan tag（换部落）→ officialClanTag 反映新 tag。
    @MainActor
    func testDerivedClanSemantics() throws {
        let neverFetched = OfficialAPIState(status: .never, lastGood: nil)
        let fetchedNoClan = playerState(clanTag: nil)
        let invalidClanTag = playerState(clanTag: "#lowercase")
        let switchedClan = playerState(clanTag: "#CLANNEW")

        let villages = [
            VillageProfile(name: "unknown", accountSnapshot: snapshot("#V1"), officialAPIState: neverFetched),
            VillageProfile(name: "noClan", accountSnapshot: snapshot("#V2"), officialAPIState: fetchedNoClan),
            VillageProfile(name: "invalid", accountSnapshot: snapshot("#V3"), officialAPIState: invalidClanTag),
            VillageProfile(name: "switched", accountSnapshot: snapshot("#V4"), officialAPIState: switchedClan),
        ]
        let model = try makeModel(villages: villages)

        // lastGood nil → unknown true、无部落归属
        XCTAssertTrue(model.clanStatusUnknown(for: villages[0].id), "lastGood nil → unknown")
        XCTAssertNil(model.officialClanTag(for: villages[0].id))

        // lastGood 存在但 clan 缺失 → unknown false、clanTag nil（区分「未知」与「确认无部落」）
        XCTAssertFalse(model.clanStatusUnknown(for: villages[1].id), "抓取成功但无部落 → 非 unknown")
        XCTAssertNil(model.officialClanTag(for: villages[1].id))

        // clan tag 无效（小写）→ clanTag nil
        XCTAssertFalse(model.clanStatusUnknown(for: villages[2].id))
        XCTAssertNil(model.officialClanTag(for: villages[2].id), "无效 tag 不得作为部落归属")

        // 换部落：新快照新 clan tag → officialClanTag 反映新 tag
        XCTAssertFalse(model.clanStatusUnknown(for: villages[3].id))
        XCTAssertEqual(model.officialClanTag(for: villages[3].id), "#CLANNEW",
                       "officialClanTag 必须反映最近成功快照的部落")
    }

    /// officialTag(for:) 派生规则（与 currentVillageOfficialTag 一致，仅来源改为显式 ID）：
    /// - 有有效 tag → 返回规范化（去首尾空白）后的 tag；
    /// - 无效格式 / 无快照 / 不存在 ID → nil；
    /// - 与 currentVillageOfficialTag（对选中村庄）一致。
    @MainActor
    func testOfficialTagRoutesByVillageID() throws {
        let villages = [
            VillageProfile(name: "valid", accountSnapshot: snapshot("  #ABC9  ")),
            VillageProfile(name: "invalid", accountSnapshot: snapshot("#lowercase")),
            VillageProfile(name: "noSnapshot"),
        ]
        let model = try makeModel(villages: villages)

        // 有有效 tag → 规范化结果
        XCTAssertEqual(model.officialTag(for: villages[0].id), "#ABC9", "首尾空白必须被去除")
        XCTAssertNotEqual(model.officialTag(for: villages[0].id), "  #ABC9  ", "必须是规范化后的 tag")

        // 无有效 tag → nil（格式无效 / 无快照 / 不存在 ID）
        XCTAssertNil(model.officialTag(for: villages[1].id), "格式无效的 tag → nil")
        XCTAssertNil(model.officialTag(for: villages[2].id), "无快照 → nil")
        XCTAssertNil(model.officialTag(for: UUID()), "不存在的 ID → nil（不崩溃）")

        // 与 currentVillageOfficialTag（对选中村庄）一致：初始选中 villages[0]
        XCTAssertEqual(model.currentVillageOfficialTag, model.officialTag(for: model.selectedVillageID),
                       "选中村庄的 currentVillageOfficialTag 必须与 by-ID 接口一致")
        // 切换到无有效 tag 的村庄：两者一致地变 nil
        model.selectVillage(id: villages[2].id)
        XCTAssertEqual(model.currentVillageOfficialTag, model.officialTag(for: model.selectedVillageID))
        XCTAssertNil(model.currentVillageOfficialTag, "切换后选中村庄无有效 tag → nil")
    }

    // MARK: - Property-based 一致性

    /// 随机生成 1-5 个村庄（随机官方状态），对每个存在的 ID：
    /// officialState(for:) 与数组中村庄状态恒等；随机不存在的 ID → nil。50 轮。
    @MainActor
    func testPropertyBasedOfficialStateRoutingConsistency() throws {
        for iteration in 0..<50 {
            let count = Int.random(in: 1...5)
            var villages: [VillageProfile] = []
            for i in 0..<count {
                villages.append(VillageProfile(
                    name: "V\(i)",
                    accountSnapshot: snapshot("#V\(i)"),
                    officialAPIState: randomPlayerState()
                ))
            }
            let model = try makeModel(villages: villages)

            for village in villages {
                XCTAssertEqual(model.officialState(for: village.id), village.officialAPIState,
                               "第 \(iteration) 轮：存在的 ID 必须返回对应村庄的状态")
            }
            XCTAssertNil(model.officialState(for: UUID()),
                         "第 \(iteration) 轮：随机不存在的 ID 必须返回 nil")
        }
    }

    /// 随机官方状态（随机 status / lastGood 有无 / 部落形态），50 轮：
    /// - clanStatusUnknown == (lastGood == nil) 恒成立；
    /// - officialClanTag 非 nil ⟹ lastGood?.clan?.tag 存在且有效、且等于规范化后的 tag。
    @MainActor
    func testPropertyBasedDerivedClanSemantics() throws {
        for iteration in 0..<50 {
            let state = randomPlayerState()
            let village = VillageProfile(name: "V", officialAPIState: state)
            let model = try makeModel(villages: [village])

            XCTAssertEqual(model.clanStatusUnknown(for: village.id), state.lastGood == nil,
                           "第 \(iteration) 轮：clanStatusUnknown 必须与 lastGood 缺失等价")

            if let tag = model.officialClanTag(for: village.id) {
                XCTAssertNotNil(state.lastGood,
                                "第 \(iteration) 轮：officialClanTag 非 nil ⟹ lastGood 存在")
                XCTAssertNotNil(state.lastGood?.clan?.tag,
                                "第 \(iteration) 轮：officialClanTag 非 nil ⟹ 快照含部落 tag")
                // 刻意保留旧类型名：作为 OfficialTagValidator typealias 的
                // 真实兼容回归（Issue #48 Step 1 重命名后仍可编译运行）。
                XCTAssertTrue(OfficialPlayerTagValidator.isValid(tag),
                              "第 \(iteration) 轮：officialClanTag 必须是有效格式: \(tag)")
                XCTAssertEqual(tag, OfficialPlayerTagValidator.normalized(state.lastGood?.clan?.tag),
                               "第 \(iteration) 轮：officialClanTag 必须是规范化后的部落 tag")
            }
        }
    }

    // MARK: - 刷新进行中状态按村庄 / 部落 ID 隔离（Issue #35 P2-1）

    /// 官方玩家刷新在途状态按村庄 ID 隔离（mock 请求挂起模拟在途）：
    /// - A 在途 → isRefreshingOfficialPlayer(A.id) == true、B == false；
    /// - 在途期间切换到村庄 B：两者状态不变（切村回归）；
    /// - 请求完成 → 全部 false；兼容计算属性 isRefreshingOfficialData 同步可用。
    @MainActor
    func testRefreshingStateIsolatedByVillageID() async throws {
        // 挂起门闩：handler 阻塞直到测试放行，制造"请求在途"窗口。
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() } // 兜底：断言失败也放行，避免挂起的 mock 请求阻塞测试进程
        let playerHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            gate.wait()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullPlayerFixtureData())
        }
        let clanHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             fullClanFixtureData())
        }
        let villages = [
            VillageProfile(name: "A", accountSnapshot: snapshot("#A"), officialAPIState: playerState(clanTag: "#CLANA")),
            VillageProfile(name: "B", accountSnapshot: snapshot("#B"), officialAPIState: playerState(clanTag: "#CLANB")),
        ]
        let model = try makeModel(villages: villages, playerHandler: playerHandler, clanHandler: clanHandler)

        // A 的刷新在途（集合在同步段设置，立即生效）
        model.refreshOfficialPlayer(villageID: model.villages[0].id)
        XCTAssertTrue(model.isRefreshingOfficialPlayer(villageID: model.villages[0].id),
                      "A 刷新在途 → A 卡片必须显示刷新中")
        XCTAssertFalse(model.isRefreshingOfficialPlayer(villageID: model.villages[1].id),
                       "B 未刷新 → B 卡片不得显示刷新中（P2-1 串村修复）")
        XCTAssertFalse(model.isRefreshingOfficialPlayer(villageID: UUID()), "不存在的 ID → false")
        XCTAssertTrue(model.isRefreshingOfficialData, "兼容计算属性：任意村庄在途 → true")

        // 在途期间切换到村庄 B：隔离状态不得漂移
        model.selectVillage(id: model.villages[1].id)
        XCTAssertTrue(model.isRefreshingOfficialPlayer(villageID: model.villages[0].id),
                      "切村后 A 的刷新在途状态必须保留")
        XCTAssertFalse(model.isRefreshingOfficialPlayer(villageID: model.villages[1].id),
                       "切村后 B 仍不得显示刷新中")

        // 放行请求 → 完成清空
        gate.signal()
        await waitUntil {
            !model.isRefreshingOfficialPlayer(villageID: model.villages[0].id)
                && !model.isRefreshingOfficialPlayer(villageID: model.villages[1].id)
        }
        XCTAssertFalse(model.isRefreshingOfficialData, "完成后兼容计算属性 → false")
    }

    /// 部落档案刷新在途状态按 clan tag 隔离：
    /// - A 村部落 #CLANANON 在途 → isRefreshingClan("#CLANANON") == true、
    ///   isRefreshingClan("#CLANB") == false、isRefreshingClan(nil) == false；
    /// - 完成 → 全部 false；兼容计算属性 isRefreshingClanData 同步可用。
    @MainActor
    func testRefreshingClanTagIsolated() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let clanHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            gate.wait()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullClanFixtureData())
        }
        let villages = [
            VillageProfile(name: "A", accountSnapshot: snapshot("#A"), officialAPIState: playerState(clanTag: "#CLANANON")),
            VillageProfile(name: "B", accountSnapshot: snapshot("#B"), officialAPIState: playerState(clanTag: "#CLANB")),
        ]
        let model = try makeModel(villages: villages, clanHandler: clanHandler)

        model.refreshClan(villageID: model.villages[0].id)
        XCTAssertTrue(model.isRefreshingClan(clanTag: "#CLANANON"), "A 部落档案在途 → true")
        XCTAssertFalse(model.isRefreshingClan(clanTag: "#CLANB"), "B 部落档案未在途 → false（P2-1 串卡修复）")
        XCTAssertFalse(model.isRefreshingClan(clanTag: nil), "nil tag → false")
        XCTAssertTrue(model.isRefreshingClanData, "兼容计算属性：任意部落档案在途 → true")

        gate.signal()
        await waitUntil { !model.isRefreshingClan(clanTag: "#CLANANON") }
        XCTAssertFalse(model.isRefreshingClan(clanTag: "#CLANANON"), "完成后 → false")
        XCTAssertFalse(model.isRefreshingClanData, "完成后兼容计算属性 → false")
    }

    /// war / log / capital 三层与部落档案同构（同步段捕获发起村庄 tag 后设置集合），
    /// 各做最小在途断言 + 完成后兼容计算属性可用性。
    @MainActor
    func testRefreshingWarLogCapitalTagsIsolated() async throws {
        let logGate = DispatchSemaphore(value: 0)
        defer { logGate.signal() }
        // 仅 warlog 请求挂起制造在途窗口；capital 请求不挂起
        //（其"在途"断言靠同步段设置的集合即可确定性成立，见下方注释）。
        let logHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            if request.url?.path.contains("/capitalraidseasons") == true {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        fullCapitalRaidPageData())
            }
            logGate.wait()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    fullWarLogPageData())
        }
        let warHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"state":"notInWar"}"#.utf8))
        }
        let villages = [
            VillageProfile(name: "A", accountSnapshot: snapshot("#A"), officialAPIState: playerState(clanTag: "#CLANANON")),
            VillageProfile(name: "B", accountSnapshot: snapshot("#B"), officialAPIState: playerState(clanTag: "#CLANB")),
        ]
        let model = try makeModel(villages: villages, clanWarHandler: warHandler, clanLogHandler: logHandler)

        // 战争层（不挂起，完成即清空）
        model.refreshClanWar(villageID: model.villages[0].id)
        XCTAssertTrue(model.isRefreshingClanWar(clanTag: "#CLANANON"), "A 部落战争在途 → true")
        XCTAssertFalse(model.isRefreshingClanWar(clanTag: "#CLANB"), "B 部落战争未在途 → false")
        XCTAssertFalse(model.isRefreshingClanWar(clanTag: nil), "nil tag → false")
        await waitUntil { !model.isRefreshingClanWar(clanTag: "#CLANANON") }

        // 战争日志层（挂起在途）
        model.refreshWarLog(villageID: model.villages[0].id)
        XCTAssertTrue(model.isRefreshingWarLog(clanTag: "#CLANANON"), "A 部落战争日志在途 → true")
        XCTAssertFalse(model.isRefreshingWarLog(clanTag: "#CLANB"), "B 部落战争日志未在途 → false")
        XCTAssertFalse(model.isRefreshingWarLog(clanTag: nil), "nil tag → false")
        logGate.signal()
        await waitUntil { !model.isRefreshingWarLog(clanTag: "#CLANANON") }

        // 资本层（集合在同步段设置；调用与断言之间无 await，Task 无法抢先
        // 清空集合，因此不挂起请求也可确定性断言"在途"）
        model.refreshCapitalRaid(villageID: model.villages[0].id)
        XCTAssertTrue(model.isRefreshingCapital(clanTag: "#CLANANON"), "A 部落资本在途 → true")
        XCTAssertFalse(model.isRefreshingCapital(clanTag: "#CLANB"), "B 部落资本未在途 → false")
        XCTAssertFalse(model.isRefreshingCapital(clanTag: nil), "nil tag → false")
        await waitUntil { !model.isRefreshingCapital(clanTag: "#CLANANON") }

        // 三层兼容计算属性完成 → false
        XCTAssertFalse(model.isRefreshingClanWarData)
        XCTAssertFalse(model.isRefreshingWarLogData)
        XCTAssertFalse(model.isRefreshingCapitalData)
    }
}
