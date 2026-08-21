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

// MARK: - Issue #211: 突袭周末行 identity（预计算、轻量）
//
//  设计约束（与 #199 互斥）：
//  - 官方赛季无服务端唯一 ID，三元组 `startTime|endTime|state` 会重复
//    （#197 fixture 17 条只有 3 个唯一三元组），不能直接用三元组或
//    数组 offset/UUID/随机值作 ForEach identity。
//  - 必须在分页合并/渲染层一次生成，不在 View body/diff 路径执行
//    完整赛季 JSON 编码（含 members/attackLog/defenseLog），也不
//    得换成另一个同等重型的哈希。
//  - 详情字段（capitalTotalLoot/members/attackLog/defenseLog 等）
//    变化时行 ID 保持不变，避免 DisclosureGroup 展开态因详情刷新抖动。
//  - 重复三元组的不同历史记录仍需不同 ID，且跨分页累计、重建缓存、
//    重新解码后顺序与 ID 稳定。
//  - 实现：语义主键（三元组）+ 合并阶段确定性的重复序号。序号按
//    全局出现顺序对同三元组计数：`key = start|end|state`, `id = key#seq`
//    （seq 为该 key 此前出现次数，0-based）。该 scheme：
//    - `#0/#1...` 区分同三元组的多条真实记录；
//    - 详情变化不影响 key/seq，故 ID 不变；
//    - 追加分页或一次性合并只要输入顺序一致，结果 ID 一致；
//    - 重编码/解码后 items 顺序不变则 ID 仍一致；
//    - 不依赖 offset 语义，局部删除不导致跨 key 的 ID 漂移（只影响
//      同 key 的后续序号，但该场景要求“出现异常重排时显式重建
//      row identity”而非静默错位）。
//  - 异常重排（如服务端返回顺序变化）会导致基于顺序的序号错位，
//    此时应视为需要重建身份（fail-closed：不静默复用旧 ID 去重
//    丢记录，也不自动展开/请求）。
//  - `OfficialCapitalRaidSeason` 的 Codable/Hashable 事实模型保持
//    原样，不将临时 UI ID 写回持久化 payload。

/// 突袭周末列表的渲染行模型（旁路官方 Codable payload 的 UI identity）。
public struct CapitalRaidSeasonRow: Identifiable, Hashable, Sendable {
    /// 稳定行 identity（见 `CapitalRaidRowIdentity` 契约）。
    public let id: String
    public let season: OfficialCapitalRaidSeason

    public init(id: String, season: OfficialCapitalRaidSeason) {
        self.id = id
        self.season = season
    }
}

/// 突袭周末行身份生成（纯函数，确定性，可测）。
public enum CapitalRaidRowIdentity {
    /// 语义主键：`startTime|endTime|state`。nil 按空字符串处理。
    /// 分隔符 `|` 在真实数据（ISO8601 / "ended"/"ongoing"）中不出现，
    /// 因此无需转义；若未来出现含 `|` 的值，仍保持确定性（仅同输入
    /// 同输出，不承诺跨格式可逆）。
    public static func tripleKey(for season: OfficialCapitalRaidSeason) -> String {
        let start = season.startTime ?? ""
        let end = season.endTime ?? ""
        let state = season.state ?? ""
        return "\(start)|\(end)|\(state)"
    }

    /// 为已按呈现顺序排好的赛季数组生成稳定行模型。
    ///
    /// - 参数 seasons: 按最终呈现顺序（含分页累计、去重后）的赛季列表。
    /// - 返回: 与输入一一对应的 `CapitalRaidSeasonRow`，ID 满足 #211 契约。
    ///
    /// 重复三元组按出现次数编号：
    /// `id = "\(tripleKey)#\(seq)"`，其中 `seq` 为该 key 此前出现次数。
    /// 该函数为 O(n) 轻量路径（仅字符串拼接+字典计数），不得执行
    /// JSON 编码或重型哈希。
    public static func rows(for seasons: [OfficialCapitalRaidSeason]) -> [CapitalRaidSeasonRow] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(seasons.count)
        var result: [CapitalRaidSeasonRow] = []
        result.reserveCapacity(seasons.count)
        for season in seasons {
            let key = tripleKey(for: season)
            let seq = counts[key, default: 0]
            counts[key] = seq + 1
            let id = "\(key)#\(seq)"
            result.append(CapitalRaidSeasonRow(id: id, season: season))
        }
        return result
    }

    /// 已排序/已合并的分页整体的便捷入口。
    public static func rows(for page: OfficialCapitalRaidPage) -> [CapitalRaidSeasonRow] {
        rows(for: page.items)
    }
}

// MARK: - Issue #199: 突袭周末赛季稳定身份键（保留兼容，View 不应再使用）

public extension OfficialCapitalRaidSeason {
    /// 旧的 UI 稳定身份键（#199）：完整赛季 JSON 编码（含 members/attackLog/defenseLog）。
    ///
    /// - Warning: 该键在 #211 后已视为“重型路径”，`CapitalRaidCardView` 不再在
    ///   ForEach diff 中调用它。请使用 `CapitalRaidRowIdentity.rows(for:)` 的
    ///   预计算轻量 ID。若需历史对比，仍可保留此计算属性作迁移参照。
    var stableIdentityKey: String {
        let encoder = JSONEncoder()
        // 关键：`.sortedKeys`——完整内容含 `badgeUrls: [String: String]` 等
        // 字典字段，Swift Dictionary 迭代顺序不稳定（同语义不同插入顺序会
        // 产生不同 JSON），必须按键排序才能保证「语义相同 → 键相同」。
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return "season:" + String(reflecting: self)
        }
        return "season:" + data.base64EncodedString()
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

// MARK: - Issue #231: Capital Raid load-more identity-aware merge

/// Capital Raid 专用分页合并：load-more overlap 复用 #230 identity matcher，不改 generic `PaginationMerge`。
public enum CapitalRaidPaginationMerge {
    /// load-more 合并后的 row identity 处置。
    public enum LoadMoreReconciliation: Sendable, Equatable {
        /// prefix identity 可证明匹配，row cache 增量 reconcile。
        case identityPreserving
        /// overlap 歧义：row cache fail-closed reset（单次 generation bump）。
        case ambiguous
    }

    public struct LoadMoreResult: Sendable, Equatable {
        public let page: OfficialPaginatedPage<OfficialCapitalRaidSeason>
        public let reconciliation: LoadMoreReconciliation

        public init(
            page: OfficialPaginatedPage<OfficialCapitalRaidSeason>,
            reconciliation: LoadMoreReconciliation
        ) {
            self.page = page
            self.reconciliation = reconciliation
        }
    }

    /// 加载更多后的累计页面（Capital Raid 专用）：
    /// - suffix/prefix overlap 用 identity matcher 更新 payload，而非 `Equatable` 去重；
    /// - 游标停滞语义与 generic merge 一致。
    public static func mergedLoadMorePage(
        existing: OfficialPaginatedPage<OfficialCapitalRaidSeason>,
        fetched: OfficialPaginatedPage<OfficialCapitalRaidSeason>
    ) -> LoadMoreResult {
        let stalled: Bool = {
            guard let fetchedAfter = fetched.after, let existingAfter = existing.after else {
                return false
            }
            return fetchedAfter == existingAfter
        }()
        let (items, reconciliation) = mergedLoadMoreItems(
            existing: existing.items,
            newPage: fetched.items
        )
        return LoadMoreResult(
            page: OfficialPaginatedPage(
                items: items,
                before: fetched.before ?? existing.before,
                after: stalled ? nil : fetched.after
            ),
            reconciliation: reconciliation
        )
    }

    /// 纯函数：identity-aware load-more items 合并（可单测）。
    static func mergedLoadMoreItems(
        existing: [OfficialCapitalRaidSeason],
        newPage: [OfficialCapitalRaidSeason]
    ) -> (items: [OfficialCapitalRaidSeason], reconciliation: LoadMoreReconciliation) {
        if newPage.isEmpty {
            return (existing, .identityPreserving)
        }

        if existing.count == 1 && newPage.count == 1 {
            if CapitalRaidSeasonMatcher.canSafelyMatch(oldSeasons: existing, newSeasons: newPage) {
                return (newPage, .identityPreserving)
            }
            if tripleKeyCounts(for: existing) == tripleKeyCounts(for: newPage) {
                return (newPage, .ambiguous)
            }
            return appendItems(existing: existing, newPage: newPage)
        }

        if existing.count == newPage.count && existing.count > 1,
           CapitalRaidRowIdentity.tripleKey(for: existing[0])
               == CapitalRaidRowIdentity.tripleKey(for: newPage[0]),
           CapitalRaidSeasonMatcher.canSafelyMatch(oldSeasons: existing, newSeasons: newPage) {
            return (newPage, .identityPreserving)
        }

        if existing.count == newPage.count && existing.count > 1,
           CapitalRaidRowIdentity.tripleKey(for: existing[existing.count - 1])
               == CapitalRaidRowIdentity.tripleKey(for: newPage[0]),
           hasPositionalTripleOverlap(existing: existing, newPage: newPage, overlap: existing.count),
           tripleKeyCounts(for: existing) == tripleKeyCounts(for: newPage),
           CapitalRaidSeasonMatcher.classifyBoundaryOverlap(
               oldSeasons: existing,
               newSeasons: newPage
           ) == .ambiguous {
            return (newPage, .ambiguous)
        }

        let maxOverlap = min(existing.count, newPage.count)
        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            guard isPaginationOverlapCandidate(
                existing: existing,
                newPage: newPage,
                overlap: overlap
            ) else {
                continue
            }
            let suffix = Array(existing.suffix(overlap))
            let prefix = Array(newPage.prefix(overlap))
            switch CapitalRaidSeasonMatcher.classifyBoundaryOverlap(
                oldSeasons: suffix,
                newSeasons: prefix
            ) {
            case .notCandidate:
                continue
            case .ambiguous:
                return (
                    Array(existing.dropLast(overlap)) + newPage,
                    .ambiguous
                )
            case .matched:
                guard shouldApplyOverlapCandidate(
                    existing: existing,
                    newPage: newPage,
                    overlap: overlap
                ) else {
                    continue
                }
                return mergeWithOverlap(
                    existing: existing,
                    newPage: newPage,
                    overlap: overlap,
                    reconciliation: .identityPreserving
                )
            }
        }

        return appendItems(existing: existing, newPage: newPage)
    }

    private static func mergeWithOverlap(
        existing: [OfficialCapitalRaidSeason],
        newPage: [OfficialCapitalRaidSeason],
        overlap: Int,
        reconciliation: LoadMoreReconciliation
    ) -> (items: [OfficialCapitalRaidSeason], reconciliation: LoadMoreReconciliation) {
        // Once the suffix/prefix boundary has been identified, every item after
        // that boundary is a new page occurrence. Do not run whole-payload
        // de-duplication over the suffix: an identical payload can still be a
        // distinct row occurrence later in the paginated sequence.
        let merged = Array(existing.dropLast(overlap)) + newPage
        return (merged, reconciliation)
    }

    private static func appendItems(
        existing: [OfficialCapitalRaidSeason],
        newPage: [OfficialCapitalRaidSeason]
    ) -> (items: [OfficialCapitalRaidSeason], reconciliation: LoadMoreReconciliation) {
        var merged = existing
        for item in newPage where !merged.contains(item) {
            merged.append(item)
        }
        return (merged, .identityPreserving)
    }

    /// 是否应把该 overlap 当作 pagination boundary 更新（而非 append 新 occurrence）。
    private static func shouldApplyOverlapCandidate(
        existing: [OfficialCapitalRaidSeason],
        newPage: [OfficialCapitalRaidSeason],
        overlap: Int
    ) -> Bool {
        if newPage.count > overlap { return true }

        guard newPage.count == overlap else { return false }

        let suffix = Array(existing.suffix(overlap))
        if CapitalRaidSeasonMatcher.hasUniqueExactPayloadBoundaryAnchor(
            oldSeasons: existing,
            newSeasons: newPage,
            overlap: overlap
        ) {
            return true
        }
        for triple in Set(suffix.map(CapitalRaidRowIdentity.tripleKey(for:))) {
            let countInExisting = tripleOccurrenceCount(of: triple, in: existing)
            let countInSuffix = tripleOccurrenceCount(of: triple, in: suffix)
            if countInExisting != countInSuffix {
                return false
            }
        }
        return true
    }

    private static func tripleOccurrenceCount(
        of triple: String,
        in seasons: [OfficialCapitalRaidSeason]
    ) -> Int {
        seasons.reduce(into: 0) { count, season in
            if CapitalRaidRowIdentity.tripleKey(for: season) == triple {
                count += 1
            }
        }
    }

    /// suffix/prefix 是否为 pagination boundary overlap 候选（positional triple + 非页内重复模式）。
    private static func isPaginationOverlapCandidate(
        existing: [OfficialCapitalRaidSeason],
        newPage: [OfficialCapitalRaidSeason],
        overlap: Int
    ) -> Bool {
        guard overlap > 0 else { return false }
        guard hasPositionalTripleOverlap(existing: existing, newPage: newPage, overlap: overlap) else {
            return false
        }
        let priorEnd = existing.count - overlap
        guard priorEnd > 0 else { return false }
        if CapitalRaidSeasonMatcher.hasUniqueExactPayloadBoundaryAnchor(
            oldSeasons: existing,
            newSeasons: newPage,
            overlap: overlap
        ) {
            return true
        }
        let priorCounts = tripleKeyCounts(for: Array(existing.prefix(priorEnd)))
        let suffixCounts = tripleKeyCounts(for: Array(existing.suffix(overlap)))
        for (triple, suffixCount) in suffixCounts {
            if priorCounts[triple, default: 0] >= suffixCount {
                return false
            }
        }
        return true
    }

    private static func hasPositionalTripleOverlap(
        existing: [OfficialCapitalRaidSeason],
        newPage: [OfficialCapitalRaidSeason],
        overlap: Int
    ) -> Bool {
        guard overlap > 0 else { return false }
        for index in 0..<overlap {
            let existingIndex = existing.count - overlap + index
            if CapitalRaidRowIdentity.tripleKey(for: existing[existingIndex])
                != CapitalRaidRowIdentity.tripleKey(for: newPage[index]) {
                return false
            }
        }
        return true
    }

    private static func tripleKeyCounts(for seasons: [OfficialCapitalRaidSeason]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for season in seasons {
            let key = CapitalRaidRowIdentity.tripleKey(for: season)
            counts[key, default: 0] += 1
        }
        return counts
    }
}
