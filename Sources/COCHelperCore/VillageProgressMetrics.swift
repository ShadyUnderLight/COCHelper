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

/// Issue #70：三指标投影。纯函数，known 判定与 `VillageDetailProjection.totalCompletion`
/// 同规则（单一来源：`VillageDetailProjection.isKnown`）。
///
/// 指标语义：
/// - currentStageProgress：`Σmin(level, currentStageMaxLevel) / ΣcurrentStageMaxLevel`，
///   分母只含 known 且阶段上限可计算的实例。非升级 known 项 stageMax 非 nil；
///   升级中项可能 stageMax == nil（快照缺解锁建筑记录，投影 isUpgrading 分支先于
///   stageMax 检查）——该形态计入阶段指标专用缺失权重触发降级，不静默丢分母
///   （实现要求 5）。cap 先 max(0,·) 钳制，恶意目录负 cap 不产生负贡献（F1）；
///   **阶段 2（completeDenominator == true）**：分母扩展到 known ∪ available
///   宇宙差集（差集项 currentLevel == 0 → 分子贡献 0，cap 过滤与 known 同规则）；
/// - globalProgress：`Σmin(level, maxLevel) / ΣmaxLevel`，同样只含 known 实例；
///   阶段 2 分母同样并入 available 差集项；
/// - snapshotCoverage：`known 实例权重 / 全部追踪类别观测实例权重`——观测数据
///   完整性（已知/未知比例）。**阶段 2**：分母含宇宙差集项权重，成为完整覆盖率
///   `known / (known + unknown + available)`（100% ⟺ 快照覆盖全部宇宙项）。
///
/// 状态判定（决策 2/3/5 + 阶段 2）：
/// - `catalogIsUsable == false` → 三指标全部 `.unavailable`（目录不可用/版本不匹配，
///   fail-closed，禁止假精度）；
/// - 分母 == 0 → `.unknown`（无快照或无可确认实例）；
/// - 未知实例权重 > 0（含 needsReimport 项归未知侧，实现要求 4）→ `.partial`；
/// - **阶段 2**：completeDenominator == true 且宇宙差集权重 > 0 → `.partial`
///   （覆盖率 < 100% 保守：快照可能不全，不得伪装 ready）；
/// - `compatibility == .unverified` → 可计算指标强制 `.partial`（未验证目录不伪装
///   ready），degradedReason 说明；
/// - `completeDenominator == false`（阶段 1 语义：TH 缺失/目录无宇宙/BB base，
///   UI 层按 `projection.universeComplete` 传参）→ 可计算且无其余降级 → `.partial`
///   强制（分母为已观测项目，非村庄全部实例，不得误称全村庄进度——验收 3）；
/// - 其余 → `.ready`。
/// 饱和（issue #66 fail-closed）：分子/分母各自饱和求和，任一饱和 →
/// `saturated = true` → ratio 恒 nil；饱和不改变 state（UI 层饱和优先）。
public enum VillageProgressProjection {
    public static func metrics(
        from items: [VillageItemState],
        catalogIsUsable: Bool,
        compatibility: CatalogCompatibility?,
        completeDenominator: Bool = false
    ) -> VillageProgressMetrics {
        guard catalogIsUsable else {
            return unavailableMetrics()
        }
        // known 判定单一来源：VillageDetailProjection.isKnown（internal，防漂移）。
        // 计时结束待重新导入（needsReimport）的实例等级为最后记录值、可能已过期，
        // 不计入 known（issue #70 实现要求 4：降级而非假精度）；该信号与目录无关。
        let known = items.filter { VillageDetailProjection.isKnown($0) && !$0.needsReimport }
        // 未知实例权重（独立求和，饱和不丢失；溢出标志并入 unknownWeightInfo）。
        // Issue #70 阶段 2：宇宙差集 .available 项**不计入** unknown 侧——差集项
        // 是「已知存在但快照未导入」（count 来自宇宙表），与「目录未命中无法
        // 确认」的 unknown 语义不同，独立降级源（availableWeight 文案）；混入
        // unknown 会误报「未知或待重新导入」（结果实际含完整分母）。
        let unknownWeightInfo = VillageDetailProjection.instanceCountAndOverflow(
            of: items.filter {
                $0.status != .available
                    && (!VillageDetailProjection.isKnown($0) || $0.needsReimport)
            }
        )

        // 阶段进度：分母 = Σ(stageMax × weight)，分子 = Σ(min(level, stageMax) × weight)
        // 升级中且快照缺解锁建筑记录（stageMax == nil）的 known 项：#67 的 stageMax
        // 前提只对非升级项成立；该形态真实可达（投影 isUpgrading 分支先于 stageMax
        // 检查）。不得静默丢分母——计入阶段指标专用缺失权重触发降级（实现要求 5）。
        // nil 与 ≤0 cap（恶意目录，钳为 0 贡献）统一归缺失侧，防与正常项混合时
        // 无降级说明（交叉审核 nit 1，与漏洞 1 同构）。
        //
        // Issue #70 阶段 2（completeDenominator == true）：eligible = known ∪
        // available 宇宙差集。差集项 currentLevel == 0 → 分子贡献恒 0（现有
        // min(max(0, 0), cap) = 0 天然处理）；cap 过滤与 known 同规则
        //（stageMax > 0 / maxLevel > 0，任务书「available 过滤同 known 规则」）。
        // completeDenominator == false（阶段 1）→ available 不进 eligible
        //（isKnown 显式排除 .available，现有 known 过滤自动正确）。
        let available = completeDenominator
            ? items.filter { $0.status == .available }
            : []
        let stageEligible = known.filter { ($0.currentStageMaxLevel ?? 0) > 0 }
            + available.filter { ($0.currentStageMaxLevel ?? 0) > 0 }
        // 缺失侧只统计 known（评审 nit 1）：available 差集项的 stageMax == nil/≤0
        //（目录异常）由 eligible 过滤剔除后**不**计入本缺失侧——差集项已由
        // availableWeight 独立降级文案承担（全部 available 权重，含 cap 异常项），
        // 混入会与「缺少阶段上限」文案重复降级。
        let stageMissingWeightInfo = VillageDetailProjection.instanceCountAndOverflow(
            of: known.filter { ($0.currentStageMaxLevel ?? 0) <= 0 }
        )
        // cap 先 max(0,·) 再参与 min：恶意目录 cap 为负不得产生负分子/负分母
        // （交叉审核 F1，fail-closed 禁止假精度与负 ratio）。
        let stageDen = weightedCappedSum(stageEligible) { max(0, $0.currentStageMaxLevel ?? 0) }
        let stageNum = weightedCappedSum(stageEligible) {
            min(max(0, $0.currentLevel ?? 0), max(0, $0.currentStageMaxLevel ?? 0))
        }

        // 全局进度：分母 = Σ(maxLevel × weight)，分子 = Σ(min(level, maxLevel) × weight)
        // 与 stage 对称：nil/≤0 的非法 maxLevel 计入缺失权重降级（外部评审 P2-2），
        // 不静默 0 贡献。available 差集项同样并入（completeDenominator 时）。
        let globalEligible = known.filter { ($0.maxLevel ?? 0) > 0 }
            + available.filter { ($0.maxLevel ?? 0) > 0 }
        let globalMissingWeightInfo = VillageDetailProjection.instanceCountAndOverflow(
            of: known.filter { ($0.maxLevel ?? 0) <= 0 }
        )
        let globalDen = weightedCappedSum(globalEligible) { max(0, $0.maxLevel ?? 0) }
        let globalNum = weightedCappedSum(globalEligible) {
            min(max(0, $0.currentLevel ?? 0), max(0, $0.maxLevel ?? 0))
        }

        // 覆盖率：分母 = 全部观测实例权重 + 宇宙差集权重（完整覆盖率口径，
        // Issue #70 阶段 2：known / (known + unknown + available)）；
        // 分子 = known 实例权重（饱和信息保留）。
        // 现状 coverageDen = instanceCountAndOverflow(of: items) 已含 available
        //（合成项直接进 items）→ 自动完整，无需额外改动。
        let coverageDen = VillageDetailProjection.instanceCountAndOverflow(of: items)
        let coverageNum = VillageDetailProjection.instanceCountAndOverflow(of: known)

        // 宇宙差集权重（仅 completeDenominator 时纳入 partial 判定：存在差集项
        // → 覆盖率 < 100%，保守 partial，不得伪装 ready）。
        let availableWeightInfo = completeDenominator
            ? VillageDetailProjection.instanceCountAndOverflow(of: available)
            : (count: 0, didOverflow: false)

        let unverifiedCatalog = compatibility?.isUnverified ?? false

        return VillageProgressMetrics(
            currentStageProgress: makeMetric(
                kind: .currentStageProgress,
                numerator: stageNum.value,
                denominator: stageDen.value,
                saturated: stageNum.saturated || stageDen.saturated,
                unknownWeight: unknownWeightInfo.count,
                availableWeight: availableWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                denominatorIsComplete: completeDenominator,
                units: "级",
                emptyReason: "无可确认项目，暂无法计算",
                extraReason: stageMissingWeightInfo.count > 0
                    ? String(stageMissingWeightInfo.count) + " 项缺少阶段上限，未计入阶段进度。"
                    : nil
            ),
            globalProgress: makeMetric(
                kind: .globalProgress,
                numerator: globalNum.value,
                denominator: globalDen.value,
                saturated: globalNum.saturated || globalDen.saturated,
                unknownWeight: unknownWeightInfo.count,
                availableWeight: availableWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                denominatorIsComplete: completeDenominator,
                units: "级",
                emptyReason: "无可确认项目，暂无法计算",
                extraReason: globalMissingWeightInfo.count > 0
                    ? String(globalMissingWeightInfo.count) + " 项缺少或异常全局上限，未计入全局进度。"
                    : nil
            ),
            snapshotCoverage: makeMetric(
                kind: .snapshotCoverage,
                numerator: coverageNum.count,
                denominator: coverageDen.count,
                saturated: coverageNum.didOverflow || coverageDen.didOverflow,
                unknownWeight: unknownWeightInfo.count,
                availableWeight: availableWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                denominatorIsComplete: true, // 覆盖率语义天然是观测范围，不受完整分母影响
                units: "实例",
                emptyReason: "尚未导入快照"
            )
        )
    }

    /// 升级总览「观测数据完整性」卡的聚合：全部已导入村庄 × 全部基地的
    /// snapshotCoverage 实例权重汇总（Σknown/Σobserved）。coverage 分母天然
    /// 含宇宙差集 .available 实例（合成项恒在投影 items 中——universeComplete
    /// 的 home 投影合成时；completeDenominator 只影响 stage/global 的 eligible
    /// 与 partial 判定，不影响 coverage 口径）——聚合值语义 = 已观测实例占
    /// 全部可建造数量（UI detail 文案「已观测实例 · 全部村庄」准确，决策 8）。
    /// 任一村庄基地的 coverage 饱和或累加溢出 → 返回 nil（fail-closed：整体
    /// 不展示假精度，不得静默跳过饱和项让分母变小——外部评审 P1-2 复审）。
    /// 无已导入村庄或观测总数为 0 → nil（UI 不渲染该卡）。
    public static func aggregateCoverage(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        now: Date = Date()
    ) -> (known: Int, observed: Int)? {
        var known = 0
        var observed = 0
        for village in villages where village.hasImportedData {
            for base in TrackerBase.allCases {
                let projection = VillageCatalogProjection.project(
                    village: village,
                    catalog: catalog,
                    seasonalPhases: seasonalPhases,
                    base: base,
                    now: now
                )
                let metrics = VillageProgressProjection.metrics(
                    from: projection.items.filter { $0.status != .unavailable },
                    catalogIsUsable: projection.catalogIsUsable,
                    compatibility: projection.compatibility
                )
                let coverage = metrics.snapshotCoverage
                if coverage.saturated { return nil } // fail-closed
                let (k, kOver) = known.addingReportingOverflow(coverage.numerator)
                let (o, oOver) = observed.addingReportingOverflow(coverage.denominator)
                if kOver || oOver { return nil } // 累加溢出 fail-closed
                known = k
                observed = o
            }
        }
        guard observed > 0 else { return nil }
        return (known, observed)
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
        availableWeight: Int,
        unverifiedCatalog: Bool,
        denominatorIsComplete: Bool,
        units: String,
        emptyReason: String,
        extraReason: String? = nil
    ) -> ProgressMetric {
        let state: ProgressMetricState
        var reasons: [String] = []
        if denominator == 0 {
            state = .unknown
            reasons.append(emptyReason)
            // 唯一 known 项是升级中+缺 stageMax 时：emptyReason 不足以解释
            // 分母为 0 的成因，extraReason 拼接保留（交叉审核 A-2/B-F7）。
            if let extraReason {
                reasons.append(extraReason)
            }
        } else {
            if !denominatorIsComplete {
                reasons.append("分母为已观测项目，非村庄全部实例，无法计算完整村庄进度。")
            }
            if unknownWeight > 0 {
                reasons.append(String(unknownWeight) + " 项未知或待重新导入，结果仅为已观测项目。")
            }
            // Issue #70 阶段 2：完整分母下存在宇宙差集（可建造未观测）→ 覆盖率
            // < 100%，保守 partial（快照可能不全，不得伪装 ready）。权重 0
            //（差集项 count 恒 > 0，理论不可达）不产生文案。
            if availableWeight > 0 {
                reasons.append(String(availableWeight) + " 项宇宙差集未观测（可建造未导入），进度为完整分母下的保守估计。")
            }
            if let extraReason {
                reasons.append(extraReason)
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

    /// 等级式公式的实例加权饱和求和：`value(item) × instanceWeight` 累加，
    /// 乘法/加法任一溢出饱和到 Int.max 并置位（issue #66 fail-closed）。
    /// 聚合行 `countOverflowed` 标志补位上报（与 `instanceCountAndOverflow`
    /// 同契约）：单行 count=Int.max 且 value 贡献 1 时 `1 × Int.max` 无算术
    /// 溢出，但原始多条记录权重和已超 Int.max——饱和信息不得在链路前端丢失。
    private static func weightedCappedSum(
        _ items: [VillageItemState],
        value: (VillageItemState) -> Int
    ) -> (value: Int, saturated: Bool) {
        var saturated = false
        let total = items.reduce(0) { acc, item in
            if item.countOverflowed {
                saturated = true
            }
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
