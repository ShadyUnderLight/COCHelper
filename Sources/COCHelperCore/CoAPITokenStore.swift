import Foundation
import Security

/// 可注入的 token 存取抽象：测试用内存实现，生产用 Keychain。
public protocol CoAPITokenStoring: Sendable {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

public enum CoAPITokenStoreError: Error, Equatable, Sendable {
    /// Keychain 返回了非预期状态（不包含 errSecItemNotFound，它表示"未配置"）。
    case unexpectedStatus(OSStatus)
}

/// macOS Keychain 中的 generic password 存储。
/// 设计约束（Issue #5 红线）：token 绝不写入 UserDefaults/源码/JSON/日志，只能经此类进出 Keychain。
public struct KeychainTokenStore: CoAPITokenStoring {
    public let service: String   // 默认 "com.coc-helper.coapi"
    public let account: String   // 默认 "developer-token"

    public init(service: String = "com.coc-helper.coapi", account: String = "developer-token") {
        self.service = service
        self.account = account
    }

    public func readToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            // token 非 UTF-8 不可达；Data 转 String 失败视为无 token，不抛错
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        default:
            throw CoAPITokenStoreError.unexpectedStatus(status)
        }
    }

    public func saveToken(_ token: String) throws {
        // SecItemAdd 的参数是一个描述待存条目的字典（须含 kSecClass），不是分离的 query
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var result: CFTypeRef?
        let status = SecItemAdd(item as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // 已存在 → 更新已有密码
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let updates: [String: Any] = [
                kSecValueData as String: Data(token.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CoAPITokenStoreError.unexpectedStatus(updateStatus)
            }
        default:
            throw CoAPITokenStoreError.unexpectedStatus(status)
        }
    }

    public func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return  // 幂等：未配置也算成功
        default:
            throw CoAPITokenStoreError.unexpectedStatus(status)
        }
    }
}
