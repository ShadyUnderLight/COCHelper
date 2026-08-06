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

    /// 部落类型中文（官方字符串 open / inviteOnly / closed → 统一译文）。
    static func typeLabel(_ raw: String) -> String {
        switch raw {
        case "open": "开放"
        case "inviteOnly": "仅邀请"
        case "closed": "关闭"
        default: raw
        }
    }

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
