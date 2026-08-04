import Foundation
import XCTest
@testable import COCHelperCore

final class CoAPIFetchClanTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient(
        config: CoAPIConfig = CoAPIConfig(maxRetryCount: 0),
        handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    ) -> CoAPIClient {
        MockURLProtocol.handler = handler
        return CoAPIClient(config: config, session: MockURLProtocol.makeSession()) { "fake-token" }
    }

    // MARK: - 成功路径

    func testFetchClanSuccessAndURLEncoding() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             fullClanFixtureData())
        }

        let clan = try await client.fetchClan(tag: "#CLANANONYMIZED")

        XCTAssertEqual(clan.tag, "#CLANANONYMIZED")
        XCTAssertEqual(clan.name, "anonymized-clan")
        XCTAssertEqual(clan.clanLevel, 12)

        let lastRequest = MockURLProtocol.lastRequest()
        XCTAssertEqual(lastRequest?.url?.path(percentEncoded: true), "/v1/clans/%23CLANANONYMIZED")
        XCTAssertNil(lastRequest?.url?.fragment, "# 不应被解析成 fragment")
        XCTAssertFalse(lastRequest?.url?.absoluteString.contains("#") ?? false)
        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer fake-token")
    }

    func testFetchClanMinimalEmptyObjectSucceeds() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{}".utf8))
        }

        let clan = try await client.fetchClan(tag: "#MINIMAL")
        XCTAssertNil(clan.name)
        XCTAssertNil(clan.clanLevel)
    }

    // MARK: - 错误路径（表驱动，与 fetchPlayer 同契约）

    func testFetchClanErrorStatusMapping() async {
        let cases: [(status: Int, body: String?, expected: CoAPIError)] = [
            (401, nil, .unauthorized),
            (403, #"{"reason":"accessDenied.invalidIp"}"#, .accessDenied(reason: "accessDenied.invalidIp")),
            (404, nil, .notFound),
            (429, nil, .rateLimited(retryAfterSeconds: nil)),
            (500, nil, .serverError(statusCode: 500)),
        ]

        for c in cases {
            let client = makeClient { request in
                (HTTPURLResponse(url: request.url!, statusCode: c.status, httpVersion: nil, headerFields: nil)!,
                 c.body.map { Data($0.utf8) } ?? Data())
            }

            do {
                _ = try await client.fetchClan(tag: "#CLAN")
                XCTFail("expected \(c.expected), got success")
            } catch let error as CoAPIError {
                XCTAssertEqual(error, c.expected, "status \(c.status)")
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
    }

    // MARK: - 解码失败路径

    func testFetchClanMalformedResponseIncludesFieldPath() async {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"clanLevel": "not-an-int"}"#.utf8))
        }

        do {
            _ = try await client.fetchClan(tag: "#CLAN")
            XCTFail("expected malformedResponse")
        } catch let error as CoAPIError {
            guard case .malformedResponse(let detail) = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("clanLevel"), "detail 应包含字段路径: \(detail)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFetchClanMalformedResponseSanitizesDetail() async {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("not-json".utf8))
        }

        do {
            _ = try await client.fetchClan(tag: "#CLAN")
            XCTFail("expected malformedResponse")
        } catch let error as CoAPIError {
            guard case .malformedResponse(let detail) = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
            // 脱敏契约：detail 不含 URL/tag/token
            XCTAssertFalse(detail.contains("CLAN"))
            XCTAssertFalse(detail.contains("clashofclans"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// 非 2xx 且 body 不是 JSON 时不得误报 malformedResponse（错误映射优先）。
    func testFetchClanErrorTakesPriorityOverDecoding() async {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data("not-json".utf8))
        }

        do {
            _ = try await client.fetchClan(tag: "#CLAN")
            XCTFail("expected notFound")
        } catch let error as CoAPIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
