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
        case "open": "所有人均可加入"
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
        leagueLabel(id: league?.id, kind: .home)
    }

    /// 建筑大师基地联赛：按稳定 API ID 本地化。
    public static func builderBaseLeagueLabel(_ league: PlayerLeague?) -> String? {
        leagueLabel(id: league?.id, kind: .builderBase)
    }

    /// 部落都城联赛：按稳定 API ID 本地化。
    public static func capitalLeagueLabel(_ league: ClanLeague?) -> String? {
        leagueLabel(id: league?.id, kind: .capital)
    }

    /// 入会所需联赛等级：按稳定 API ID 本地化。
    public static func requiredLeagueTierLabel(_ tier: ClanLeagueTier?) -> String? {
        leagueLabel(id: tier?.id, kind: .requiredTier)
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

    /// 排位段位（leagueTier，2026 新增字段）：按稳定 API ID 查 home context 本地化。
    /// - nil → nil（字段缺失不显示）。
    /// - 未知 ID → "待本地化（ID: x）"：leagueTier 是 2026 新增字段，未知 ID
    ///   说明官方新增了段位，语义是「待后续补充」；与 league 的「未本地化联赛」
    ///   降级文案区分（league 目录已全量审计，未知即异常）。
    public static func playerLeagueTierLabel(_ tier: PlayerLeague?) -> String? {
        guard let id = tier?.id else { return nil }
        return leagueTierCatalog?.name(forID: id, context: .home) ?? "待本地化（ID: \(id)）"
    }

    private enum LeagueKind {
        case home
        case builderBase
        case capital
        case requiredTier
    }

    /// 联赛/段位本地化目录缓存（Issue #71）：单一数据源替换原手写字典；
    /// 目录缺失/malformed 时所有查询走降级文案，UI 不崩溃。
    private static let leagueTierCatalog = LeagueTierCatalog.loadBundled()

    private static func leagueLabel(id: Int?, kind: LeagueKind) -> String? {
        guard let id else { return nil }
        let context: LeagueTierContext
        switch kind {
        case .home: context = .home
        case .builderBase: context = .builderBase
        case .capital: context = .capital
        case .requiredTier: context = .requiredTier
        }
        return leagueTierCatalog?.name(forID: id, context: context) ?? "未本地化联赛（ID: \(id)）"
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
}
