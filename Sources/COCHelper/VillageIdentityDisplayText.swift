import Foundation
import COCHelperCore
import SwiftUI

/// Issue #49 Task 2/3：侧边栏、升级总览头部、账号数据页与村庄详情页头部共用的
/// 身份行内文案与回退小标记。
/// 状态文案遵守 issue 风格表：stale→"已过期"；failed→"获取失败"；
/// success→"官方 API 已更新 <time>"；never/skipped/loading→短次级文案。
/// 无官方昵称（本地名/tag/未命名回退）时显示小标记"待获取昵称"，不把 tag 冒充大标题。
///
/// internal（非 public）：同 target（COCHelper 视图层）内跨文件复用；
/// 不属 Core 公共契约，也不接受跨 target 使用。
enum VillageIdentityDisplayText {
    /// 无官方昵称时的一行小标记（subtle、secondary 样式）。
    static let nicknamePendingMarker = "待获取昵称"

    /// 回退小标记视图（Issue #49 评审 P2）：`identity.source != .officialName`
    /// 时渲染一行"待获取昵称"（所有非官方来源——本地名/tag/未命名——都是
    /// 昵称缺失的回退状态，不把 tag 冒充昵称），有官方昵称时不渲染任何内容。
    /// 语义与侧边栏内联条件完全一致；各页面在"别名行"缺失处使用它。
    @ViewBuilder
    static func nicknamePendingMarkerView(identity: VillageDisplayIdentity) -> some View {
        if identity.source != .officialName {
            Text(nicknamePendingMarker)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

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
