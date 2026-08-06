import SwiftUI
import AppKit
import COCHelperCore

/// Issue #45：同类建筑组卡左列汇总视图。
///
/// 展示 `BuildingGroup.summary`（BuildingGroupProjection 聚合）的组级信息：
/// - 组图标：组内第一个实例的 `VillageItemState.preferredAssetURLs` 4 级候选链
///   （currentLevelVisual → currentLevelIcon → levelVisual → icon，与列表行/详情
///   sheet 共用解析防漂移；Issue #39 语义：按 currentLevel 显示对应等级外观），
///   NSImage 依次加载，全部失败回退 SF Symbol（displayCategory → category →
///   hammer.fill）。版本参数固定 `GameCatalog.defaultBundledVersion`：本组件
///   不接收 catalog，UI 层如需真实版本后续再接入。
/// - 组名 + 实例数量合计（count ?? 1 求和，> 1 显示 ×N 胶囊）
/// - 剩余等级数（remainingLevelCount，monospacedDigit）
/// - 费用汇总（costByResource，千分位；无费用时显示「无费用数据」）
/// - 完整时长合计（totalDurationSeconds，前缀必须注明是完整升级耗时而非完成日期）
/// - 完整性标注（partialMissing 橙色 / versionMismatch 红色 / complete 不显示）
///
/// 布局：VStack(alignment: .leading) 紧凑间距；组件撑满可用高度（组卡内即
/// 实例区高度，实现「跨实例高度」的整列浅色背景圆角汇总栏）。
struct BuildingGroupSummaryView: View {
    let group: BuildingGroup

    /// 组内第一个实例（图标来源；与列表行共用 `preferredAssetURLs` 防漂移）。
    private var firstInstance: BuildingInstance? { group.instances.first }

    /// 实例数量合计（count ?? 1 求和；> 1 显示 ×N 胶囊，== 1 不显示）。
    private var totalCount: Int {
        group.instances.reduce(0) { $0 + ($1.item.count ?? 1) }
    }

    /// 费用汇总：每项「资源 千分位数量」，按投影字典序（确定性）；
    /// 无任何费用数据时兜底「无费用数据」。
    private var costSummaryLabel: String {
        let parts = group.summary.costByResource.map {
            $0.resource + " " + BuildingCostFormatter.label($0.totalCost)
        }
        return parts.isEmpty ? "无费用数据" : parts.joined(separator: " · ")
    }

    /// 完整时长合计：按 completeness 分支（交叉评审发现的口径缺陷修复——
    /// 不能只看 remainingLevelCount == 0 就报「已达目录上限」）：
    /// - versionMismatch（目录过时，如大本营 Lv19 > 目录 max 18）：一律显示
    ///   「暂无目录数据」，不得把旧目录汇总当成确定事实（Issue #45 契约）；
    /// - complete 且剩余等级 0：真满级 →「已达目录上限」（参照
    ///   `UpgradeDisplayRow.durationLabel` 的 isMaxed 分支先例）；
    /// - partialMissing 且剩余等级 0（如 currentLevel == nil，剩余等级不可确定）：
    ///   「暂无目录数据」，不误报已满级；
    /// - 剩余等级 > 0：`AccountDurationFormatter.label`（完整升级耗时，不得写成
    ///   完成日期）；== 0 秒且阶梯非空且全部时长已知（如城墙 durationSeconds == 0
    ///   计入 0 秒）显示「即时」；其余（阶梯部分缺失）显示「暂无目录数据」。
    private var totalDurationLabel: String {
        if group.summary.completeness == .versionMismatch {
            return "暂无目录数据"
        }
        if group.summary.remainingLevelCount == 0 {
            if group.summary.completeness == .complete {
                return "已达目录上限"
            }
            return "暂无目录数据"
        }
        let seconds = group.summary.totalDurationSeconds
        if seconds > 0 { return AccountDurationFormatter.label(seconds) }
        let steps = group.instances.flatMap(\.steps)
        if !steps.isEmpty && steps.allSatisfy(\.hasDuration) {
            return "即时"
        }
        return "暂无目录数据"
    }

    /// 完整性标注：partialMissing 橙色小字 / versionMismatch 红色小字 /
    /// complete 不显示（满级与正常组不打扰用户）。
    @ViewBuilder
    private var completenessLabel: some View {
        switch group.summary.completeness {
        case .partialMissing:
            Text("部分目录数据缺失")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .versionMismatch:
            Text("目录版本不匹配")
                .font(.caption2)
                .foregroundStyle(.red)
        case .complete:
            EmptyView()
        }
    }

    /// 4 级候选链 asset 首图；firstInstance 缺失或全部加载失败 → nil（SF Symbol 兜底）。
    private func assetImage(_ item: VillageItemState?) -> NSImage? {
        guard let item else { return nil }
        return item.preferredAssetURLs(version: GameCatalog.defaultBundledVersion)
            .lazy.compactMap { NSImage(contentsOf: $0) }.first
    }

    /// 组图标：第一个实例的 4 级候选链，失败回退 SF Symbol（不崩溃）。
    @ViewBuilder
    private var iconView: some View {
        if let image = assetImage(firstInstance?.item) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
        } else {
            Image(systemName: group.displayCategory?.systemImage ?? group.category?.systemImage ?? "hammer.fill")
                .font(.title2)
                .foregroundStyle(group.displayCategory?.tint ?? group.category?.tint ?? Color.secondary)
                .frame(width: 36, height: 36)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            iconView

            HStack(spacing: 7) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if totalCount > 1 {
                    Text("×" + String(totalCount))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
            }

            Text("剩余等级 " + String(group.summary.remainingLevelCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(costSummaryLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("完整时长合计：" + totalDurationLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            completenessLabel
        }
        .frame(minWidth: 180, maxWidth: 180, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 千分位费用格式化。
///
/// 注意 `String(format: "%,d", …)` 在 macOS 不产生分组（comma flag 未实现，
/// 会原样输出 "%d" 而非分组数字），故用 NumberFormatter(.decimal) 走当前
/// locale 分组符（与 `AccountDurationFormatter` 同为纯函数式格式化器）。
enum BuildingCostFormatter {
    static func label(_ cost: Int64) -> String {
        numberFormatter.string(from: NSNumber(value: cost)) ?? String(cost)
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
