import Foundation
import XCTest
@testable import COCHelperCore

final class CoAPIFetchClanWarTests: XCTestCase {
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

    func testFetchClanWarSuccessAndURLEncoding() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             fullClanWarFixtureData())
        }

        let war = try await client.fetchClanWar(tag: "#CLANANONYMIZED")

        XCTAssertEqual(war.state, "inWar")
        XCTAssertEqual(war.clan?.stars, 88)

        let lastRequest = MockURLProtocol.lastRequest()
        XCTAssertEqual(lastRequest?.url?.path(percentEncoded: true), "/v1/clans/%23CLANANONYMIZED/currentwar")
        XCTAssertNil(lastRequest?.url?.fragment)
        XCTAssertFalse(lastRequest?.url?.absoluteString.contains("#") ?? false)
        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer fake-token")
    }

    func testFetchClanWarNotInWarSucceeds() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"state":"notInWar"}"#.utf8))
        }

        let war = try await client.fetchClanWar(tag: "#CLAN")
        XCTAssertEqual(war.state, "notInWar")
    }

    func testFetchClanWarErrorStatusMapping() async {
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
                _ = try await client.fetchClanWar(tag: "#CLAN")
                XCTFail("expected \(c.expected), got success")
            } catch let error as CoAPIError {
                XCTAssertEqual(error, c.expected, "status \(c.status)")
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
    }

    func testFetchClanWarMalformedResponseIncludesFieldPath() async {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"teamSize": "not-an-int"}"#.utf8))
        }

        do {
            _ = try await client.fetchClanWar(tag: "#CLAN")
            XCTFail("expected malformedResponse")
        } catch let error as CoAPIError {
            guard case .malformedResponse(let detail) = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("teamSize"), "detail 应包含字段路径: \(detail)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFetchClanWarMalformedResponseSanitizesDetail() async {
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("not-json".utf8))
        }

        do {
            _ = try await client.fetchClanWar(tag: "#CLAN")
            XCTFail("expected malformedResponse")
        } catch let error as CoAPIError {
            guard case .malformedResponse(let detail) = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
            XCTAssertFalse(detail.contains("CLAN"))
            XCTAssertFalse(detail.contains("clashofclans"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
