import Foundation
import XCTest
@testable import COCHelperCore

/// Thread-safe call counter for asserting handler invocation counts.
private final class CallCounter: @unchecked Sendable {
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

/// Builds a mock HTTP response; a free function so `@Sendable` handler closures
/// do not capture the (non-Sendable) test case instance.
private func mockResponse(_ status: Int, headers: [String: String]? = nil, url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
}

final class CoAPIClientTests: XCTestCase {
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

    private func expectError<T>(
        _ expression: @autoclosure () async throws -> T,
        _ expected: CoAPIError
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected), got success")
        } catch let error as CoAPIError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Success paths

    func testFetchLocationsSuccess() async throws {
        let json = #"{"items":[{"id":32000000,"name":"International","isCountry":false},{"id":32000001,"name":"China","isCountry":true}]}"#
        let client = makeClient { request in
            (mockResponse(200, url: request.url!), Data(json.utf8))
        }

        let result = try await client.fetchLocations()

        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items[0].id, 32_000_000)
        XCTAssertEqual(result.items[0].name, "International")
        XCTAssertEqual(result.items[1].isCountry, true)

        let lastRequest = MockURLProtocol.lastRequest()
        XCTAssertEqual(lastRequest?.url?.path, "/v1/locations")
        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer fake-token")
    }

    func testUnknownFieldsTolerated() async throws {
        let json = #"{"items":[{"id":1,"name":"A","isCountry":false,"unknownKey":123,"nested":{"x":1}}],"extra":"ignored"}"#
        let client = makeClient { request in
            (mockResponse(200, url: request.url!), Data(json.utf8))
        }

        let result = try await client.fetchLocations()

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].id, 1)
    }

    func testMalformedJSON() async {
        let client = makeClient { request in
            (mockResponse(200, url: request.url!), Data("not json".utf8))
        }

        await expectError(try await client.fetchLocations(), .malformedResponse(detail: "locations decode failed"))
    }

    func testMissingCredentialsNoRequest() async {
        let counter = CallCounter()
        MockURLProtocol.handler = { request in
            counter.increment()
            return (mockResponse(200, url: request.url!), Data())
        }
        let client = CoAPIClient(
            config: CoAPIConfig(),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { nil }
        )

        await expectError(try await client.request(path: "/locations"), .missingCredentials)

        XCTAssertEqual(counter.count, 0, "token 为 nil 时不应发起请求")
    }

    // MARK: - Status mapping (table-driven, no retries)

    func testStatusMapping() async {
        let cases: [(status: Int, headers: [String: String]?, body: String?, expected: CoAPIError)] = [
            (401, nil, nil, .unauthorized),
            (403, nil, #"{"reason":"accessDenied.invalidIp","message":"..."}"#, .accessDenied(reason: "accessDenied.invalidIp")),
            (403, nil, "not json", .accessDenied(reason: "forbidden")),
            (404, nil, nil, .notFound),
            (429, ["Retry-After": "60"], nil, .rateLimited(retryAfterSeconds: 60)),
            (429, nil, nil, .rateLimited(retryAfterSeconds: nil)),
            (500, nil, nil, .serverError(statusCode: 500)),
        ]

        for c in cases {
            let counter = CallCounter()
            let client = CoAPIClient(
                config: CoAPIConfig(maxRetryCount: 0),
                session: MockURLProtocol.makeSession(),
                tokenProvider: { "fake-token" }
            )
            MockURLProtocol.handler = { request in
                counter.increment()
                return (mockResponse(c.status, headers: c.headers, url: request.url!), c.body.map { Data($0.utf8) } ?? Data())
            }

            await expectError(try await client.request(path: "/locations"), c.expected)
            XCTAssertEqual(counter.count, 1, "status \(c.status) 不应重试")
        }
    }

    // MARK: - Transport errors

    func testTimeoutMapsToTimeout() async {
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        await expectError(try await client.request(path: "/locations"), .timeout)
    }

    func testCancellationPropagates() async {
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await client.request(path: "/locations")
            XCTFail("expected cancellation error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled, "取消应原样透传，而不是映射成网络错误")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testNegativeMaxRetryCountDoesNotTrap() async {
        let counter = CallCounter()
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: -1, baseRetryDelay: 0.001),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { request in
            counter.increment()
            return (mockResponse(500, url: request.url!), Data())
        }

        await expectError(try await client.request(path: "/locations"), .serverError(statusCode: 500))
        XCTAssertEqual(counter.count, 1, "负数 maxRetryCount 应退化为单次尝试")
    }

    // MARK: - Retry behavior

    func testRateLimitRetriesThenSucceeds() async throws {
        let counter = CallCounter()
        let client = CoAPIClient(
            config: CoAPIConfig(baseRetryDelay: 0.001),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { request in
            counter.increment()
            let status = counter.count == 1 ? 429 : 200
            return (mockResponse(status, url: request.url!), Data(#"{"items":[{"id":1}]}"#.utf8))
        }

        let result = try await client.fetchLocations()

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(counter.count, 2, "429 后应重试一次")
    }

    func testRateLimitExhaustsRetries() async {
        let counter = CallCounter()
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 2, baseRetryDelay: 0.001),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { request in
            counter.increment()
            return (mockResponse(429, url: request.url!), Data())
        }

        await expectError(try await client.request(path: "/locations"), .rateLimited(retryAfterSeconds: nil))
        XCTAssertEqual(counter.count, 3, "恒 429 时应尝试 maxRetryCount + 1 次")
    }

    func testServerErrorDoesNotRetry() async {
        let counter = CallCounter()
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 2),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { request in
            counter.increment()
            return (mockResponse(500, url: request.url!), Data())
        }

        await expectError(try await client.request(path: "/locations"), .serverError(statusCode: 500))
        XCTAssertEqual(counter.count, 1, "5xx 不应重试")
    }

    // MARK: - Smoke

    func testSmokeSuccess() async {
        let client = makeClient { request in
            (mockResponse(200, url: request.url!), Data(#"{"items":[{"id":1},{"id":2}]}"#.utf8))
        }

        let result = await client.smoke()

        XCTAssertEqual(result, .success(locationCount: 2))
    }

    func testSmokeMissingCredentials() async {
        let client = CoAPIClient(
            config: CoAPIConfig(),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { nil }
        )

        let result = await client.smoke()

        XCTAssertEqual(result, .missingCredentials)
    }

    func testSmokeAuthorizationFailed() async {
        let client = makeClient { request in
            (mockResponse(403, url: request.url!), Data(#"{"reason":"accessDenied.invalidIp"}"#.utf8))
        }

        let result = await client.smoke()

        XCTAssertEqual(result, .authorizationFailed(reason: "accessDenied.invalidIp"))
    }

    // MARK: - Review-fix coverage

    func testRateLimitRetryHonorsRetryAfterHeader() async throws {
        // 服务器 Retry-After 为 1 秒：即使本地退避基数是 0.001s，重试前也必须
        // 尊重服务器指示（sleep ≈ 1s，而不是 0.001s 连打）。
        let counter = CallCounter()
        let client = CoAPIClient(
            config: CoAPIConfig(baseRetryDelay: 0.001, maxRetryDelay: 0.1),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        let startedAt = Date()
        MockURLProtocol.handler = { request in
            counter.increment()
            if counter.count == 1 {
                return (mockResponse(429, headers: ["Retry-After": "1"], url: request.url!), Data())
            }
            return (mockResponse(200, url: request.url!), Data(#"{"items":[{"id":1}]}"#.utf8))
        }

        let result = try await client.fetchLocations()

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(counter.count, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.8,
                                    "重试间隔应尊重 Retry-After（≥0.8s）而不是本地 0.001s 基数的指数退避")
    }

    func testRateLimitRetryAfterFromBody() async {
        // Retry-After 来自响应 body（无 header）时也能提取。
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { request in
            (mockResponse(429, url: request.url!), Data(#"{"reason":"rateLimitExceeded","retryAfter":30}"#.utf8))
        }

        await expectError(try await client.request(path: "/locations"), .rateLimited(retryAfterSeconds: 30))
    }

    func testRetryableURLErrorRetriesThenSucceeds() async throws {
        let counter = CallCounter()
        let client = CoAPIClient(
            config: CoAPIConfig(baseRetryDelay: 0.001),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { request in
            counter.increment()
            if counter.count == 1 {
                throw URLError(.networkConnectionLost)
            }
            return (mockResponse(200, url: request.url!), Data(#"{"items":[{"id":1}]}"#.utf8))
        }

        let result = try await client.fetchLocations()

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(counter.count, 2, "可重试网络错误后应重试一次")
    }

    func testTokenRereadBetweenRetries() async {
        // token 在每次 attempt 重新读取：第一次有效、第二次变为 nil 时，
        // 第二次 attempt 不发请求，直接报 missingCredentials。
        let counter = CallCounter()
        let tokenSource = TokenSequence(["tok-1", nil])
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 2, baseRetryDelay: 0.001),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { tokenSource.next() }
        )
        MockURLProtocol.handler = { request in
            counter.increment()
            return (mockResponse(429, url: request.url!), Data())
        }

        await expectError(try await client.request(path: "/locations"), .missingCredentials)
        XCTAssertEqual(counter.count, 1, "token 变为 nil 后不应再发请求")
    }

    func testNegativeRetryDelayDoesNotTrap() async {
        // 负数 baseRetryDelay/maxRetryDelay 不得触发 UInt64 转换 trap。
        let counter = CallCounter()
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 1, baseRetryDelay: -1, maxRetryDelay: -1),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { request in
            counter.increment()
            return (mockResponse(429, url: request.url!), Data())
        }

        await expectError(try await client.request(path: "/locations"), .rateLimited(retryAfterSeconds: nil))
        XCTAssertEqual(counter.count, 2, "负数退避配置应退化为立即重试")
    }

    func testSmokeMapsErrorKinds() async {
        // smoke 六类失败映射：每种错误类别 → 对应 smoke 结果。
        let cases: [(status: Int, body: String?, expected: CoAPISmokeResult)] = [
            (404, nil, .notFound),
            (429, nil, .rateLimited),
            (500, nil, .serverError),
            (200, "not json", .networkFailure(detail: "malformed response")),
        ]
        for c in cases {
            let client = makeClient(config: CoAPIConfig(maxRetryCount: 0)) { request in
                (mockResponse(c.status, url: request.url!), Data((c.body ?? "").utf8))
            }
            let result = await client.smoke()
            XCTAssertEqual(result, c.expected, "smoke 对 status \(c.status) 的映射错误")
        }

        // 超时 → networkFailure("timeout")
        let timeoutClient = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let timeoutResult = await timeoutClient.smoke()
        XCTAssertEqual(timeoutResult, .networkFailure(detail: "timeout"))
    }

    func testAccessDeniedReasonIsTruncated() async {
        // 服务器回显的 reason 被截断到 200 字符，防止超长内容进入日志/UI。
        let longReason = String(repeating: "x", count: 300)
        let client = makeClient(config: CoAPIConfig(maxRetryCount: 0)) { request in
            (mockResponse(403, url: request.url!), Data(#"{"reason":"\#(longReason)"}"#.utf8))
        }

        await expectError(
            try await client.request(path: "/locations"),
            .accessDenied(reason: String(repeating: "x", count: 200))
        )
    }

    func testSmokeUnauthorizedAndNetworkBranches() async {
        // 401 → authorizationFailed("unauthorized")；非 timeout 的 URLError → networkFailure("network")
        let unauthorizedClient = makeClient(config: CoAPIConfig(maxRetryCount: 0)) { request in
            (mockResponse(401, url: request.url!), Data())
        }
        let unauthorizedResult = await unauthorizedClient.smoke()
        XCTAssertEqual(unauthorizedResult, .authorizationFailed(reason: "unauthorized"))

        let networkClient = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let networkResult = await networkClient.smoke()
        XCTAssertEqual(networkResult, .networkFailure(detail: "network"))
    }

    // MARK: - External review fixes (P1/P2)

    func testEmptyObjectResponseIsMalformed() async {
        // 结构异常的 2xx（空对象）必须判为 malformed，不能报连通成功。
        let client = makeClient { request in
            (mockResponse(200, url: request.url!), Data("{}".utf8))
        }

        await expectError(try await client.fetchLocations(), .malformedResponse(detail: "locations decode failed"))
    }

    func testNullItemsResponseIsMalformed() async {
        // `items: null` 同样违反 locations schema。
        let client = makeClient { request in
            (mockResponse(200, url: request.url!), Data(#"{"items":null}"#.utf8))
        }

        await expectError(try await client.fetchLocations(), .malformedResponse(detail: "locations decode failed"))
    }

    func testEmptyObjectSmokeReportsNetworkFailure() async {
        // smoke 对结构异常响应必须退出为非成功，而不是 success(locationCount: 0)。
        let client = makeClient { request in
            (mockResponse(200, url: request.url!), Data("{}".utf8))
        }

        let result = await client.smoke()

        XCTAssertEqual(result, .networkFailure(detail: "malformed response"))
    }

    func testNetworkErrorDetailIsSanitized() async {
        // 底层错误即使携带敏感 URL/path（FailingURLString），映射后的
        // CoAPIError.network 也不能包含它。
        let sensitivePath = "/players/%23SECRETTAG123"
        let client = CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "fake-token" }
        )
        MockURLProtocol.handler = { _ in
            throw URLError(.cannotFindHost, userInfo: [
                NSURLErrorFailingURLErrorKey: URL(string: "https://api.clashofclans.com" + sensitivePath)!,
                NSURLErrorFailingURLStringErrorKey: "https://api.clashofclans.com" + sensitivePath,
            ])
        }

        do {
            _ = try await client.request(path: "/locations")
            XCTFail("expected network error")
        } catch let error as CoAPIError {
            guard case .network(let underlying) = error else {
                XCTFail("expected .network, got \(error)")
                return
            }
            XCTAssertFalse(underlying.contains(sensitivePath), "network detail 不得包含敏感 path")
            XCTAssertFalse(underlying.contains("clashofclans"), "network detail 不得包含 host")
            XCTAssertTrue(underlying.contains("URLError code"), "应保留可诊断的错误码分类")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

/// Thread-safe sequential token source for asserting token re-read between retries.
private final class TokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]
    private var index = 0

    init(_ values: [String?]) {
        self.values = values
    }

    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard index < values.count else { return nil }
        let value = values[index]
        index += 1
        return value
    }
}
