import SwiftUI
import COCHelperCore

/// Issue #45：建筑组卡实例行内逐级升级阶梯网格（per-record）。
///
/// 输入升序 `[BuildingUpgradeStep]`（BuildingGroupProjection 已保证 level 升序
/// 且界内；**每组实例只传该记录自己的阶梯，不得跨实例合并**——不同等级记录
/// 的阶梯各自显示，避免把当前等级画成待升级项）。固定三列 LazyVGrid
/// 单元格展示 Lv / 费用 / 完整时长，单元格语义与 `LevelDetailSheet` 逐级行
/// 一致：durationSeconds == 0 显示「即时」、nil 显示「暂无目录数据」、
/// 费用 nil 显示「无费用数据」。阶梯为空（满级或不可 join）时显示占位
/// 「无剩余等级」。
struct BuildingUpgradeStepGrid: View {
    /// 升序阶梯（调用方传入；可为空数组）。
    let steps: [BuildingUpgradeStep]

    /// 固定三列（规格「两列或三列」取上限；窄窗口每列收缩，不加横向滚动）。
    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    /// 费用文案：千分位；费用缺失 →「无费用数据」；资源缺失归「未知资源」
    /// （与投影汇总 `BuildingGroupProjection.summary` 同规则，不丢弃费用）。
    private func costLabel(_ step: BuildingUpgradeStep) -> String {
        guard let cost = step.upgradeCost else { return "无费用数据" }
        let resource = step.upgradeResource ?? "未知资源"
        return resource + " " + BuildingCostFormatter.label(cost)
    }

    /// 时长文案：0 = 有效即时升级 →「即时」；nil = 缺失 →「暂无目录数据」。
    private func durationLabel(_ step: BuildingUpgradeStep) -> String {
        if step.isInstant { return "即时" }
        guard let seconds = step.durationSeconds else { return "暂无目录数据" }
        return AccountDurationFormatter.label(seconds)
    }

    private func stepCell(_ step: BuildingUpgradeStep) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Lv " + String(step.level))
                .font(.subheadline.weight(.bold).monospacedDigit())
            Text(costLabel(step))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(durationLabel(step))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        if steps.isEmpty {
            Text("无剩余等级")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(steps, id: \.level) { step in
                    stepCell(step)
                }
            }
        }
    }
}
