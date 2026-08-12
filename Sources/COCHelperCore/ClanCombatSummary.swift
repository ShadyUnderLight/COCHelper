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
    /// 目标 tag（官方 defenderTag 透传）；nil = 缺失。warlog/currentwar 共用
    /// 类型：warlog 调用点不消费该字段（Issue #127 扩展，默认 nil 向后兼容）。
    public let defenderTag: String?
    /// 攻击时长（秒，官方透传）；nil = 缺失。展示格式见 `ClanCombatSummary.durationText`。
    public let duration: Int?

    public init(order: Int? = nil, stars: Int? = nil, destructionPercentage: Double? = nil,
                defenderTag: String? = nil, duration: Int? = nil) {
        self.order = order
        self.stars = stars
        self.destructionPercentage = destructionPercentage
        self.defenderTag = defenderTag
        self.duration = duration
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
    /// 数值兜底：将百分比夹在 [0, 100]；非有限值（NaN/Inf）→ 0。
    /// 仅供算术兜底，**不得直接用于渲染**——显示层必须走 `displayDestructionPercent`，
    /// 否则 NaN/Inf 会被伪装成 0%。
    public static func clampedPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    /// 摧毁率展示值：nil 或非有限（NaN/±Inf）→ nil（未知，调用方显示"摧毁率未知"/省略）；
    /// 有限值钳制到 [0, 100]。显示层一律走本函数，禁止直接用 clampedPercent 渲染。
    public static func displayDestructionPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    /// 攻击时长展示文本（分:秒，如 145 → "2:25"）；nil 或负值 → nil（未知）。
    /// 不伪造时长；超长值（如 Int.max）分钟数直接大字面量，无算术风险。
    public static func durationText(_ duration: Int?) -> String? {
        guard let duration, duration >= 0 else { return nil }
        let minutes = duration / 60
        let seconds = duration % 60
        return "\(minutes):" + String(format: "%02d", seconds)
    }

    /// 百分比文本（摧毁率展示单一来源，Core 版）：整数无小数，非整数 1 位小数。
    /// 固定 en_US_POSIX（`String(format:)` 默认随系统区域，某些区域小数点变逗号）。
    /// 防御：超出 Int 可表示范围的 Double 走 %.1f 分支（不 trap）。
    /// 注：app target 的 `ClanDisplayFormat.percent` 是另一份拷贝（既有先例：
    /// WarLogCardView.percent），Core 内一律用本函数保证单一来源。
    public static func percentText(_ value: Double) -> String {
        guard value < Double(Int.max), value >= Double(Int.min) else {
            return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), arguments: [value])
        }
        return value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), arguments: [value])
    }

    /// 已摧毁子城数：官方字段优先（0 也是官方事实）；缺失时从子城明细推导。
    /// 只有全部子城摧毁率已知（有限）才返回确切计数（含 0）；
    /// 任一子城摧毁率未知（nil/NaN/Inf）→ nil（调用方省略分句，绝不编造或低估）。
    public static func destroyedDistrictCount(
        districtsDestroyed: Int?, districts: [CapitalRaidDistrict]
    ) -> Int? {
        if let districtsDestroyed { return districtsDestroyed }
        guard !districts.isEmpty else { return nil }
        let percents = districts.map { displayDestructionPercent($0.destructionPercent) }
        guard percents.allSatisfy({ $0 != nil }) else { return nil }
        return percents.compactMap { $0 }.filter { $0 >= 100 }.count
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
