import Foundation
import XCTest
@testable import COCHelperCore

/// 构造 mock HTTP 响应（free function，避免 @Sendable handler 捕获 self）。
private func clanMockResponse(_ status: Int, url: URL, body: Data = Data()) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

final class ClanRefresherTests: XCTestCase {
    /// 请求计数（线程安全：URLProtocol 在不同线程调用 handler）。
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        private(set) var requestedTags: [String] = []

        func record(tag: String) {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            requestedTags.append(tag)
        }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeRefresher(
        handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    ) -> ClanRefresher {
        MockURLProtocol.handler = handler
        return ClanRefresher(client: CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession()
        ) { "fake-token" })
    }

    private func sampleClanState(tag: String, name: String) -> ClanAPIState {
        ClanAPIState(
            status: .success,
            clanTag: tag,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastGood: OfficialClanSnapshot(
                tag: tag, name: name, type: nil, description: nil,
                clanLevel: 5, badgeUrls: nil, members: 10, requiredTrophies: nil,
                requiredTownHallLevel: nil, warWins: nil, warLosses: nil, warTies: nil,
                warWinStreak: nil, isWarLogPublic: nil, labels: nil, clanCapital: nil,
                unrecognizedKeys: []
            )
        )
    }

    // MARK: - 去重（验收标准：同一刷新批次的重复 clan tag 只产生一次请求）

    func testDuplicateClanTagsProduceSingleRequest() async {
        let counter = RequestCounter()
        let refresher = makeRefresher { request in
            // 提取 %23TAG 还原 tag 用于计数
            let path = request.url?.path ?? ""
            let raw = path.replacingOccurrences(of: "/v1/clans/", with: "")
                .replacingOccurrences(of: "%23", with: "#")
            counter.record(tag: raw)
            return (clanMockResponse(200, url: request.url!), fullClanFixtureData())
        }

        // 同一部落下的 4 个村庄
        let tags: [String?] = ["#CLANANONYMIZED", "#CLANANONYMIZED", "#CLANANONYMIZED", "#CLANANONYMIZED"]
        let result = await refresher.refreshClans(villageClanTags: tags, previous: [:])

        XCTAssertEqual(counter.count, 1, "重复 clan tag 必须只产生一次网络请求")
        XCTAssertEqual(counter.requestedTags, ["#CLANANONYMIZED"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["#CLANANONYMIZED"]?.status, .success)
    }

    func testDistinctClanTagsProduceOneRequestEach() async {
        let counter = RequestCounter()
        let refresher = makeRefresher { request in
            let path = request.url?.path ?? ""
            counter.record(tag: path)
            return (clanMockResponse(200, url: request.url!), fullClanFixtureData())
        }

        let tags: [String?] = ["#AAA", "#BBB", "#AAA", "#CCC"]
        let result = await refresher.refreshClans(villageClanTags: tags, previous: [:])

        XCTAssertEqual(counter.count, 3, "三个唯一 tag 各一次请求")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.keys), Set(["#AAA", "#BBB", "#CCC"]))
    }

    // MARK: - no-clan / 无效 tag（不请求，不产生状态）

    func testNilAndInvalidClanTagsAreIgnoredWithoutRequest() async {
        let counter = RequestCounter()
        let refresher = makeRefresher { request in
            counter.record(tag: "unexpected")
            return (clanMockResponse(200, url: request.url!), fullClanFixtureData())
        }

        // "  #CLAN  " 规范化后有效（会请求），由单独测试覆盖；这里只放无效值。
        let tags: [String?] = [nil, "", "   ", "#", "#lowercase", "NOHASH"]
        let result = await refresher.refreshClans(villageClanTags: tags, previous: [:])

        XCTAssertTrue(counter.requestedTags.isEmpty, "无效 clan tag 不发起请求")
        XCTAssertTrue(result.isEmpty, "无有效 clan tag 时不产生状态")
    }

    /// 超长 tag（> 20 字符，Issue #48 Step 1 新长度上限）在刷新链路中被跳过，
    /// 不发起请求、不产生状态——锁住 validator 长度契约在下游的生效。
    func testOverlongClanTagIsIgnoredWithoutRequest() async {
        let counter = RequestCounter()
        let refresher = makeRefresher { request in
            counter.record(tag: "unexpected")
            return (clanMockResponse(200, url: request.url!), fullClanFixtureData())
        }

        let overlong = "#" + String(repeating: "A", count: 21)
        let result = await refresher.refreshClans(villageClanTags: [overlong], previous: [:])

        XCTAssertTrue(counter.requestedTags.isEmpty, "超长 clan tag 不发起请求")
        XCTAssertTrue(result.isEmpty, "超长 clan tag 不产生状态")
    }

    // MARK: - 规范化

    func testWhitespaceTagIsNormalizedBeforeRequest() async {
        let counter = RequestCounter()
        let refresher = makeRefresher { request in
            counter.record(tag: request.url?.path ?? "")
            return (clanMockResponse(200, url: request.url!), fullClanFixtureData())
        }

        let result = await refresher.refreshClans(villageClanTags: ["  #CLANANONYMIZED  "], previous: [:])

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(result["#CLANANONYMIZED"]?.status, .success,
                       "规范化后的 tag 作为字典 key")
        XCTAssertEqual(result["#CLANANONYMIZED"]?.clanTag, "#CLANANONYMIZED")
    }

    // MARK: - last-good（验收标准：失败不清除上一份有效部落快照）

    func testFailurePreservesPreviousLastGood() async {
        let refresher = makeRefresher { request in
            (clanMockResponse(429, url: request.url!), Data())
        }

        let previous = [
            "#CLAN": sampleClanState(tag: "#CLAN", name: "previous-good"),
            "#OTHER": sampleClanState(tag: "#OTHER", name: "untouched-clan"),
        ]
        let result = await refresher.refreshClans(villageClanTags: ["#CLAN"], previous: previous)

        let clanState = result["#CLAN"]
        XCTAssertEqual(clanState?.status, .failed)
        XCTAssertEqual(clanState?.lastGood?.name, "previous-good", "失败必须保留 last-good")
        XCTAssertEqual(clanState?.fetchedAt, previous["#CLAN"]?.fetchedAt)
        XCTAssertNotNil(clanState?.lastErrorReason)
    }

    func testFailureWithoutPreviousHasNoLastGood() async {
        let refresher = makeRefresher { request in
            (clanMockResponse(500, url: request.url!), Data())
        }

        let result = await refresher.refreshClans(villageClanTags: ["#NEWCLAN"], previous: [:])

        XCTAssertEqual(result["#NEWCLAN"]?.status, .failed)
        XCTAssertNil(result["#NEWCLAN"]?.lastGood, "首次失败没有 last-good")
        XCTAssertEqual(result["#NEWCLAN"]?.lastHTTPStatus, 500)
    }

    /// 换部落语义：本次只请求新 tag；refresher 不管理未被请求的 tag
    /// （返回字典只含请求过的 key，旧数据保留由调用方 merge 决定）。
    func testUnrequestedPreviousTagsAreNotTouched() async {
        let counter = RequestCounter()
        let refresher = makeRefresher { request in
            counter.record(tag: request.url?.path ?? "")
            return (clanMockResponse(200, url: request.url!), fullClanFixtureData())
        }

        let previous = ["#OLDCLAN": sampleClanState(tag: "#OLDCLAN", name: "old-clan-good")]
        let result = await refresher.refreshClans(villageClanTags: ["#CLANANONYMIZED"], previous: previous)

        XCTAssertEqual(counter.count, 1)
        XCTAssertNil(result["#OLDCLAN"], "未请求的旧 tag 不由 refresher 返回")
        XCTAssertEqual(result["#CLANANONYMIZED"]?.status, .success)
    }

    // MARK: - URL 契约

    /// 请求路径必须单层编码 #，不得出现裸 #（与 player 端点同契约）。
    func testRequestPathEncodesHash() async {
        let counter = RequestCounter()
        let refresher = makeRefresher { request in
            counter.record(tag: request.url?.path(percentEncoded: true) ?? "")
            return (clanMockResponse(200, url: request.url!), fullClanFixtureData())
        }

        _ = await refresher.refreshClans(villageClanTags: ["#CLANANONYMIZED"], previous: [:])

        XCTAssertEqual(counter.requestedTags.first, "/v1/clans/%23CLANANONYMIZED")
        XCTAssertNil(MockURLProtocol.lastRequest()?.url?.fragment, "# 不应被解析成 fragment")
    }
}
