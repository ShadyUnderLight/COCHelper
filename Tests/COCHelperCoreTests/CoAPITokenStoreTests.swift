import Foundation
import XCTest
@testable import COCHelperCore

/// 线程安全的内存实现（测试用）。@unchecked Sendable + NSLock。
final class InMemoryTokenStore: CoAPITokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    func readToken() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    func saveToken(_ token: String) throws { lock.lock(); defer { lock.unlock() }; self.token = token }
    func deleteToken() throws { lock.lock(); defer { lock.unlock() }; token = nil }
}

final class CoAPITokenStoreTests: XCTestCase {
    /// 独立 service，避免污染生产 keychain（"com.coc-helper.coapi"）。
    private let keychain = KeychainTokenStore(service: "com.coc-helper.coapi.tests")

    override func setUp() {
        super.setUp()
        try? keychain.deleteToken()  // 幂等起点
    }

    override func tearDown() {
        try? keychain.deleteToken()  // 清理，保证测试可重复
        super.tearDown()
    }

    // MARK: - 协议行为（内存实现，不碰真实 Keychain）

    func testProtocolRoundTrip() throws {
        let store = InMemoryTokenStore()
        try store.saveToken("tok-123")
        XCTAssertEqual(try store.readToken(), "tok-123")
        try store.deleteToken()
        XCTAssertNil(try store.readToken())
    }

    func testProtocolEmptyInitially() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.readToken())
    }

    // MARK: - 真实 Keychain 往返

    func testKeychainRoundTrip() throws {
        try keychain.saveToken("tok-abc")
        XCTAssertEqual(try keychain.readToken(), "tok-abc")
        try keychain.deleteToken()
        XCTAssertNil(try keychain.readToken())
    }

    func testKeychainReadEmptyInitially() throws {
        // setUp 已 delete；再删一次验证幂等
        try keychain.deleteToken()
        XCTAssertNil(try keychain.readToken())
    }
}
