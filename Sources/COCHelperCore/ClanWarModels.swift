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
    /// 官方 battleModifier：hardMode / minusOne / minusTwo / minusThree / none / null。
    /// 保存原始值（不做本地枚举映射，与 state/result 契约一致）；
    /// "none" 与缺失均视为无规则（显示层见 `BattleModifierText`）。
    public let battleModifier: String?
    public let clan: ClanWarParticipant?
    public let opponent: ClanWarParticipant?

    // MARK: 审计
    public let unrecognizedKeys: [String]

    public init(
        state: String?, teamSize: Int?, attacksPerMember: Int?,
        preparationStartTime: String?, startTime: String?, endTime: String?,
        warStartTime: String?, battleModifier: String?,
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
        self.battleModifier = battleModifier
        self.clan = clan
        self.opponent = opponent
        self.unrecognizedKeys = unrecognizedKeys
    }

    // MARK: - Codable

    /// 官方 schema 中已知的顶层键。
    /// 注意 `battleModifier`：官方字段（Hard Mode 战争时为 "hardMode"，
    /// 否则 null/缺失），列入 knownKeys 避免有效响应被误报为"未识别字段"。
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
        battleModifier = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "battleModifier")!)
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
        try container.encodeIfPresent(battleModifier, forKey: key("battleModifier"))
        try container.encodeIfPresent(clan, forKey: key("clan"))
        try container.encodeIfPresent(opponent, forKey: key("opponent"))
        try container.encodeIfPresent(unrecognizedKeys, forKey: key("unrecognizedKeys"))
    }
}

/// 格式化层：battleModifier 的稳定中文映射（放 Core：currentwar 与 warlog
/// 两张卡片共用 + 可测；UI target 是 executable，无法被测试依赖）。
public enum BattleModifierText {
    /// nil / "none" / 空串 / 纯空白 → nil（UI 不显示）；hardMode→困难模式；minusOne→传奇杯 I；
    /// minusTwo→传奇杯 II；minusThree→传奇杯 III；未知非空 → 原样返回（可审计 fallback）。
    public static func localizedText(for raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        switch raw {
        case "none":
            return nil
        case "hardMode":
            return "困难模式"
        case "minusOne":
            return "传奇杯 I"
        case "minusTwo":
            return "传奇杯 II"
        case "minusThree":
            return "传奇杯 III"
        default:
            return raw
        }
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

/// 战争中的一次攻击（官方 ClanWarAttack）。
///
/// 全 optional + 合成 Codable：字段缺失不破坏解码。
public struct ClanWarAttack: Codable, Hashable, Sendable {
    /// 该成员本次战争中的攻击顺序（1 起）。
    public let order: Int?
    public let attackerTag: String?
    public let defenderTag: String?
    public let stars: Int?
    /// 摧毁百分比（官方可能返回浮点或整数，用 Double 容忍两者）。
    public let destructionPercentage: Double?
    /// 攻击时长（秒）。
    public let duration: Int?

    public init(
        order: Int?, attackerTag: String?, defenderTag: String?,
        stars: Int?, destructionPercentage: Double?, duration: Int?
    ) {
        self.order = order
        self.attackerTag = attackerTag
        self.defenderTag = defenderTag
        self.stars = stars
        self.destructionPercentage = destructionPercentage
        self.duration = duration
    }
}

/// currentwar / warlog 成员级攻击表条目（官方 ClanWarMember）。
///
/// 官方 schema 注意点（多个独立来源验证）：
/// - 大本等级字段名是 `townhallLevel`（小写 h，与 player 端点 townHallLevel 不同）
/// - `attacks` 是 ClanWarAttack **数组**（不是次数；次数 = attacks.count）
/// - `opponentAttacks` 是被攻击次数（整数）
/// - `bestOpponentAttack` 是最佳防守攻击（对象）
/// - 官方没有成员级 stars/destructionPercentage 顶层字段——成员表现从 attacks 聚合
/// - 全 optional + 合成 Codable：官方新增字段或个别字段缺失不破坏解码
public struct ClanWarMember: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    /// 地图位置（1 起）。
    public let mapPosition: Int?
    /// 大本等级（官方字段名 townhallLevel，小写 h）。
    public let townhallLevel: Int?
    /// 对敌方发起的攻击列表（次数 = count）。
    public let attacks: [ClanWarAttack]?
    /// 被攻击次数（整数）。
    public let opponentAttacks: Int?
    /// 最佳防守攻击（对象）。
    public let bestOpponentAttack: ClanWarAttack?

    public init(
        tag: String?, name: String?, mapPosition: Int?, townhallLevel: Int?,
        attacks: [ClanWarAttack]?, opponentAttacks: Int?, bestOpponentAttack: ClanWarAttack?
    ) {
        self.tag = tag
        self.name = name
        self.mapPosition = mapPosition
        self.townhallLevel = townhallLevel
        self.attacks = attacks
        self.opponentAttacks = opponentAttacks
        self.bestOpponentAttack = bestOpponentAttack
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
