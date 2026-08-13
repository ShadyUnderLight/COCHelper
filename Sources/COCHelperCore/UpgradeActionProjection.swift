import Foundation

/// 单个升级动作可执行的 scope 覆盖状态（Issue #144）。
///
/// 与 `BuildingGroupCoverage` 同语义：整村 `ProgressUniverseCoverage` 收窄到
/// 单个 item 消费的 scope。无关类别缺失不阻塞已知项目；item 自身 section 缺失
/// 或覆盖不可用才 fail-closed。
public enum UpgradeActionCoverage: String, Hashable, Sendable {
    case complete
    case partial
    case unavailable
}

/// 一条投影产出的本地升级动作（Issue #144 canonical action）。
///
/// 普通顶层行由 `UpgradeActionProjection.action(for:catalog:catalogIsUsable:
/// manualUpgradeCore:coverage:now:)` 产出；重复建筑/城墙组由
/// `BuildingGroupProjection` 的 `BuildingGroupUpgradeAction` 经
/// `UpgradeActionProjection.actions(for:catalog:)` 适配为同一类型。
/// v1 契约：quantity 恒为 1（组也只启动一个实例）。
public struct UpgradeAction: Identifiable, Hashable, Sendable {
    public let itemKey: TrackerItemKey
    public let itemName: String
    public let base: TrackerBase
    /// 来源等级；未知/不可证时为 nil（不可启动）。
    public let fromLevel: Int?
    /// 目标等级；满级/未知/升级中占用时为 nil（不可启动）。
    public let targetLevel: Int?
    /// v1 恒为 1：一次只启动一个数量。
    public let quantity: Int64
    public let durationState: CatalogDurationState?
    public let frozenCosts: [CatalogUpgradeCost]?
    public let catalogProvenance: ManualCatalogProvenance?
    /// 必须回传给 `ManualUpgradeCore.startUpgrade`；nil = 未提供匹配的本地
    /// tracker 状态（不可启动）。
    public let baselineReference: ManualBaselineReference?
    public let isStartable: Bool
    public let disabledReason: String?
    public let diagnostics: [String]

    public var id: String {
        itemKey.stableID + ":"
            + String(fromLevel ?? -1) + "->" + String(targetLevel ?? -1)
    }

    public init(
        itemKey: TrackerItemKey,
        itemName: String,
        base: TrackerBase,
        fromLevel: Int?,
        targetLevel: Int?,
        quantity: Int64,
        durationState: CatalogDurationState?,
        frozenCosts: [CatalogUpgradeCost]?,
        catalogProvenance: ManualCatalogProvenance?,
        baselineReference: ManualBaselineReference?,
        isStartable: Bool,
        disabledReason: String?,
        diagnostics: [String]
    ) {
        self.itemKey = itemKey
        self.itemName = itemName
        self.base = base
        self.fromLevel = fromLevel
        self.targetLevel = targetLevel
        self.quantity = quantity
        self.durationState = durationState
        self.frozenCosts = frozenCosts
        self.catalogProvenance = catalogProvenance
        self.baselineReference = baselineReference
        self.isStartable = isStartable
        self.disabledReason = disabledReason
        self.diagnostics = diagnostics
    }

    /// 重复建筑/城墙组的 action 适配（`BuildingGroupUpgradeAction` → canonical）。
    /// catalog 用于补充 `ManualCatalogProvenance`（冻结 provenance 契约）。
    public init(
        buildingAction: BuildingGroupUpgradeAction,
        itemKey: TrackerItemKey,
        itemName: String,
        catalog: GameCatalog?
    ) {
        self.init(
            itemKey: itemKey,
            itemName: itemName,
            base: itemKey.base,
            fromLevel: buildingAction.fromLevel,
            targetLevel: buildingAction.targetLevel,
            quantity: buildingAction.quantity,
            durationState: buildingAction.durationState,
            frozenCosts: buildingAction.upgradeCosts,
            catalogProvenance: catalog.map { ManualCatalogProvenance(catalog: $0) },
            baselineReference: buildingAction.baselineReference,
            isStartable: buildingAction.isStartable,
            disabledReason: buildingAction.diagnostic,
            diagnostics: buildingAction.diagnostic.map { [$0] } ?? []
        )
    }
}

/// 升级总览 / 村庄详情的状态筛选桶（Issue #144 v1 契约）。
public enum UpgradeDisplayStateFilter: String, Hashable, Sendable, CaseIterable {
    case available
    case manualActive
    case importedActive
    case completed
    case needsReimport
    case unknown
}

/// 升级列表排序变体（Issue #144）。
public enum UpgradeDisplaySort: String, Hashable, Sendable, CaseIterable {
    case remaining
    case categoryName
    case level
    case stageMax
    case recentlyChanged
}

/// 可注入、可测试的展示筛选（Issue #144）。
///
/// 契约：搜索/排序只消费已构建的投影值（名称、raw identity、有效状态），
/// 不重跑 raw snapshot 解析、目录猜测或 reconcile；filter 不改变 Core 状态。
public struct UpgradeDisplayFilter: Hashable, Sendable {
    public var base: TrackerBase?
    public var category: TrackerCategory?
    public var state: UpgradeDisplayStateFilter?
    public var text: String?
    public var sort: UpgradeDisplaySort

    public init(
        base: TrackerBase? = nil,
        category: TrackerCategory? = nil,
        state: UpgradeDisplayStateFilter? = nil,
        text: String? = nil,
        sort: UpgradeDisplaySort = .categoryName
    ) {
        self.base = base
        self.category = category
        self.state = state
        self.text = text
        self.sort = sort
    }
}

/// 通用升级动作与展示筛选投影（Issue #144）。
///
/// 纯函数：不改变任何 Core 状态、不持久化、不重跑解析。UI 三处（普通行、
/// 重复建筑组卡、总览）必须消费本投影的同一门禁与展示口径。
public enum UpgradeActionProjection {
    // MARK: - Action

    /// 单个顶层项目行的 canonical action。
    ///
    /// - 嵌套项（types/modules）与 Craft Table 项：返回 nil（v1 只读）。
    /// - `manualActive` 行：返回 nil（由 Cancel/Adjust 交互承接，不显示 Start）。
    /// - 其余状态：返回 action，`isStartable == false` 时携带 disabledReason。
    /// - `cost unknown` / 部分解析失败**不阻塞**启动（只进 diagnostics）。
    public static func action(
        for item: VillageItemState,
        catalog: GameCatalog?,
        catalogIsUsable: Bool,
        manualUpgradeCore: ManualUpgradeCore?,
        coverage: UpgradeActionCoverage,
        now: Date
    ) -> UpgradeAction? {
        // 嵌套项 / 不支持类别：v1 只读，不产出动作。
        guard !item.isNested, item.status != .unavailable else { return nil }

        var reasons: [String] = []
        var diagnostics: [String] = []
        let effective = item.effectiveState
        let itemKey = Self.itemKey(of: item)
        let sourceLevel = effective?.effectiveCompletedLevel
            ?? effective?.importedCurrentLevel
            ?? item.currentLevel

        switch coverage {
        case .complete:
            break
        case .partial:
            reasons.append("覆盖不完整，不能安全启动本地升级。")
        case .unavailable:
            reasons.append("覆盖状态不可用，不能安全启动本地升级。")
        }

        if let effective {
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
            switch effective.importedCountQuality {
            case .known:
                break
            case .malformed:
                reasons.append("快照数量字段缺失或非正数，不能安全启动本地升级。")
            case .overflowed:
                reasons.append("快照数量汇总溢出，不能安全启动本地升级。")
            }
        }

        guard catalogIsUsable, let catalog else {
            reasons.append("目录不可用，不能生成升级操作。")
            return makeAction(
                item: item,
                itemKey: itemKey,
                fromLevel: sourceLevel,
                targetLevel: nil,
                durationState: nil,
                frozenCosts: nil,
                catalog: nil,
                baseline: manualUpgradeCore?.itemState(for: itemKey)?.baselineReference,
                reasons: reasons,
                diagnostics: diagnostics
            )
        }

        // manualActive 行由 Cancel/Adjust 交互承接，不显示 Start。
        if effective?.status == .manualActive { return nil }

        // 目标等级：单一来源 #68 next-upgrade 语义（禁止 currentLevel + 1 推导）。
        let targetLevel: Int?
        switch item.effectiveNextUpgrade {
        case .available(let level, _):
            targetLevel = level
        case .requires(let nextLevel, let requirements, _):
            targetLevel = nextLevel
            var message = "目标等级超过当前阶段上限。"
            if !requirements.isEmpty {
                message += "解锁条件：" + requirements.displayLabels(base: item.base.rawValue)
            }
            reasons.append(message)
        case .globalMaxed:
            targetLevel = nil
            reasons.append("已达到目录最高等级。")
        case .inProgressFact:
            // importedActive 行已由 status gate 报「导入计时」；其余 inProgressFact
            // 不可达（manualActive 已提前返回）。
            targetLevel = nil
        case .unverified:
            targetLevel = nil
            reasons.append("无法验证阶段上限。")
        case .unknown, nil:
            targetLevel = nil
            reasons.append("目录未收录或目标等级不可达。")
        }

        let catalogItem = catalog.item(section: item.section, dataID: item.dataID)
        let catalogLevel = targetLevel.flatMap { target in
            catalogItem?.levels.first { $0.level == target }
        }
        let durationState = catalogLevel?.durationState
        switch durationState {
        case .timed, .instant:
            break
        default:
            reasons.append("目标升级时长不可用。")
        }
        let frozenCosts = catalogLevel?.upgradeCosts
        if frozenCosts?.contains(where: \.parseFailed) == true {
            diagnostics.append("目标升级费用含解析失败项，启动时保留 raw 费用证据。")
        } else if frozenCosts == nil {
            diagnostics.append("目标升级费用未知，启动时保留 unknown cost 状态。")
        }

        // 阶段/全局上限（防御：nextUpgrade 已编码，双保险防投影漂移）。
        let stageMax = effective?.currentStageMaxLevel ?? item.currentStageMaxLevel
        let globalMax = effective?.globalMaxLevel ?? item.maxLevel
        if let targetLevel, let stageMax, targetLevel > stageMax {
            reasons.append("目标等级超过当前阶段上限。")
        }
        if let targetLevel, let globalMax, targetLevel > globalMax {
            reasons.append("目标等级超过目录全局上限。")
        }

        // 本地 tracker 状态与可用数量。
        if manualUpgradeCore == nil {
            reasons.append("未提供本地 tracker 状态，不能直接执行升级。")
        } else if let manualState = manualUpgradeCore?.itemState(for: itemKey) {
            switch manualState.status {
            case .observed, .manualCompleted:
                break
            case .unknown:
                reasons.append("本地 tracker 状态未知。")
            case .conflict:
                reasons.append("本地 tracker 状态冲突。")
            }
            if let distribution = manualUpgradeCore?
                .effectiveState(for: itemKey)?.effectiveCompletedDistribution,
                let sourceLevel,
                distribution.quantity(at: sourceLevel) < 1 {
                reasons.append("本地 tracker 的可用数量不足。")
            }
        } else {
            reasons.append("本地 tracker 没有对应的 itemState。")
        }

        let baseline = manualUpgradeCore?.itemState(for: itemKey)?.baselineReference
        return makeAction(
            item: item,
            itemKey: itemKey,
            fromLevel: sourceLevel,
            targetLevel: targetLevel,
            durationState: durationState,
            frozenCosts: frozenCosts,
            catalog: catalog,
            baseline: baseline,
            reasons: reasons,
            diagnostics: diagnostics
        )
    }

    /// 整村覆盖状态收窄到单个 item 的 scope（Issue #144）。
    ///
    /// - `.complete` → `.complete`；`.unavailable` → `.unavailable`。
    /// - `.partial`：item 自身 section（归一化去掉 "2" 后缀）缺失 → `.partial`；
    ///   否则无关类别缺失不阻塞 → `.complete`。
    public static func coverage(
        for item: VillageItemState,
        progressCoverage: ProgressUniverseCoverage
    ) -> UpgradeActionCoverage {
        switch progressCoverage {
        case .complete:
            return .complete
        case .unavailable:
            return .unavailable
        case .partial(let missingSections, _):
            let section = item.section.hasSuffix("2")
                ? String(item.section.dropLast())
                : item.section
            return missingSections.contains(section) ? .partial : .complete
        }
    }

    /// 重复建筑/城墙组卡的 canonical actions（v1 每 action quantity = 1）。
    public static func actions(
        for group: BuildingGroup,
        catalog: GameCatalog?
    ) -> [UpgradeAction] {
        group.trackerState.actions.map { action in
            UpgradeAction(
                buildingAction: action,
                itemKey: group.trackerState.itemKey,
                itemName: group.name,
                catalog: catalog
            )
        }
    }

    // MARK: - 展示状态与筛选

    /// 行级展示状态桶（Issue #144 v1 契约六桶）。
    public static func displayState(of item: VillageItemState) -> UpgradeDisplayStateFilter {
        if let effective = item.effectiveState {
            switch effective.status {
            case .manualActive:
                return .manualActive
            case .importedActive:
                return .importedActive
            case .manualCompleted:
                return .completed
            case .needsReimport:
                return .needsReimport
            case .conflict, .unknown, .unavailable:
                return .unknown
            case .observed:
                return item.isEffectivelyMaxed ? .completed : .available
            }
        }
        if item.needsReimport { return .needsReimport }
        switch item.status {
        case .upgrading:
            return .importedActive
        case .maxed:
            return .completed
        case .complete:
            return .available
        case .unknown, .unverified, .unavailable, .available:
            return .unknown
        }
    }

    /// 筛选 + 排序（纯函数，确定性；不重跑解析/reconcile，不改变 Core 状态）。
    public static func filtered(
        _ items: [VillageItemState],
        filter: UpgradeDisplayFilter,
        at now: Date
    ) -> [VillageItemState] {
        var result = items
        if let base = filter.base {
            result = result.filter { $0.base == base }
        }
        if let category = filter.category {
            result = result.filter { $0.category == category }
        }
        if let state = filter.state {
            result = result.filter { displayState(of: $0) == state }
        }
        if let text = filter.text, !text.isEmpty {
            let needle = Self.normalized(text)
            result = result.filter { item in
                Self.normalized(item.name).contains(needle)
                    || String(item.dataID).contains(text)
                    || item.section.contains(text)
            }
        }
        switch filter.sort {
        case .remaining:
            result.sort { lhs, rhs in
                let l = lhs.effectiveRemainingSeconds(at: now)
                let r = rhs.effectiveRemainingSeconds(at: now)
                switch (l, r) {
                case let (a?, b?) where a != b:
                    return a < b
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    return Self.nameTieBreak(lhs, rhs)
                }
            }
        case .categoryName:
            result.sort { lhs, rhs in
                let l = lhs.category?.sortOrder ?? TrackerCategory.allCases.count
                let r = rhs.category?.sortOrder ?? TrackerCategory.allCases.count
                if l != r { return l < r }
                return Self.nameTieBreak(lhs, rhs)
            }
        case .level:
            result.sort { lhs, rhs in
                let l = lhs.effectiveCurrentLevel
                let r = rhs.effectiveCurrentLevel
                switch (l, r) {
                case let (a?, b?) where a != b:
                    return a < b
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    return Self.nameTieBreak(lhs, rhs)
                }
            }
        case .stageMax:
            result.sort { lhs, rhs in
                let l = lhs.currentStageMaxLevel ?? lhs.maxLevel
                let r = rhs.currentStageMaxLevel ?? rhs.maxLevel
                switch (l, r) {
                case let (a?, b?) where a != b:
                    return a < b
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    return Self.nameTieBreak(lhs, rhs)
                }
            }
        case .recentlyChanged:
            result.sort { lhs, rhs in
                let l = latestManualActivity(of: lhs)
                let r = latestManualActivity(of: rhs)
                switch (l, r) {
                case let (a?, b?) where a != b:
                    return a > b  // 最近优先
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    return Self.nameTieBreak(lhs, rhs)
                }
            }
        }
        return result
    }

    // MARK: - Private

    private static func itemKey(of item: VillageItemState) -> TrackerItemKey {
        if let key = item.effectiveState?.itemKey { return key }
        return TrackerItemKey.root(base: item.base, rawSection: item.section, dataID: item.dataID)
    }

    private static func makeAction(
        item: VillageItemState,
        itemKey: TrackerItemKey,
        fromLevel: Int?,
        targetLevel: Int?,
        durationState: CatalogDurationState?,
        frozenCosts: [CatalogUpgradeCost]?,
        catalog: GameCatalog?,
        baseline: ManualBaselineReference?,
        reasons: [String],
        diagnostics: [String]
    ) -> UpgradeAction {
        let startable = reasons.isEmpty
            && fromLevel != nil
            && targetLevel != nil
            && baseline != nil
            && Self.isUsableDuration(durationState)
        return UpgradeAction(
            itemKey: itemKey,
            itemName: item.name,
            base: item.base,
            fromLevel: fromLevel,
            targetLevel: targetLevel,
            quantity: 1,
            durationState: durationState,
            frozenCosts: frozenCosts,
            catalogProvenance: catalog.map { ManualCatalogProvenance(catalog: $0) },
            baselineReference: baseline,
            isStartable: startable,
            disabledReason: reasons.isEmpty ? nil : reasons.joined(separator: "；"),
            diagnostics: diagnostics
        )
    }

    private static func isUsableDuration(_ state: CatalogDurationState?) -> Bool {
        switch state {
        case .timed, .instant:
            return true
        default:
            return false
        }
    }

    private static func latestManualActivity(of item: VillageItemState) -> Date? {
        item.effectiveState?.activeManualRecords.map(\.startedAt).max()
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func nameTieBreak(_ lhs: VillageItemState, _ rhs: VillageItemState) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id < rhs.id
    }
}
