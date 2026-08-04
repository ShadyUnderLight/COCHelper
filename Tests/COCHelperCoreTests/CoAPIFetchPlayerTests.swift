import Foundation
import XCTest
@testable import COCHelperCore

/// 构造 mock HTTP 响应；独立函数避免 @Sendable handler 捕获测试用例实例。
private func fetchMockResponse(_ status: Int, headers: [String: String]? = nil, url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
}

/// 读取完整玩家 fixture（free function，避免被 @Sendable closure 捕获 self）。
func fullPlayerFixtureData() -> Data {
    let url = Bundle.module.url(forResource: "official_player_full", withExtension: "json")!
    return try! Data(contentsOf: url)
}

final class CoAPIFetchPlayerTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient(
        config: CoAPIConfig = CoAPIConfig(),
        token: String? = "fake-token",
        handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    ) -> CoAPIClient {
        MockURLProtocol.handler = handler
        return CoAPIClient(config: config, session: MockURLProtocol.makeSession()) { token }
    }

    private func expectError(
        _ expected: CoAPIError,
        _ operation: @escaping () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected), got success")
        } catch let error as CoAPIError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - 成功路径

    func testFetchPlayerSuccessAndURLEncoding() async throws {
        let client = makeClient { request in
            (fetchMockResponse(200, url: request.url!), fullPlayerFixtureData())
        }

        let snapshot = try await client.fetchPlayer(tag: "#ANONYMIZED")

        XCTAssertEqual(snapshot.name, "anonymized-player")
        XCTAssertEqual(snapshot.townHallLevel, 14)
        XCTAssertEqual(snapshot.trophies, 4521)

        let lastRequest = MockURLProtocol.lastRequest()
        // 验收标准：真实请求路径不携带未编码的 #（URLBuilder 单层编码为 %23）
        XCTAssertEqual(lastRequest?.url?.path(percentEncoded: true), "/v1/players/%23ANONYMIZED")
        XCTAssertNil(lastRequest?.url?.fragment, "# 不应被解析成 fragment")
        XCTAssertFalse(lastRequest?.url?.absoluteString.contains("#") ?? false)
        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer fake-token")
    }

    func testFetchPlayerMinimalEmptyObjectSucceeds() async throws {
        let client = makeClient { request in
            (fetchMockResponse(200, url: request.url!), Data("{}".utf8))
        }

        let snapshot = try await client.fetchPlayer(tag: "#MINIMAL")

        XCTAssertNil(snapshot.name)
        XCTAssertNil(snapshot.clan)
        XCTAssertTrue(snapshot.unrecognizedKeys.isEmpty)
    }

    // MARK: - 错误路径（表驱动，无重试）

    func testFetchPlayerErrorStatusMapping() async {
        let cases: [(status: Int, headers: [String: String]?, body: String?, expected: CoAPIError)] = [
            (401, nil, nil, .unauthorized),
            (403, nil, #"{"reason":"accessDenied.invalidIp"}"#, .accessDenied(reason: "accessDenied.invalidIp")),
            (404, nil, nil, .notFound),
            (429, ["Retry-After": "60"], nil, .rateLimited(retryAfterSeconds: 60)),
            (500, nil, nil, .serverError(statusCode: 500)),
        ]

        for c in cases {
            let client = CoAPIClient(
                config: CoAPIConfig(maxRetryCount: 0),
                session: MockURLProtocol.makeSession(),
                tokenProvider: { "fake-token" }
            )
            MockURLProtocol.handler = { request in
                (fetchMockResponse(c.status, headers: c.headers, url: request.url!), c.body.map { Data($0.utf8) } ?? Data())
            }

            await expectError(c.expected) {
                _ = try await client.fetchPlayer(tag: "#ABC")
            }
        }
    }

    func testFetchPlayerTimeoutMapsToTimeout() async {
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        await expectError(.timeout) {
            _ = try await client.fetchPlayer(tag: "#ABC")
        }
    }

    func testFetchPlayerMalformedJSONMapsToMalformedResponse() async {
        let client = makeClient { request in
            (fetchMockResponse(200, url: request.url!), Data("not json".utf8))
        }

        await expectError(.malformedResponse(detail: "player decode failed")) {
            _ = try await client.fetchPlayer(tag: "#ABC")
        }
    }

    /// 类型不匹配（schema 漂移）时错误应附字段路径（脱敏，无原始值）。
    func testFetchPlayerDecodingErrorIncludesFieldPath() async {
        let json = ##"{"tag": "#ABC", "townHallLevel": "fourteen"}"##
        let client = makeClient { request in
            (fetchMockResponse(200, url: request.url!), Data(json.utf8))
        }

        await expectError(.malformedResponse(detail: "player decode failed: townHallLevel")) {
            _ = try await client.fetchPlayer(tag: "#ABC")
        }
    }

    // MARK: - property-based：# 编码在随机 tag 上不泄漏裸 #

    func testPropertyFetchPlayerURLNeverContainsBareHash() async {
        var rng = SeededRandomGenerator(seed: 8)
        for _ in 0..<50 {
            let tag = "#" + randomAlnum(using: &rng)
            let client = makeClient { request in
                (fetchMockResponse(200, url: request.url!), Data("{}".utf8))
            }

            _ = try? await client.fetchPlayer(tag: tag)

            let lastRequest = MockURLProtocol.lastRequest()
            let encoded = lastRequest?.url?.path(percentEncoded: true) ?? ""
            XCTAssertFalse(encoded.contains("#"), "请求路径不应含裸 #: \(encoded)")
            XCTAssertTrue(encoded.hasPrefix("/v1/players/"), "路径应以 /v1/players/ 开头: \(encoded)")
            XCTAssertEqual(lastRequest?.url?.path, "/v1/players/\(tag)", "percent-decoded 路径应还原原始 tag")
        }
    }

    private func randomAlnum(using rng: inout SeededRandomGenerator) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let length = rng.randomInt(in: 1...10)
        return (0..<length).map { _ in String(charset[rng.randomInt(in: 0...(charset.count - 1))]) }.joined()
    }
}
