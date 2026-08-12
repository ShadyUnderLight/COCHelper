import Foundation

/// 单个升级阶梯单元格（目录逐级数据）。
public struct BuildingUpgradeStep: Hashable, Sendable {
    /// 目标等级（升序）。
    public let level: Int
    /// 多资源升级费用（透传 `CatalogLevel.upgradeCosts`，Issue #73）。
    /// nil = 无费用数据；非空数组即存在费用数据（含全 parseFailed——此时 UI
    /// 展示 raw 原文）。元素语义见 `CatalogUpgradeCost`。
    public let upgradeCosts: [CatalogUpgradeCost]?
    /// 完整升级时长；nil = 缺失，0 = 有效即时升级。
    public let durationSeconds: Int64?
    /// Issue #74b：目录缺失原因（CatalogLevel.missingReason 透传；组卡据此
    /// 区分「全部缺失」与「部分缺失」，缺失类不再与「无目录」同文案）。
    public let missingReason: String?

    public init(
        level: Int,
        upgradeCosts: [CatalogUpgradeCost]?,
        durationSeconds: Int64?,
        missingReason: String? = nil
    ) {
        self.level = level
        self.upgradeCosts = upgradeCosts
        self.durationSeconds = durationSeconds
        self.missingReason = missingReason
    }

    /// 是否存在费用数据：`upgradeCosts` 非空即存在（全 parseFailed 也返回 true，
    /// 此时 UI 展示 raw 原文；`ClanDisplayFormat.upgradeCostLabel` 三分支）。
    public var hasCost: Bool { upgradeCosts?.isEmpty == false }
    public var hasDuration: Bool { durationSeconds != nil }
    public var isInstant: Bool { durationSeconds == 0 }

    /// Issue #74b：时长语义映射（与 `CatalogLevel.durationState` 同一单一
    /// 映射点 `CatalogDurationState.state`，防双实现漂移）。nil = 双 nil
    /// 未知场景（UI 兜底「暂无目录数据」）。
    public var durationState: CatalogDurationState? {
        CatalogDurationState.state(durationSeconds: durationSeconds, missingReason: missingReason)
    }
}

/// 一条原始快照记录 + 其升级阶梯（可追溯）。
public struct BuildingInstance: Identifiable, Hashable, Sendable {
    /// 原始快照记录 ID（可追溯，非 agg: 前缀）。
    public let id: String
    /// 原始投影记录（复用全部现有字段：currentLevel/maxLevel/count/计时/资产…）。
    public let item: VillageItemState
    /// 阶梯单元格，level 升序；满级或不可 join 时为空数组。
    public let steps: [BuildingUpgradeStep]
}

/// 单资源费用汇总。
public struct BuildingResourceTotal: Hashable, Sendable {
    public let resource: String
    public let totalCost: Int64
}

/// 组卡汇总完整性。
public enum BuildingGroupCompleteness: String, Hashable, Sendable, CaseIterable {
    /// 全部阶梯费用/时长齐全。
    case complete
    /// 任一阶梯费用或时长缺失（或存在无法生成阶梯的已知实例）。
    case partialMissing
    /// 任一实例 currentLevel > maxLevel（目录过时）：不得输出权威汇总。
    case versionMismatch
}

/// 组卡汇总。
public struct BuildingGroupSummary: Hashable, Sendable {
    /// 所有实例数量之和（使用 `VillageItemState.instanceWeight`）。
    public let instanceCount: Int
    /// 所有实例剩余等级数之和（×instanceWeight）。
    public let remainingLevelCount: Int
    /// 所有已知等级完整升级时间之和（×instanceWeight，秒）。
    public let totalDurationSeconds: Int64
    /// 按资源类型汇总的费用（×instanceWeight；按 resource 字典序）。
    /// 只累加成功项（!parseFailed && amount != nil）；parseFailed 项金额不可信
    /// 不进入汇总（任一失败项 → completeness 降级，UI 另显 raw 原文）。
    public let costByResource: [BuildingResourceTotal]
    /// 任一汇总字段发生饱和。为 true 时数值仅是可表示上界，不应作为精确业务数据展示。
    public let saturated: Bool
    public let completeness: BuildingGroupCompleteness
}

/// One v1 local-tracker action exposed by a duplicate group.
///
/// The action always represents one source quantity.  A caller can invoke the
/// existing `ManualUpgradeCore.startUpgrade` once for this action; batching and
/// queue management remain outside this projection.
public struct BuildingGroupUpgradeAction: Hashable, Sendable {
    public let fromLevel: Int
    public let targetLevel: Int
    public let quantity: Int64
    public let durationState: CatalogDurationState?
    public let upgradeCosts: [CatalogUpgradeCost]?
    public let isStartable: Bool
    public let diagnostic: String?

    public init(
        fromLevel: Int,
        targetLevel: Int,
        quantity: Int64 = 1,
        durationState: CatalogDurationState?,
        upgradeCosts: [CatalogUpgradeCost]?,
        isStartable: Bool,
        diagnostic: String? = nil
    ) {
        self.fromLevel = fromLevel
        self.targetLevel = targetLevel
        self.quantity = quantity
        self.durationState = durationState
        self.upgradeCosts = upgradeCosts
        self.isStartable = isStartable
        self.diagnostic = diagnostic
    }
}

/// Stable tracker-facing state for one duplicate group.
///
/// `effectiveCompletedDistribution` is the currently available completed
/// material.  When an active local record reserves one source quantity, that
/// quantity is absent from this distribution and appears in
/// `activeTargetDistribution` instead.  This keeps source conservation visible
/// without collapsing mixed-level records into a singular current level.
public struct BuildingGroupTrackerState: Hashable, Sendable {
    public let itemKey: TrackerItemKey
    public let importedDistribution: ManualLevelDistribution?
    public let manualCompletedDistribution: ManualLevelDistribution?
    public let effectiveCompletedDistribution: ManualLevelDistribution?
    public let activeTargetDistribution: ManualLevelDistribution
    public let activeRecords: [ManualUpgradeRecord]
    public let status: EffectiveVillageItemStatus
    public let provenance: [EffectiveVillageItemProvenance]
    public let diagnostics: [String]
    public let actions: [BuildingGroupUpgradeAction]

    public init(
        itemKey: TrackerItemKey,
        importedDistribution: ManualLevelDistribution?,
        manualCompletedDistribution: ManualLevelDistribution?,
        effectiveCompletedDistribution: ManualLevelDistribution?,
        activeTargetDistribution: ManualLevelDistribution = .empty,
        activeRecords: [ManualUpgradeRecord] = [],
        status: EffectiveVillageItemStatus,
        provenance: [EffectiveVillageItemProvenance] = [],
        diagnostics: [String] = [],
        actions: [BuildingGroupUpgradeAction] = []
    ) {
        self.itemKey = itemKey
        self.importedDistribution = importedDistribution
        self.manualCompletedDistribution = manualCompletedDistribution
        self.effectiveCompletedDistribution = effectiveCompletedDistribution
        self.activeTargetDistribution = activeTargetDistribution
        self.activeRecords = activeRecords
        self.status = status
        self.provenance = provenance
        self.diagnostics = diagnostics
        self.actions = actions
    }

    /// Quantity still available to start at a source level; nil means unknown.
    public func availableQuantity(at level: Int) -> Int64? {
        effectiveCompletedDistribution.map { $0.quantity(at: level) }
    }

    public var importedQuantity: Int64? {
        importedDistribution?.totalQuantity
    }

    public var completedQuantity: Int64? {
        effectiveCompletedDistribution?.totalQuantity
    }

    public var activeQuantity: Int64 {
        activeTargetDistribution.totalQuantity
    }

    public func activeQuantity(fromLevel: Int) -> Int64 {
        activeRecords
            .filter { $0.fromLevel == fromLevel }
            .reduce(0) { $0 + $1.quantity }
    }

    public func activeQuantity(targetLevel: Int) -> Int64 {
        activeTargetDistribution.quantity(at: targetLevel)
    }
}

/// 同类建筑组。
public struct BuildingGroup: Identifiable, Hashable, Sendable {
    public let base: TrackerBase
    public let section: String
    public let dataID: Int64
    public let name: String
    public let instances: [BuildingInstance]  // 快照输入顺序
    public let summary: BuildingGroupSummary
    /// 投影层推导（复用 BuildingDisplayCategoryRules），UI 分派键。
    public let displayCategory: TrackerDisplayCategory?
    public let category: TrackerCategory?
    /// Stable local-tracker state; one state per semantic group key.
    public let trackerState: BuildingGroupTrackerState
    public var id: String { "\(base.rawValue):\(section):\(dataID)" }
}

/// 组卡投影入口。纯函数，不改变任何现有投影/持久化语义。
/// 输出范围：section ∈ {buildings, buildings2} 的非嵌套项（UI 门仅剩 craftTable 防御）。
public enum BuildingGroupProjection {
    public static func project(
        village: VillageProfile,
        catalog: GameCatalog?,
        base: TrackerBase,
        expectedGameVersion: String? = nil,  // Issue #74a：默认不自我比较（unverified）
        seasonalPhases: SeasonalPhaseTable = .empty,
        now: Date = Date(),
        manualUpgradeCore: ManualUpgradeCore? = nil
    ) -> [BuildingGroup] {
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            expectedGameVersion: expectedGameVersion,
            seasonalPhases: seasonalPhases,
            base: base,
            now: now,
            manualUpgradeCore: manualUpgradeCore
        )
        return project(projection: projection, catalog: catalog, base: base)
    }

    /// Builds group cards from the already-resolved village projection.
    ///
    /// The previous implementation re-read `AccountSnapshot` and called the
    /// catalog mapper again. Reusing `rawItems` keeps prerequisite, lifecycle,
    /// and effective-state decisions identical to detail/overview consumers.
    public static func project(
        projection: VillageCatalogProjection,
        catalog: GameCatalog?,
        base: TrackerBase
    ) -> [BuildingGroup] {
        // 目录可用性（与 VillageCatalogProjection 同语义，Review 反馈 P1-2）：
        // 目录存在且版本与期望匹配时才可用；expectedGameVersion == nil 不校验。
        // 注意区分两种降级（Issue #45 契约第 5 节）：目录不可用（catalog == nil）
        // 是「缺失态」→ partialMissing（UI 橙标 + 诊断）；目录存在但版本不匹配
        // 是「不得输出权威汇总」→ versionMismatch（UI 红标诊断）。
        // Issue #74a：完成度可用性由兼容性状态派生（与 VillageCatalogProjection
        // 同一判定点，防手写版本比较漂移）。
        let catalogIsUsable = projection.catalogIsUsable
        // 原始记录层（聚合前）：只取 buildings/buildings2 的非嵌套项。
        // catalogIsUsable 必须显式传入（Issue #67 P1-2）：版本不匹配时行状态
        // 不得消费旧目录判 maxed/complete——组卡→详情链路与列表行同口径。
        let records = projection.rawItems.filter {
            !$0.isNested && ($0.section == "buildings" || $0.section == "buildings2")
                && $0.base == base
        }

        // 按 (base, section, dataID) 分组。组顺序必须由稳定语义键决定，不能
        // 依赖快照数组的首现顺序；实例数组本身仍保留输入顺序供追溯/UI 使用。
        struct GroupKey: Hashable {
            let section: String
            let dataID: Int64
        }
        var grouped: [GroupKey: [VillageItemState]] = [:]
        for record in records {
            let key = GroupKey(section: record.section, dataID: record.dataID)
            grouped[key, default: []].append(record)
        }
        let keys = grouped.keys.sorted {
            if $0.section != $1.section { return $0.section < $1.section }
            return $0.dataID < $1.dataID
        }
        let effectiveByKey = Dictionary(
            uniqueKeysWithValues: projection.effectiveTrackerItems.map { ($0.itemKey, $0) }
        )

        return keys.compactMap { key in
            guard let records = grouped[key],
                  let first = records.sorted(by: { $0.id < $1.id }).first else { return nil }
            let instances = records.map { record in
                BuildingInstance(
                    id: record.id,
                    item: record,
                    steps: steps(for: record, catalog: catalog, catalogIsUsable: catalogIsUsable)
                )
            }
            let itemKey = TrackerItemKey.root(
                base: base,
                rawSection: first.section,
                dataID: first.dataID
            )
            return BuildingGroup(
                base: base,
                section: first.section,
                dataID: first.dataID,
                name: first.name,
                instances: instances,
                summary: summary(for: instances, catalogIsUsable: catalogIsUsable, catalogIsNil: catalog == nil),
                displayCategory: first.displayCategory,
                category: first.category,
                trackerState: trackerState(
                    for: itemKey,
                    effective: effectiveByKey[itemKey],
                    catalog: catalog,
                    catalogIsUsable: catalogIsUsable
                )
            )
        }
    }

    private static func trackerState(
        for itemKey: TrackerItemKey,
        effective: EffectiveVillageItemState?,
        catalog: GameCatalog?,
        catalogIsUsable: Bool
    ) -> BuildingGroupTrackerState {
        guard let effective else {
            return BuildingGroupTrackerState(
                itemKey: itemKey,
                importedDistribution: nil,
                manualCompletedDistribution: nil,
                effectiveCompletedDistribution: nil,
                status: .unavailable,
                diagnostics: ["没有对应的稳定 tracker 状态。"]
            )
        }

        var diagnostics = effective.diagnostic.map { [$0] } ?? []
        if effective.effectiveCompletedDistribution == nil {
            diagnostics.append("完成等级分布未知，不能生成升级操作。")
        }
        if catalog == nil || !catalogIsUsable {
            diagnostics.append("目录不可用，不能生成升级操作。")
        } else if catalog?.item(section: itemKey.rawSection, dataID: itemKey.dataID) == nil {
            diagnostics.append("目录中没有对应的升级条目，不能生成升级操作。")
        }

        return BuildingGroupTrackerState(
            itemKey: itemKey,
            importedDistribution: effective.importedDistribution,
            manualCompletedDistribution: effective.manualCompletedDistribution,
            effectiveCompletedDistribution: effective.effectiveCompletedDistribution,
            activeTargetDistribution: effective.activeTargetDistribution,
            activeRecords: effective.activeManualRecords,
            status: effective.status,
            provenance: effective.provenance,
            diagnostics: unique(diagnostics),
            actions: actions(
                for: effective,
                catalog: catalog,
                catalogIsUsable: catalogIsUsable
            )
        )
    }

    private static func actions(
        for effective: EffectiveVillageItemState,
        catalog: GameCatalog?,
        catalogIsUsable: Bool
    ) -> [BuildingGroupUpgradeAction] {
        guard catalogIsUsable,
              let distribution = effective.effectiveCompletedDistribution,
              let catalogItem = catalog?.item(
                section: effective.itemKey.rawSection,
                dataID: effective.itemKey.dataID
              ),
              catalogItem.base == effective.itemKey.base.rawValue else {
            return []
        }

        let levels = catalogItem.levels.sorted { $0.level < $1.level }
        return distribution.levels.compactMap { source in
            guard let target = levels.first(where: { $0.level > source.level }) else {
                return nil
            }

            var reasons: [String] = []
            switch effective.status {
            case .observed, .manualCompleted, .manualActive:
                break
            case .importedActive:
                reasons.append("导入计时尚未被本地 tracker 精确接管。")
            case .needsReimport:
                reasons.append("导入快照需要重新导入。")
            case .conflict:
                reasons.append("本地与导入状态冲突。")
            case .unknown:
                reasons.append("当前等级分布未知。")
            case .unavailable:
                reasons.append("当前项目不可用。")
            }

            if let stageMax = effective.currentStageMaxLevel {
                if target.level > stageMax {
                    reasons.append("目标等级超过当前阶段上限。")
                }
            } else {
                reasons.append("当前阶段上限无法验证。")
            }

            if let globalMax = effective.globalMaxLevel, target.level > globalMax {
                reasons.append("目标等级超过目录全局上限。")
            }

            switch target.durationState {
            case .timed, .instant:
                break
            default:
                reasons.append("目标升级时长不可用。")
            }

            let isStartable = reasons.isEmpty && source.quantity > 0
            return BuildingGroupUpgradeAction(
                fromLevel: source.level,
                targetLevel: target.level,
                durationState: target.durationState,
                upgradeCosts: target.upgradeCosts,
                isStartable: isStartable,
                diagnostic: reasons.isEmpty ? nil : reasons.joined(separator: "；")
            )
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// 阶梯：目录 levels 中 `level ∈ (currentLevel, effectiveMax]` 的条目，按 level 升序。
    /// 目录等级可能不连续，必须过滤目录 levels 而非生成连续整数。
    /// `effectiveMax` = 阶段上限（issue #67）优先，不可计算时回退全局 maxLevel——
    /// 与行级 `.maxed` 判定同口径，保证组卡与列表行不矛盾（审核 C important）。
    /// currentLevel 为 nil、目录未命中或 base 不匹配（maxLevel == nil）→ 空数组。
    ///
    /// Issue #73：`BuildingUpgradeStep.upgradeCosts` 直接透传 `CatalogLevel.upgradeCosts`
    /// （多资源数组，含 parseFailed 项与 raw 原文）；汇总分桶/降级语义在
    /// `summary(for:)` 处理。
    /// unverified（缺 prerequisite 无法验证阶段上限，Issue #67 fail-closed）
    /// → 空数组：不得把无法验证的全局等级展示为可升级阶梯。
    /// unknown（含版本不匹配，Issue #67 P1-2 fail-closed）→ 空数组：旧目录
    /// 阶梯不得展示（maxLevel 仅保留供展示，不产生可升级阶梯，审核 G important）。
    /// Issue #68 Task 2：升级记录 status 恒为 .upgrading（独立于目录），上述
    /// status 守卫挡不住，必须显式 fail-closed 两条规则：
    /// - `!catalogIsUsable`（目录版本不匹配/不可用）→ 空数组：T17b no-stale-ladder
    ///   规则扩展到升级记录（版本不匹配降级整个投影，与 records() 同口径）；
    /// - 升级中且 `currentStageMaxLevel == nil`（缺 prerequisite 无法验证阶段上限）
    ///   → 空数组：不得回退全局 maxLevel 生成超出阶段上限的阶梯（与 unverified
    ///   同 fail-closed 语义）。
    /// 升级中且阶段上限可计算：阶梯 = `(currentLevel, effectiveMax]`，目标等级
    ///（currentLevel + 1）保留（升级记录阶梯起点同非升级记录，T8）。
    private static func steps(
        for item: VillageItemState,
        catalog: GameCatalog?,
        catalogIsUsable: Bool
    ) -> [BuildingUpgradeStep] {
        guard catalogIsUsable,
              !(item.isEffectivelyUpgrading && item.currentStageMaxLevel == nil),
              item.status != .unverified, item.status != .unknown,
              !effectiveStateIsUnusable(item),
              let maxLevel = item.maxLevel,
              let catalogItem = catalog?.item(section: item.section, dataID: item.dataID)
        else { return [] }
        let effectiveMax = item.currentStageMaxLevel ?? maxLevel
        let currentLevel = item.effectiveCurrentLevel
        return catalogItem.levels
            .filter { $0.level > (currentLevel ?? .max) && $0.level <= effectiveMax }
            .sorted { $0.level < $1.level }
            .map { level in
                BuildingUpgradeStep(
                    level: level.level,
                    upgradeCosts: level.upgradeCosts,
                    durationSeconds: level.durationSeconds,
                    missingReason: level.missingReason
                )
            }
    }

    private static func summary(for instances: [BuildingInstance], catalogIsUsable: Bool, catalogIsNil: Bool) -> BuildingGroupSummary {
        var instanceCount = 0
        var remainingLevelCount = 0
        var totalDurationSeconds: Int64 = 0
        var costByResource: [String: Int64] = [:]
        var hasPartialMissing = false
        var hasVersionMismatch = false
        var saturated = false

        for instance in instances {
            let count = instance.item.instanceWeight
            let instanceCountResult = SaturatingArithmetic.add(instanceCount, count)
            instanceCount = instanceCountResult.value
            // 原始 group path 当前不会携带聚合结果，但保留该标志可防止未来
            // 复用带聚合 count 的状态时静默丢失上游饱和信息。
            saturated = saturated || instance.item.countOverflowed || instanceCountResult.overflowed
            // 任一实例 currentLevel > maxLevel（目录过时）→ versionMismatch，最高优先级。
            if let maxLevel = instance.item.maxLevel, let currentLevel = instance.item.effectiveCurrentLevel,
               currentLevel > maxLevel {
                hasVersionMismatch = true
            }
            // 仅目录命中且 currentLevel 存在的实例计入剩余等级数（max(0, …) 防御目录过时）。
            // 上限 = 阶段上限优先（issue #67，与阶梯/行级满级同口径）；不可计算回退全局。
            // unverified（缺 prerequisite 无法验证）与 unknown（含版本不匹配，旧目录
            // 不可信）→ 不计剩余等级（fail-closed，不得把无法验证/过期的全局等级数
            // 伪装成可升级剩余；审核 G important）。
            // Issue #68 Task 2：升级中且阶梯为空（版本不匹配/缺 prerequisite 时 steps
            // 恒为空，即 Task-2 fail-closed 信号）→ 同样不计剩余等级：不得用旧目录
            // 或全局 maxLevel 计剩余（与阶梯同口径，汇总与阶梯不得矛盾）。
            if instance.item.status == .unverified || instance.item.status == .unknown
                || effectiveStateIsUnusable(instance.item)
                || (instance.item.isEffectivelyUpgrading && instance.steps.isEmpty) {
                hasPartialMissing = true
            } else if let maxLevel = instance.item.maxLevel,
                      let currentLevel = instance.item.effectiveCurrentLevel {
                let effectiveMax = instance.item.currentStageMaxLevel ?? maxLevel
                let levelDifference = SaturatingArithmetic.subtract(effectiveMax, currentLevel)
                saturated = saturated || levelDifference.overflowed
                let remainingLevels = max(0, levelDifference.value)
                let weightedRemainingLevels = SaturatingArithmetic.multiply(remainingLevels, count)
                saturated = saturated || weightedRemainingLevels.overflowed
                let remainingTotal = SaturatingArithmetic.add(
                    remainingLevelCount,
                    weightedRemainingLevels.value
                )
                remainingLevelCount = remainingTotal.value
                saturated = saturated || remainingTotal.overflowed
            }
            // 无法生成阶梯的实例降级：目录未命中（或 base 不匹配，maxLevel == nil）；
            // 或目录命中但 currentLevel 缺失 / 未满级却 steps 为空。已满级
            // （currentLevel >= effectiveMax，阶段或全局，issue #67）steps 为空是
            // 正常状态，不降级。unverified/unknown 在上面已置位 partialMissing（fail-closed）。
            if let maxLevel = instance.item.maxLevel,
               instance.item.status != .unverified, instance.item.status != .unknown,
               !effectiveStateIsUnusable(instance.item) {
                let effectiveMax = instance.item.currentStageMaxLevel ?? maxLevel
                let maxed = instance.item.effectiveCurrentLevel.map { $0 >= effectiveMax } ?? false
                if instance.item.effectiveCurrentLevel == nil || (instance.steps.isEmpty && !maxed) {
                    hasPartialMissing = true
                }
            } else {
                hasPartialMissing = true
            }
            for step in instance.steps {
                // 任一阶梯费用或时长缺失 → 降级（0 是有效即时升级，不降级）。
                // 费用缺失 = upgradeCosts 为 nil 或空数组（Python 侧不产出空数组，防御语义）。
                if step.upgradeCosts?.isEmpty != false || step.durationSeconds == nil {
                    hasPartialMissing = true
                }
                if let duration = step.durationSeconds {
                    let weightedDuration = SaturatingArithmetic.multiply(duration, Int64(count))
                    saturated = saturated || weightedDuration.overflowed
                    let durationTotal = SaturatingArithmetic.add(
                        totalDurationSeconds,
                        weightedDuration.value
                    )
                    totalDurationSeconds = durationTotal.value
                    saturated = saturated || durationTotal.overflowed
                }
                for cost in step.upgradeCosts ?? [] {
                    // 任一费用项解析失败 → 降级（汇总不完整；raw 原文由 UI 展示，
                    // 见 ClanDisplayFormat.upgradeCostLabel）。
                    guard !cost.parseFailed, let amount = cost.amount else {
                        hasPartialMissing = true
                        continue
                    }
                    // 成功项按 resource 原值分桶（显示层再本地化，桶序不受本地化影响）；
                    // 0 是真实费用，照常累加（不视为缺失）。
                    let weightedCost = SaturatingArithmetic.multiply(amount, Int64(count))
                    saturated = saturated || weightedCost.overflowed
                    let costTotal = SaturatingArithmetic.add(
                        costByResource[cost.resource, default: 0],
                        weightedCost.value
                    )
                    costByResource[cost.resource] = costTotal.value
                    saturated = saturated || costTotal.overflowed
                }
            }
        }

        return BuildingGroupSummary(
            instanceCount: instanceCount,
            remainingLevelCount: remainingLevelCount,
            totalDurationSeconds: totalDurationSeconds,
            // 按 resource 字典序排序（确定性：实例重排后桶序不变）。
            costByResource: costByResource
                .sorted { $0.key < $1.key }
                .map { BuildingResourceTotal(resource: $0.key, totalCost: $0.value) },
            saturated: saturated,
            // 目录缺失（catalogIsNil）是「缺失态」→ partialMissing（Issue #45 契约）；
            // 目录存在但版本不匹配（!catalogIsUsable）→ versionMismatch（旧目录不得支撑
            // 权威汇总）；其次实例级目录过时；再其次数据缺失。
            completeness: catalogIsNil ? .partialMissing
                : !catalogIsUsable ? .versionMismatch
                : hasVersionMismatch ? .versionMismatch
                : hasPartialMissing ? .partialMissing
                : .complete
        )
    }

    private static func effectiveStateIsUnusable(_ item: VillageItemState) -> Bool {
        guard let status = item.effectiveState?.status else { return false }
        switch status {
        case .unknown, .conflict, .needsReimport, .unavailable:
            return true
        case .observed, .manualCompleted, .manualActive, .importedActive:
            return false
        }
    }
}
