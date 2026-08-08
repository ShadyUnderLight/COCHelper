import Foundation

// MARK: - 状态

/// 指标可计算状态（issue #70 契约）。
public enum ProgressMetricState: String, Hashable, Sendable, CaseIterable {
    /// 分母完整、无缺失输入、目录已验证：可直接展示百分比。
    case ready
    /// 可计算但输入部分缺失（未知项/目录未验证）：展示百分比 + 降级说明。
    case partial
    /// 不可计算：目录不可用或版本不匹配（fail-closed，禁止假精度）。
    case unavailable
    /// 无数据：无快照或无可计算实例（分母为 0）。
    case unknown
}

// MARK: - 指标

/// 单个指标的展示模型。
public struct ProgressMetric: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// 当前阶段进度：等级和 / 当前阶段上限和（cap = currentStageMaxLevel）。
        case currentStageProgress
        /// 全局养成进度：等级和 / 目录全局上限和（cap = maxLevel）。
        case globalProgress
        /// 观测数据完整性：已关联目录实例数 / 追踪类别观测实例数。
        case snapshotCoverage
    }

    public let kind: Kind
    /// 分子（实例加权，饱和求和）。
    public let numerator: Int
    /// 分母（实例加权，饱和求和）。
    public let denominator: Int
    public let state: ProgressMetricState
    /// 任一求和饱和（issue #66 fail-closed）：ratio 恒 nil，UI 显示异常。
    public let saturated: Bool
    /// 分子/分母的展示单位（"级"/"实例"）。
    public let units: String
    /// 降级原因（ready 时 nil）。
    public let degradedReason: String?

    public var id: String { kind.rawValue }

    /// 展示比例；saturated、分母 ≤ 0、state 不可计算（unavailable/unknown）时 nil。
    public var ratio: Double? {
        guard !saturated, denominator > 0, state == .ready || state == .partial else { return nil }
        return Double(numerator) / Double(denominator)
    }

    public init(
        kind: Kind,
        numerator: Int,
        denominator: Int,
        state: ProgressMetricState,
        saturated: Bool = false,
        units: String,
        degradedReason: String? = nil
    ) {
        self.kind = kind
        self.numerator = numerator
        self.denominator = denominator
        self.state = state
        self.saturated = saturated
        self.units = units
        self.degradedReason = degradedReason
    }
}

/// 一个村庄、一个基地的三指标聚合（issue #70）。
public struct VillageProgressMetrics: Hashable, Sendable {
    public let currentStageProgress: ProgressMetric
    public let globalProgress: ProgressMetric
    public let snapshotCoverage: ProgressMetric
}

// MARK: - 投影

/// Issue #70：三指标投影。纯函数，输入与 `VillageDetailProjection.totalCompletion`
/// 同口径（调用方已过滤 status == .unavailable 的 trackedItems）。
///
/// 指标语义：
/// - currentStageProgress：`Σmin(level, currentStageMaxLevel) / ΣcurrentStageMaxLevel`，
///   分母只含 known 且阶段上限可计算的实例（#67 保证 known ⇒ stageMax 非 nil）；
/// - globalProgress：`Σmin(level, maxLevel) / ΣmaxLevel`，同样只含 known 实例；
/// - snapshotCoverage：`known 实例权重 / 全部追踪类别观测实例权重`——观测数据
///   完整性（已知/未知比例），不是村庄实例宇宙的完整覆盖率（目录侧缺失项
///   枚举未落地，阶段 2 数据管线）；issue #70 契约不得称"全村庄完成度"。
///
/// 状态判定（决策 2/3/5）：
/// - `catalogIsUsable == false` → 三指标全部 `.unavailable`（目录不可用/版本不匹配，
///   fail-closed，禁止假精度）；
/// - 分母 == 0 → `.unknown`（无快照或无可确认实例）；
/// - 未知实例权重 > 0 → `.partial`；
/// - `compatibility == .unverified` → 可计算指标强制 `.partial`（未验证目录不伪装
///   ready），degradedReason 说明；
/// - 其余 → `.ready`。
/// 饱和（issue #66 fail-closed）：分子/分母各自饱和求和，任一饱和 →
/// `saturated = true` → ratio 恒 nil；饱和不改变 state（UI 层饱和优先）。
public enum VillageProgressProjection {
    public static func metrics(
        from items: [VillageItemState],
        catalogIsUsable: Bool,
        compatibility: CatalogCompatibility? = nil
    ) -> VillageProgressMetrics {
        guard catalogIsUsable else {
            return unavailableMetrics()
        }
        // 与 VillageDetailProjection.isKnown 同一规则（private 不可跨类型调用，逐字复制）。
        let known = items.filter { isKnown($0) }
        // 未知实例权重（独立求和，饱和不丢失；溢出标志并入 unknownWeightInfo）
        let unknownWeightInfo = VillageDetailProjection.instanceCountAndOverflow(of: items.filter { !isKnown($0) })

        // 阶段进度：分母 = Σ(stageMax × weight)，分子 = Σ(min(level, stageMax) × weight)
        let stageEligible = known.filter { $0.currentStageMaxLevel != nil }
        let stageDen = weightedCappedSum(stageEligible) { $0.currentStageMaxLevel ?? 0 }
        let stageNum = weightedCappedSum(stageEligible) {
            min($0.currentLevel ?? 0, $0.currentStageMaxLevel ?? 0)
        }

        // 全局进度：分母 = Σ(maxLevel × weight)，分子 = Σ(min(level, maxLevel) × weight)
        let globalEligible = known
        let globalDen = weightedCappedSum(globalEligible) { $0.maxLevel ?? 0 }
        let globalNum = weightedCappedSum(globalEligible) {
            min($0.currentLevel ?? 0, $0.maxLevel ?? 0)
        }

        // 覆盖率：分母 = 全部观测实例权重，分子 = known 实例权重（饱和信息保留）
        let coverageDen = VillageDetailProjection.instanceCountAndOverflow(of: items)
        let coverageNum = VillageDetailProjection.instanceCountAndOverflow(of: known)

        let unverifiedCatalog = compatibility?.isUnverified ?? false

        return VillageProgressMetrics(
            currentStageProgress: makeMetric(
                kind: .currentStageProgress,
                numerator: stageNum.value,
                denominator: stageDen.value,
                saturated: stageNum.saturated || stageDen.saturated,
                unknownWeight: unknownWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                units: "级",
                emptyReason: "无可确认项目，暂无法计算"
            ),
            globalProgress: makeMetric(
                kind: .globalProgress,
                numerator: globalNum.value,
                denominator: globalDen.value,
                saturated: globalNum.saturated || globalDen.saturated,
                unknownWeight: unknownWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                units: "级",
                emptyReason: "无可确认项目，暂无法计算"
            ),
            snapshotCoverage: makeMetric(
                kind: .snapshotCoverage,
                numerator: coverageNum.count,
                denominator: coverageDen.count,
                saturated: coverageNum.didOverflow || coverageDen.didOverflow,
                unknownWeight: unknownWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                units: "实例",
                emptyReason: "尚未导入快照"
            )
        )
    }

    // MARK: - Helpers

    private static func unavailableMetrics() -> VillageProgressMetrics {
        let reason = "目录不可用或版本不匹配，暂无法计算该指标。"
        return VillageProgressMetrics(
            currentStageProgress: ProgressMetric(
                kind: .currentStageProgress, numerator: 0, denominator: 0,
                state: .unavailable, units: "级", degradedReason: reason),
            globalProgress: ProgressMetric(
                kind: .globalProgress, numerator: 0, denominator: 0,
                state: .unavailable, units: "级", degradedReason: reason),
            snapshotCoverage: ProgressMetric(
                kind: .snapshotCoverage, numerator: 0, denominator: 0,
                state: .unavailable, units: "实例", degradedReason: reason)
        )
    }

    private static func makeMetric(
        kind: ProgressMetric.Kind,
        numerator: Int,
        denominator: Int,
        saturated: Bool,
        unknownWeight: Int,
        unverifiedCatalog: Bool,
        units: String,
        emptyReason: String
    ) -> ProgressMetric {
        let state: ProgressMetricState
        var reasons: [String] = []
        if denominator == 0 {
            state = .unknown
            reasons.append(emptyReason)
        } else {
            if unknownWeight > 0 {
                reasons.append(String(unknownWeight) + " 项未知，结果仅为已观测项目。")
            }
            if unverifiedCatalog {
                reasons.append("目录与玩家版本未验证，百分比可能过时。")
            }
            state = (reasons.isEmpty) ? .ready : .partial
        }
        return ProgressMetric(
            kind: kind,
            numerator: numerator,
            denominator: denominator,
            state: state,
            saturated: saturated,
            units: units,
            degradedReason: reasons.isEmpty ? nil : reasons.joined(separator: " ")
        )
    }

    /// 计入指标分母的条件（与 VillageDetailProjection.isKnown 逐字同规则）：
    /// unknown/unavailable/available/unverified 不计；maxLevel/currentLevel 缺失
    /// 不计；upgrading 且 nextLevel > maxLevel（版本不匹配）不计。
    private static func isKnown(_ item: VillageItemState) -> Bool {
        guard item.status != .unknown, item.status != .unavailable,
              item.status != .available, item.status != .unverified else { return false }
        guard item.maxLevel != nil, item.currentLevel != nil else { return false }
        if item.isUpgrading,
           let nextLevel = item.nextLevel,
           let maxLevel = item.maxLevel,
           nextLevel > maxLevel {
            return false
        }
        return true
    }

    /// 等级式公式的实例加权饱和求和：`value(item) × instanceWeight` 累加，
    /// 乘法/加法任一溢出饱和到 Int.max 并置位（issue #66 fail-closed）。
    private static func weightedCappedSum(
        _ items: [VillageItemState],
        value: (VillageItemState) -> Int
    ) -> (value: Int, saturated: Bool) {
        var saturated = false
        let total = items.reduce(0) { acc, item in
            let (scaled, mulOverflow) = value(item).multipliedReportingOverflow(by: item.instanceWeight)
            let (sum, addOverflow) = acc.addingReportingOverflow(scaled)
            if mulOverflow || addOverflow {
                saturated = true
                return Int.max
            }
            return sum
        }
        return (total, saturated)
    }
}
