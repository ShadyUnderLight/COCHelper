import Foundation
import XCTest
@testable import COCHelperCore

final class CoAPIFetchPaginatedTests: XCTestCase {
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

    // MARK: - warlog

    func testFetchWarLogSuccessAndQueryEncoding() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             fullWarLogPageData())
        }

        let page = try await client.fetchWarLog(tag: "#CLANANONYMIZED", after: "CURSORAFTER1", limit: 10)

        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.after, "CURSORAFTER1")

        let lastRequest = MockURLProtocol.lastRequest()
        XCTAssertEqual(lastRequest?.url?.path(percentEncoded: true), "/v1/clans/%23CLANANONYMIZED/warlog")
        // query 参数编码：游标含特殊字符时 URLComponents 自动 percent-encode
        let query = lastRequest?.url?.query(percentEncoded: true) ?? ""
        XCTAssertTrue(query.contains("after=CURSORAFTER1"), "query: \(query)")
        XCTAssertTrue(query.contains("limit=10"), "query: \(query)")
        XCTAssertNil(lastRequest?.url?.fragment)
    }

    /// 游标值含特殊字符时生成合法 URL：URLComponents 按 RFC 3986 编码
    /// （值内 `=` 编码防破坏 key=value；`/` `+` 为合法 sub-delim 按字面传输）。
    func testFetchWarLogEncodesCursorSpecialCharacters() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"items":[]}"#.utf8))
        }

        _ = try await client.fetchWarLog(tag: "#CLAN", after: "a/b+c=d")

        let url = MockURLProtocol.lastRequest()?.url
        XCTAssertNotNil(url)
        let query = url?.query(percentEncoded: true) ?? ""
        // `/` 与 `+` 是 RFC 3986 允许的 sub-delim（保留）；`=` 在值内被编码
        XCTAssertTrue(query.contains("after=a/b+c%3Dd"), "query: \(query)")
        XCTAssertNil(url?.fragment)
        // URL 可解析且 query 参数结构完整（不会因 `=` 歧义截断）
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let afterValue = components?.queryItems?.first(where: { $0.name == "after" })?.value
        XCTAssertEqual(afterValue, "a/b+c=d", "服务端应能按字面取回原始游标")
    }

    /// 无游标/limit 时不加 query 参数。
    func testFetchWarLogWithoutPaginationParamsHasNoQuery() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"items":[]}"#.utf8))
        }

        _ = try await client.fetchWarLog(tag: "#CLAN")

        XCTAssertNil(MockURLProtocol.lastRequest()?.url?.query,
                     "无分页参数时不应出现 query")
    }

    // MARK: - capital raid seasons

    func testFetchCapitalRaidSeasonsSuccess() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             fullCapitalRaidPageData())
        }

        let page = try await client.fetchCapitalRaidSeasons(tag: "#CLAN")

        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].capitalTotalLoot, 123456)
        let lastRequest = MockURLProtocol.lastRequest()
        XCTAssertEqual(lastRequest?.url?.path(percentEncoded: true), "/v1/clans/%23CLAN/capitalraidseasons")
    }

    // MARK: - 错误映射

    func testFetchWarLogErrorStatusMapping() async {
        let cases: [(status: Int, expected: CoAPIError)] = [
            (401, .unauthorized),
            (403, .accessDenied(reason: "forbidden")),
            (404, .notFound),
            (429, .rateLimited(retryAfterSeconds: nil)),
            (500, .serverError(statusCode: 500)),
        ]

        for c in cases {
            let client = makeClient { request in
                (HTTPURLResponse(url: request.url!, statusCode: c.status, httpVersion: nil, headerFields: nil)!,
                 Data())
            }
            do {
                _ = try await client.fetchWarLog(tag: "#CLAN")
                XCTFail("expected \(c.expected)")
            } catch let error as CoAPIError {
                XCTAssertEqual(error, c.expected, "status \(c.status)")
            } catch {
                XCTFail("unexpected: \(error)")
            }
        }
    }

    /// 战争日志不公开：官方返回 403 → 映射为 accessDenied（调用方显式呈现）。
    func testFetchWarLogPrivateLogReturns403() async {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Data(#"{"reason":"accessDenied"}"#.utf8))
        }
        do {
            _ = try await client.fetchWarLog(tag: "#CLAN")
            XCTFail("expected accessDenied")
        } catch let error as CoAPIError {
            guard case .accessDenied = error else {
                return XCTFail("expected accessDenied, got \(error)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - 解码失败

    func testFetchWarLogMalformedResponseSanitized() async {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("not-json".utf8))
        }
        do {
            _ = try await client.fetchWarLog(tag: "#CLAN")
            XCTFail("expected malformedResponse")
        } catch let error as CoAPIError {
            guard case .malformedResponse(let detail) = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
            XCTAssertFalse(detail.contains("CLAN"))
            XCTAssertFalse(detail.contains("clashofclans"))
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
