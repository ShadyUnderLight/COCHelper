import SwiftUI
import AppKit
import COCHelperCore
import COCHelperApp

/// Issue #45：同类建筑组卡左列汇总视图。
///
/// 展示 `BuildingGroup.summary`（BuildingGroupProjection 聚合）的组级信息：
/// - 组图标：组内第一个实例的 `VillageItemState.preferredAssetURLs` 4 级候选链
///   （currentLevelVisual → currentLevelIcon → levelVisual → icon，与列表行/详情
///   sheet 共用解析防漂移；Issue #39 语义：按 currentLevel 显示对应等级外观），
///   NSImage 依次加载，全部失败回退 SF Symbol（displayCategory → category →
///   hammer.fill）。版本参数固定 `GameCatalog.defaultBundledVersion`：本组件
///   不接收 catalog，UI 层如需真实版本后续再接入。
/// - 组名 + 实例数量合计（Core 层按 instanceWeight 饱和求和，> 1 显示 ×N 胶囊）
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

    /// 实例数量合计（Core 层已按 instanceWeight 饱和求和；> 1 显示 ×N 胶囊）。
    private var totalCount: Int { group.summary.instanceCount }

    /// 费用汇总：每项「资源 千分位数量」，按投影字典序（确定性）；
    /// 无任何费用数据时兜底「无费用数据」。
    /// Review 反馈 P1-1：部分目录数据缺失（partialMissing）时加「已知费用：」
    /// 前缀，明确只汇总了已知部分，不得被误读为完整总额。
    private var costSummaryLabel: String {
        if group.summary.saturated { return "数据异常（超出可表示范围）" }
        let parts = group.summary.costByResource.map {
            ClanDisplayFormat.resourceLabel($0.resource) + " " + BuildingCostFormatter.label($0.totalCost)
        }
        if parts.isEmpty { return "无费用数据" }
        if group.summary.completeness == .partialMissing {
            return "已知费用：" + parts.joined(separator: " · ")
        }
        return parts.joined(separator: " · ")
    }

    /// 组内是否存在阶段满级实例（`currentStageMaxLevel < maxLevel`，Issue #67）：
    /// 与行级「当前阶段已满级（全局尚有 N 级）」文案同口径，汇总「已达当前阶段
    /// 上限」判定与组卡摘要共用，防双实现漂移。
    private var hasStageCappedInstance: Bool {
        group.instances.contains { instance in
            guard let stage = instance.item.currentStageMaxLevel,
                  let max = instance.item.maxLevel else { return false }
            return stage < max
        }
    }

    /// 阶段满级阻塞条件摘要（Issue #68 验收 2，组卡侧）：仅当汇总实际显示
    /// 「已达当前阶段上限」且组内至少一个实例 `.requires` 时，展示第一个
    /// .requires 实例的下一级解锁条件（与详情 sheet 头部 caption 同文案来源
    /// `displayLabels`）。其余情况 nil（不打扰用户）。
    private var stageGateSummary: String? {
        let showsStageCappedText = group.summary.remainingLevelCount == 0
            && group.summary.completeness == .complete
            && hasStageCappedInstance
        guard showsStageCappedText else { return nil }
        guard let first = group.instances.first(where: {
            if case .requires = $0.item.effectiveNextUpgrade { return true }
            return false
        }) else { return nil }
        guard case .requires(_, let requirements, _) = first.item.effectiveNextUpgrade else { return nil }
        return "下一级解锁条件：" + requirements.displayLabels(base: first.item.base.rawValue)
    }

    /// 完整时长合计：按 completeness 分支（交叉评审发现的口径缺陷修复——
    /// 不能只看 remainingLevelCount == 0 就报「已达目录上限」）：
    /// - versionMismatch（目录过时，如大本营 Lv19 > 目录 max 18）：一律显示
    ///   「暂无目录数据」，不得把旧目录汇总当成确定事实（Issue #45 契约）；
    /// - complete 且剩余等级 0：
    ///   - 任一实例阶段上限低于全局上限（`currentStageMaxLevel < maxLevel`，
    ///     Issue #67）→「已达当前阶段上限」（全局更高等级未解锁，与行级
    ///     「当前阶段已满级（全局尚有 N 级）」文案一致，审核 D important）；
    ///   - 否则真满级 →「已达目录上限」（参照 `UpgradeDisplayRow.durationLabel`
    ///     的 isMaxed 分支先例）；
    /// - partialMissing 且剩余等级 0（如 currentLevel == nil，剩余等级不可确定）：
    ///   「暂无目录数据」，不误报已满级；
    /// - 剩余等级 > 0：`AccountDurationFormatter.label`（完整升级耗时，不得写成
    ///   完成日期）；== 0 秒且阶梯非空且全部时长已知（如城墙 durationSeconds == 0
    ///   计入 0 秒）显示「即时」；其余（阶梯部分缺失）显示「暂无目录数据」。
    private var totalDurationLabel: String {
        if group.summary.saturated {
            return "数据异常（超出可表示范围）"
        }
        if group.summary.completeness == .versionMismatch {
            return "暂无目录数据"
        }
        if group.summary.remainingLevelCount == 0 {
            if group.summary.completeness == .complete {
                return hasStageCappedInstance ? "已达当前阶段上限" : "已达目录上限"
            }
            return "暂无目录数据"
        }
        let seconds = group.summary.totalDurationSeconds
        if seconds > 0 { return AccountDurationFormatter.label(seconds) }
        let steps = group.instances.flatMap(\.steps)
        if !steps.isEmpty && steps.allSatisfy(\.hasDuration) {
            return "即时"
        }
        // Issue #74b：阶梯非空但全部时长缺失（目录命中、源字段缺失）→
        // 明确「目录无时长数据」，与「无目录/未收录」的「暂无目录数据」区分；
        // 部分缺失（seconds == 0 且阶梯混合）保持「暂无目录数据」（有数值时
        // 已走 seconds > 0 分支并带 partialMissing 橙标）。
        if !steps.isEmpty && steps.allSatisfy({ $0.durationSeconds == nil }) {
            return "目录无时长数据"
        }
        return "暂无目录数据"
    }

    /// 完整性标注：partialMissing 橙色小字 / versionMismatch 红色小字 /
    /// complete 不显示（满级与正常组不打扰用户）。
    @ViewBuilder
    private var completenessLabel: some View {
        if group.summary.saturated {
            Text("数据异常（超出可表示范围）")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
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
    }

    /// 4 级候选链 asset 首图；firstInstance 缺失或全部加载失败 → nil（SF Symbol 兜底）。
    private func assetImage(_ item: VillageItemState?) -> NSImage? {
        guard let item else { return nil }
        return PerformanceImageDecode.firstDecodable(
            item.preferredAssetURLs(version: GameCatalog.defaultBundledVersion)
        )
    }

    /// 组图标：第一个实例的 4 级候选链，失败回退 SF Symbol（不崩溃）。
    /// Review 反馈 P2-1：资产缺失原因叠加警告角标 + help（同 UpgradeDisplayRow 模式）。
    @ViewBuilder
    private var iconView: some View {
        Group {
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
        .overlay(alignment: .bottomTrailing) {
            if firstInstance?.item.assetMissingReason != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .offset(x: 4, y: 4)
            }
        }
        .help(iconHelp)
    }

    /// 组图标 help：资产缺失原因优先（与 UpgradeDisplayRow.iconHelp 同语义）。
    private var iconHelp: String {
        if let reason = firstInstance?.item.assetMissingReason {
            return "目录图标或等级外观缺失：" + reason
        }
        if let missingReason = firstInstance?.item.missingReason { return missingReason }
        return "游戏资源图标"
    }

    /// 时长前缀：partialMissing 时明确「已知时长」（Review 反馈 P1-1），
    /// 不得把部分汇总误读为完整总额；其余情况保持「完整时长合计」。
    private var durationPrefix: String {
        group.summary.completeness == .partialMissing ? "已知时长：" : "完整时长合计："
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            iconView

            HStack(spacing: 7) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !group.summary.saturated && totalCount > 1 {
                    Text("×" + String(totalCount))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
            }

            if !group.summary.saturated {
                Text("剩余等级 " + String(group.summary.remainingLevelCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(costSummaryLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(durationPrefix + totalDurationLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let stageGateSummary {
                    // Issue #68 验收 2：阶段满级（「已达当前阶段上限」）下补充
                    // 具体阻塞 Requirement（仅当组内存在 .requires 实例）。
                    Text(stageGateSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            completenessLabel
        }
        .frame(minWidth: 180, maxWidth: 180, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
