import Foundation

/// 快照审计键协议：refresher 从快照提取 `unrecognizedKeys`（分页包装返回空）。
public protocol UnrecognizedKeysProviding {
    var unrecognizedKeys: [String] { get }
}

extension OfficialClanSnapshot: UnrecognizedKeysProviding {}
extension OfficialClanWarSnapshot: UnrecognizedKeysProviding {}

extension OfficialPaginatedPage: UnrecognizedKeysProviding {
    /// 分页包装层不持有审计字段（条目级审计留待条目模型扩展）。
    public var unrecognizedKeys: [String] { [] }
}

/// 官方分页响应包装（warlog / capitalraidseasons 共用）。
///
/// - `items` 缺省为 []（传输层损坏容错：官方总是返回数组，但缓存损坏时
///   不应让整个页面解码失败）。
/// - `before` / `after` 是分页游标：向更早翻页用 `after=<after 值>`；
///   末页或官方省略时二者为 nil。
public struct OfficialPaginatedPage<Item: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let items: [Item]
    public let before: String?
    public let after: String?

    public init(items: [Item], before: String?, after: String?) {
        self.items = items
        self.before = before
        self.after = after
    }

    private enum CodingKeys: String, CodingKey {
        case items, before, after
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        before = try container.decodeIfPresent(String.self, forKey: .before)
        after = try container.decodeIfPresent(String.self, forKey: .after)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(before, forKey: .before)
        try container.encodeIfPresent(after, forKey: .after)
    }
}

// MARK: - 战争日志条目

/// warlog 中的一个已结束战争条目。
///
/// 成员攻击明细（`clan.members`/`opponent.members`）deferred：嵌套未知键由
/// Codable 合成容忍，不声明属性。
public struct OfficialWarLogEntry: Codable, Hashable, Sendable {
    /// win / lose / tie（官方字符串，不做本地枚举映射）。
    public let result: String?
    public let endTime: String?
    public let teamSize: Int?
    public let attacksPerMember: Int?
    public let clan: ClanWarParticipant?
    public let opponent: ClanWarParticipant?

    public init(
        result: String?, endTime: String?, teamSize: Int?, attacksPerMember: Int?,
        clan: ClanWarParticipant?, opponent: ClanWarParticipant?
    ) {
        self.result = result
        self.endTime = endTime
        self.teamSize = teamSize
        self.attacksPerMember = attacksPerMember
        self.clan = clan
        self.opponent = opponent
    }
}

// MARK: - 部落资本赛季条目

/// capitalraidseasons 中的一个赛季。
///
/// 成员攻击/防守明细（`attackLog`/`defenseLog`）deferred：嵌套容忍。
public struct OfficialCapitalRaidSeason: Codable, Hashable, Sendable {
    /// ended / ongoing（官方字符串）。
    public let state: String?
    public let startTime: String?
    public let endTime: String?
    public let totalLooted: Int?
    public let offensiveReward: Int?
    public let defensiveReward: Int?
    public let clan: CapitalRaidClanSummary?

    public init(
        state: String?, startTime: String?, endTime: String?,
        totalLooted: Int?, offensiveReward: Int?, defensiveReward: Int?,
        clan: CapitalRaidClanSummary?
    ) {
        self.state = state
        self.startTime = startTime
        self.endTime = endTime
        self.totalLooted = totalLooted
        self.offensiveReward = offensiveReward
        self.defensiveReward = defensiveReward
        self.clan = clan
    }
}

public struct CapitalRaidClanSummary: Codable, Hashable, Sendable {
    public let attackCount: Int?
    public let destroyedDistricts: Int?

    public init(attackCount: Int?, destroyedDistricts: Int?) {
        self.attackCount = attackCount
        self.destroyedDistricts = destroyedDistricts
    }
}

// MARK: - 分页游标逻辑（防无限循环）

/// 分页终结判定（纯函数，可测）。
public enum PaginationLogic {
    /// 是否还有更多页：
    /// - 响应 `after` 为 nil（末页）→ 无更多
    /// - 响应 `after` == 请求游标（游标未前进）→ 无更多（防无限循环）
    /// - 其余 → 有更多
    public static func hasMore(requestedCursor: String?, responseAfter: String?) -> Bool {
        guard let responseAfter else { return false }
        return responseAfter != requestedCursor
    }
}

/// 分页合并（纯函数，可测）：累计页语义（lastGood = 累计列表 + 最新游标）。
public enum PaginationMerge {
    /// 新页追加到累计列表，跳过与已有条目重复的项（验收：不重复记录）。
    /// 已有顺序保持，新条目按页顺序追加。
    public static func mergedItems<Item: Equatable>(existing: [Item], newPage: [Item]) -> [Item] {
        var merged = existing
        for item in newPage where !merged.contains(item) {
            merged.append(item)
        }
        return merged
    }

    /// 加载更多后的累计页面：
    /// - 首屏（existing 为 nil）→ 直接采用 fetched
    /// - 续页 → items 去重合并；`after` 推进为最新响应的值
    /// - **游标停滞**（响应 after == 请求游标）→ `after` 清空为 nil：
    ///   视为末页终止（防无限循环；UI 的 hasMore 派生以 after 非 nil 为准）
    /// - `before` 保留最新响应值（未使用的前翻游标，保留供未来）。
    public static func mergedPage<Item: Equatable>(
        existing: OfficialPaginatedPage<Item>?,
        fetched: OfficialPaginatedPage<Item>
    ) -> OfficialPaginatedPage<Item> {
        guard let existing else { return fetched }
        let stalled: Bool = {
            guard let fetchedAfter = fetched.after, let existingAfter = existing.after else {
                return false
            }
            return fetchedAfter == existingAfter
        }()
        return OfficialPaginatedPage(
            items: mergedItems(existing: existing.items, newPage: fetched.items),
            before: fetched.before ?? existing.before,
            after: stalled ? nil : fetched.after
        )
    }
}
