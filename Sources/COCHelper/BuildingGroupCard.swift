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
/// 「正在升级」和「待重新导入确认」均消费 `VillageItemState` 的有效状态谓词，
/// 与总览/详情的 sidecar 语义保持一致。
struct BuildingGroupCard: View {
    let group: BuildingGroup
    let onOpenDetail: (BuildingInstance) -> Void
    let now: Date

    /// 实例区：每条记录一个实例块（头部行 + 内嵌阶梯），实例块间分隔线。
    /// `BuildingInstance` 是 Identifiable（id = 原始快照记录 ID，组内唯一），
    /// 末位判断用 `last?.id` 与 `LevelDetailSheet` 逐级行先例一致。
    private var instanceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.instances) { instance in
                instanceBlock(instance)
                if instance.id != group.instances.last?.id {
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
            BuildingUpgradeStepGrid(steps: instance.steps, item: instance.item)
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
                    if item.isEffectivelyUpgrading || item.effectivelyNeedsReimport {
                        HStack(spacing: 6) {
                            if item.isEffectivelyUpgrading {
                                StatusBadge(text: "正在升级", tint: .orange)
                            }
                            if item.effectivelyNeedsReimport {
                                StatusBadge(text: "待重新导入确认", tint: .orange)
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                if let remainingSeconds = item.effectiveRemainingSeconds(at: now), remainingSeconds > 0 {
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

    /// 等级标签：currentLevel 缺失 →「等级未记录」；maxLevel 缺失 →「X级 / --」。
    private func levelLabel(_ item: VillageItemState) -> String {
        guard let currentLevel = item.effectiveCurrentLevel else { return "等级未记录" }
        if let maxLevel = item.maxLevel {
            return String(currentLevel) + "级 / " + String(maxLevel) + "级"
        }
        return String(currentLevel) + "级 / --"
    }

    /// 实例图标：4 级候选链 NSImage 加载，失败回退 SF Symbol（同列表行规格）。
    /// Review 反馈 P2-1：资产缺失原因（assetMissingReason，render_failed /
    /// export_not_found 等）必须可见——叠加警告角标 + help 文案，与
    /// `UpgradeDisplayRow.iconView` 同模式，不得静默回退成普通 SF Symbol。
    @ViewBuilder
    private func iconView(_ item: VillageItemState) -> some View {
        Group {
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
        .overlay(alignment: .bottomTrailing) {
            if item.assetMissingReason != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .offset(x: 4, y: 4)
            }
        }
        .help(iconHelp(item))
    }

    /// 图标 help 文案：资产缺失原因优先（与 UpgradeDisplayRow.iconHelp 同语义）。
    private func iconHelp(_ item: VillageItemState) -> String {
        if let reason = item.assetMissingReason {
            return "目录图标或等级外观缺失：" + reason
        }
        if let missingReason = item.missingReason { return missingReason }
        return "游戏资源图标"
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
