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

        XCTAssertEqual(result.items?.count, 2)
        XCTAssertEqual(result.items?[0].id, 32_000_000)
        XCTAssertEqual(result.items?[0].name, "International")
        XCTAssertEqual(result.items?[1].isCountry, true)

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

        XCTAssertEqual(result.items?.count, 1)
        XCTAssertEqual(result.items?[0].id, 1)
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

        XCTAssertEqual(result.items?.count, 1)
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
}
