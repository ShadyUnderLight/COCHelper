import Foundation

/// 用户手动跟踪的部落档案（Issue #41）。
///
/// 与村庄档案（`VillageProfile`）、玩家快照（`AccountSnapshot`）完全独立；
/// API 数据不写入本档案——部落数据仍在按 Tag 共享的 `clanStates` 等状态层。
/// `clanTag` 是规范化后的唯一主键（`Identifiable.id`）。AppModel 添加时
/// 先查重（重复返回 .duplicate，不覆盖原档案）；`TrackedClanStore.upsert`
/// 是替换语义，供其他场景使用。
public struct TrackedClanProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String { clanTag }
    /// 规范化部落 Tag（trim + 大写 + `#` 前缀校验），稳定身份。
    public let clanTag: String
    /// 用户自定义显示名称/备注，可为 nil。
    public var displayName: String?
    /// 创建时间（本地）。
    public var createdAt: Date

    public init(clanTag: String, displayName: String?, createdAt: Date) {
        self.clanTag = clanTag
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

/// 官方部落 Tag 的规范化与校验（Issue #41）。
///
/// 字符集与玩家 Tag 相同（`#` + 大写 `A-Z` + `0-9`），但语义独立：
/// - 输入先 trim 首尾空白；
/// - 先拒非 ASCII：避免 uppercase 后 `ß→SS`、`ı→I` 等静默改写 tag 字符
///   （官方 Tag 不含非 ASCII 字符，拒绝比改写更安全）；
/// - 转大写（官方 Tag 不区分大小写，规范化避免同一部落两个 key）；
/// - 缺少 `#` 前缀、只有 `#`、空值或含非法字符一律拒绝（不自动补 `#`）；
/// - 成功结果保证 `OfficialPlayerTagValidator.isValid` 为 true。
public enum ClanTagNormalizer {
    /// 规范化部落 Tag；非法输入返回 nil。
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 先拒非 ASCII：避免 uppercase 后 ß→SS、ı→I 等静默改写 tag 字符
        guard trimmed.allSatisfy({ $0.isASCII }) else { return nil }
        let uppercased = trimmed.uppercased()
        guard OfficialPlayerTagValidator.isValid(uppercased) else { return nil }
        return uppercased
    }
}
