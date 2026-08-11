import Foundation

/// 战争日志卡片展示投影（Issue #124）：集中定义可见条数、按钮状态，
/// 避免把"本地隐藏条目"与"服务端游标"两个分页概念混在 SwiftUI 条件里。
///
/// 顺序语义：保持官方 warlog 返回顺序，只做 prefix 截取，不排序。
/// （官方接口当前按最近在前返回；如确认官方不保证该顺序，须在此层
/// 另行定义可验证的排序规则，不得静默猜测。）
public enum WarLogDisplayProjection {
    /// 首屏默认可见条数。
    public static let defaultVisibleCount: Int = 10
    /// "查看更多"每次增加的条数。
    public static let increment: Int = 10

    /// "查看更多"按钮状态。
    public enum MoreState: Equatable, Sendable {
        /// 无更多：隐藏按钮（本地已展示完且无服务端游标）。
        case none
        /// 本地缓存还有未展示条目：点击纯本地展开（不发请求）。
        case localHidden
        /// 本地已展示完且服务端还有游标：点击请求下一页。
        case serverMore
    }

    /// 展示投影：`prefix(visibleCount)` 最终上限保护。
    /// 负数钳制为 0（`Array.prefix` 负长度触发 fatal error）。
    public static func visibleEntries<T>(_ entries: [T], visibleCount: Int) -> [T] {
        Array(entries.prefix(max(0, visibleCount)))
    }

    /// 按钮状态判定：本地隐藏优先于服务端更多（本地未展示完时不发请求）。
    public static func moreState(
        totalEntries: Int, visibleCount: Int, hasServerMore: Bool
    ) -> MoreState {
        if visibleCount < totalEntries { return .localHidden }
        if hasServerMore { return .serverMore }
        return .none
    }
}
