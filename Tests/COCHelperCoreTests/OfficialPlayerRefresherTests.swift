import Foundation
import XCTest
@testable import COCHelperCore

private func refresherMockResponse(_ status: Int, url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// 线程安全请求计数器。
private final class RefreshCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}

final class OfficialPlayerRefresherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeRefresher(
        handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?,
        counter: RefreshCallCounter? = nil
    ) -> OfficialPlayerRefresher {
        MockURLProtocol.handler = { request in
            counter?.increment()
            return try handler?(request) ?? (refresherMockResponse(200, url: request.url!), Data())
        }
        return OfficialPlayerRefresher(
            client: CoAPIClient(session: MockURLProtocol.makeSession(), tokenProvider: { "fake-token" })
        )
    }

    private func village(_ name: String, tag: String?, official: OfficialAPIState? = nil) -> VillageProfile {
        VillageProfile(
            name: name,
            accountSnapshot: tag.map { AccountSnapshotFixtures.snapshot(tag: $0) },
            officialAPIState: official
        )
    }

    private var playerJSON: Data {
        fullPlayerFixtureData()
    }

    // MARK: - 单村庄刷新

    func testRefreshSuccessSetsSuccessState() async throws {
        let refresher = makeRefresher { request in
            (refresherMockResponse(200, url: request.url!), fullPlayerFixtureData())
        }

        let state = await refresher.refresh(village: village("v", tag: "#ABC"), now: now)

        XCTAssertEqual(state.status, .success)
        XCTAssertEqual(state.playerTag, "#ABC")
        XCTAssertEqual(state.fetchedAt, now)
        XCTAssertEqual(state.lastAttemptAt, now)
        XCTAssertNil(state.lastErrorReason)
        XCTAssertNil(state.lastHTTPStatus)
        XCTAssertEqual(state.lastGood?.name, "anonymized-player")
        XCTAssertEqual(state.unrecognizedKeys.sorted(), ["bestVersusTrophies", "futureUnknownField", "versusTrophies"])
    }

    func testRefreshMissingTagSetsSkippedWithoutRequest() async {
        let counter = RefreshCallCounter()
        let refresher = makeRefresher(handler: nil, counter: counter)

        let state = await refresher.refresh(village: village("v", tag: nil), now: now)

        XCTAssertEqual(state.status, .skipped)
        XCTAssertNil(state.lastGood)
        XCTAssertEqual(counter.count, 0, "缺 tag 不应发起网络请求")
    }

    func testRefreshSkippedKeepsPreviousLastGood() async {
        let good = try! JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullPlayerFixtureData())
        let previous = OfficialAPIState(status: .success, fetchedAt: now - 60, lastGood: good)
        let refresher = makeRefresher(handler: nil)

        // 村庄曾成功获取官方数据，重新导入后 tag 缺失 → skipped 仍保留上次成功快照。
        let state = await refresher.refresh(village: village("v", tag: nil, official: previous), now: now)

        XCTAssertEqual(state.status, .skipped)
        XCTAssertEqual(state.lastGood, good, "skipped 不应清空上次成功快照")
        XCTAssertEqual(state.fetchedAt, previous.fetchedAt)
    }

    func testRefreshInvalidTagSetsSkippedWithoutRequest() async {
        let counter = RefreshCallCounter()
        let refresher = makeRefresher(handler: nil, counter: counter)

        let state = await refresher.refresh(village: village("v", tag: "abc"), now: now)

        XCTAssertEqual(state.status, .skipped)
        XCTAssertEqual(counter.count, 0, "无效 tag 不应发起网络请求")
    }

    func testRefreshFailureSetsFailedAndKeepsPreviousLastGood() async {
        let previous = OfficialAPIState(
            status: .success,
            fetchedAt: now - 60,
            lastGood: try! JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullPlayerFixtureData())
        )
        let refresher = makeRefresher { request in
            (refresherMockResponse(404, url: request.url!), Data())
        }

        let state = await refresher.refresh(village: village("v", tag: "#ABC", official: previous), now: now)

        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.lastAttemptAt, now)
        XCTAssertNotNil(state.lastErrorReason)
        XCTAssertEqual(state.lastHTTPStatus, 404)
        XCTAssertEqual(state.lastGood, previous.lastGood, "失败必须保留 last-good 快照")
    }

    func testRefreshFailureWithoutPreviousHasNilLastGood() async {
        let refresher = makeRefresher { request in
            throw URLError(.timedOut)
        }

        let state = await refresher.refresh(village: village("v", tag: "#ABC"), now: now)

        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.lastHTTPStatus, nil)
        XCTAssertNil(state.lastGood)
        XCTAssertEqual(state.lastErrorReason, "请求超时")
    }

    // MARK: - 错误原因映射（脱敏、用户可读）

    func testErrorReasonMapping() async {
        // 通过真实网络路径触发错误：HTTP 状态码 / URLError / 缺 token。
        // 注意：不能直接抛 CoAPIError——URLProtocol 会把它桥接成 NSError，类型丢失。
        let cases: [(
            handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?,
            token: String?,
            expectedReason: String,
            expectedStatus: Int?
        )] = [
            (
                handler: { request in (refresherMockResponse(401, url: request.url!), Data()) },
                token: "fake-token",
                expectedReason: "认证失败（401）",
                expectedStatus: 401
            ),
            (
                handler: { request in
                    (refresherMockResponse(403, url: request.url!), Data(#"{"reason":"accessDenied.invalidIp"}"#.utf8))
                },
                token: "fake-token",
                expectedReason: "访问被拒绝：accessDenied.invalidIp",
                expectedStatus: 403
            ),
            (
                handler: { request in (refresherMockResponse(404, url: request.url!), Data()) },
                token: "fake-token",
                expectedReason: "未找到对应的玩家、部落或战争（404）",
                expectedStatus: 404
            ),
            (
                handler: { request in (refresherMockResponse(429, url: request.url!), Data()) },
                token: "fake-token",
                expectedReason: "请求被限流（429），请稍后再试",
                expectedStatus: 429
            ),
            (
                handler: { request in (refresherMockResponse(500, url: request.url!), Data()) },
                token: "fake-token",
                expectedReason: "服务器错误（500）",
                expectedStatus: 500
            ),
            (
                handler: { _ in throw URLError(.timedOut) },
                token: "fake-token",
                expectedReason: "请求超时",
                expectedStatus: nil
            ),
            (
                handler: nil,
                token: nil,
                expectedReason: "未配置 API token",
                expectedStatus: nil
            ),
        ]

        for c in cases {
            MockURLProtocol.handler = c.handler
            let refresher = OfficialPlayerRefresher(
                client: CoAPIClient(
                    config: CoAPIConfig(maxRetryCount: 0),
                    session: MockURLProtocol.makeSession(),
                    tokenProvider: { c.token }
                )
            )

            let state = await refresher.refresh(village: village("v", tag: "#ABC"), now: now)

            XCTAssertEqual(state.status, .failed, "reason: \(c.expectedReason)")
            XCTAssertEqual(state.lastErrorReason, c.expectedReason, "reason: \(c.expectedReason)")
            XCTAssertEqual(state.lastHTTPStatus, c.expectedStatus, "reason: \(c.expectedReason)")
        }
    }

    // MARK: - 批量刷新

    func testRefreshAllDeduplicatesByTag() async {
        let counter = RefreshCallCounter()
        let refresher = makeRefresher(
            handler: { request in
                (refresherMockResponse(200, url: request.url!), fullPlayerFixtureData())
            },
            counter: counter
        )

        let villages = [
            village("a", tag: "#ABC"),
            village("b", tag: "#ABC"),
            village("c", tag: "#XYZ"),
            village("d", tag: nil),
        ]

        let results = await refresher.refreshAll(villages: villages, now: now)

        XCTAssertEqual(counter.count, 2, "两个唯一 tag 应只触发两次请求")
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results[villages[0].id]?.status, .success)
        XCTAssertEqual(results[villages[1].id]?.status, .success)
        XCTAssertEqual(results[villages[0].id]?.lastGood, results[villages[1].id]?.lastGood, "同 tag 村庄应复用同一快照")
        XCTAssertEqual(results[villages[2].id]?.status, .success)
        XCTAssertEqual(results[villages[3].id]?.status, .skipped, "缺 tag 村庄应明确 skipped")
    }

    func testRefreshAllFailureKeepsEachVillageOwnLastGood() async {
        let good = try! JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullPlayerFixtureData())
        let refresher = makeRefresher { request in
            (refresherMockResponse(500, url: request.url!), Data())
        }

        let villages = [
            village("a", tag: "#ABC", official: OfficialAPIState(status: .success, fetchedAt: now - 60, lastGood: good)),
            village("b", tag: "#ABC", official: nil),
            village("c", tag: "#XYZ", official: nil),
        ]

        let results = await refresher.refreshAll(villages: villages, now: now)

        XCTAssertEqual(results[villages[0].id]?.lastGood, good, "有 last-good 的村庄失败后必须保留")
        XCTAssertNil(results[villages[1].id]?.lastGood, "无 last-good 的村庄失败后仍为 nil")
        XCTAssertEqual(results[villages[0].id]?.lastHTTPStatus, 500)
    }

    func testRefreshAllEmptyVillagesReturnsEmpty() async {
        let counter = RefreshCallCounter()
        let refresher = makeRefresher(handler: nil, counter: counter)

        let results = await refresher.refreshAll(villages: [], now: now)

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(counter.count, 0)
    }

    func testRefreshAllSkippedKeepsPreviousLastGood() async {
        let good = try! JSONDecoder().decode(OfficialPlayerSnapshot.self, from: fullPlayerFixtureData())
        let previous = OfficialAPIState(status: .success, fetchedAt: now - 60, lastGood: good)
        let refresher = makeRefresher(handler: nil)

        let results = await refresher.refreshAll(villages: [village("a", tag: nil, official: previous)], now: now)

        let state = results.values.first
        XCTAssertEqual(state?.status, .skipped)
        XCTAssertEqual(state?.lastGood, good, "批量 skipped 也应保留 last-good")
    }

    func testRefreshAllDuplicateVillageIDsDoesNotCrash() async {
        // 损坏持久化数据可能产生重复村庄 ID：必须降级而不是 fatal。
        let counter = RefreshCallCounter()
        let refresher = makeRefresher(
            handler: { request in
                (refresherMockResponse(200, url: request.url!), fullPlayerFixtureData())
            },
            counter: counter
        )

        let duplicateID = UUID()
        let a = VillageProfile(id: duplicateID, name: "a", accountSnapshot: AccountSnapshotFixtures.snapshot(tag: "#ABC"))
        let b = VillageProfile(id: duplicateID, name: "b", accountSnapshot: AccountSnapshotFixtures.snapshot(tag: "#ABC"))

        let results = await refresher.refreshAll(villages: [a, b], now: now)

        XCTAssertEqual(counter.count, 1, "重复 ID 村庄共享同一 tag，仍应只请求一次")
        XCTAssertEqual(results.count, 1, "重复 ID 只保留一条结果")
        XCTAssertEqual(results[duplicateID]?.status, .success)
    }

    // MARK: - property-based：请求次数 == 唯一 tag 数

    func testPropertyRefreshAllRequestCountEqualsUniqueTagCount() async {
        var rng = SeededRandomGenerator(seed: 11)
        for _ in 0..<10 {
            var villages: [VillageProfile] = []
            var expectedTags = Set<String>()
            for _ in 0..<Int.random(in: 1...8) {
                if rng.randomInt(in: 0...1) == 0 {
                    let tag = "#" + randomAlnum(using: &rng)
                    villages.append(village("v\(villages.count)", tag: tag))
                    expectedTags.insert(tag)
                } else {
                    villages.append(village("v\(villages.count)", tag: nil))
                }
            }

            let counter = RefreshCallCounter()
            let refresher = makeRefresher(
                handler: { request in
                    (refresherMockResponse(200, url: request.url!), Data("{}".utf8))
                },
                counter: counter
            )

            _ = await refresher.refreshAll(villages: villages, now: now)

            XCTAssertEqual(counter.count, expectedTags.count, "请求次数应等于实际唯一 tag 数")
        }
    }

    private func randomAlnum(using rng: inout SeededRandomGenerator) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let length = rng.randomInt(in: 1...10)
        return (0..<length).map { _ in String(charset[rng.randomInt(in: 0...(charset.count - 1))]) }.joined()
    }
}
