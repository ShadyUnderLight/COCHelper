import Foundation

/// 单个升级阶梯单元格（目录逐级数据）。
public struct BuildingUpgradeStep: Hashable, Sendable {
    /// 目标等级（升序）。
    public let level: Int
    /// 目录费用；nil = 缺失。
    public let upgradeCost: Int64?
    /// 费用资源类型；nil = 缺失（仅当 cost 存在时可能）。
    public let upgradeResource: String?
    /// 完整升级时长；nil = 缺失，0 = 有效即时升级。
    public let durationSeconds: Int64?

    public var hasCost: Bool { upgradeCost != nil }
    public var hasDuration: Bool { durationSeconds != nil }
    public var isInstant: Bool { durationSeconds == 0 }
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
    public let costByResource: [BuildingResourceTotal]
    /// 任一汇总字段发生饱和。为 true 时数值仅是可表示上界，不应作为精确业务数据展示。
    public let saturated: Bool
    public let completeness: BuildingGroupCompleteness
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
    public var id: String { "\(base.rawValue):\(section):\(dataID)" }
}

/// 组卡投影入口。纯函数，不改变任何现有投影/持久化语义。
/// 输出范围：section ∈ {buildings, buildings2} 的非嵌套项（UI 门仅剩 craftTable 防御）。
public enum BuildingGroupProjection {
    public static func project(
        village: VillageProfile,
        catalog: GameCatalog?,
        base: TrackerBase,
        expectedGameVersion: String? = GameCatalog.defaultBundledVersion,
        now: Date = Date()
    ) -> [BuildingGroup] {
        guard let snapshot = village.accountSnapshot else { return [] }
        // 目录可用性（与 VillageCatalogProjection 同语义，Review 反馈 P1-2）：
        // 目录存在且版本与期望匹配时才可用；expectedGameVersion == nil 不校验。
        // 注意区分两种降级（Issue #45 契约第 5 节）：目录不可用（catalog == nil）
        // 是「缺失态」→ partialMissing（UI 橙标 + 诊断）；目录存在但版本不匹配
        // 是「不得输出权威汇总」→ versionMismatch（UI 红标诊断）。
        let hasGlobalVersionMismatch: Bool
        if let catalog, let expectedGameVersion {
            hasGlobalVersionMismatch = catalog.gameVersion != expectedGameVersion
        } else {
            hasGlobalVersionMismatch = false
        }
        // 原始记录层（聚合前）：只取 buildings/buildings2 的非嵌套项。
        let records = VillageCatalogProjection.records(
            from: snapshot,
            catalog: catalog,
            base: base,
            now: now,
            unlocks: PlayerUnlockLevels(snapshot: snapshot)
        ).filter { !$0.isNested && ($0.section == "buildings" || $0.section == "buildings2") }

        // 按 (base, section, dataID) 分组，组按首现顺序输出（字典 + 有序键数组）。
        var keys: [String] = []
        var grouped: [String: [VillageItemState]] = [:]
        for record in records {
            let key = "\(base.rawValue):\(record.section):\(record.dataID)"
            if grouped[key] == nil { keys.append(key) }
            grouped[key, default: []].append(record)
        }

        return keys.compactMap { key in
            guard let records = grouped[key], let first = records.first else { return nil }
            let instances = records.map { record in
                BuildingInstance(id: record.id, item: record, steps: steps(for: record, catalog: catalog))
            }
            return BuildingGroup(
                base: base,
                section: first.section,
                dataID: first.dataID,
                name: first.name,
                instances: instances,
                summary: summary(for: instances, hasGlobalVersionMismatch: hasGlobalVersionMismatch),
                displayCategory: first.displayCategory,
                category: first.category
            )
        }
    }

    /// 阶梯：目录 levels 中 `level ∈ (currentLevel, effectiveMax]` 的条目，按 level 升序。
    /// 目录等级可能不连续，必须过滤目录 levels 而非生成连续整数。
    /// `effectiveMax` = 阶段上限（issue #67）优先，不可计算时回退全局 maxLevel——
    /// 与行级 `.maxed` 判定同口径，保证组卡与列表行不矛盾（审核 C important）。
    /// currentLevel 为 nil、目录未命中或 base 不匹配（maxLevel == nil）→ 空数组。
    private static func steps(
        for item: VillageItemState,
        catalog: GameCatalog?
    ) -> [BuildingUpgradeStep] {
        guard let maxLevel = item.maxLevel,
              let catalogItem = catalog?.item(section: item.section, dataID: item.dataID)
        else { return [] }
        let effectiveMax = item.currentStageMaxLevel ?? maxLevel
        let currentLevel = item.currentLevel
        return catalogItem.levels
            .filter { $0.level > (currentLevel ?? .max) && $0.level <= effectiveMax }
            .sorted { $0.level < $1.level }
            .map {
                BuildingUpgradeStep(
                    level: $0.level,
                    upgradeCost: $0.upgradeCost,
                    upgradeResource: $0.upgradeResource,
                    durationSeconds: $0.durationSeconds
                )
            }
    }

    private static func summary(for instances: [BuildingInstance], hasGlobalVersionMismatch: Bool) -> BuildingGroupSummary {
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
            if let maxLevel = instance.item.maxLevel, let currentLevel = instance.item.currentLevel,
               currentLevel > maxLevel {
                hasVersionMismatch = true
            }
            // 仅目录命中且 currentLevel 存在的实例计入剩余等级数（max(0, …) 防御目录过时）。
            // 上限 = 阶段上限优先（issue #67，与阶梯/行级满级同口径）；不可计算回退全局。
            if let maxLevel = instance.item.maxLevel, let currentLevel = instance.item.currentLevel {
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
            // 正常状态，不降级。
            if let maxLevel = instance.item.maxLevel {
                let effectiveMax = instance.item.currentStageMaxLevel ?? maxLevel
                let maxed = instance.item.currentLevel.map { $0 >= effectiveMax } ?? false
                if instance.item.currentLevel == nil || (instance.steps.isEmpty && !maxed) {
                    hasPartialMissing = true
                }
            } else {
                hasPartialMissing = true
            }
            for step in instance.steps {
                // 任一阶梯费用或时长缺失 → 降级（0 是有效即时升级，不降级）。
                if step.upgradeCost == nil || step.durationSeconds == nil {
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
                if let cost = step.upgradeCost {
                    // 资源缺失但费用存在 → 归入「未知资源」桶（不丢弃费用）。
                    let resource = step.upgradeResource ?? "未知资源"
                    let weightedCost = SaturatingArithmetic.multiply(cost, Int64(count))
                    saturated = saturated || weightedCost.overflowed
                    let costTotal = SaturatingArithmetic.add(
                        costByResource[resource, default: 0],
                        weightedCost.value
                    )
                    costByResource[resource] = costTotal.value
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
            // 全局版本不匹配优先级最高（旧目录不得支撑权威汇总，Issue #45 契约）；
            // 其次实例级目录过时；再其次数据缺失。
            completeness: hasGlobalVersionMismatch ? .versionMismatch
                : hasVersionMismatch ? .versionMismatch
                : hasPartialMissing ? .partialMissing
                : .complete
        )
    }
}
