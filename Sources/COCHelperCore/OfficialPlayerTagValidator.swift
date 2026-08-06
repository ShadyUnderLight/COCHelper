import Foundation

/// 官方 tag（玩家/部落共用）的规范化与格式校验的**唯一权威规则**。
///
/// 规则（所有入口统一：村庄快照派生、手动添加、刷新请求）：
/// - 官方 tag 的字符集为 `#` 加上大写 `A-Z` 与数字 `0-9`；
/// - 长度：官方 tag 通常 8-12 位（不含 `#`），`body ≤ 14` 为防御上限
///   （超长输入一律拒绝，避免非 canonical 数据进入缓存键）；
/// - `normalized` 只做首尾空白去除（不转大小写、不补 `#`）。
public enum OfficialPlayerTagValidator {
    /// 去掉首尾空白；空串或 nil 返回 nil。
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 校验 tag 格式：以 `#` 开头、至少一个字符、其余为大写字母或数字、
    /// body 不超过 14 位（含 `#` 共 ≤ 15）。
    public static func isValid(_ tag: String) -> Bool {
        guard tag.hasPrefix("#") else { return false }
        let rest = tag.dropFirst()
        guard !rest.isEmpty, rest.count <= 14 else { return false }
        return rest.allSatisfy { $0.isASCII && (($0.isLetter && $0.isUppercase) || $0.isNumber) }
    }
}
