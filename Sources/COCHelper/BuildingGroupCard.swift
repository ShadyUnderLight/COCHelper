import SwiftUI
import AppKit
import COCHelperCore
import COCHelperApp

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
    /// Issue #144：组级 Start 动作（v1 每次 quantity = 1）。
    var startActions: [UpgradeAction] = []
    var onStart: ((UpgradeAction) -> Void)? = nil
    /// Issue #144 review P1-1：组内本地 active 记录也必须有 Cancel/Adjust 入口。
    var onCancel: ((ManualUpgradeRecord) -> Void)? = nil
    var onAdjust: ((ManualUpgradeRecord) -> Void)? = nil

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

    /// 实例图标：4 级候选链异步加载（`ResourceIconView`，后台 actor + session
    /// cache），失败回退 SF Symbol（同列表行规格）。
    /// Review 反馈 P2-1：资产缺失原因（assetMissingReason，render_failed /
    /// export_not_found 等）必须可见——叠加警告角标 + help 文案，与
    /// `UpgradeDisplayRow.iconView` 同模式，不得静默回退成普通 SF Symbol。
    /// Issue #198：同步解码收敛到 `ResourceIconView`，候选链/回退/角标语义不变。
    private func iconView(_ item: VillageItemState) -> some View {
        ResourceIconView(
            urls: item.preferredAssetURLs(version: GameCatalog.defaultBundledVersion),
            slotSize: 24,
            systemImage: item.displayCategory?.systemImage ?? item.category?.systemImage ?? "hammer.fill",
            tint: item.displayCategory?.tint ?? item.category?.tint ?? Color.secondary,
            symbolFont: .body,
            pngHelp: iconHelp(item),
            sfHelp: iconHelp(item)
        )
        .overlay(alignment: .bottomTrailing) {
            if item.assetMissingReason != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .offset(x: 4, y: 4)
            }
        }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 18) {
                    BuildingGroupSummaryView(group: group)
                    instanceList
                }
                let activeRecords = group.trackerState.activeRecords
                if !startActions.isEmpty || !activeRecords.isEmpty {
                    Divider()
                    actionRow(activeRecords: activeRecords)
                }
            }
        }
    }

    /// Issue #144：组级动作行（聚合 action，v1 一次启动一个实例；
    /// review P1-1：active 记录提供 Cancel/Adjust）。
    private func actionRow(activeRecords: [ManualUpgradeRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("本地升级")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(startActions, id: \.id) { action in
                    if action.isStartable {
                        Button("开始升级 " + Self.levelLabel(action)) {
                            onStart?(action)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("开始升级 " + group.name + " " + Self.levelLabel(action))
                    } else {
                        Button("开始升级 " + Self.levelLabel(action)) {}
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(true)
                            .help(action.disabledReason ?? "不可启动")
                    }
                }
                let diagnostics = group.trackerState.diagnostics
                if !diagnostics.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(diagnostics.joined(separator: "\n"))
                }
                Spacer()
            }
            if !activeRecords.isEmpty {
                HStack(spacing: 8) {
                    Text("进行中")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(activeRecords) { record in
                        Text("Lv \(record.fromLevel) → \(record.targetLevel)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("取消") {
                            onCancel?(record)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("取消升级 " + group.name + " " + Self.levelLabel(record))
                        Button("调整时间") {
                            onAdjust?(record)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("调整开始时间 " + group.name + " " + Self.levelLabel(record))
                    }
                    Spacer()
                }
            }
        }
    }

    private static func levelLabel(_ record: ManualUpgradeRecord) -> String {
        "\(record.fromLevel) → \(record.targetLevel)"
    }

    private static func levelLabel(_ action: UpgradeAction) -> String {
        guard let from = action.fromLevel, let target = action.targetLevel else { return "" }
        return "\(from) → \(target)"
    }
}
