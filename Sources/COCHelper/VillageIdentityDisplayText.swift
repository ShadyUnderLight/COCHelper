import Foundation
import COCHelperCore

/// Issue #49 Task 2/3：侧边栏、升级总览头部与村庄详情页头部共用的身份行内文案。
/// 状态文案遵守 issue 风格表：stale→"已过期"；failed→"获取失败"；
/// success→"官方 API 已更新 <time>"；never/skipped/loading→短次级文案。
/// 无官方昵称（本地名/tag/未命名回退）时显示小标记"待获取昵称"，不把 tag 冒充大标题。
///
/// internal（非 public）：同 target（COCHelper 视图层）内跨文件复用；
/// 不属 Core 公共契约，也不接受跨 target 使用。
enum VillageIdentityDisplayText {
    /// 无官方昵称时的一行小标记（subtle、secondary 样式）。
    static let nicknamePendingMarker = "待获取昵称"

    /// 官方展示状态 → 一行 caption 文案。
    static func statusText(for identity: VillageDisplayIdentity) -> String {
        switch identity.officialStatus {
        case .never: return "尚未获取官方数据"
        case .loading: return "获取中…"
        case .success:
            guard let fetchedAt = identity.officialFetchedAt else { return "官方 API 已更新" }
            return "官方 API 已更新 " + fetchedAt.formatted(date: .abbreviated, time: .shortened)
        case .stale: return "已过期"
        case .failed: return "获取失败"
        case .skipped: return "已跳过"
        }
    }

    /// 第二行 tag 行：`<tag> · <状态>`（一行 caption，tag 优先不被截断）。
    /// tag 缺失或空白（Task 1 文档化的病态输入，契约字面透传）时返回调用点各自的
    /// 兜底文案——兜底文案按调用点保持（侧边栏 "等待导入 JSON"、升级总览与详情页
    /// "尚未导入账号 JSON"），不统一（历史行为）。UI 展示侧的空白裁剪只用于
    /// 兜底判定，不透传、不改 Core 契约。
    static func tagLineText(identity: VillageDisplayIdentity, fallback: String) -> String {
        guard let tag = identity.tag,
              !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return tag + " · " + statusText(for: identity)
    }
}
