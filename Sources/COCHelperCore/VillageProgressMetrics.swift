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
        /// 实例/数量维度的已完成实例数 / 追踪实例数。
        case instanceProgress
        /// 导入事实与本地手动完成状态合并后的全局 Tracker 进度。
        case effectiveTrackerProgress
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

/// 一个村庄、一个基地的五种相互独立的进度口径。
public struct VillageProgressMetrics: Hashable, Sendable {
    public let currentStageProgress: ProgressMetric
    public let globalProgress: ProgressMetric
    public let snapshotCoverage: ProgressMetric

    public let instanceProgress: ProgressMetric
    public let effectiveTrackerProgress: ProgressMetric

    public init(
        currentStageProgress: ProgressMetric,
        globalProgress: ProgressMetric,
        snapshotCoverage: ProgressMetric,
        instanceProgress: ProgressMetric? = nil,
        effectiveTrackerProgress: ProgressMetric? = nil
    ) {
        self.currentStageProgress = currentStageProgress
        self.globalProgress = globalProgress
        self.snapshotCoverage = snapshotCoverage
        self.instanceProgress = instanceProgress ?? ProgressMetric(
            kind: .instanceProgress,
            numerator: 0,
            denominator: 0,
            state: .unknown,
            units: "实例",
            degradedReason: "尚未建立实例进度口径。"
        )
        self.effectiveTrackerProgress = effectiveTrackerProgress ?? ProgressMetric(
            kind: .effectiveTrackerProgress,
            numerator: 0,
            denominator: 0,
            state: .unknown,
            units: "级",
            degradedReason: "尚未建立有效 Tracker 进度口径。"
        )
    }
}

/// 升级总览「观测数据完整性」卡的聚合结果（Issue #110）。
/// 数值 = 全部已导入村庄 × 全部基地的 snapshotCoverage 累加（BB 数值照旧计入）；
/// coverage = 仅合并 home 基地的 progressCoverage（决策 5：BB 恒 .unavailable，
/// 不参与 scope 判定——否则任何已导入村庄都自带 unavailable 对，聚合恒降级）；
/// 但存在有观测数据的 BB 对时 merged .complete 必须降级为 .partial（外部
/// 交叉审核 P1：数值含不可靠数据源时不得静默宣称完整）。
/// diagnostics = 聚合覆盖诊断（partial 专属，UI 层逐条展示；否则空数组）。
public struct AggregateCoverage: Hashable, Sendable {
    public let numerator: Int
    public let denominator: Int
    public let coverage: ProgressUniverseCoverage
    public let diagnostics: [String]

    /// 聚合卡 tooltip 的 scope 措辞（外部交叉审核 P2）：complete / unavailable
    /// 分母构成同质（全类别宇宙 / 纯已观测），与单村庄 `helpText` 口径一致；
    /// partial 为跨村庄/基地混合口径（complete 村庄全类别宇宙 + partial 村庄
    /// 观测∪建筑陷阱差集 + unavailable 村庄/BB 纯观测），不得复用单村庄
    /// 「与建筑/陷阱宇宙差集合计」措辞——聚合专用文案，明细见 diagnostics。
    public var helpText: String {
        switch coverage {
        case .complete:
            return "已观测实例占村庄全部可建造数量"
        case .partial:
            return "聚合分母为各村庄/基地已观测实例与可用宇宙差集之和，非统一完整宇宙口径"
        case .unavailable:
            return "分母为已观测实例，非全部可能建筑"
        }
    }
}

// MARK: - 投影

/// Issue #70/#140：五指标投影。纯函数，known 判定与 `VillageDetailProjection.totalCompletion`
/// 同规则（单一来源：`VillageDetailProjection.isKnown`）。
///
/// 指标语义：
/// - currentStageProgress：`Σmin(level, currentStageMaxLevel) / ΣcurrentStageMaxLevel`，
///   分母只含 known 且阶段上限可计算的实例。非升级 known 项 stageMax 非 nil；
///   升级中项可能 stageMax == nil（快照缺解锁建筑记录，投影 isUpgrading 分支先于
///   stageMax 检查）——该形态计入阶段指标专用缺失权重触发降级，不静默丢分母
///   （实现要求 5）。cap 先 max(0,·) 钳制，恶意目录负 cap 不产生负贡献（F1）；
///   **完整分母（`coverage.isComplete`，Issue #96）**：分母扩展到 known ∪
///   available 宇宙差集（差集项 currentLevel == 0 → 分子贡献 0，cap 过滤与
///   known 同规则）；
/// - globalProgress：`Σmin(level, maxLevel) / ΣmaxLevel`，同样只含 known 实例；
///   完整分母下同样并入 available 差集项；
/// - snapshotCoverage：`known 实例权重 / 全部追踪类别观测实例权重`——观测数据
///   完整性（已知/未知比例）。分母含宇宙差集项权重，成为完整覆盖率
///   `known / (known + unknown + available)`（100% ⟺ 快照覆盖全部宇宙项）。
///
/// 状态判定（决策 2/3/5 + Issue #96）：
/// - `catalogIsUsable == false` → 五种指标全部 `.unavailable`（目录不可用/版本不匹配，
///   fail-closed，禁止假精度）；
/// - 分母 == 0 → `.unknown`（无快照或无可确认实例）；
/// - 未知实例权重 > 0（含 needsReimport 项归未知侧，实现要求 4）→ `.partial`；
/// - 完整分母（`coverage.isComplete`）且宇宙差集权重 > 0 → `.partial`
///   （覆盖率 < 100% 保守：快照可能不全，不得伪装 ready）；
/// - `compatibility == .unverified` → 可计算指标强制 `.partial`（未验证目录不伪装
///   ready），degradedReason 说明；
/// - `coverage.isComplete == false`（Issue #96：partial/unavailable——TH 缺失/
///   目录无宇宙/BB base/快照缺 section 等）→ 可计算且无其余降级 → `.partial`
///   强制（分母为已观测项目，非村庄全部实例，不得误称全村庄进度——验收 3）；
///   partial 的缺失 section / 未建模类别明细拼入降级文案（覆盖诊断），
///   unavailable（目录/TH/BB 侧）由「分母为已观测项目」文案覆盖；
/// - 其余 → `.ready`。
/// 饱和（issue #66 fail-closed）：分子/分母各自饱和求和，任一饱和 →
/// `saturated = true` → ratio 恒 nil；饱和不改变 state（UI 层饱和优先）。
public enum VillageProgressProjection {
    public static func metrics(
        from items: [VillageItemState],
        catalogIsUsable: Bool,
        compatibility: CatalogCompatibility?,
        coverage: ProgressUniverseCoverage = .unavailable
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
        // Issue #96：完整分母许可 = 覆盖契约 .complete（三消费者唯一判定点，
        // 不各自解释旧 universeComplete）。partial/unavailable → 阶段 1 语义
        //（差集不进 eligible，分母为已观测项目 + 覆盖诊断）。
        let completeDenominator = coverage.isComplete
        // 覆盖诊断（partial 专属）：缺失 section / 未建模类别，透传给降级文案。
        let coverageDiagnostic = Self.coverageDiagnostic(for: coverage)

        // eligible = known ∪（完整分母时）available 宇宙差集。差集项
        // currentLevel == 0 → 分子贡献恒 0（现有 min(max(0, 0), cap) = 0 天然
        // 处理）；cap 过滤与 known 同规则（stageMax > 0 / maxLevel > 0，
        // 任务书「available 过滤同 known 规则」）。
        // 非完整分母（Issue #96：coverage.isComplete == false）→ available 不进
        // eligible（isKnown 显式排除 .available，现有 known 过滤自动正确）。
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
        // 不静默 0 贡献。available 差集项同样并入（coverage.isComplete 时）。
        let globalEligible = known.filter { ($0.maxLevel ?? 0) > 0 }
            + available.filter { ($0.maxLevel ?? 0) > 0 }
        let globalMissingWeightInfo = VillageDetailProjection.instanceCountAndOverflow(
            of: known.filter { ($0.maxLevel ?? 0) <= 0 }
        )
        let globalDen = weightedCappedSum(globalEligible) { max(0, $0.maxLevel ?? 0) }
        let globalNum = weightedCappedSum(globalEligible) {
            min(max(0, $0.currentLevel ?? 0), max(0, $0.maxLevel ?? 0))
        }

        // 覆盖率：分母 = 全部追踪类别观测实例权重 + 已建模类别（有宇宙键）的
        // 宇宙差集权重（Issue #70 阶段 2 + #96 口径契约：known / (known +
        // unknown + available)）。
        // **口径契约（P1 交叉审核）**：complete（全类别建模）时分母 = 全类别
        // 宇宙全量；partial（仅建筑/陷阱建模）时分母 = 全部类别已观测 ∪
        // 建筑/陷阱差集——未建模类别（units 等）只计观测、无差集补充。
        // UI help 文案必须与之一致（`ProgressUniverseCoverage.helpText`，Issue
        // #110 共享到 Core 防漂移），不得宣称
        //「已建模可建造数量」（该称谓要求分母只含已建模类别的宇宙量）。
        // 现状 coverageDen = instanceCountAndOverflow(of: items) 已含 available
        //（合成项直接进 items）→ 自动符合契约，无需额外改动。
        let coverageDen = VillageDetailProjection.instanceCountAndOverflow(of: items)
        let coverageNum = VillageDetailProjection.instanceCountAndOverflow(of: known)

        // 宇宙差集权重（仅 coverage.isComplete 时纳入 partial 判定：存在差集项
        // → 覆盖率 < 100%，保守 partial，不得伪装 ready）。
        let availableWeightInfo = completeDenominator
            ? VillageDetailProjection.instanceCountAndOverflow(of: available)
            : (count: 0, didOverflow: false)

        let unverifiedCatalog = compatibility?.isUnverified ?? false

        let currentStageMetric = makeMetric(
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
                    : nil,
                coverageDiagnostic: coverageDiagnostic
            )
        let globalMetric = makeMetric(
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
                    : nil,
                coverageDiagnostic: coverageDiagnostic
            )
        let snapshotMetric = makeMetric(
                kind: .snapshotCoverage,
                numerator: coverageNum.count,
                denominator: coverageDen.count,
                saturated: coverageNum.didOverflow || coverageDen.didOverflow,
                unknownWeight: unknownWeightInfo.count,
                availableWeight: availableWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                // 覆盖率分母天然是观测范围，不受完整分母影响（该参数只决定
                // 「分母为已观测项目」文案，覆盖率不触发）。Issue #110：
                // 覆盖诊断照常透传——partial（缺 section/未建模类别）时
                // reasons 非空 → makeMetric 自动降级 .partial，即使
                // numerator == denominator 也不得显示无 scope 的裸 100%
                //（验收 3）；complete + 全 known 时 reasons 空 → .ready 不变。
                denominatorIsComplete: true,
                units: "实例",
                emptyReason: "尚未导入快照",
                coverageDiagnostic: coverageDiagnostic
            )
        let instanceDenominator = VillageDetailProjection.instanceCountAndOverflow(of: items)
        let instanceNumerator = VillageDetailProjection.instanceCountAndOverflow(
            of: known.filter { $0.status == .maxed }
        )
        let instanceMetric = makeMetric(
            kind: .instanceProgress,
            numerator: instanceNumerator.count,
            denominator: instanceDenominator.count,
            saturated: instanceNumerator.didOverflow || instanceDenominator.didOverflow,
            unknownWeight: unknownWeightInfo.count,
            availableWeight: availableWeightInfo.count,
            unverifiedCatalog: unverifiedCatalog,
            denominatorIsComplete: completeDenominator,
            units: "实例",
            emptyReason: "无可确认项目，暂无法计算",
            coverageDiagnostic: coverageDiagnostic
        )
        let effectiveMetric = ProgressMetric(
            kind: .effectiveTrackerProgress,
            numerator: globalMetric.numerator,
            denominator: globalMetric.denominator,
            state: globalMetric.state,
            saturated: globalMetric.saturated,
            units: globalMetric.units,
            degradedReason: globalMetric.degradedReason
        )

        return VillageProgressMetrics(
            currentStageProgress: currentStageMetric,
            globalProgress: globalMetric,
            snapshotCoverage: snapshotMetric,
            instanceProgress: instanceMetric,
            effectiveTrackerProgress: effectiveMetric
        )
    }

    /// 升级总览「观测数据完整性」卡的聚合：全部已导入村庄 × 全部基地的
    /// snapshotCoverage 实例权重汇总（Σknown/Σobserved）。该指标分母天然
    /// 含宇宙差集 .available 实例（合成项恒在投影 items 中——progressCoverage
    /// 的 home 投影合成时；coverage 参数只影响 stage/global 的 eligible
    /// 与 partial 判定，不影响覆盖率口径）——聚合值语义 = 已观测实例占
    ///（建筑/陷阱）宇宙建模范围内的可建造数量（Issue #96：差集仅覆盖
    /// 建筑/陷阱，不得宣称全村庄；UI detail 文案「已观测实例 · 全部村庄」
    /// 中「全部村庄」指聚合范围——跨全部已导入村庄，非分母宣称，决策 8）。
    /// 任一村庄基地的 coverage 饱和或累加溢出 → 返回 nil（fail-closed：整体
    /// 不展示假精度，不得静默跳过饱和项让分母变小——外部评审 P1-2 复审）。
    /// 无已导入村庄或观测总数为 0 → nil（UI 不渲染该卡）。
    /// Issue #110：返回 `AggregateCoverage?`（数值字段与旧 tuple 逐位一致）；
    /// coverage 仅合并 home 对的 progressCoverage（BB 恒 .unavailable，决策 5
    /// ——混入会使任何已导入村庄的聚合恒降级，候选 A 否决）；但**有观测数据
    /// 的 BB 对**（denominator > 0，数值已计入聚合）必须触发 scope 降级——
    /// BB 数据源不可靠（决策 5），home 全 .complete 时不得静默宣称「完整」
    /// （外部交叉审核 P1）；diagnostics 由 `aggregateCoverageDiagnostics`
    /// 生成（partial 专属，UI 层展示）。
    public static func aggregateCoverage(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        now: Date = Date(),
        projectionProvider: VillageProjectionProvider? = nil,
        craftTableCatalog: CraftTableCatalog? = nil,
        manualUpgradeCores: [UUID: ManualUpgradeCore]? = nil
    ) -> AggregateCoverage? {
        var known = 0
        var observed = 0
        var homeCoverages: [ProgressUniverseCoverage] = []
        var bbHasObservations = false
        for village in villages where village.hasImportedData {
            for base in TrackerBase.allCases {
                // Issue #200 review P1：注入投影缓存（AppModel 层），避免
                // 总览完整性卡每个 tick 对每村庄×基地重跑完整投影；
                // 未注入时保持直接构建（行为不变）。craftTableCatalog /
                // manualUpgradeCores 与详情页（villageRender）同口径透传，
                // 避免覆盖数值因 manual core 漂移（review 二轮 golden 修复）。
                let projection = projectionProvider?(village, base, now)
                    ?? VillageCatalogProjection.project(
                        village: village,
                        catalog: catalog,
                        seasonalPhases: seasonalPhases,
                        craftTableCatalog: craftTableCatalog,
                        base: base,
                        now: now,
                        manualUpgradeCore: manualUpgradeCores?[village.id]
                    )
                if base == .home {
                    homeCoverages.append(projection.progressCoverage)
                }
                let metrics = projection.progressMetrics
                let coverage = metrics.snapshotCoverage
                if coverage.saturated { return nil } // fail-closed
                let (k, kOver) = known.addingReportingOverflow(coverage.numerator)
                let (o, oOver) = observed.addingReportingOverflow(coverage.denominator)
                if kOver || oOver { return nil } // 累加溢出 fail-closed
                known = k
                observed = o
                // BB 对不参与 home scope 合并（决策 5 恒 .unavailable），但数值
                // 照旧计入聚合——因此只要 BB 有观测数据（denominator > 0）就
                // 必须反映到 scope：merged == .complete 时降为 .partial +
                // BB 数据源诊断，不得把不可靠数据源的数值混进「完整」承诺。
                if base != .home && coverage.denominator > 0 {
                    bbHasObservations = true
                }
            }
        }
        guard observed > 0 else { return nil }
        var merged = Self.mergedCoverage(of: homeCoverages)
        if bbHasObservations && merged == .complete {
            // 数值含 BB 观测 → 完整宇宙承诺不成立（外部交叉审核 P1）
            merged = .partial(missingSections: [], unmodeledCategories: [])
        }
        return AggregateCoverage(
            numerator: known,
            denominator: observed,
            coverage: merged,
            diagnostics: Self.aggregateCoverageDiagnostics(
                merged: merged,
                unavailableHomeCount: homeCoverages.filter { $0 == .unavailable }.count,
                includesBuilderBaseData: bbHasObservations
            )
        )
    }

    /// 合并多村庄 home 对的 coverage（Issue #110，纯函数，供 property 测试）：
    /// - 存在任一 .partial → .partial——missingSections / unmodeledCategories
    ///   取并集，missing 先按类别映射 subtract unmodeled 去重（同一类别既
    ///   缺失又未建模只报一次，防诊断重复；未映射到类别的 section 保底保留）；
    /// - 无 .partial 但含 .unavailable 与 .complete 混合 → .partial（明细空，
    ///   诊断由 unavailableHomeCount 计数生成）——unavailable 村庄（TH 未知/
    ///   目录无宇宙）不得被静默成 .complete（Reflexion 自查修复）；
    /// - 无任何 partial/unavailable 且存在 .complete → .complete（无诊断）；
    /// - 全 .unavailable 或空列表 → .unavailable（无差集，纯已观测口径；
    ///   调用方 observed == 0 → nil 路径兜底）。
    static func mergedCoverage(
        of coverages: [ProgressUniverseCoverage]
    ) -> ProgressUniverseCoverage {
        var missing = Set<String>()
        var unmodeled = Set<TrackerCategory>()
        var sawComplete = false
        var sawPartial = false
        var sawUnavailable = false
        for coverage in coverages {
            switch coverage {
            case .complete:
                sawComplete = true
            case .partial(let sections, let categories):
                sawPartial = true
                missing.formUnion(sections)
                unmodeled.formUnion(categories)
            case .unavailable:
                sawUnavailable = true
            }
        }
        if sawPartial {
            // 去重：missing 中映射到未建模类别的 section 让位给 unmodeled 侧
            //（同一类别只在 unmodeled 报一次）；映射不到的 section 保留（fallback）。
            let deduped = missing.filter {
                guard let category = TrackerCategory.from(section: $0) else { return true }
                return !unmodeled.contains(category)
            }
            return .partial(missingSections: deduped, unmodeledCategories: unmodeled)
        }
        if !sawComplete { return .unavailable }
        if sawUnavailable {
            return .partial(missingSections: [], unmodeledCategories: [])
        }
        return .complete
    }

    /// 聚合覆盖诊断（Issue #110，partial 专属；merged 非 partial → []）。
    /// 措辞与 detail 页 `coverageDiagnostic(for:)` 同风格，但 missing 前缀
    /// 「部分村庄」——聚合是跨村庄并集，不得暗示所有村庄都缺同一类别；
    /// 中文类别名映射复用 `TrackerCategory.from(section:)?.title`（同口径，
    /// fallback 原文）。unavailableHomeCount = 合并前 home 对中 .unavailable
    /// 的个数（BB 对不参与——决策 5 只排除 BB 的 scope 参与，计数同样只算
    /// home 对，避免「任何已导入村庄都带一个 BB unavailable 对」的恒量噪音）。
    /// includesBuilderBaseData = 存在有观测数据的 BB 对（外部交叉审核 P1：
    /// BB 数值计入聚合后必须附加数据源诊断，不得静默）。
    static func aggregateCoverageDiagnostics(
        merged: ProgressUniverseCoverage,
        unavailableHomeCount: Int,
        includesBuilderBaseData: Bool = false
    ) -> [String] {
        guard case .partial(let missing, let unmodeled) = merged else { return [] }
        var parts: [String] = []
        if !missing.isEmpty {
            let titles = missing
                .compactMap { TrackerCategory.from(section: $0)?.title ?? $0 }
                .sorted()
                .joined(separator: "、")
            parts.append("部分村庄快照缺少类别数据（" + titles + "），无法确认完整村庄进度。")
        }
        if !unmodeled.isEmpty {
            parts.append("目录未对" + unmodeled.map(\.title).sorted().joined(separator: "、") + "的实例数量建模，无法确认完整村庄进度。")
        }
        if unavailableHomeCount > 0 {
            parts.append(String(unavailableHomeCount) + " 个村庄覆盖状态不可用，无法确认完整村庄进度。")
        }
        if includesBuilderBaseData {
            parts.append("聚合含建筑大师基地已观测数据（数据源不可靠，未纳入完整宇宙口径），无法确认完整村庄进度。")
        }
        return parts
    }

    // MARK: - Helpers

    /// Issue #96：覆盖诊断文案（partial 专属）。unavailable（目录/TH/BB 侧）
    /// 由既有「分母为已观测项目」文案覆盖；complete 无诊断。
    private static func coverageDiagnostic(for coverage: ProgressUniverseCoverage) -> String? {
        guard case .partial(let missing, let unmodeled) = coverage else { return nil }
        var parts: [String] = []
        if !missing.isEmpty {
            // 先映射中文类别名再排序（与 unmodeled 分支同口径——两条诊断的
            // 类别顺序一致，避免中英混排与口径不一致）；progressSections 全为
            // 追踪类别，from() 恒非 nil，fallback 保底。
            let titles = missing
                .compactMap { TrackerCategory.from(section: $0)?.title ?? $0 }
                .sorted()
                .joined(separator: "、")
            parts.append("快照缺少类别数据（" + titles + "），无法确认完整村庄进度。")
        }
        if !unmodeled.isEmpty {
            parts.append("目录未对" + unmodeled.map(\.title).sorted().joined(separator: "、") + "的实例数量建模，无法确认完整村庄进度。")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

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
                state: .unavailable, units: "实例", degradedReason: reason),
            instanceProgress: ProgressMetric(
                kind: .instanceProgress, numerator: 0, denominator: 0,
                state: .unavailable, units: "实例", degradedReason: reason),
            effectiveTrackerProgress: ProgressMetric(
                kind: .effectiveTrackerProgress, numerator: 0, denominator: 0,
                state: .unavailable, units: "级", degradedReason: reason)
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
        extraReason: String? = nil,
        coverageDiagnostic: String? = nil
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
            if let coverageDiagnostic {
                reasons.append(coverageDiagnostic)
            }
        } else {
            if !denominatorIsComplete {
                reasons.append("分母为已观测项目，非村庄全部实例，无法计算完整村庄进度。")
            }
            if unknownWeight > 0 {
                reasons.append(String(unknownWeight) + " 项未知或待重新导入，结果仅为已观测项目。")
            }
            // Issue #96：完整分母下存在宇宙差集（可建造未观测）→ 覆盖率
            // < 100%，保守 partial（快照可能不全，不得伪装 ready）。权重 0
            //（差集项 count 恒 > 0，理论不可达）不产生文案。
            if availableWeight > 0 {
                reasons.append(String(availableWeight) + " 项宇宙差集未观测（可建造未导入），进度为完整分母下的保守估计。")
            }
            if let extraReason {
                reasons.append(extraReason)
            }
            if let coverageDiagnostic {
                reasons.append(coverageDiagnostic)
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
