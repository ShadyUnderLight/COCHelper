import Foundation

/// 战争中的一次攻击明细行（逐次攻击，与官方数组一一对应）。
///
/// 契约：**摧毁率永不累加**——`destructionPercentage` 原样保留（含 nil），
/// 投影层绝不产出任何聚合百分比（如 100% + 80% = 180% 的旧 bug）。
public struct ClanWarAttackLine: Hashable, Sendable {
    /// 攻击顺序（1 起）；nil = 缺失。
    public let order: Int?
    /// 星数；nil = 缺失。
    public let stars: Int?
    /// 摧毁百分比；nil = 缺失（不得用 0 顶替）。
    public let destructionPercentage: Double?

    public init(order: Int? = nil, stars: Int? = nil, destructionPercentage: Double? = nil) {
        self.order = order
        self.stars = stars
        self.destructionPercentage = destructionPercentage
    }
}

/// 单个成员的战争攻击汇总。
public struct ClanWarMemberSummary: Hashable, Sendable {
    /// 攻击次数（= 输入 attacks 条数）。
    public let attackCount: Int
    /// 星数总和（缺失星数记 0，锁定旧语义）。
    public let totalStars: Int
    /// 逐次攻击明细，与输入一一对应、保持官方顺序。
    public let lines: [ClanWarAttackLine]

    public init(attackCount: Int, totalStars: Int, lines: [ClanWarAttackLine]) {
        self.attackCount = attackCount
        self.totalStars = totalStars
        self.lines = lines
    }
}

/// 突袭日志中的单个子城明细行（与官方 districts 数组一一对应）。
///
/// 契约：**摧毁率永不累加**——`destructionPercent` 原样保留（含 nil）。
public struct CapitalRaidDistrictLine: Hashable, Sendable {
    /// 子城名；nil = 缺失。
    public let name: String?
    /// 星数；nil = 缺失。
    public let stars: Int?
    /// 摧毁百分比；nil = 缺失（不得用 0 顶替）。
    public let destructionPercent: Double?
    /// 攻击次数；nil = 缺失。
    public let attackCount: Int?
    /// 掠夺的都城金币；nil = 缺失。
    public let totalLooted: Int?

    public init(name: String? = nil, stars: Int? = nil, destructionPercent: Double? = nil,
                attackCount: Int? = nil, totalLooted: Int? = nil) {
        self.name = name
        self.stars = stars
        self.destructionPercent = destructionPercent
        self.attackCount = attackCount
        self.totalLooted = totalLooted
    }
}

/// 突袭季日志的子城汇总。
public struct CapitalRaidDistrictSummary: Hashable, Sendable {
    /// 子城明细，与输入一一对应、保持官方顺序。
    public let districts: [CapitalRaidDistrictLine]
    /// 掠夺金币总和（缺失记 0）。
    public let totalLooted: Int

    public init(districts: [CapitalRaidDistrictLine], totalLooted: Int) {
        self.districts = districts
        self.totalLooted = totalLooted
    }
}

/// 战争/突袭聚合投影入口。纯函数，不改变任何现有模型/持久化语义。
///
/// 核心契约：百分比字段（destructionPercentage / destructionPercent）**永不累加**，
/// 一律逐行保留；仅星数、金币、次数这类可加总量参与聚合。
public enum ClanCombatSummary {
    /// 将百分比夹在 [0, 100]；非有限值（NaN/Inf）防御为 0。
    public static func clampedPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    /// 聚合成员战争攻击：逐次攻击明细原样保留，星数求和。
    public static func warMember(attacks: [ClanWarAttack]) -> ClanWarMemberSummary {
        ClanWarMemberSummary(
            attackCount: attacks.count,
            totalStars: attacks.reduce(0) { $0 + ($1.stars ?? 0) },
            lines: attacks.map {
                ClanWarAttackLine(
                    order: $0.order,
                    stars: $0.stars,
                    destructionPercentage: $0.destructionPercentage
                )
            }
        )
    }

    /// 聚合突袭子城：逐子城明细原样保留，掠夺金币求和。
    public static func raidDistricts(_ districts: [CapitalRaidDistrict]) -> CapitalRaidDistrictSummary {
        CapitalRaidDistrictSummary(
            districts: districts.map {
                CapitalRaidDistrictLine(
                    name: $0.name,
                    stars: $0.stars,
                    destructionPercent: $0.destructionPercent,
                    attackCount: $0.attackCount,
                    totalLooted: $0.totalLooted
                )
            },
            totalLooted: districts.reduce(0) { $0 + ($1.totalLooted ?? 0) }
        )
    }
}
