import Foundation

/// 快照审计键协议：refresher 从快照提取 `unrecognizedKeys`（分页包装返回空）。
public protocol UnrecognizedKeysProviding {
    var unrecognizedKeys: [String] { get }
}

extension OfficialClanSnapshot: UnrecognizedKeysProviding {}
extension OfficialClanWarSnapshot: UnrecognizedKeysProviding {}
extension OfficialWarLogPage: UnrecognizedKeysProviding {
    public var unrecognizedKeys: [String] { [] }
}
extension OfficialCapitalRaidPage: UnrecognizedKeysProviding {
    public var unrecognizedKeys: [String] { [] }
}

/// 官方分页响应的**泛型包装**（warlog / capitalraidseasons 共用）。
///
/// 官方结构（APIClanWarLogList / APICapitalRaidSeasons）：
/// `{ "items": [...], "paging": { "cursors": { "after": "...", "before": "..." } } }`
/// - `items` **必填**（缺失或 null 是损坏响应，必须解码失败 → 保留 last-good，
///   不得静默当作成功空页）
/// - `paging` / `cursors` / 游标均可选（末页或官方省略时为 nil）
public struct OfficialPaginatedPage<Item: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let items: [Item]
    /// `paging.cursors.after`（向后翻页游标；末页为 nil）。
    public let after: String?
    /// `paging.cursors.before`（向前翻页游标；未使用，保留供未来）。
    public let before: String?

    public init(items: [Item], before: String?, after: String?) {
        self.items = items
        self.before = before
        self.after = after
    }

    private enum CodingKeys: String, CodingKey {
        case items, paging
    }

    private enum PagingKeys: String, CodingKey {
        case cursors
    }

    private enum CursorKeys: String, CodingKey {
        case after, before
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // items 必填：缺失/null → 解码失败（malformed），保留既有 last-good
        items = try container.decode([Item].self, forKey: .items)
        if let paging = try container.decodeIfPresent(PagingContainer.self, forKey: .paging) {
            after = paging.after
            before = paging.before
        } else {
            after = nil
            before = nil
        }
    }

    /// paging 容器：`{ "cursors": { "after": ..., "before": ... } }`。
    private struct PagingContainer: Decodable {
        let after: String?
        let before: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: PagingKeys.self)
            let cursors = try container.decodeIfPresent(CursorsContainer.self, forKey: .cursors)
            after = cursors?.after
            before = cursors?.before
        }

        private struct CursorsContainer: Decodable {
            let after: String?
            let before: String?
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        if after != nil || before != nil {
            var paging = container.nestedContainer(keyedBy: PagingKeys.self, forKey: .paging)
            var cursors = paging.nestedContainer(keyedBy: CursorKeys.self, forKey: .cursors)
            try cursors.encodeIfPresent(after, forKey: .after)
            try cursors.encodeIfPresent(before, forKey: .before)
        }
    }
}

// MARK: - 端点具体包装（遵守 EndpointParserVersioning，避免泛型多条件遵守冲突）

/// warlog 分页快照（具体类型）：转发 `OfficialPaginatedPage<OfficialWarLogEntry>`。
public struct OfficialWarLogPage: Codable, Hashable, Sendable, EndpointParserVersioning {
    public let page: OfficialPaginatedPage<OfficialWarLogEntry>

    public init(page: OfficialPaginatedPage<OfficialWarLogEntry>) {
        self.page = page
    }

    /// 0.4：成员级攻防日志解析范围（0.3）+ battleModifier 解析（Issue #72）。
    public static var currentParserVersion: String { "clan-war-log-0.4" }

    public var items: [OfficialWarLogEntry] { page.items }
    public var after: String? { page.after }
    public var before: String? { page.before }

    public init(from decoder: Decoder) throws {
        page = try OfficialPaginatedPage<OfficialWarLogEntry>(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try page.encode(to: encoder)
    }
}

/// capitalraidseasons 分页快照（具体类型）。
public struct OfficialCapitalRaidPage: Codable, Hashable, Sendable, EndpointParserVersioning {
    public let page: OfficialPaginatedPage<OfficialCapitalRaidSeason>

    public init(page: OfficialPaginatedPage<OfficialCapitalRaidSeason>) {
        self.page = page
    }

    /// 0.3：赛季成员贡献解析范围（Issue #20，Task 2）。
    public static var currentParserVersion: String { "clan-capital-0.3" }

    public var items: [OfficialCapitalRaidSeason] { page.items }
    public var after: String? { page.after }
    public var before: String? { page.before }

    public init(from decoder: Decoder) throws {
        page = try OfficialPaginatedPage<OfficialCapitalRaidSeason>(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try page.encode(to: encoder)
    }
}

// MARK: - 战争日志条目

/// warlog 中的一个已结束战争条目。
///
/// 成员攻击明细经 `ClanWarParticipant.members` 解析（缺失容忍，见
/// ClanWarModels.swift）。
public struct OfficialWarLogEntry: Codable, Hashable, Sendable {
    /// win / lose / tie（官方字符串，不做本地枚举映射）。
    public let result: String?
    public let endTime: String?
    public let teamSize: Int?
    public let attacksPerMember: Int?
    /// 官方 battleModifier（warlog 条目同样返回；Hard Mode/传奇杯战争），
    /// 保存原始值；"none" 与缺失视为无规则。
    public let battleModifier: String?
    public let clan: ClanWarParticipant?
    public let opponent: ClanWarParticipant?

    public init(
        result: String?, endTime: String?, teamSize: Int?, attacksPerMember: Int?,
        battleModifier: String?,
        clan: ClanWarParticipant?, opponent: ClanWarParticipant?
    ) {
        self.result = result
        self.endTime = endTime
        self.teamSize = teamSize
        self.attacksPerMember = attacksPerMember
        self.battleModifier = battleModifier
        self.clan = clan
        self.opponent = opponent
    }
}

// MARK: - 部落都城突袭周末成员与攻防日志（Issue #20）

/// capitalraidseasons 赛季成员贡献条目（官方 ClanCapitalRaidSeasonMember）。
///
/// 全 optional + 合成 Codable：官方新增字段或个别字段缺失不破坏解码。
public struct CapitalRaidSeasonMember: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    /// 本成员突袭周末掠夺的都城金币。
    public let capitalResourcesLooted: Int?
    /// 本成员赛季攻击次数。
    public let attacks: Int?

    public init(
        tag: String?, name: String?, capitalResourcesLooted: Int?, attacks: Int?
    ) {
        self.tag = tag
        self.name = name
        self.capitalResourcesLooted = capitalResourcesLooted
        self.attacks = attacks
    }
}

/// 攻防日志中的部落方（官方 ClanCapitalRaidSeasonClanInfo）。
///
/// attackLog 条目用 `defender`、defenseLog 条目用 `attacker`（官方字段名）。
public struct CapitalRaidClanInfo: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    public let level: Int?
    public let badgeUrls: [String: String]?

    public init(tag: String?, name: String?, level: Int?, badgeUrls: [String: String]?) {
        self.tag = tag
        self.name = name
        self.level = level
        self.badgeUrls = badgeUrls
    }
}

/// 攻防日志中的子城明细（官方 ClanCapitalRaidSeasonDistrict）。
///
/// 摧毁率与都城金币掠夺量在 districts 内（官方无顶层 looted/destructionPercent）。
public struct CapitalRaidDistrict: Codable, Hashable, Sendable {
    public let name: String?
    public let id: Int?
    /// 子城大本营等级。
    public let districtHallLevel: Int?
    public let stars: Int?
    /// 摧毁百分比（官方整数，用 Double 容忍浮点形态）。
    public let destructionPercent: Double?
    public let attackCount: Int?
    /// 该子城掠夺的都城金币。
    public let totalLooted: Int?

    public init(
        name: String?, id: Int?, districtHallLevel: Int?, stars: Int?,
        destructionPercent: Double?, attackCount: Int?, totalLooted: Int?
    ) {
        self.name = name
        self.id = id
        self.districtHallLevel = districtHallLevel
        self.stars = stars
        self.destructionPercent = destructionPercent
        self.attackCount = attackCount
        self.totalLooted = totalLooted
    }
}

/// attackLog 条目（官方 ClanCapitalRaidSeasonAttackLogEntry）。
public struct CapitalRaidAttackLogEntry: Codable, Hashable, Sendable {
    /// 被进攻的部落（官方字段名 defender）。
    public let defender: CapitalRaidClanInfo?
    public let attackCount: Int?
    public let districtCount: Int?
    public let districtsDestroyed: Int?
    /// 子城明细（摧毁率/都城金币掠夺量在此）。
    public let districts: [CapitalRaidDistrict]?

    public init(
        defender: CapitalRaidClanInfo?, attackCount: Int?, districtCount: Int?,
        districtsDestroyed: Int?, districts: [CapitalRaidDistrict]?
    ) {
        self.defender = defender
        self.attackCount = attackCount
        self.districtCount = districtCount
        self.districtsDestroyed = districtsDestroyed
        self.districts = districts
    }
}

/// defenseLog 条目（官方 ClanCapitalRaidSeasonDefenseLogEntry）。
/// 注意：官方字段名是 `attacker`（与 attackLog 的 `defender` 不同）。
public struct CapitalRaidDefenseLogEntry: Codable, Hashable, Sendable {
    /// 进攻的部落（官方字段名 attacker）。
    public let attacker: CapitalRaidClanInfo?
    public let attackCount: Int?
    public let districtCount: Int?
    public let districtsDestroyed: Int?
    public let districts: [CapitalRaidDistrict]?

    public init(
        attacker: CapitalRaidClanInfo?, attackCount: Int?, districtCount: Int?,
        districtsDestroyed: Int?, districts: [CapitalRaidDistrict]?
    ) {
        self.attacker = attacker
        self.attackCount = attackCount
        self.districtCount = districtCount
        self.districtsDestroyed = districtsDestroyed
        self.districts = districts
    }
}

// MARK: - 部落都城突袭周末条目

/// capitalraidseasons 中的一个赛季（字段与官方 APICapitalRaidSeason 对齐：
/// 统计字段为**顶层**，无嵌套 clan 对象）。
///
/// 成员/攻击/防守明细（`members`/`attackLog`/`defenseLog`）缺失容忍：
/// 全 optional + 合成 Codable，官方省略或字段缺失不破坏解码。
public struct OfficialCapitalRaidSeason: Codable, Hashable, Sendable {
    /// ended / ongoing（官方字符串）。
    public let state: String?
    public let startTime: String?
    public let endTime: String?
    /// 突袭周末掠夺的都城金币总量（官方字段名 capitalTotalLoot）。
    public let capitalTotalLoot: Int?
    /// 完成突袭数。
    public let raidsCompleted: Int?
    /// 总攻击数。
    public let totalAttacks: Int?
    /// 摧毁敌方子城数。
    public let enemyDistrictsDestroyed: Int?
    public let offensiveReward: Int?
    public let defensiveReward: Int?
    /// 赛季成员贡献列表（缺失容忍）。
    public let members: [CapitalRaidSeasonMember]?
    /// 进攻日志（每次突袭一条；缺失容忍）。
    public let attackLog: [CapitalRaidAttackLogEntry]?
    /// 防守日志（缺失容忍）。
    public let defenseLog: [CapitalRaidDefenseLogEntry]?

    public init(
        state: String?, startTime: String?, endTime: String?,
        capitalTotalLoot: Int?, raidsCompleted: Int?, totalAttacks: Int?,
        enemyDistrictsDestroyed: Int?, offensiveReward: Int?, defensiveReward: Int?,
        members: [CapitalRaidSeasonMember]?, attackLog: [CapitalRaidAttackLogEntry]?,
        defenseLog: [CapitalRaidDefenseLogEntry]?
    ) {
        self.state = state
        self.startTime = startTime
        self.endTime = endTime
        self.capitalTotalLoot = capitalTotalLoot
        self.raidsCompleted = raidsCompleted
        self.totalAttacks = totalAttacks
        self.enemyDistrictsDestroyed = enemyDistrictsDestroyed
        self.offensiveReward = offensiveReward
        self.defensiveReward = defensiveReward
        self.members = members
        self.attackLog = attackLog
        self.defenseLog = defenseLog
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
