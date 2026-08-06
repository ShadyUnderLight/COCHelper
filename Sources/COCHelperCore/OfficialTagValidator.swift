import Foundation

/// 官方 tag 的统一契约（Issue #48 Step 1）：规范化与格式校验。
///
/// 玩家 tag 与部落 tag 使用**同一字符集**（官方定义：`#` + 大写 `A-Z` + 数字 `0-9`），
/// 因此本类型是玩家/部落共用的唯一规则来源：缓存 key、请求 URL、重复判断、
/// 输入校验必须全部经过这里，不允许在 Sidebar / AppModel / API client 中
/// 分别实现规则（Issue #48 拆分建议第 1 条）。
///
/// 三个职责层次：
/// - `normalized`：**存储级**标准化（trim），供既有数据链路使用，行为不变。
/// - `normalizedInput`：**输入级**标准化（trim + 全大写 + 补齐 `#`），供用户
///   输入流程（部落添加、玩家导入）使用。幂等：`normalizedInput(normalizedInput(x)) == normalizedInput(x)`。
///   只负责形态归一，**不过滤非法字符**——字符合法性由 `isValid` 判定，
///   保证调用方能用标准化结果向用户指出具体非法字符。
/// - `isValid`：格式 + 长度校验（`#` 开头，其余 1...`maxTagLength` 个 ASCII 大写字母或数字）。
public enum OfficialTagValidator {
    /// 防御性长度上限（不含 `#`）。**非官方约束**：官方未公布 tag 长度上限，
    /// 此值取宽松的 20，仅用于输入快速失败（超长输入 100% 是误输入，
    /// 本地拒绝优于打 API 拿 404）。未来官方若公布正式上限，更新此常量即可，
    /// 单一来源保证所有调用点同步生效。
    public static let maxTagLength = 20

    /// 存储级标准化：去掉首尾空白；空串或 nil 返回 nil。
    /// 不做大小写/前缀改写（既有契约，调用方显式传入带 `#` 的 tag）。
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 输入级标准化：trim + 全大写 + 补齐 `#`；空串或 nil 返回 nil。
    ///
    /// 幂等：结果再次传入返回相同值（大写稳定、`#` 不重复补）。
    /// 非法字符（如 `-`）会被**保留**，由 `isValid` 拒绝——这样调用方可以把
    /// `normalizedInput` 的结果直接展示给用户做错误提示，而非静默吞掉字符。
    public static func normalizedInput(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let uppercased = trimmed.uppercased()
        return uppercased.hasPrefix("#") ? uppercased : "#" + uppercased
    }

    /// 校验 tag 格式与长度：以 `#` 开头、`1...maxTagLength` 个 ASCII 大写字母或数字。
    /// 期望传入的是标准化后的 tag（`normalized` 或 `normalizedInput` 的结果）。
    public static func isValid(_ tag: String) -> Bool {
        guard tag.hasPrefix("#") else { return false }
        let rest = tag.dropFirst()
        guard !rest.isEmpty, rest.count <= maxTagLength else { return false }
        return rest.allSatisfy { $0.isASCII && (($0.isLetter && $0.isUppercase) || $0.isNumber) }
    }
}

// MARK: - 兼容别名

/// 旧名兼容（Issue #48 Step 1 重命名前的 public API）。
/// 官方 tag 通用契约已统一为 `OfficialTagValidator`，玩家/部落共用；
/// 新代码请使用 `OfficialTagValidator`。
public typealias OfficialPlayerTagValidator = OfficialTagValidator
