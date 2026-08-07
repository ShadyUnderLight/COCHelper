import SwiftUI
import COCHelperCore

/// Issue #45：建筑组卡实例行内逐级升级阶梯网格（per-record）。
///
/// 输入升序 `[BuildingUpgradeStep]`（BuildingGroupProjection 已保证 level 升序
/// 且界内；**每组实例只传该记录自己的阶梯，不得跨实例合并**——不同等级记录
/// 的阶梯各自显示，避免把当前等级画成待升级项）。固定三列 LazyVGrid
/// 单元格展示 Lv / 费用 / 完整时长，单元格语义与 `LevelDetailSheet` 逐级行
/// 一致：durationSeconds == 0 显示「即时」、缺失类按原因区分显示（Issue
/// #74b：time_missing 等显示「目录缺失」而非「暂无目录数据」）、
/// 费用 nil 显示「无费用数据」。阶梯为空（满级或不可 join）时显示占位
/// 「无剩余等级」。
///
/// 窄窗口适配（Issue #45：「用横向滚动适配较窄窗口」，Review 反馈 P2-2）：
/// 固定列宽 3×150pt + 外层横向 ScrollView——实例区宽度不足 466pt 时横向滚动，
/// 充足时三列完整显示，单元格不因挤压而截断。
struct BuildingUpgradeStepGrid: View {
    /// 升序阶梯（调用方传入；可为空数组）。
    let steps: [BuildingUpgradeStep]

    /// 单列固定宽：3 列 + 2×8 spacing = 466pt 内容宽。
    private static let columnWidth: CGFloat = 150

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Self.columnWidth), spacing: 8), count: 3)
    }

    /// 费用文案：千分位；费用缺失 →「无费用数据」；资源缺失归「未知资源」
    /// （与投影汇总 `BuildingGroupProjection.summary` 同规则，不丢弃费用）。
    private func costLabel(_ step: BuildingUpgradeStep) -> String {
        guard let cost = step.upgradeCost else { return "无费用数据" }
        return ClanDisplayFormat.resourceLabel(step.upgradeResource) + " " + BuildingCostFormatter.label(cost)
    }

    /// 时长文案：Issue #74b 走 `CatalogDurationState.durationLabel`（与详情页/
    /// 列表行共用同一文案源，防漂移）——0 = 有效即时升级 →「即时」；缺失类
    /// （time_missing/no_time_source/initialLevel/parseFailed）按原因区分；
    /// 双 nil 未知场景 →「暂无目录数据」。
    private func durationLabel(_ step: BuildingUpgradeStep) -> String {
        step.durationState?.durationLabel ?? "暂无目录数据"
    }

    private func stepCell(_ step: BuildingUpgradeStep) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(step.level) + "级")
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
