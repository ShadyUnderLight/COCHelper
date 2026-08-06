import Foundation
import XCTest
@testable import COCHelperCore
@testable import COCHelperApp

/// 构造 mock HTTP 响应（free function，避免 @Sendable handler 捕获 self）。
private func clanResolveResponse(_ status: Int, url: URL, body: Data = Data()) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
}

/// AppModel.resolveClan（Issue #48 Step A：添加部落的解析预览阶段）测试。
///
/// 覆盖：本地校验失败、无 token、404/403/429/5xx/网络错误分类、
/// 成功写入共享缓存（clanStates + 持久化）、规范化入参、查重查询。
final class AppModelClanResolveTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "AppModelClanResolveTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 复刻 AppModelTrackedClanRefreshTests.makeModel 的注入方式。
    /// `tokenProvider` 可注入 nil（模拟未配置 token）或 "fake-token"。
    /// `maxRetryCount`/`baseRetryDelay` 用于重试退避取消路径（默认不重试）。
    @MainActor
    private func makeModel(
        tokenProvider: @escaping @Sendable () -> String? = { "fake-token" },
        maxRetryCount: Int = 0,
        baseRetryDelay: TimeInterval = 0,
        clanHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> AppModel {
        MockURLProtocol.handler = { request in
            try clanHandler(request)
        }
        let clanRefresher = ClanRefresher(client: CoAPIClient(
            config: CoAPIConfig(maxRetryCount: maxRetryCount, baseRetryDelay: baseRetryDelay),
            session: MockURLProtocol.makeSession()
        ) { tokenProvider() })
        return AppModel(
            defaults: defaults,
            clanRefresher: clanRefresher,
            clanWarRefresher: ClanWarRefresher(client: CoAPIClient(
                config: CoAPIConfig(maxRetryCount: 0),
                session: MockURLProtocol.makeSession()
            ) { "fake-token" }),
            clanLogClient: CoAPIClient(
                config: CoAPIConfig(maxRetryCount: 0),
                session: MockURLProtocol.makeSession()
            ) { "fake-token" }
        )
    }

    // MARK: - 本地校验失败

    @MainActor
    func testResolveClanRejectsInvalidTagWithoutRequest() async throws {
        let model = try makeModel { request in
            XCTFail("非法 tag 不应发起请求: \(request.url?.path ?? "")")
            return clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        let result = await model.resolveClan(rawTag: "abc-123")
        guard case .failure(let error) = result else {
            return XCTFail("非法 tag 必须失败，实际: \(result)")
        }
        XCTAssertEqual(error, .invalidTag)
    }

    @MainActor
    func testResolveClanRejectsNilAndEmptyWithoutRequest() async throws {
        let model = try makeModel { request in
            XCTFail("空输入不应发起请求")
            return clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        for raw in [nil as String?, "", "   "] {
            let result = await model.resolveClan(rawTag: raw)
            guard case .failure(let error) = result else {
                return XCTFail("输入 \(raw.debugDescription) 必须失败")
            }
            XCTAssertEqual(error, .invalidTag)
        }
    }

    // MARK: - 错误分类（CoAPIError → ClanResolveError 映射）

    @MainActor
    func testResolveClanWithoutTokenMapsToMissingToken() async throws {
        let model = try makeModel(tokenProvider: { nil }) { request in
            XCTFail("无 token 不应发起请求")
            return clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        guard case .failure(let error) = result else {
            return XCTFail("无 token 必须失败，实际: \(result)")
        }
        XCTAssertEqual(error, .missingToken)
    }

    @MainActor
    func testResolveClanNotFoundMapsToNotFound() async throws {
        let model = try makeModel { request in
            clanResolveResponse(404, url: request.url!)
        }
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertEqual(result, .failure(.notFound))
    }

    @MainActor
    func testResolveClanAccessDeniedMapsFrom401And403() async throws {
        for status in [401, 403] {
            let model = try makeModel { request in
                clanResolveResponse(status, url: request.url!)
            }
            let result = await model.resolveClan(rawTag: "#2QJQ8J88")
            XCTAssertEqual(result, .failure(.accessDenied), "HTTP \(status) 应映射为 accessDenied")
        }
    }

    @MainActor
    func testResolveClanRateLimitedMapsToRateLimited() async throws {
        let model = try makeModel { request in
            clanResolveResponse(429, url: request.url!)
        }
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertEqual(result, .failure(.rateLimited))
    }

    @MainActor
    func testResolveClanServerErrorMapsToServer() async throws {
        for status in [500, 502, 503] {
            let model = try makeModel { request in
                clanResolveResponse(status, url: request.url!)
            }
            let result = await model.resolveClan(rawTag: "#2QJQ8J88")
            XCTAssertEqual(result, .failure(.server), "HTTP \(status) 应映射为 server")
        }
    }

    @MainActor
    func testResolveClanNetworkErrorMapsToNetwork() async throws {
        let model = try makeModel { _ in
            throw URLError(.notConnectedToInternet)
        }
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertEqual(result, .failure(.network))
    }

    /// CoAPIError.timeout（URLError.timedOut）→ .network（与 network 同类文案）。
    @MainActor
    func testResolveClanTimeoutMapsToNetwork() async throws {
        let model = try makeModel { _ in
            throw URLError(.timedOut)
        }
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertEqual(result, .failure(.network))
    }

    /// 200 + 非法 JSON → CoAPIError.malformedResponse → .malformed（文案区分于网络错误）。
    @MainActor
    func testResolveClanMalformedMapsToMalformed() async throws {
        let model = try makeModel { request in
            clanResolveResponse(200, url: request.url!, body: Data("not-json".utf8))
        }
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertEqual(result, .failure(.malformed))
    }

    /// 取消传播（重试退避路径）：429 + 重试配置下，client 在 Task.sleep 退避时
    /// 被取消 → CancellationError 透传 → resolveClan 必须映射为 .cancelled
    /// 而非 .network（CoAPIClient 契约："never be misreported as a network failure"）。
    @MainActor
    func testResolveClanCancellationMapsToCancelled() async throws {
        let model = try makeModel(maxRetryCount: 1, baseRetryDelay: 2) { request in
            clanResolveResponse(429, url: request.url!)
        }
        let task = Task { await model.resolveClan(rawTag: "#2QJQ8J88") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
    }

    /// URLSession 取消路径：URLError(.cancelled) 同样透传，必须映射为 .cancelled。
    @MainActor
    func testResolveClanCancelledURLErrorMapsToCancelled() async throws {
        let model = try makeModel { _ in
            throw URLError(.cancelled)
        }
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertEqual(result, .failure(.cancelled))
    }

    // MARK: - 成功路径

    /// 失败不得写入共享缓存/持久化（"看起来已保存"防护的不变量）。
    @MainActor
    func testResolveClanFailureDoesNotWriteSharedState() async throws {
        let model = try makeModel { request in
            clanResolveResponse(404, url: request.url!)
        }
        _ = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertNil(model.clanStates["#2QJQ8J88"], "失败不得写入 clanStates")
        XCTAssertNil(defaults.data(forKey: "coc-helper.clans.v1"), "失败不得持久化")
    }

    @MainActor
    func testResolveClanSuccessReturnsSnapshotAndWritesSharedState() async throws {
        let model = try makeModel { request in
            // URL.path 返回解码后的形式（%23 → #）。
            XCTAssertEqual(request.url?.path, "/v1/clans/#2QJQ8J88")
            return clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        let snapshot = try XCTUnwrap(result.successOrNil, "解析必须成功")
        XCTAssertEqual(snapshot.name, "anonymized-clan")
        XCTAssertEqual(snapshot.requiredLeagueTier?.id, 105000028)
        XCTAssertEqual(snapshot.requiredLeagueTier?.name, "Titan League I")
        // 共享缓存已写入：详情页首屏可直接展示，无需再次请求。
        let state = try XCTUnwrap(model.clanStates["#2QJQ8J88"], "解析成功后必须写入 clanStates")
        XCTAssertEqual(state.status, .success)
        XCTAssertNotNil(state.fetchedAt)
        XCTAssertEqual(state.lastGood?.name, "anonymized-clan")
        XCTAssertEqual(state.parserVersion, "clan-snapshot-0.3")
        XCTAssertEqual(state.unrecognizedKeys, ["newOfficialField"])
    }

    @MainActor
    func testResolveClanNormalizesInputBeforeRequest() async throws {
        let model = try makeModel { request in
            XCTAssertEqual(request.url?.path, "/v1/clans/#2QJQ8J88", "小写/空白输入必须规范化后再请求")
            return clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        let result = await model.resolveClan(rawTag: "  #2qjq8j88  ")
        XCTAssertNotNil(result.successOrNil)
    }

    @MainActor
    func testResolveClanSuccessPersistsSharedState() async throws {
        let model = try makeModel { request in
            clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        _ = await model.resolveClan(rawTag: "#2QJQ8J88")
        // 持久化：重新解码 clanStates 存储 key，确认写入。
        let data = try XCTUnwrap(defaults.data(forKey: "coc-helper.clans.v1"), "解析成功后必须持久化 clanStates")
        let store = try JSONDecoder().decode(ClanStateStore.self, from: data)
        XCTAssertNotNil(store.states["#2QJQ8J88"])
    }

    // MARK: - 查重查询（isClanTracked）

    @MainActor
    func testIsClanTrackedMatchesTrackedList() throws {
        let model = try makeModel { request in
            clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        XCTAssertFalse(model.isClanTracked(rawTag: "#2QJQ8J88"), "初始无跟踪")
        model.addTrackedClan(rawTag: "#2QJQ8J88", displayName: nil)
        XCTAssertTrue(model.isClanTracked(rawTag: "#2QJQ8J88"))
        XCTAssertTrue(model.isClanTracked(rawTag: "  #2qjq8j88  "), "规范化后匹配")
        XCTAssertFalse(model.isClanTracked(rawTag: "#OTHER"))
        XCTAssertFalse(model.isClanTracked(rawTag: "非法"), "非法输入返回 false 而非崩溃")
    }

    /// resolveClan 本身不查重（职责单一）：已收藏部落仍可解析（预览/刷新用途）。
    @MainActor
    func testResolveClanAllowsAlreadyTrackedTag() async throws {
        let model = try makeModel { request in
            clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        model.addTrackedClan(rawTag: "#2QJQ8J88", displayName: nil)
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertNotNil(result.successOrNil)
    }

    // MARK: - single-flight（#48 验收：同一 Tag 并发刷新只产生一次实际请求）

    /// 同 tag 刷新批次在途时解析：必须等待批次结束并**复用结果**，
    /// 不得发起第二个请求（handler 计数 = 1）。
    ///
    /// 时序：`refreshClan` 同步设置 `refreshingClanTags` 后返回（Task 尚未
    /// 执行）；`resolveClan` 的同步段先检查到 tag 在途 → 进入等待让出主
    /// actor → 批次 Task 执行完成（合并先于清空集合）→ resolveClan 恢复
    /// 读到批次成功结果 → 复用。
    @MainActor
    func testResolveClanReusesInFlightRefresh() async throws {
        let counter = ResolveRequestCounter()
        let model = try makeModel { request in
            counter.record(tag: request.url?.path ?? "")
            return clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        model.refreshClan(tag: "#2QJQ8J88")
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertNotNil(result.successOrNil, "等待批次结束后必须复用成功快照")
        XCTAssertEqual(counter.count, 1, "single-flight：解析不得发起第二个请求")
    }

    /// 在途批次失败：解析等待后映射批次失败状态，不发第二个请求。
    @MainActor
    func testResolveClanReusesInFlightRefreshFailure() async throws {
        let counter = ResolveRequestCounter()
        let model = try makeModel { request in
            counter.record(tag: request.url?.path ?? "")
            return clanResolveResponse(404, url: request.url!)
        }
        model.refreshClan(tag: "#2QJQ8J88")
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertEqual(result, .failure(.notFound), "批次失败状态必须映射复用")
        XCTAssertEqual(counter.count, 1, "single-flight：失败也不得发起第二个请求")
    }

    /// waitedForBatch 负例：**无在途批次**时，即使 clanStates 已有该 tag 的
    /// 成功缓存（上次解析/刷新遗留），也必须重新请求——解析语义是获取最新，
    /// 不得误复用旧缓存。锁定"仅确实等待过批次才复用"的核心语义。
    @MainActor
    func testResolveClanDoesNotReuseStaleCacheWithoutInFlight() async throws {
        let counter = ResolveRequestCounter()
        let model = try makeModel { request in
            counter.record(tag: request.url?.path ?? "")
            return clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        _ = await model.resolveClan(rawTag: "#2QJQ8J88")  // 第一次：写入成功缓存
        XCTAssertEqual(counter.count, 1)
        _ = await model.resolveClan(rawTag: "#2QJQ8J88")  // 第二次：无在途 → 必须重新请求
        XCTAssertEqual(counter.count, 2, "无在途批次时不得复用旧缓存，必须重新请求")
    }

    /// **排队批次 single-flight**（外部终审 P1）：批次 A 在途（handler 阻塞
    /// 500ms 保证 A 未完成）时 refreshClan(B) 进入 pendingClanRefreshTags 排队；
    /// resolveClan(B) 同步段执行时 B 不在当前批次（refreshingClanTags）但在已
    /// 排队批次中——必须等待补跑批次处理 B 并复用结果，B 全程只请求一次。
    @MainActor
    func testResolveClanWaitsForQueuedRefresh() async throws {
        let counter = ResolveRequestCounter()
        let model = try makeModel { request in
            let tag = request.url?.path.replacingOccurrences(of: "/v1/clans/", with: "") ?? ""
            counter.record(tag: tag)
            if tag == "#AAA" {
                // 批次 A 的请求阻塞 500ms：确保 resolveClan 同步段执行时
                // 批次 A 仍在途（refreshingClanTags 尚未清空/补跑）。
                Thread.sleep(forTimeInterval: 0.5)
            }
            return clanResolveResponse(200, url: request.url!, body: fullClanFixtureData())
        }
        model.refreshClan(tag: "#AAA")          // 批次 A：在途 500ms
        model.refreshClan(tag: "#2QJQ8J88")     // 忙时 → B 进入 pendingClanRefreshTags 排队
        let result = await model.resolveClan(rawTag: "#2QJQ8J88")
        XCTAssertNotNil(result.successOrNil, "等待补跑批次后必须复用成功快照")
        // 等批次 A + 补跑批次（含 B）全部完成后再断言请求次数。
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(counter.count(forTag: "#2QJQ8J88"), 1, "排队的 B 解析后只应请求一次")
        XCTAssertEqual(counter.count(forTag: "#AAA"), 1, "批次 A 正常请求一次")
    }

    // MARK: - isClanRefreshPending 谓词边界（纯函数，无需时序）

    /// 三个来源（当前批次 / 显式排队 / 全量排队的村庄 tags）逐一命中。
    @MainActor
    func testIsClanRefreshPendingMatchesEachSource() {
        XCTAssertTrue(AppModel.isClanRefreshPending(
            inFlightTags: ["#A"], queuedTags: [], queuedAll: false, villageClanTags: [], tag: "#A"))
        XCTAssertTrue(AppModel.isClanRefreshPending(
            inFlightTags: [], queuedTags: ["#B"], queuedAll: false, villageClanTags: [], tag: "#B"))
        XCTAssertTrue(AppModel.isClanRefreshPending(
            inFlightTags: [], queuedTags: [], queuedAll: true, villageClanTags: ["#C"], tag: "#C"))
        XCTAssertFalse(AppModel.isClanRefreshPending(
            inFlightTags: [], queuedTags: [], queuedAll: false, villageClanTags: [], tag: "#X"))
        // queuedAll 但村庄 tags 不含该 tag（动态集合丢弃）→ false（等待退出，fallthrough 请求）
        XCTAssertFalse(AppModel.isClanRefreshPending(
            inFlightTags: [], queuedTags: [], queuedAll: true, villageClanTags: ["#C"], tag: "#X"))
    }

    // MARK: - C1 防回退谓词边界（纯函数，无需并发时序）

    private func clanState(_ status: OfficialAPIRequestStatus, fetchedAt: Date?) -> ClanAPIState {
        ClanAPIState(status: status, clanTag: "#T", fetchedAt: fetchedAt)
    }

    /// 批次失败 + 批次期间更新的成功（fetchedAt > batchStart）→ 跳过覆盖。
    @MainActor
    func testShouldSkipFailedOverwriteWhenNewerSuccessExists() {
        let batchStart = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(AppModel.shouldSkipFailedOverwrite(
            refreshedState: clanState(.failed, fetchedAt: nil),
            existing: clanState(.success, fetchedAt: batchStart.addingTimeInterval(1)),
            batchStart: batchStart
        ))
    }

    /// 批次失败 + 既有成功早于批次开始（正常失败覆盖，保留 last-good）→ 不跳过。
    @MainActor
    func testShouldSkipFailedOverwriteFalseForOlderSuccess() {
        let batchStart = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(AppModel.shouldSkipFailedOverwrite(
            refreshedState: clanState(.failed, fetchedAt: nil),
            existing: clanState(.success, fetchedAt: batchStart.addingTimeInterval(-1)),
            batchStart: batchStart
        ))
    }

    /// 批次成功 → 永远不跳过（更新的抓取数据正常覆盖）。
    @MainActor
    func testShouldSkipFailedOverwriteFalseForSuccessfulBatch() {
        let batchStart = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(AppModel.shouldSkipFailedOverwrite(
            refreshedState: clanState(.success, fetchedAt: batchStart.addingTimeInterval(1)),
            existing: clanState(.success, fetchedAt: batchStart.addingTimeInterval(2)),
            batchStart: batchStart
        ))
    }

    /// 无既有状态 / 既有状态失败 / 既有成功无 fetchedAt / fetchedAt == batchStart
    /// （不可达边界，防御上不跳过）→ 不跳过。
    @MainActor
    func testShouldSkipFailedOverwriteFalseWithoutNewerSuccess() {
        let batchStart = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(AppModel.shouldSkipFailedOverwrite(
            refreshedState: clanState(.failed, fetchedAt: nil),
            existing: nil,
            batchStart: batchStart
        ))
        XCTAssertFalse(AppModel.shouldSkipFailedOverwrite(
            refreshedState: clanState(.failed, fetchedAt: nil),
            existing: clanState(.failed, fetchedAt: batchStart.addingTimeInterval(1)),
            batchStart: batchStart
        ))
        XCTAssertFalse(AppModel.shouldSkipFailedOverwrite(
            refreshedState: clanState(.failed, fetchedAt: nil),
            existing: clanState(.success, fetchedAt: nil),
            batchStart: batchStart
        ))
        // == 边界：严格大于语义（主 actor 串行下 == 不可达，防御上不跳过）。
        XCTAssertFalse(AppModel.shouldSkipFailedOverwrite(
            refreshedState: clanState(.failed, fetchedAt: nil),
            existing: clanState(.success, fetchedAt: batchStart),
            batchStart: batchStart
        ))
    }
}

private extension Result {
    /// 测试辅助：success 值或 nil。
    var successOrNil: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

/// 请求计数（线程安全：URLProtocol 在不同线程调用 handler）。
private final class ResolveRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private var countsByTag: [String: Int] = [:]

    func record(tag: String) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        countsByTag[tag, default: 0] += 1
    }

    func count(forTag tag: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return countsByTag[tag] ?? 0
    }
}
