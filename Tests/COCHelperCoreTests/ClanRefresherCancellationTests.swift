import Foundation
import XCTest
@testable import COCHelperCore

/// 取消传播：CancellationError 不得以"未知错误：CancellationError"呈现给用户。
final class ClanRefresherCancellationTests: XCTestCase {
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

    func testCancellationErrorNeverLeaksTypeName() async {
        // URLProtocol 会把 CancellationError 桥接为 NSError，因此这里无法
        // 精确到达 refresher 的 `catch is CancellationError` 分支；该分支的
        // 真实触发路径是 Task 取消时 CoAPIClient 内部的 Task.sleep 抛出
        // CancellationError。本测试验证核心契约：无论取消以何种形态到达，
        // 用户可见的 reason 都不得泄漏 CancellationError 类型名或落入
        // "未知错误" 泛型分支。
        let refresher = makeRefresher { _ in
            throw CancellationError()
        }

        let result = await refresher.refreshClans(
            villageClanTags: ["#CLAN"],
            previous: [:]
        )

        XCTAssertEqual(result["#CLAN"]?.status, .failed)
        let reason = result["#CLAN"]?.lastErrorReason ?? ""
        XCTAssertFalse(reason.contains("CancellationError"), "不得泄漏 CancellationError 类型名: \(reason)")
        XCTAssertFalse(reason.contains("未知错误"), "不得落入泛型未知错误分支: \(reason)")
    }
}
