import Foundation
import COCHelperCore

/// 部落展示格式化（Issue #48 Step A 审查修复）：ClanCardView 与添加预览
/// 共用，保证徽章安全规则与类型译文**单一来源**（此前两处各自实现，
/// 译文不一致且安全 allowlist 有复制漂移风险）。
///
/// 本类型位于 App 层（COCHelperApp）：格式化是 UI 职责，且测试 target
/// 依赖 COCHelperApp 可直接 @testable 验证（Issue #71 Task 3）。
public enum ClanDisplayFormat {
    /// 徽章 URL 安全：仅加载官方 https 图片域名，防止异常数据注入其他
    /// 协议/域名（AsyncImage 会跟随重定向，allowlist 是纵深防御）。
    public static func badgeURL(_ snapshot: OfficialClanSnapshot) -> URL? {
        guard let string = snapshot.badgeUrls?["medium"] ?? snapshot.badgeUrls?["small"],
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              host == "clashofclans.com" || host.hasSuffix(".clashofclans.com") else {
            return nil
        }
        return url
    }

    /// 部落类型中文（官方字符串 open / inviteOnly / closed → 官方简中语义）。
    public static func typeLabel(_ raw: String) -> String {
        switch raw {
        case "open": "任何人都可加入"
        case "inviteOnly": "只有被批准才能加入"
        case "closed": "不可加入"
        default: "未知"
        }
    }

    /// 将内部来源标识转换成用户可读文案；原始标识只保留在状态模型中。
    public static func sourceLabel(_ raw: String?) -> String? {
        switch raw {
        case "official-api": "官方 API 数据"
        case "cached-official-api": "缓存的官方 API 数据"
        default: nil
        }
    }

    /// 玩家主村联赛：按稳定 API ID 本地化，不依赖官方返回的英文 name。
    public static func playerLeagueLabel(_ league: PlayerLeague?) -> String? {
        leagueLabel(id: league?.id, name: league?.name, kind: .home)
    }

    /// 建筑大师基地联赛：按稳定 API ID 本地化。
    public static func builderBaseLeagueLabel(_ league: PlayerLeague?) -> String? {
        leagueLabel(id: league?.id, name: league?.name, kind: .builderBase)
    }

    /// 部落都城联赛：按稳定 API ID 本地化。
    public static func capitalLeagueLabel(_ league: ClanLeague?) -> String? {
        leagueLabel(id: league?.id, name: league?.name, kind: .capital)
    }

    /// 部落当前 CWL 联赛（warLeague）：按稳定 API ID 本地化。
    /// 与 capitalLeagueLabel（都城联赛）语义严格区分，UI 文案不得互相回显。
    public static func warLeagueLabel(_ league: ClanLeague?) -> String? {
        leagueLabel(id: league?.id, name: league?.name, kind: .war)
    }

    /// 入会所需联赛等级：按稳定 API ID 本地化。
    public static func requiredLeagueTierLabel(_ tier: ClanLeagueTier?) -> String? {
        leagueLabel(id: tier?.id, name: tier?.name, kind: .requiredTier)
    }

    /// 目录资源标识 → 官方简中资源名。未知值不直接泄漏英文标识。
    /// 委托 Core 的 `CatalogResourceLocalization`（纯函数，可单元测试；
    /// 矿石映射 CommonOre/RareOre/EpicOre → 官方简中，Issue #73 Task 3）。
    /// public：跨模块（COCHelper executable）调用必需（Issue #71 移层）。
    public static func resourceLabel(_ raw: String?) -> String {
        CatalogResourceLocalization.label(raw)
    }

    /// 多资源升级费用展示（Issue #73 Task 3 三分支，LevelDetailSheet 与
    /// BuildingUpgradeStepGrid 共用，单一来源）：
    /// - `upgradeCosts` 为 nil 或空 → "无费用数据"
    /// - 全部成功 → 每项「资源 千分位金额」，多项用 " · " 连接
    ///   （如 "闪亮矿石 120 · 璀璨矿石 40"）
    /// - 含 parseFailed → 成功项正常显示；失败项显示 raw 原文
    ///   （如 "金币（金额: "forty"）"），整段前缀「已知费用：」作警示语义
    ///   （与 BuildingGroupSummaryView 的 partialMissing 前缀同规则）
    /// 金额 0 是真实费用，正常显示（0 不视为缺失）。
    public static func upgradeCostLabel(_ costs: [CatalogUpgradeCost]?) -> String {
        guard let costs, !costs.isEmpty else { return "无费用数据" }
        var parts: [String] = []
        var hasFailed = false
        for cost in costs {
            if let amount = cost.amount, !cost.parseFailed {
                parts.append(resourceLabel(cost.resource) + " " + BuildingCostFormatter.label(amount))
            } else {
                hasFailed = true
                let raw = cost.rawAmount ?? ""
                let rawText = raw.isEmpty ? "金额缺失" : "金额: \"" + raw + "\""
                parts.append(resourceLabel(cost.resource) + "（" + rawText + "）")
            }
        }
        if hasFailed { return "已知费用：" + parts.joined(separator: " · ") }
        return parts.joined(separator: " · ")
    }

    /// 排位段位（leagueTier，2026 新增字段）：按稳定 API ID 查 leagueTier
    /// context（105xxxxxx 排位段位表，与 requiredLeagueTier 同一 ID 表）。
    /// - nil → nil（字段缺失不显示）。
    /// - 未知 ID → "待本地化（ID: x, name）"：保留官方原始 name 可审计
    ///   （Issue #71：未知新 ID 不丢失官方 name/id，不伪造中文名）。
    public static func playerLeagueTierLabel(_ tier: PlayerLeague?) -> String? {
        guard let id = tier?.id else { return nil }
        guard let name = leagueTierCatalog?.name(forID: id, context: .leagueTier) else {
            return tierNameFallback("待本地化", id: id, officialName: tier?.name)
        }
        return name
    }

    private enum LeagueKind {
        case home
        case builderBase
        case capital
        case requiredTier
        case war
    }

    /// 联赛/段位本地化目录缓存（Issue #71）：单一数据源替换原手写字典；
    /// 目录缺失/malformed 时所有查询走降级文案，UI 不崩溃。
    private static let leagueTierCatalog = LeagueTierCatalog.loadBundled()

    private static func leagueLabel(id: Int?, name: String?, kind: LeagueKind) -> String? {
        guard let id else { return nil }
        let context: LeagueTierContext
        switch kind {
        case .home: context = .home
        case .builderBase: context = .builderBase
        case .capital: context = .capital
        case .requiredTier: context = .leagueTier
        case .war: context = .war
        }
        guard let localized = leagueTierCatalog?.name(forID: id, context: context) else {
            return tierNameFallback("未本地化联赛", id: id, officialName: name)
        }
        return localized
    }

    /// 未知 ID 降级文案：保留官方原始 name（可审计），name 缺失时只显示 ID。
    private static func tierNameFallback(_ prefix: String, id: Int, officialName: String?) -> String {
        if let officialName, !officialName.isEmpty {
            return "\(prefix)（ID: \(id), \(officialName)）"
        }
        return "\(prefix)（ID: \(id)）"
    }

    /// 战争记录概览："胜-负" 或 "胜-负-平"；无数据返回 nil。
    public static func warRecordLabel(_ snapshot: OfficialClanSnapshot) -> String? {
        switch (snapshot.warWins, snapshot.warLosses, snapshot.warTies) {
        case let (wins?, losses?, ties?):
            return "\(wins)-\(losses)-\(ties)"
        case let (wins?, losses?, _):
            return "\(wins)-\(losses)"
        default:
            return nil
        }
    }

    /// 部落等级（ClanWarParticipant.clanLevel / Clan.clanLevel 语义）：
    /// - nil → nil（字段缺失不渲染占位）
    /// - 非 nil → "部落等级 \(n)"，任何 Int 值原样格式化（含异常负值
    ///   不钳制：纯字符串插值无崩溃路径，保留 API 原始信号可审计）
    ///
    /// Issue #95：此前战争卡片把 clanLevel 传入无上下文的 `level` 参数并
    /// 渲染为"X级大本营"，本函数将部落等级文案语义固定于此，禁止与
    /// townHallLevel（大本营等级）文案复用同一"X级"格式。
    public static func clanLevelLabel(_ clanLevel: Int?) -> String? {
        guard let clanLevel else { return nil }
        return "部落等级 \(clanLevel)"
    }

    /// 百分比文本：整数无小数，非整数 1 位小数（摧毁率展示的单一来源）。
    ///
    /// 固定用 en_US_POSIX 区域格式化——`String(format:)` 默认随系统区域设置，
    /// 某些区域会把小数点换成逗号（如 "12,5"），UI 展示会漂移。
    /// 防御（M1/M2）：`Double(Int.max)` 即 2^63、`Double(Int.min)` 即 -2^63，
    /// 超出任一边界的值 `Int(value)` 转换都会 trap（负向如 `percent(-1e19)`
    /// 实测崩溃 "result would be less than Int.min"）——整数分支前先拒绝
    /// 不可表示的大值，改走 `%.1f` 分支（公开 API 契约外输入不崩溃；
    /// 现有调用点摧毁率 ∈ [0,100] 不可达此分支）。
    public static func percent(_ value: Double) -> String {
        guard value < Double(Int.max), value >= Double(Int.min) else {
            return String(format: "%.1f", locale: posixLocale, arguments: [value])
        }
        return value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", locale: posixLocale, arguments: [value])
    }

    /// 固定小数点格式化的区域设置（不随系统区域改变输出）。
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
}
