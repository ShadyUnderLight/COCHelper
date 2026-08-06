import SwiftUI
import COCHelperCore

/// Issue #45：同类建筑组卡右列逐级升级阶梯网格。
///
/// 输入升序 `[BuildingUpgradeStep]`（BuildingGroupProjection 已保证 level 升序
/// 且界内）。两列 LazyVGrid 单元格展示 Lv / 费用 / 完整时长，单元格语义与
/// `LevelDetailSheet` 逐级行一致：durationSeconds == 0 显示「即时」、
/// nil 显示「暂无目录数据」、费用 nil 显示「暂无费用」。
/// 外层横向滚动适配窄窗口；阶梯为空（满级或不可 join）时显示占位「无剩余等级」。
struct BuildingUpgradeStepGrid: View {
    /// 升序阶梯（调用方传入；可为空数组）。
    let steps: [BuildingUpgradeStep]

    /// 两列固定宽度单元格（内容超宽时由外层横向滚动兜底）。
    private let columns = [
        GridItem(.fixed(150), spacing: 8),
        GridItem(.fixed(150), spacing: 8),
    ]

    /// 费用文案：千分位；费用缺失 →「暂无费用」；资源缺失归「未知资源」
    /// （与投影汇总 `BuildingGroupProjection.summary` 同规则，不丢弃费用）。
    private func costLabel(_ step: BuildingUpgradeStep) -> String {
        guard let cost = step.upgradeCost else { return "暂无费用" }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(steps, id: \.level) { step in
                        stepCell(step)
                    }
                }
            }
        }
    }
}
