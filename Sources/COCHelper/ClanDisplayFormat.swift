import Foundation
import COCHelperCore

/// 部落展示格式化（Issue #48 Step A 审查修复）：ClanCardView 与添加预览
/// 共用，保证徽章安全规则与类型译文**单一来源**（此前两处各自实现，
/// 译文不一致且安全 allowlist 有复制漂移风险）。
enum ClanDisplayFormat {
    /// 徽章 URL 安全：仅加载官方 https 图片域名，防止异常数据注入其他
    /// 协议/域名（AsyncImage 会跟随重定向，allowlist 是纵深防御）。
    static func badgeURL(_ snapshot: OfficialClanSnapshot) -> URL? {
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
    static func typeLabel(_ raw: String) -> String {
        switch raw {
        case "open": "所有人均可加入"
        case "inviteOnly": "只有被批准才能加入"
        case "closed": "不可加入"
        default: "未知"
        }
    }

    /// 将内部来源标识转换成用户可读文案；原始标识只保留在状态模型中。
    static func sourceLabel(_ raw: String?) -> String? {
        switch raw {
        case "official-api": "官方 API 数据"
        case "cached-official-api": "缓存的官方 API 数据"
        default: nil
        }
    }

    /// 玩家主村联赛：按稳定 API ID 本地化，不依赖官方返回的英文 name。
    static func playerLeagueLabel(_ league: PlayerLeague?) -> String? {
        leagueLabel(id: league?.id, kind: .home)
    }

    /// 建筑大师基地联赛：按稳定 API ID 本地化。
    static func builderBaseLeagueLabel(_ league: PlayerLeague?) -> String? {
        leagueLabel(id: league?.id, kind: .builderBase)
    }

    /// 部落都城联赛：按稳定 API ID 本地化。
    static func capitalLeagueLabel(_ league: ClanLeague?) -> String? {
        leagueLabel(id: league?.id, kind: .capital)
    }

    /// 入会所需联赛等级：按稳定 API ID 本地化。
    static func requiredLeagueTierLabel(_ tier: ClanLeagueTier?) -> String? {
        leagueLabel(id: tier?.id, kind: .requiredTier)
    }

    /// 目录资源标识 → 官方简中资源名。未知值不直接泄漏英文标识。
    static func resourceLabel(_ raw: String?) -> String {
        guard let raw else { return "未知资源" }
        return switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gold": "金币"
        case "elixir": "圣水"
        case "darkelixir", "dark_elixir": "暗黑重油"
        case "capitalresource", "capitalgold", "raidcapitalgold": "都城金币"
        case "buildergold", "builderbasegold": "建筑大师基地金币"
        case "builderelixir", "builderbaseelixir": "建筑大师基地圣水"
        default: "未知资源"
        }
    }

    private enum LeagueKind {
        case home
        case builderBase
        case capital
        case requiredTier
    }

    private static func leagueLabel(id: Int?, kind: LeagueKind) -> String? {
        guard let id else { return nil }
        let label: String?
        switch kind {
        case .home:
            label = homeLeagueNames[id]
        case .builderBase:
            label = builderBaseLeagueNames[id]
        case .capital:
            label = capitalLeagueNames[id]
        case .requiredTier:
            label = requiredLeagueTierNames[id]
        }
        return label ?? "未本地化联赛（ID: \(id)）"
    }

    /// 主村联赛 ID：29000000 为未定级，29000022 为传奇联赛。
    private static let homeLeagueNames: [Int: String] = [
        29000000: "未定级",
        29000001: "青铜联赛 III",
        29000002: "青铜联赛 II",
        29000003: "青铜联赛 I",
        29000004: "白银联赛 III",
        29000005: "白银联赛 II",
        29000006: "白银联赛 I",
        29000007: "黄金联赛 III",
        29000008: "黄金联赛 II",
        29000009: "黄金联赛 I",
        29000010: "水晶联赛 III",
        29000011: "水晶联赛 II",
        29000012: "水晶联赛 I",
        29000013: "大师联赛 III",
        29000014: "大师联赛 II",
        29000015: "大师联赛 I",
        29000016: "冠军联赛 III",
        29000017: "冠军联赛 II",
        29000018: "冠军联赛 I",
        29000019: "泰坦联赛 III",
        29000020: "泰坦联赛 II",
        29000021: "泰坦联赛 I",
        29000022: "传奇联赛",
    ]

    /// 当前项目实际使用到的建筑大师基地联赛 ID。
    private static let builderBaseLeagueNames: [Int: String] = [
        44000013: "传奇联赛",
    ]

    /// 当前项目实际使用到的部落都城联赛 ID。
    private static let capitalLeagueNames: [Int: String] = [
        85000006: "泰坦联赛 I",
    ]

    /// 当前项目实际使用到的入会联赛等级 ID。
    private static let requiredLeagueTierNames: [Int: String] = [
        105000028: "泰坦联赛 I",
    ]

    /// 战争记录概览："胜-负" 或 "胜-负-平"；无数据返回 nil。
    static func warRecordLabel(_ snapshot: OfficialClanSnapshot) -> String? {
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
