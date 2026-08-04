import Foundation

/// 官方玩家 tag 的规范化与格式校验。
///
/// 官方 tag 的字符集为 `#` 加上大写 `A-Z` 与数字 `0-9`；本地导入的 tag
/// 可能带前后空白，请求前必须先归一化。
public enum OfficialPlayerTagValidator {
    /// 去掉首尾空白；空串或 nil 返回 nil。
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 校验 tag 格式：以 `#` 开头、至少一个字符、其余为大写字母或数字。
    public static func isValid(_ tag: String) -> Bool {
        guard tag.hasPrefix("#") else { return false }
        let rest = tag.dropFirst()
        guard !rest.isEmpty else { return false }
        return rest.allSatisfy { $0.isASCII && (($0.isLetter && $0.isUppercase) || $0.isNumber) }
    }
}
