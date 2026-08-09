import Foundation

/// 官方 `GET /v1/players/{playerTag}` 响应的解码模型。
///
/// 所有字段均为 optional：官方新增字段或个别字段缺失不会让整个快照解码失败
/// （验收标准）。顶层未识别键会被收集进 `unrecognizedKeys` 供审计；嵌套结构
/// 使用 Codable 合成，容忍未知子字段。
///
/// `unrecognizedKeys` 本身也参与编码：解码时若 JSON 中存在该键（即本模型
/// 自身编码的产物）则直接读取，否则从顶层未知键收集。
public struct OfficialPlayerSnapshot: Codable, Hashable, Sendable {
    // MARK: 身份与进度
    public let tag: String?
    public let name: String?
    public let townHallLevel: Int?
    public let townHallWeaponLevel: Int?
    /// 官方响应中 `townHallWeaponLevel` 键是否存在（Issue #75 工作流 B）。
    ///
    /// `decodeIfPresent` 无法区分"键缺失"与"显式 null"，此标记在持久化时
    /// 保留该区分：true = 官方写了该键（值为 null 表示官方显式声明无武器等级
    /// 维度，如 12–15 本移除等级后）；false = 官方未提供该字段。
    /// 注意：**不做任何按大本营等级推断"未建造/不适用"的逻辑**——12–15 本
    /// 武器保留但等级被官方移除，nil ≠ 未建造。
    public let townHallWeaponLevelKeyPresent: Bool
    public let builderHallLevel: Int?
    public let expLevel: Int?

    // MARK: 竞技状态
    public let trophies: Int?
    public let bestTrophies: Int?
    public let warStars: Int?
    public let attackWins: Int?
    public let defenseWins: Int?
    public let builderBaseTrophies: Int?
    public let versusBattleWins: Int?
    public let legendStatistics: LegendStatistics?

    // MARK: 社交与贡献
    public let clan: PlayerClan?
    public let role: String?
    public let warPreference: String?
    public let donations: Int?
    public let donationsReceived: Int?
    /// 玩家累计贡献给部落都城的都城金币数量。
    public let clanCapitalContributions: Int?

    // MARK: 联赛与成就
    public let league: PlayerLeague?
    public let builderBaseLeague: PlayerLeague?
    /// 2026 排位体系新增段位：官方 `/v1/players/{tag}` 响应 `leagueTier` 对象
    /// （形状与 `league` 相同：id/name/iconUrls）。旧响应无此键时解码为 nil。
    public let leagueTier: PlayerLeague?
    public let achievements: [PlayerAchievement]?
    public let labels: [PlayerLabel]?
    public let playerHouse: PlayerHouse?

    // MARK: 单位与装备
    public let troops: [PlayerItemLevel]?
    public let heroes: [PlayerItemLevel]?
    public let spells: [PlayerItemLevel]?
    public let heroEquipment: [PlayerItemLevel]?

    // MARK: 审计
    public let unrecognizedKeys: [String]

    public init(
        tag: String?, name: String?,
        townHallLevel: Int?, townHallWeaponLevel: Int?,
        townHallWeaponLevelKeyPresent: Bool = true, builderHallLevel: Int?, expLevel: Int?,
        trophies: Int?, bestTrophies: Int?, warStars: Int?, attackWins: Int?, defenseWins: Int?,
        builderBaseTrophies: Int?, versusBattleWins: Int?, legendStatistics: LegendStatistics?,
        clan: PlayerClan?, role: String?, warPreference: String?, donations: Int?,
        donationsReceived: Int?, clanCapitalContributions: Int?,
        league: PlayerLeague?, builderBaseLeague: PlayerLeague?, leagueTier: PlayerLeague? = nil,
        achievements: [PlayerAchievement]?,
        labels: [PlayerLabel]?, playerHouse: PlayerHouse?,
        troops: [PlayerItemLevel]?, heroes: [PlayerItemLevel]?, spells: [PlayerItemLevel]?,
        heroEquipment: [PlayerItemLevel]?,
        unrecognizedKeys: [String]
    ) {
        self.tag = tag
        self.name = name
        self.townHallLevel = townHallLevel
        self.townHallWeaponLevel = townHallWeaponLevel
        self.townHallWeaponLevelKeyPresent = townHallWeaponLevelKeyPresent
        self.builderHallLevel = builderHallLevel
        self.expLevel = expLevel
        self.trophies = trophies
        self.bestTrophies = bestTrophies
        self.warStars = warStars
        self.attackWins = attackWins
        self.defenseWins = defenseWins
        self.builderBaseTrophies = builderBaseTrophies
        self.versusBattleWins = versusBattleWins
        self.legendStatistics = legendStatistics
        self.clan = clan
        self.role = role
        self.warPreference = warPreference
        self.donations = donations
        self.donationsReceived = donationsReceived
        self.clanCapitalContributions = clanCapitalContributions
        self.league = league
        self.builderBaseLeague = builderBaseLeague
        self.leagueTier = leagueTier
        self.achievements = achievements
        self.labels = labels
        self.playerHouse = playerHouse
        self.troops = troops
        self.heroes = heroes
        self.spells = spells
        self.heroEquipment = heroEquipment
        self.unrecognizedKeys = unrecognizedKeys
    }

    // MARK: - Codable

    private static let knownKeys: Set<String> = [
        "tag", "name", "townHallLevel", "townHallWeaponLevel",
        "townHallWeaponLevelKeyPresent", "builderHallLevel", "expLevel",
        "trophies", "bestTrophies", "warStars", "attackWins", "defenseWins",
        "builderBaseTrophies", "versusBattleWins", "legendStatistics",
        "clan", "role", "warPreference", "donations", "donationsReceived", "clanCapitalContributions",
        "league", "builderBaseLeague", "leagueTier", "achievements", "labels", "playerHouse",
        "troops", "heroes", "spells", "heroEquipment",
        "unrecognizedKeys",
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SnapshotCodingKey.self)

        tag = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "tag")!)
        name = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "name")!)
        townHallLevel = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "townHallLevel")!)
        townHallWeaponLevel = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "townHallWeaponLevel")!)
        // 三态键存在性（Issue #75 工作流 B）：
        // 1. 有 marker 键（本模型 0.2+ 编码产物）→ 直接采用；
        // 2. 无 marker 但有 unrecognizedKeys 键（旧版 0.1 编码产物恒写该键）→
        //    S2 策略：默认 true，旧 nil 还原为"API 显式 null"语义（升级零过渡噪音）；
        // 3. 其余为官方原始 JSON → presence = 武器键是否真实存在于响应
        //    （数据驱动，不做任何按大本营等级的推断）。
        if let marker = try container.decodeIfPresent(Bool.self, forKey: .init(stringValue: "townHallWeaponLevelKeyPresent")!) {
            townHallWeaponLevelKeyPresent = marker
        } else if container.contains(.init(stringValue: "unrecognizedKeys")!) {
            townHallWeaponLevelKeyPresent = true
        } else {
            townHallWeaponLevelKeyPresent = container.contains(.init(stringValue: "townHallWeaponLevel")!)
        }
        builderHallLevel = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "builderHallLevel")!)
        expLevel = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "expLevel")!)
        trophies = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "trophies")!)
        bestTrophies = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "bestTrophies")!)
        warStars = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "warStars")!)
        attackWins = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "attackWins")!)
        defenseWins = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "defenseWins")!)
        builderBaseTrophies = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "builderBaseTrophies")!)
        versusBattleWins = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "versusBattleWins")!)
        legendStatistics = try container.decodeIfPresent(LegendStatistics.self, forKey: .init(stringValue: "legendStatistics")!)
        clan = try container.decodeIfPresent(PlayerClan.self, forKey: .init(stringValue: "clan")!)
        role = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "role")!)
        warPreference = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "warPreference")!)
        donations = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "donations")!)
        donationsReceived = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "donationsReceived")!)
        clanCapitalContributions = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "clanCapitalContributions")!)
        league = try container.decodeIfPresent(PlayerLeague.self, forKey: .init(stringValue: "league")!)
        builderBaseLeague = try container.decodeIfPresent(PlayerLeague.self, forKey: .init(stringValue: "builderBaseLeague")!)
        leagueTier = try container.decodeIfPresent(PlayerLeague.self, forKey: .init(stringValue: "leagueTier")!)
        achievements = try container.decodeIfPresent([PlayerAchievement].self, forKey: .init(stringValue: "achievements")!)
        labels = try container.decodeIfPresent([PlayerLabel].self, forKey: .init(stringValue: "labels")!)
        playerHouse = try container.decodeIfPresent(PlayerHouse.self, forKey: .init(stringValue: "playerHouse")!)
        troops = try container.decodeIfPresent([PlayerItemLevel].self, forKey: .init(stringValue: "troops")!)
        heroes = try container.decodeIfPresent([PlayerItemLevel].self, forKey: .init(stringValue: "heroes")!)
        spells = try container.decodeIfPresent([PlayerItemLevel].self, forKey: .init(stringValue: "spells")!)
        heroEquipment = try container.decodeIfPresent([PlayerItemLevel].self, forKey: .init(stringValue: "heroEquipment")!)

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
        try container.encodeIfPresent(townHallLevel, forKey: key("townHallLevel"))
        // marker 恒写（Issue #75 工作流 B 核心契约）：
        // - presence=true 且 value 非 nil → 写等级
        // - presence=true 且 value nil → 写显式 null（保留官方语义）
        // - presence=false → 不写武器键（保持缺失）
        try container.encode(townHallWeaponLevelKeyPresent, forKey: key("townHallWeaponLevelKeyPresent"))
        if townHallWeaponLevelKeyPresent {
            if let townHallWeaponLevel {
                try container.encode(townHallWeaponLevel, forKey: key("townHallWeaponLevel"))
            } else {
                try container.encodeNil(forKey: key("townHallWeaponLevel"))
            }
        }
        try container.encodeIfPresent(builderHallLevel, forKey: key("builderHallLevel"))
        try container.encodeIfPresent(expLevel, forKey: key("expLevel"))
        try container.encodeIfPresent(trophies, forKey: key("trophies"))
        try container.encodeIfPresent(bestTrophies, forKey: key("bestTrophies"))
        try container.encodeIfPresent(warStars, forKey: key("warStars"))
        try container.encodeIfPresent(attackWins, forKey: key("attackWins"))
        try container.encodeIfPresent(defenseWins, forKey: key("defenseWins"))
        try container.encodeIfPresent(builderBaseTrophies, forKey: key("builderBaseTrophies"))
        try container.encodeIfPresent(versusBattleWins, forKey: key("versusBattleWins"))
        try container.encodeIfPresent(legendStatistics, forKey: key("legendStatistics"))
        try container.encodeIfPresent(clan, forKey: key("clan"))
        try container.encodeIfPresent(role, forKey: key("role"))
        try container.encodeIfPresent(warPreference, forKey: key("warPreference"))
        try container.encodeIfPresent(donations, forKey: key("donations"))
        try container.encodeIfPresent(donationsReceived, forKey: key("donationsReceived"))
        try container.encodeIfPresent(clanCapitalContributions, forKey: key("clanCapitalContributions"))
        try container.encodeIfPresent(league, forKey: key("league"))
        try container.encodeIfPresent(builderBaseLeague, forKey: key("builderBaseLeague"))
        try container.encodeIfPresent(leagueTier, forKey: key("leagueTier"))
        try container.encodeIfPresent(achievements, forKey: key("achievements"))
        try container.encodeIfPresent(labels, forKey: key("labels"))
        try container.encodeIfPresent(playerHouse, forKey: key("playerHouse"))
        try container.encodeIfPresent(troops, forKey: key("troops"))
        try container.encodeIfPresent(heroes, forKey: key("heroes"))
        try container.encodeIfPresent(spells, forKey: key("spells"))
        try container.encodeIfPresent(heroEquipment, forKey: key("heroEquipment"))
        try container.encodeIfPresent(unrecognizedKeys, forKey: key("unrecognizedKeys"))
    }
}

/// 大本营武器等级的显示三态（Issue #75 工作流 B）。
///
/// 数据驱动，**不做任何按大本营等级（townHallLevel）的推断**：12–15 本武器
/// 保留但等级被官方移除（API 返回 null）≠ 未建造，因此不在此处产生
/// "未建造/不适用"文案——UI 对 `notApplicable` 的处理是隐藏整行。
public enum TownHallWeaponLevelDisplayState: Equatable, Hashable, Sendable {
    /// 官方提供有效等级。
    case level(Int)
    /// 官方显式 null：无武器等级维度（UI 隐藏整行）。
    case notApplicable
    /// 官方未提供该字段（键缺失）。
    case notProvided
}

extension OfficialPlayerSnapshot {
    public var townHallWeaponLevelDisplayState: TownHallWeaponLevelDisplayState {
        if let townHallWeaponLevel { return .level(townHallWeaponLevel) }
        return townHallWeaponLevelKeyPresent ? .notApplicable : .notProvided
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

public struct LegendStatistics: Codable, Hashable, Sendable {
    public let legendTrophies: Int?
    public let bestSeason: LegendSeason?
    public let previousSeason: LegendSeason?
    public let bestVersusSeason: LegendSeason?
    public let currentSeason: LegendSeason?

    public init(
        legendTrophies: Int?, bestSeason: LegendSeason?, previousSeason: LegendSeason?,
        bestVersusSeason: LegendSeason?, currentSeason: LegendSeason?
    ) {
        self.legendTrophies = legendTrophies
        self.bestSeason = bestSeason
        self.previousSeason = previousSeason
        self.bestVersusSeason = bestVersusSeason
        self.currentSeason = currentSeason
    }
}

public struct LegendSeason: Codable, Hashable, Sendable {
    public let id: String?
    public let rank: Int?
    public let trophies: Int?

    public init(id: String?, rank: Int?, trophies: Int?) {
        self.id = id
        self.rank = rank
        self.trophies = trophies
    }
}

public struct PlayerClan: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    public let clanLevel: Int?
    public let badgeUrls: [String: String]?

    public init(tag: String?, name: String?, clanLevel: Int?, badgeUrls: [String: String]?) {
        self.tag = tag
        self.name = name
        self.clanLevel = clanLevel
        self.badgeUrls = badgeUrls
    }
}

public struct PlayerLeague: Codable, Hashable, Sendable {
    public let id: Int?
    public let name: String?
    public let iconUrls: [String: String]?

    public init(id: Int?, name: String?, iconUrls: [String: String]?) {
        self.id = id
        self.name = name
        self.iconUrls = iconUrls
    }
}

public struct PlayerAchievement: Codable, Hashable, Sendable {
    public let name: String?
    public let stars: Int?
    public let value: Int?
    public let target: Int?
    public let info: String?
    public let completionInfo: String?
    public let village: String?

    public init(
        name: String?, stars: Int?, value: Int?, target: Int?,
        info: String?, completionInfo: String?, village: String?
    ) {
        self.name = name
        self.stars = stars
        self.value = value
        self.target = target
        self.info = info
        self.completionInfo = completionInfo
        self.village = village
    }
}

public struct PlayerLabel: Codable, Hashable, Sendable {
    public let id: Int?
    public let name: String?
    public let iconUrls: [String: String]?

    public init(id: Int?, name: String?, iconUrls: [String: String]?) {
        self.id = id
        self.name = name
        self.iconUrls = iconUrls
    }
}

public struct PlayerHouse: Codable, Hashable, Sendable {
    /// optional：官方可能返回空对象（`{"playerHouse":{}}`），此时视为部分字段缺失而非 malformed。
    public let elements: [PlayerHouseElement]?

    public init(elements: [PlayerHouseElement]?) {
        self.elements = elements
    }
}

public struct PlayerHouseElement: Codable, Hashable, Sendable {
    public let id: Int?
    public let type: String?
    public let level: Int?

    public init(id: Int?, type: String?, level: Int?) {
        self.id = id
        self.type = type
        self.level = level
    }
}

public struct PlayerItemLevel: Codable, Hashable, Sendable {
    public let name: String?
    public let level: Int?
    public let maxLevel: Int?
    public let village: String?
    public let superTroopIsActive: Bool?

    public init(name: String?, level: Int?, maxLevel: Int?, village: String?, superTroopIsActive: Bool?) {
        self.name = name
        self.level = level
        self.maxLevel = maxLevel
        self.village = village
        self.superTroopIsActive = superTroopIsActive
    }
}
