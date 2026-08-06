import SwiftUI
import AppKit
import COCHelperCore

/// Issue #45：同类建筑组卡（Panel + HStack 三列）。
///
/// - 左：`BuildingGroupSummaryView`（组级汇总，固定宽）
/// - 中：实例列表——每条原始快照记录一行（图标 / Lv 当前 / 上限 / ×N / 状态
///   徽标 / 实时剩余时间），整行 Button 点击回调 `onOpenDetail(instance)`
///   （由调用方决定如何打开详情，如 `LevelDetailSheet`）；行间分隔线。
/// - 右：`BuildingUpgradeStepGrid`（固定宽区域，内部横向滚动）
///
/// 右列阶梯为组内全部实例阶梯的等级并集（去重保序）：同一 dataID 共享同一
/// 目录项，同一 level 的费用/时长跨实例一致，按 level 去重不丢信息，避免
/// 同组多实例（如不同等级城墙）重复单元格。
///
/// 图标复用 `VillageItemState.preferredAssetURLs` 4 级候选链（与列表行/详情
/// sheet 同解析防漂移），版本固定 `GameCatalog.defaultBundledVersion`（本组件
/// 不接收 catalog）。状态徽标复用 `StatusBadge`（UpgradeDisplayRow 内）：
/// 「正在升级」条件 `item.isUpgrading`（remainingSeconds > 0）、「待重新导入
/// 确认」条件 `item.needsReimport`（timerSeconds != nil && remainingSeconds == 0，
/// 与投影层同谓词防漂移）。
struct BuildingGroupCard: View {
    let group: BuildingGroup
    let onOpenDetail: (BuildingInstance) -> Void

    /// 组内全部实例阶梯的等级并集（按 level 去重，保持升序）。
    private var mergedSteps: [BuildingUpgradeStep] {
        var seenLevels = Set<Int>()
        var steps: [BuildingUpgradeStep] = []
        for instance in group.instances {
            for step in instance.steps where !seenLevels.contains(step.level) {
                seenLevels.insert(step.level)
                steps.append(step)
            }
        }
        return steps
    }

    /// 实例列表：每条记录一行 Button，行间分隔线。
    private var instanceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.instances) { instance in
                instanceRow(instance)
                if instance.id != group.instances.last?.id {
                    Divider()
                }
            }
        }
        .frame(minWidth: 200, alignment: .leading)
    }

    /// 单实例行。`BuildingInstance` 直接回传调用方（Task 3 集成时由调用方
    /// 决定打开哪个 sheet/详情），本组件不构造 `UpgradeDisplayRecord`。
    private func instanceRow(_ instance: BuildingInstance) -> some View {
        let item = instance.item
        return Button {
            onOpenDetail(instance)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                iconView(item)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(levelLabel(item))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        if let count = item.count, count > 1 {
                            Text("×" + String(count))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.07), in: Capsule())
                        }
                    }
                    if item.isUpgrading || item.needsReimport {
                        HStack(spacing: 6) {
                            if item.isUpgrading {
                                StatusBadge(text: "正在升级", tint: .orange)
                            }
                            if item.needsReimport {
                                StatusBadge(text: "待重新导入确认", tint: .orange)
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                if let remainingSeconds = item.remainingSeconds, remainingSeconds > 0 {
                    Text(AccountDurationFormatter.label(remainingSeconds))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 等级标签：currentLevel 缺失 →「等级未记录」；maxLevel 缺失 →「Lv X / --」。
    private func levelLabel(_ item: VillageItemState) -> String {
        guard let currentLevel = item.currentLevel else { return "等级未记录" }
        if let maxLevel = item.maxLevel {
            return "Lv " + String(currentLevel) + " / " + String(maxLevel)
        }
        return "Lv " + String(currentLevel) + " / --"
    }

    /// 实例图标：4 级候选链 NSImage 加载，失败回退 SF Symbol（同列表行规格）。
    @ViewBuilder
    private func iconView(_ item: VillageItemState) -> some View {
        if let image = item.preferredAssetURLs(version: GameCatalog.defaultBundledVersion)
            .lazy.compactMap({ NSImage(contentsOf: $0) }).first {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: item.displayCategory?.systemImage ?? item.category?.systemImage ?? "hammer.fill")
                .font(.body)
                .foregroundStyle(item.displayCategory?.tint ?? item.category?.tint ?? Color.secondary)
                .frame(width: 24, height: 24)
        }
    }

    var body: some View {
        Panel {
            HStack(alignment: .top, spacing: 18) {
                BuildingGroupSummaryView(group: group)
                instanceList
                BuildingUpgradeStepGrid(steps: mergedSteps)
                    .frame(width: 320, alignment: .leading)
            }
        }
    }
}
