import Foundation

/// 官方 `GET /v1/clans/{clanTag}/currentwar` 响应的解码模型。
///
/// 设计契约（与 `OfficialClanSnapshot` 一致）：
/// - 所有字段均为 optional：`notInWar`（无战争，200）与 `warEnded`
///   （战争已结束、部分字段缺失）都是合法成功响应。
/// - `state` 取值：notInWar / preparation / inWar / warEnded（官方字符串，
///   不做本地枚举映射，避免 schema 漂移时解码失败）。
/// - 时间字段保持官方 ISO 字符串（如 `20260804T080000.000Z`），首期不解析
///   为 Date（解析格式与容错留给有明确展示需求时）。
/// - `clan.members` / `opponent.members`（成员级攻击表）按 `ClanWarMember`
///   解码；缺失或字段不全均容忍。
/// - 顶层未知键收集进 `unrecognizedKeys` 供审计。
public struct OfficialClanWarSnapshot: Codable, Hashable, Sendable {
    public let state: String?
    /// 队伍规模（人数）。
    public let teamSize: Int?
    /// 每人攻击次数。
    public let attacksPerMember: Int?
    public let preparationStartTime: String?
    public let startTime: String?
    public let endTime: String?
    /// warEnded 状态下提供。
    public let warStartTime: String?
    public let clan: ClanWarParticipant?
    public let opponent: ClanWarParticipant?

    // MARK: 审计
    public let unrecognizedKeys: [String]

    public init(
        state: String?, teamSize: Int?, attacksPerMember: Int?,
        preparationStartTime: String?, startTime: String?, endTime: String?,
        warStartTime: String?,
        clan: ClanWarParticipant?, opponent: ClanWarParticipant?,
        unrecognizedKeys: [String]
    ) {
        self.state = state
        self.teamSize = teamSize
        self.attacksPerMember = attacksPerMember
        self.preparationStartTime = preparationStartTime
        self.startTime = startTime
        self.endTime = endTime
        self.warStartTime = warStartTime
        self.clan = clan
        self.opponent = opponent
        self.unrecognizedKeys = unrecognizedKeys
    }

    // MARK: - Codable

    /// 官方 schema 中已知的顶层键。
    /// 注意 `battleModifier`：官方字段（Hard Mode 战争时为 "hardMode"，
    /// 否则 null），已知但首期 deferred——不设属性（首期只做摘要展示），
    /// 列入 knownKeys 避免有效响应被误报为"未识别字段"。
    private static let knownKeys: Set<String> = [
        "state", "teamSize", "attacksPerMember",
        "preparationStartTime", "startTime", "endTime", "warStartTime",
        "battleModifier",
        "clan", "opponent",
        "unrecognizedKeys",
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SnapshotCodingKey.self)

        state = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "state")!)
        teamSize = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "teamSize")!)
        attacksPerMember = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "attacksPerMember")!)
        preparationStartTime = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "preparationStartTime")!)
        startTime = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "startTime")!)
        endTime = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "endTime")!)
        warStartTime = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "warStartTime")!)
        clan = try container.decodeIfPresent(ClanWarParticipant.self, forKey: .init(stringValue: "clan")!)
        opponent = try container.decodeIfPresent(ClanWarParticipant.self, forKey: .init(stringValue: "opponent")!)

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

        try container.encodeIfPresent(state, forKey: key("state"))
        try container.encodeIfPresent(teamSize, forKey: key("teamSize"))
        try container.encodeIfPresent(attacksPerMember, forKey: key("attacksPerMember"))
        try container.encodeIfPresent(preparationStartTime, forKey: key("preparationStartTime"))
        try container.encodeIfPresent(startTime, forKey: key("startTime"))
        try container.encodeIfPresent(endTime, forKey: key("endTime"))
        try container.encodeIfPresent(warStartTime, forKey: key("warStartTime"))
        try container.encodeIfPresent(clan, forKey: key("clan"))
        try container.encodeIfPresent(opponent, forKey: key("opponent"))
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

/// currentwar / warlog 成员级攻击表条目（官方 ClanWarMember）。
///
/// 全 optional + 合成 Codable：官方新增字段或个别字段缺失（如 warEnded
/// 后部分成员无攻击记录、大本等级缺失）不破坏解码；未知子字段
/// （如 opponentAttacks 逐次攻击明细）容忍忽略，不做属性声明（deferred）。
public struct ClanWarMember: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    /// 大本等级（战争结束/未开战时可能缺失）。
    public let townHallLevel: Int?
    /// 地图位置（1 起）。
    public let mapPosition: Int?
    /// 已使用攻击次数（成员可能 0 次攻击）。
    public let attacks: Int?
    public let stars: Int?
    /// 摧毁百分比（官方可能返回浮点或整数，用 Double 容忍两者）。
    public let destructionPercentage: Double?

    public init(
        tag: String?, name: String?, townHallLevel: Int?, mapPosition: Int?,
        attacks: Int?, stars: Int?, destructionPercentage: Double?
    ) {
        self.tag = tag
        self.name = name
        self.townHallLevel = townHallLevel
        self.mapPosition = mapPosition
        self.attacks = attacks
        self.stars = stars
        self.destructionPercentage = destructionPercentage
    }
}

/// 战争一方（己方/对方）的摘要，含成员级攻击表（缺失容忍）。
public struct ClanWarParticipant: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    public let badgeUrls: [String: String]?
    public let clanLevel: Int?
    public let attacks: Int?
    public let stars: Int?
    /// 摧毁百分比（官方可能返回浮点或整数，用 Double 容忍两者）。
    public let destructionPercentage: Double?
    /// 成员级攻击表（currentwar 双方 / warlog 每场战争；缺失容忍）。
    public let members: [ClanWarMember]?

    public init(
        tag: String?, name: String?, badgeUrls: [String: String]?,
        clanLevel: Int?, attacks: Int?, stars: Int?, destructionPercentage: Double?,
        members: [ClanWarMember]?
    ) {
        self.tag = tag
        self.name = name
        self.badgeUrls = badgeUrls
        self.clanLevel = clanLevel
        self.attacks = attacks
        self.stars = stars
        self.destructionPercentage = destructionPercentage
        self.members = members
    }
}
