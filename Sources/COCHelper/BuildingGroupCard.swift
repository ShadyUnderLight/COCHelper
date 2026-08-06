import SwiftUI
import AppKit
import COCHelperCore

/// Issue #45：同类建筑组卡（Panel + HStack 两区）。
///
/// - 左：`BuildingGroupSummaryView`（组级汇总，固定宽 180pt）
/// - 右：实例区 VStack——每条原始快照记录一个实例块：头部行（图标 /
///   Lv 当前 / 上限 / ×N / 状态徽标 / 实时剩余时间，整行 Button 点击回调
///   `onOpenDetail(instance)`，由调用方决定如何打开详情）+ 该实例自己的
///   `BuildingUpgradeStepGrid`（per-record 阶梯，内嵌在实例行内，缩进与
///   图标列对齐）；实例块间分隔线。
///
/// 阶梯必须 per-record：Core 层 `instance.steps` 已是按该记录
/// `(currentLevel, maxLevel]` 过滤的升序阶梯（BuildingGroupProjectionTests
/// T4 钉死），跨实例并集会破坏语义——如 Lv9/Lv10 两条记录并集出 Lv10 单元格，
/// Lv10 记录的当前等级会被画成待升级项（Issue #45 验收「不同等级记录各自
/// 显示正确的等级阶梯」）。
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

    /// 实例区：每条记录一个实例块（头部行 + 内嵌阶梯），实例块间分隔线。
    /// 用索引判断末位（避免逐实例 O(n²) 的 `last?.id` 比较）。
    private var instanceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.instances.indices, id: \.self) { index in
                instanceBlock(group.instances[index])
                if index != group.instances.count - 1 {
                    Divider()
                }
            }
        }
        .frame(minWidth: 320, alignment: .leading)
    }

    /// 单实例块：头部行（Button → `onOpenDetail`）+ 该记录自己的阶梯网格。
    private func instanceBlock(_ instance: BuildingInstance) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            instanceRow(instance)
            Divider()
            // 缩进与头部图标列对齐（24pt 图标 + 10pt spacing）。
            BuildingUpgradeStepGrid(steps: instance.steps)
                .padding(.leading, 34)
                .padding(.vertical, 8)
        }
    }

    /// 实例头部行。`BuildingInstance` 直接回传调用方（Task 3 集成时由调用方
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
            }
        }
    }
}
