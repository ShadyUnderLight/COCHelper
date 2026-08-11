import Foundation

/// 官方 `GET /v1/clans/{clanTag}` 响应的解码模型。
///
/// 设计契约（与 `OfficialPlayerSnapshot` 一致）：
/// - 所有字段均为 optional：官方新增字段或个别字段缺失不会让整个快照解码失败。
/// - `memberList` 是官方字段但首期**显式 deferred**（不解析成员明细，避免
///   为逐成员展示延伸出 N+1 请求）：它属于 `knownKeys`，不会进入
///   `unrecognizedKeys` 审计，但也不设属性——需要完整成员资料时另开 issue。
/// - 顶层未知键收集进 `unrecognizedKeys` 供审计；嵌套结构使用 Codable 合成，
///   容忍未知子字段。
/// - `unrecognizedKeys` 本身参与编码：解码时若 JSON 中存在该键（即本模型
///   自身编码的产物）则直接读取，否则从顶层未知键收集。
public struct OfficialClanSnapshot: Codable, Hashable, Sendable {
    // MARK: 身份
    public let tag: String?
    public let name: String?
    /// 部落类型：open / inviteOnly / closed（官方字符串，不做本地枚举映射）。
    public let type: String?
    public let description: String?
    public let clanLevel: Int?
    public let badgeUrls: [String: String]?

    // MARK: 规模与要求
    public let members: Int?
    public let requiredTrophies: Int?
    /// 官方 raw key 是 `requiredTownhallLevel`（Hall 的 H 为小写）。
    /// Swift 属性保留既有 `requiredTownHallLevel` 名称，兼容现有调用方。
    public let requiredTownHallLevel: Int?
    public let requiredBuilderBaseTrophies: Int?
    public let requiredLeagueTier: ClanLeagueTier?

    // MARK: 积分与联赛
    public let clanBuilderBasePoints: Int?
    /// 部落的都城奖杯数量。
    public let clanCapitalPoints: Int?
    /// 部落都城联赛。
    public let capitalLeague: ClanLeague?
    /// 部落当前 CWL 联赛（官方 raw key `warLeague`，对象形状 {id, name}）。
    public let warLeague: ClanLeague?

    // MARK: 战争记录概览
    public let warWins: Int?
    public let warLosses: Int?
    public let warTies: Int?
    public let warWinStreak: Int?
    /// false = 战争日志不公开（3c 处理 warlog 时依赖此字段做显式不可用状态）。
    public let isWarLogPublic: Bool?

    // MARK: 标签与都城概览
    public let labels: [ClanLabel]?
    public let clanCapital: ClanCapital?

    // MARK: 审计
    public let unrecognizedKeys: [String]

    public init(
        tag: String?, name: String?, type: String?, description: String?,
        clanLevel: Int?, badgeUrls: [String: String]?,
        members: Int?, requiredTrophies: Int?, requiredTownHallLevel: Int?,
        warWins: Int?, warLosses: Int?, warTies: Int?, warWinStreak: Int?,
        isWarLogPublic: Bool?,
        labels: [ClanLabel]?, clanCapital: ClanCapital?,
        unrecognizedKeys: [String],
        requiredBuilderBaseTrophies: Int? = nil,
        requiredLeagueTier: ClanLeagueTier? = nil,
        clanBuilderBasePoints: Int? = nil,
        clanCapitalPoints: Int? = nil,
        capitalLeague: ClanLeague? = nil,
        warLeague: ClanLeague? = nil
    ) {
        self.tag = tag
        self.name = name
        self.type = type
        self.description = description
        self.clanLevel = clanLevel
        self.badgeUrls = badgeUrls
        self.members = members
        self.requiredTrophies = requiredTrophies
        self.requiredTownHallLevel = requiredTownHallLevel
        self.requiredBuilderBaseTrophies = requiredBuilderBaseTrophies
        self.requiredLeagueTier = requiredLeagueTier
        self.clanBuilderBasePoints = clanBuilderBasePoints
        self.clanCapitalPoints = clanCapitalPoints
        self.capitalLeague = capitalLeague
        self.warLeague = warLeague
        self.warWins = warWins
        self.warLosses = warLosses
        self.warTies = warTies
        self.warWinStreak = warWinStreak
        self.isWarLogPublic = isWarLogPublic
        self.labels = labels
        self.clanCapital = clanCapital
        self.unrecognizedKeys = unrecognizedKeys
    }

    // MARK: - Codable

    /// 官方 schema 中已知的顶层键。
    /// 注意 `memberList`：已知但首期不解析（deferred），列入此处避免审计噪音。
    private static let knownKeys: Set<String> = [
        "tag", "name", "type", "description", "clanLevel",
        "clanPoints", "clanVersusPoints", "requiredTrophies", "requiredTownhallLevel",
        // 旧版本曾错误地按 Swift 属性名编码，继续作为兼容别名接受。
        "requiredTownHallLevel", "requiredBuilderBaseTrophies", "requiredLeagueTier",
        "clanBuilderBasePoints", "clanCapitalPoints", "capitalLeague",
        "warFrequency", "warWinStreak", "warWins", "warTies", "warLosses",
        "isWarLogPublic", "warLeague", "members", "memberList", "labels",
        "requiredVersusTrophies", "chatLanguage", "clanCapital",
        "badgeUrls", "location", "isFamilyFriendly",
        "unrecognizedKeys",
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SnapshotCodingKey.self)

        tag = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "tag")!)
        name = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "name")!)
        type = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "type")!)
        description = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "description")!)
        clanLevel = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "clanLevel")!)
        badgeUrls = try container.decodeIfPresent([String: String].self, forKey: .init(stringValue: "badgeUrls")!)
        members = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "members")!)
        requiredTrophies = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "requiredTrophies")!)
        requiredTownHallLevel = try (
            container.decodeIfPresent(
                Int.self,
                forKey: .init(stringValue: "requiredTownhallLevel")!
            ) ?? container.decodeIfPresent(
                Int.self,
                forKey: .init(stringValue: "requiredTownHallLevel")!
            )
        )
        requiredBuilderBaseTrophies = try container.decodeIfPresent(
            Int.self, forKey: .init(stringValue: "requiredBuilderBaseTrophies")!
        )
        requiredLeagueTier = try container.decodeIfPresent(
            ClanLeagueTier.self, forKey: .init(stringValue: "requiredLeagueTier")!
        )
        clanBuilderBasePoints = try container.decodeIfPresent(
            Int.self, forKey: .init(stringValue: "clanBuilderBasePoints")!
        )
        clanCapitalPoints = try container.decodeIfPresent(
            Int.self, forKey: .init(stringValue: "clanCapitalPoints")!
        )
        capitalLeague = try container.decodeIfPresent(
            ClanLeague.self, forKey: .init(stringValue: "capitalLeague")!
        )
        warLeague = try container.decodeIfPresent(
            ClanLeague.self, forKey: .init(stringValue: "warLeague")!
        )
        warWins = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "warWins")!)
        warLosses = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "warLosses")!)
        warTies = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "warTies")!)
        warWinStreak = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "warWinStreak")!)
        isWarLogPublic = try container.decodeIfPresent(Bool.self, forKey: .init(stringValue: "isWarLogPublic")!)
        labels = try container.decodeIfPresent([ClanLabel].self, forKey: .init(stringValue: "labels")!)
        clanCapital = try container.decodeIfPresent(ClanCapital.self, forKey: .init(stringValue: "clanCapital")!)

        if let storedKeys = try container.decodeIfPresent([String].self, forKey: .init(stringValue: "unrecognizedKeys")!) {
            unrecognizedKeys = storedKeys.sorted()
        } else {
            unrecognizedKeys = container.allKeys
                .map(\.stringValue)
                .filter { !Self.knownKeys.contains($0) }
                .sorted()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SnapshotCodingKey.self)
        let key = { SnapshotCodingKey(stringValue: $0)! }

        try container.encodeIfPresent(tag, forKey: key("tag"))
        try container.encodeIfPresent(name, forKey: key("name"))
        try container.encodeIfPresent(type, forKey: key("type"))
        try container.encodeIfPresent(description, forKey: key("description"))
        try container.encodeIfPresent(clanLevel, forKey: key("clanLevel"))
        try container.encodeIfPresent(badgeUrls, forKey: key("badgeUrls"))
        try container.encodeIfPresent(members, forKey: key("members"))
        try container.encodeIfPresent(requiredTrophies, forKey: key("requiredTrophies"))
        // 只写官方 raw key；旧的 Swift 属性名仅用于源码兼容。
        try container.encodeIfPresent(requiredTownHallLevel, forKey: key("requiredTownhallLevel"))
        try container.encodeIfPresent(requiredBuilderBaseTrophies, forKey: key("requiredBuilderBaseTrophies"))
        try container.encodeIfPresent(requiredLeagueTier, forKey: key("requiredLeagueTier"))
        try container.encodeIfPresent(clanBuilderBasePoints, forKey: key("clanBuilderBasePoints"))
        try container.encodeIfPresent(clanCapitalPoints, forKey: key("clanCapitalPoints"))
        try container.encodeIfPresent(capitalLeague, forKey: key("capitalLeague"))
        try container.encodeIfPresent(warLeague, forKey: key("warLeague"))
        try container.encodeIfPresent(warWins, forKey: key("warWins"))
        try container.encodeIfPresent(warLosses, forKey: key("warLosses"))
        try container.encodeIfPresent(warTies, forKey: key("warTies"))
        try container.encodeIfPresent(warWinStreak, forKey: key("warWinStreak"))
        try container.encodeIfPresent(isWarLogPublic, forKey: key("isWarLogPublic"))
        try container.encodeIfPresent(labels, forKey: key("labels"))
        try container.encodeIfPresent(clanCapital, forKey: key("clanCapital"))
        try container.encodeIfPresent(unrecognizedKeys, forKey: key("unrecognizedKeys"))
    }
}

/// 任意字符串均可构造的 CodingKey：让顶层解码能遍历到所有 JSON 键。
private struct SnapshotCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

// MARK: - 嵌套结构

public struct ClanCapital: Codable, Hashable, Sendable {
    /// 都城大本营等级（部落都城相关概览，首期只展示这一项）。
    public let capitalHallLevel: Int?

    public init(capitalHallLevel: Int?) {
        self.capitalHallLevel = capitalHallLevel
    }
}

/// 部落都城联赛引用（如 `capitalLeague`）。
///
/// 官方可能在该嵌套对象中增加图标等字段；合成 Codable 会忽略未知子字段，
/// 不影响顶层字段审计。
public struct ClanLeague: Codable, Hashable, Sendable {
    public let id: Int?
    public let name: String?

    public init(id: Int?, name: String?) {
        self.id = id
        self.name = name
    }
}

/// 部落加入所需的联赛等级引用。
///
/// 官方响应返回对象（`id/name/iconUrls`）；自定义解码同时接受上一版
/// 本地模型可能写出的整数，避免升级后旧缓存因字段形状变化而整条失效。
public struct ClanLeagueTier: Codable, Hashable, Sendable {
    public let id: Int?
    public let name: String?
    public let iconUrls: [String: String]?

    public init(id: Int?, name: String?, iconUrls: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.iconUrls = iconUrls
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case iconUrls
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            id = try container.decodeIfPresent(Int.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            iconUrls = try container.decodeIfPresent([String: String].self, forKey: .iconUrls)
            return
        }

        let container = try decoder.singleValueContainer()
        id = try container.decodeNil() ? nil : container.decode(Int.self)
        name = nil
        iconUrls = nil
    }
}

public struct ClanLabel: Codable, Hashable, Sendable {
    public let id: Int?
    public let name: String?

    public init(id: Int?, name: String?) {
        self.id = id
        self.name = name
    }
}
