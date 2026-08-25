import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

/// Issue #253 Phase A：AppModel 对分页累计缓存的 retention 接线。
///
/// 验证三件事：
/// 1. warlog load-more 合并后累计条目收敛到上限（头新尾旧，裁尾）；
/// 2. capitalraidseasons 同理，且 row cache 与裁剪后 state 同步
///    （#221 lifecycle：state 是事实源，row cache 是投影）；
/// 3. 启动自愈：旧版本落盘的超限 store 在 init 时被收敛并回写
///    （未超限 Tag 不株连；游标不触碰）。

// MARK: - 文件域纯函数（@Sendable handler 闭包无法捕获 self）

/// 最小合法 warlog 条目 JSON：endTime 唯一化（Equatable 去重依赖条目可区分）。
private func warLogItemJSON(_ index: Int) -> String {
    "{\"endTime\":\"war-\(String(format: "%04d", index))\"}"
}

/// warlog 分页响应 JSON（items + 可选 after 游标）。
private func warLogPageJSON(first: Int, count: Int, after: String?) -> Data {
    let items = (first..<(first + count)).map(warLogItemJSON(_:)).joined(separator: ",")
    let cursor = after.map { ",\"paging\":{\"cursors\":{\"after\":\"\($0)\"}}" } ?? ""
    return Data("{\"items\":[\(items)]\(cursor)}".utf8)
}

/// 最小合法 capital 赛季 JSON：startTime 唯一化（triple key 可区分）。
private func capitalSeasonJSON(_ index: Int) -> String {
    "{\"state\":\"ended\",\"startTime\":\"\(String(format: "s%04d", index))\",\"endTime\":\"e\"}"
}

private func capitalPageJSON(first: Int, count: Int, after: String?) -> Data {
    let items = (first..<(first + count)).map(capitalSeasonJSON(_:)).joined(separator: ",")
    let cursor = after.map { ",\"paging\":{\"cursors\":{\"after\":\"\($0)\"}}" } ?? ""
    return Data("{\"items\":[\(items)]\(cursor)}".utf8)
}

final class AppModelCacheRetentionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    /// makeModel 每次创建的实例（MainActor 隔离属性，测试内引用同一 model）。
    @MainActor
    private var currentModel: AppModel?

    override func setUp() {
        super.setUp()
        suiteName = "AppModelCacheRetentionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    /// 仿 AppModelTrackedClanRefreshTests.makeModel：MockURLProtocol 按端点路由。
    @MainActor
    private func makeModel(
        clanLogHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil
    ) -> AppModel {
        let defaultHandler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        MockURLProtocol.handler = { request in
            if request.url?.path.contains("/warlog") == true
                || request.url?.path.contains("/capitalraidseasons") == true {
                return try (clanLogHandler ?? defaultHandler)(request)
            }
            return try defaultHandler(request)
        }
        let model = AppModel(
            defaults: defaults,
            clanRefresher: ClanRefresher(client: CoAPIClient(
                config: CoAPIConfig(maxRetryCount: 0),
                session: MockURLProtocol.makeSession()
            ) { "fake-token" }),
            clanWarRefresher: ClanWarRefresher(client: CoAPIClient(
                config: CoAPIConfig(maxRetryCount: 0),
                session: MockURLProtocol.makeSession()
            ) { "fake-token" }),
            clanLogClient: CoAPIClient(
                config: CoAPIConfig(maxRetryCount: 0),
                session: MockURLProtocol.makeSession()
            ) { "fake-token" },
            historyStore: TestSnapshotHistoryStore()
        )
        currentModel = model
        return model
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("等待条件超时")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - warlog load-more 收敛

    /// 首屏 205 条 + load-more 10 条更旧 → 合并 215 条 → 收敛到上限：
    /// 头部（最新）保留，超限的最旧尾段被裁掉，游标原样推进。
    @MainActor
    func testLoadMoreWarLogTrimsAccumulatedItemsToCap() async throws {
        let cap = CacheRetentionPolicy.maxWarLogItemsPerTag
        XCTAssertGreaterThan(205 + 10, cap, "前置：合并结果必须超限才能触发裁剪")

        _ = makeModel(clanLogHandler: { request in
            let hasCursor = request.url?.query?.contains("after=") == true
            let body = hasCursor
                ? warLogPageJSON(first: 205, count: 10, after: "A2")
                : warLogPageJSON(first: 0, count: 205, after: "A1")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        })

        currentModel!.refreshWarLog(tag: "#CAPWAR1")
        await waitUntil { [self] in currentModel!.warLogState(for: "#CAPWAR1")?.lastGood?.after == "A1" }
        currentModel!.loadMoreWarLog(tag: "#CAPWAR1")
        await waitUntil { [self] in !currentModel!.isRefreshingWarLogData }

        let page = try XCTUnwrap(currentModel!.warLogState(for: "#CAPWAR1")?.lastGood)
        XCTAssertEqual(page.items.count, cap, "load-more 合并后必须收敛到保留上限")
        XCTAssertEqual(page.items.first?.endTime, "war-0000", "头部（最新）不得被裁剪")
        XCTAssertEqual(page.after, "A2", "游标是服务端翻页位置，裁剪不得触碰")
        XCTAssertTrue(page.items.contains { $0.endTime == "war-0199" }, "上限内的首屏段完整存留")
        XCTAssertFalse(page.items.contains { $0.endTime == "war-0200" }, "超出上限的首屏尾段必须裁掉")
        XCTAssertFalse(page.items.contains { $0.endTime == "war-0214" }, "追加的更旧页整段位于裁剪区")
    }

    // MARK: - capital load-more 收敛 + row cache 同步

    /// 首屏 245 赛季 + load-more 5 个更旧 → 合并 250 → 收敛到上限。
    /// 同时断言 `capitalRaidRows`（row cache 投影）与裁剪后的 state 一致，
    /// 且存留行 ID 与 head-stable 方案一致（#211）。
    @MainActor
    func testLoadMoreCapitalRaidTrimsAccumulatedSeasonsAndKeepsRowCacheInSync() async throws {
        let cap = CacheRetentionPolicy.maxCapitalSeasonsPerTag
        XCTAssertGreaterThan(245 + 5, cap, "前置：合并结果必须超限才能触发裁剪")

        _ = makeModel(clanLogHandler: { request in
            let body = request.url?.query?.contains("after=") == true
                ? capitalPageJSON(first: 245, count: 5, after: "C2")
                : capitalPageJSON(first: 0, count: 245, after: "C1")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        })

        currentModel!.refreshCapitalRaid(tag: "#CAPRAID1")
        await waitUntil { [self] in currentModel!.capitalState(for: "#CAPRAID1")?.lastGood?.after == "C1" }
        currentModel!.loadMoreCapitalRaid(tag: "#CAPRAID1")
        await waitUntil { [self] in !currentModel!.isRefreshingCapitalData }

        let page = try XCTUnwrap(currentModel!.capitalState(for: "#CAPRAID1")?.lastGood)
        XCTAssertEqual(page.items.count, cap, "capital load-more 合并后必须收敛到保留上限")
        XCTAssertEqual(page.items.first?.startTime, "s0000", "头部（最新赛季）不得被裁剪")
        XCTAssertEqual(page.after, "C2", "游标是服务端翻页位置，裁剪不得触碰")

        // row cache 与 state 同步：行数一致，行 ID 的 triple#seq 部分与从最终
        // state 直接生成的 head-stable 方案一致（缓存 ID 带 raid:gN: 前缀）。
        let rows = currentModel!.capitalRaidRows(for: "#CAPRAID1")
        XCTAssertEqual(rows.count, cap, "row cache 必须与裁剪后的 state 同步")
        let expected = CapitalRaidRowIdentity.rows(for: page.items)
        XCTAssertEqual(rows.count, expected.count)
        for (row, expectedRow) in zip(rows, expected) {
            XCTAssertTrue(row.id.hasSuffix(expectedRow.id),
                          "row ID \(row.id) 必须与 state 方案 \(expectedRow.id) 对齐")
            XCTAssertEqual(row.season, expectedRow.season)
        }
    }

    // MARK: - 启动自愈

    /// 直接向 defaults 写入超限 store（模拟旧版本累积），init 后内存与磁盘
    /// 都必须收敛到上限；未超限 Tag 不受影响（不株连）；游标不触碰。
    @MainActor
    func testStartupSelfHealTrimsLegacyOversizedStoresAndPersists() throws {
        let warCap = CacheRetentionPolicy.maxWarLogItemsPerTag
        let capitalCap = CacheRetentionPolicy.maxCapitalSeasonsPerTag

        func warEntry(_ index: Int) -> OfficialWarLogEntry {
            OfficialWarLogEntry(result: nil, endTime: "war-\(index)", teamSize: nil,
                                attacksPerMember: nil, battleModifier: nil,
                                clan: nil, opponent: nil)
        }
        func capitalSeason(_ index: Int) -> OfficialCapitalRaidSeason {
            OfficialCapitalRaidSeason(
                state: "ended", startTime: String(format: "s%04d", index),
                endTime: "e", capitalTotalLoot: nil, raidsCompleted: nil,
                totalAttacks: nil, enemyDistrictsDestroyed: nil,
                offensiveReward: nil, defensiveReward: nil,
                members: nil, attackLog: nil, defenseLog: nil)
        }

        // 超限 warlog（#BIG：cap+50 条）+ 正常 Tag（#OK：3 条）+ 超限 capital。
        let bigWarState = OfficialEndpointState<OfficialWarLogPage>(
            status: .success,
            lastGood: OfficialWarLogPage(page: OfficialPaginatedPage(
                items: (0..<(warCap + 50)).map(warEntry(_:)), before: nil, after: "KEEP")))
        let okWarState = OfficialEndpointState<OfficialWarLogPage>(
            status: .success,
            lastGood: OfficialWarLogPage(page: OfficialPaginatedPage(
                items: (900..<903).map(warEntry(_:)), before: nil, after: nil)))
        try defaultsSet(try JSONEncoder().encode(
            ClanWarLogStateStore(states: ["#BIG": bigWarState, "#OK": okWarState])),
            forKey: "coc-helper.clan-war-logs.v1")

        let bigCapitalState = OfficialEndpointState<OfficialCapitalRaidPage>(
            status: .success,
            lastGood: OfficialCapitalRaidPage(page: OfficialPaginatedPage(
                items: (0..<(capitalCap + 5)).map(capitalSeason(_:)), before: nil, after: "CKEEP")))
        try defaultsSet(try JSONEncoder().encode(
            ClanCapitalStateStore(states: ["#BIGC": bigCapitalState])),
            forKey: "coc-helper.clan-capitals.v1")

        _ = makeModel()
        let model = try XCTUnwrap(currentModel)

        // 内存视图：#BIG 收敛、#OK 不株连、游标保留。
        let bigWar = try XCTUnwrap(model.warLogState(for: "#BIG"))
        XCTAssertEqual(bigWar.lastGood?.items.count, warCap)
        XCTAssertEqual(bigWar.lastGood?.after, "KEEP", "自愈同样不得触碰游标")
        let okWar = try XCTUnwrap(model.warLogState(for: "#OK"))
        XCTAssertEqual(okWar.lastGood?.items.count, 3, "未超限 Tag 不得被株连")
        let bigCapital = try XCTUnwrap(model.capitalState(for: "#BIGC"))
        XCTAssertEqual(bigCapital.lastGood?.items.count, capitalCap)
        XCTAssertEqual(bigCapital.lastGood?.after, "CKEEP")

        // 磁盘收敛：重新解码持久化 blob，确认自愈已回写（下次启动零重复成本）。
        let persistedWar = try JSONDecoder().decode(
            ClanWarLogStateStore.self,
            from: XCTUnwrap(defaults.data(forKey: "coc-helper.clan-war-logs.v1")))
        XCTAssertEqual(persistedWar.states["#BIG"]?.lastGood?.items.count, warCap)
        XCTAssertEqual(persistedWar.states["#OK"]?.lastGood?.items.count, 3)
        let persistedCapital = try JSONDecoder().decode(
            ClanCapitalStateStore.self,
            from: XCTUnwrap(defaults.data(forKey: "coc-helper.clan-capitals.v1")))
        XCTAssertEqual(persistedCapital.states["#BIGC"]?.lastGood?.items.count, capitalCap)
    }

    @MainActor
    private func defaultsSet(_ data: Data, forKey key: String) throws {
        defaults.set(data, forKey: key)
    }
}
