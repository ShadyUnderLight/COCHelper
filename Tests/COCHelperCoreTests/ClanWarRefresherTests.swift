import Foundation
import XCTest
@testable import COCHelperCore

/// 构造 mock HTTP 响应（free function，避免 @Sendable handler 捕获 self）。
private func clanWarMockResponse(_ status: Int, url: URL, body: Data = Data()) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

final class ClanWarRefresherTests: XCTestCase {
    /// 线程安全的请求记录器（同步方法内使用锁，避免 async 上下文锁限制）。
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeRefresher(
        handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    ) -> ClanWarRefresher {
        MockURLProtocol.handler = handler
        return ClanWarRefresher(client: CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession()
        ) { "fake-token" })
    }

    private func sampleWarState(tag: String, state: String = "inWar") -> ClanWarAPIState {
        ClanWarAPIState(
            status: .success,
            clanTag: tag,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastGood: OfficialClanWarSnapshot(
                state: state, teamSize: 30, attacksPerMember: 2,
                preparationStartTime: nil, startTime: nil, endTime: nil,
                warStartTime: nil, clan: nil, opponent: nil, unrecognizedKeys: []
            )
        )
    }

    // MARK: - 去重（与 clan profile 同契约）

    func testDuplicateClanTagsProduceSingleRequest() async {
        let recorder = RequestRecorder()
        let refresher = makeRefresher { request in
            recorder.record(request.url?.path ?? "")
            return (clanWarMockResponse(200, url: request.url!), fullClanWarFixtureData())
        }

        let result = await refresher.refreshClanWars(
            villageClanTags: ["#CLANANONYMIZED", "#CLANANONYMIZED", "#CLANANONYMIZED"],
            previous: [:]
        )

        XCTAssertEqual(recorder.snapshot().count, 1, "重复 clan tag 必须只产生一次请求")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["#CLANANONYMIZED"]?.status, .success)
    }

    // MARK: - notInWar 语义（成功，不是失败）

    func testNotInWarResponseIsSuccess() async {
        let refresher = makeRefresher { request in
            // 官方 no-war 响应：200 + {"state":"notInWar"}
            let data = Data(#"{"state":"notInWar"}"#.utf8)
            return (clanWarMockResponse(200, url: request.url!), data)
        }

        let result = await refresher.refreshClanWars(villageClanTags: ["#CLAN"], previous: [:])

        XCTAssertEqual(result["#CLAN"]?.status, .success, "notInWar 是合法成功响应")
        XCTAssertEqual(result["#CLAN"]?.lastGood?.state, "notInWar")
        XCTAssertNil(result["#CLAN"]?.lastErrorReason)
    }

    // MARK: - last-good

    func testFailurePreservesPreviousLastGood() async {
        let refresher = makeRefresher { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }

        let previous = ["#CLAN": sampleWarState(tag: "#CLAN")]
        let result = await refresher.refreshClanWars(villageClanTags: ["#CLAN"], previous: previous)

        XCTAssertEqual(result["#CLAN"]?.status, .failed)
        XCTAssertEqual(result["#CLAN"]?.lastGood?.state, "inWar", "失败必须保留 last-good")
        XCTAssertEqual(result["#CLAN"]?.fetchedAt, previous["#CLAN"]?.fetchedAt)
    }

    func testFailureWithoutPreviousHasNoLastGood() async {
        let refresher = makeRefresher { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let result = await refresher.refreshClanWars(villageClanTags: ["#NEWCLAN"], previous: [:])
        XCTAssertEqual(result["#NEWCLAN"]?.status, .failed)
        XCTAssertNil(result["#NEWCLAN"]?.lastGood)
        XCTAssertEqual(result["#NEWCLAN"]?.lastHTTPStatus, 500)
    }

    // MARK: - 无效 tag

    func testNilAndInvalidClanTagsAreIgnoredWithoutRequest() async {
        let recorder = RequestRecorder()
        let refresher = makeRefresher { request in
            recorder.record(request.url?.path ?? "")
            return (clanWarMockResponse(200, url: request.url!), fullClanWarFixtureData())
        }

        let result = await refresher.refreshClanWars(
            villageClanTags: [nil, "", "#", "#lowercase", "NOHASH"],
            previous: [:]
        )

        XCTAssertTrue(recorder.snapshot().isEmpty, "无效 clan tag 不发起请求")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - URL 契约

    func testRequestPathEncodesHashAndCurrentWarSuffix() async {
        let recorder = RequestRecorder()
        let refresher = makeRefresher { request in
            recorder.record(request.url?.path(percentEncoded: true) ?? "")
            return (clanWarMockResponse(200, url: request.url!), fullClanWarFixtureData())
        }

        _ = await refresher.refreshClanWars(villageClanTags: ["#CLANANONYMIZED"], previous: [:])

        XCTAssertEqual(recorder.snapshot().first, "/v1/clans/%23CLANANONYMIZED/currentwar")
        XCTAssertNil(MockURLProtocol.lastRequest()?.url?.fragment, "# 不应被解析成 fragment")
    }
}
