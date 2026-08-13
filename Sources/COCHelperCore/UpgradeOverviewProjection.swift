import Foundation

/// Issue #15：升级总览的展示聚合层。
///
/// 旧 `UpgradeTracker.activeRecords` 只显示快照中的进行中项目，缺少完整升级时长、
/// 目录状态与版本信息。本层在 `VillageCatalogProjection`（快照 × 静态目录 join）之上，
/// 把「全部村庄 × 全部基地」的投影结果聚合成按剩余时间排序的展示记录，供升级总览
/// UI 直接消费。
public struct UpgradeDisplayRecord: Identifiable, Hashable, Sendable {
    /// 全局唯一 id：`villageID:base:itemID`（不同村庄/不同 base/不同项目不冲突）。
    public let id: String
    public let villageID: UUID
    public let villageName: String
    public let villageTag: String?
    public let base: TrackerBase
    /// 投影项（含 nextLevel、nextLevelDurationSeconds、remainingSeconds、status 等）。
    public let item: VillageItemState
    /// 目录版本；目录不可用时 nil。
    public let catalogVersion: String?
    /// Issue #70/#140 实现要求 6：该村庄×基地的五种进度口径。同 village+base 的
    /// 记录共享同一实例（allRecords 内计算一次）；与详情页消费同一个
    /// `VillageProgressProjection`，供升级总览 UI 聚合覆盖率等使用。
    public let villageMetrics: VillageProgressMetrics

    /// 显式 public init（隐式 memberwise 为 internal，UI 层（COCHelper target）
    /// 无法跨模块构造；参数与 memberwise 完全一致，不破坏现有调用）。
    public init(
        id: String,
        villageID: UUID,
        villageName: String,
        villageTag: String?,
        base: TrackerBase,
        item: VillageItemState,
        catalogVersion: String?,
        villageMetrics: VillageProgressMetrics
    ) {
        self.id = id
        self.villageID = villageID
        self.villageName = villageName
        self.villageTag = villageTag
        self.base = base
        self.item = item
        self.catalogVersion = catalogVersion
        self.villageMetrics = villageMetrics
    }

    public var remainingSeconds: Int64? { item.remainingSeconds }

    /// Effective remaining time for callers that have a clock available. The
    /// legacy property above remains raw/imported for source compatibility.
    public func remainingSeconds(at now: Date) -> Int64? {
        item.effectiveRemainingSeconds(at: now)
    }

    /// 预计完成时间；remainingSeconds 不存在或非正时返回 nil。
    ///
    /// 必须传入 `UpgradeOverviewProjection.activeRecords` 调用时的同一个 `now`：
    /// 传入更晚的时间会系统性高估完成时间（now + remaining 随 now 右移）。
    public func completionDate(from now: Date) -> Date? {
        guard let remainingSeconds = item.effectiveRemainingSeconds(at: now),
              remainingSeconds > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(remainingSeconds))
    }
}

/// 升级总览展示聚合入口。
public enum UpgradeOverviewProjection {
    /// 单趟投影：一次 `allRecords` 后 split 成 active（升级中）与 pending（需重新导入）。
    ///
    /// UI 每 60s tick 调用一次本方法即可同时拿到两个列表，避免
    /// `activeRecords` + `pendingReimportRecords` 各自跑一遍完整投影（双倍计算）。
    /// 输出与两个独立方法完全一致（active 同 `activeRecords` 排序，pending 同
    /// `pendingReimportRecords` 排序），且两者按 id 互不重叠。
    ///
    /// `now` 用于计算实时剩余时间；`completionDate(from:)` 必须回传同一个 `now`，
    /// 否则完成时间会与实际不一致（详见该方法 doc comment）。
    public static func overviewRecords(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable = .empty,
        manualUpgradeCores: [UUID: ManualUpgradeCore] = [:],
        at now: Date = Date()
    ) -> (active: [UpgradeDisplayRecord], pending: [UpgradeDisplayRecord]) {
        let records = allRecords(
            from: villages,
            catalog: catalog,
            seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores,
            at: now
        )
        return (
            active: records.filter(\.item.isEffectivelyUpgrading).sorted {
                activeOrder($0, $1, at: now)
            },
            pending: records.filter(\.item.effectivelyNeedsReimport).sorted(by: pendingOrder)
        )
    }

    /// 全部村庄 × 全部 base 的进行中升级记录。
    ///
    /// 每条记录由 `VillageCatalogProjection.project` 产出并过滤有效升级状态；
    /// 按剩余时间升序（nil 视为最大排最后），再按 villageName、base、id 稳定排序。
    /// villageName 用 `localizedStandardCompare`（与旧层 UpgradeTracker 排序语义一致）。
    ///
    /// `now` 用于计算实时剩余时间；`completionDate(from:)` 必须回传同一个 `now`，
    /// 否则完成时间会与实际不一致（详见该方法 doc comment）。
    public static func activeRecords(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable = .empty,
        manualUpgradeCores: [UUID: ManualUpgradeCore] = [:],
        at now: Date = Date()
    ) -> [UpgradeDisplayRecord] {
        overviewRecords(
            from: villages,
            catalog: catalog,
            seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores,
            at: now
        ).active
    }

    /// 全部村庄 × 全部 base 中「计时已结束」的项目（待重新导入确认等级）。
    ///
    /// 过滤条件与投影聚合层的「需重新导入」有效信号一致：
    /// `VillageItemState.effectivelyNeedsReimport`（导入计时结束且没有被有效手动
    /// 状态覆盖，见 VillageCatalogProjection 聚合注释与 VillageItemState doc）。与 `activeRecords`
    /// 语义互斥：升级中项（remaining > 0）进 active，计时结束项进本列表；
    /// 普通完成项（timerSeconds == nil）两者都不进。该信号与目录收录无关——
    /// 即使目录未命中，计时结束也仍需重新导入确认。
    ///
    /// 排序：villageName（localizedStandardCompare）→ base.rawValue → item.name
    /// （localizedStandardCompare），id 兜底保证稳定。
    public static func pendingReimportRecords(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable = .empty,
        manualUpgradeCores: [UUID: ManualUpgradeCore] = [:],
        at now: Date = Date()
    ) -> [UpgradeDisplayRecord] {
        overviewRecords(
            from: villages,
            catalog: catalog,
            seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores,
            at: now
        ).pending
    }

    /// active 排序键：剩余时间升序（nil 视为最大排最后）→ villageName → base → id。
    private static func activeOrder(
        _ lhs: UpgradeDisplayRecord,
        _ rhs: UpgradeDisplayRecord,
        at now: Date
    ) -> Bool {
        let lhsRemaining = lhs.item.effectiveRemainingSeconds(at: now) ?? .max
        let rhsRemaining = rhs.item.effectiveRemainingSeconds(at: now) ?? .max
        if lhsRemaining != rhsRemaining { return lhsRemaining < rhsRemaining }
        let villageOrder = lhs.villageName.localizedStandardCompare(rhs.villageName)
        if villageOrder != .orderedSame { return villageOrder == .orderedAscending }
        if lhs.base.rawValue != rhs.base.rawValue { return lhs.base.rawValue < rhs.base.rawValue }
        return lhs.id < rhs.id
    }

    /// pending 排序键：villageName → base → item.name → id。
    private static func pendingOrder(_ lhs: UpgradeDisplayRecord, _ rhs: UpgradeDisplayRecord) -> Bool {
        let villageOrder = lhs.villageName.localizedStandardCompare(rhs.villageName)
        if villageOrder != .orderedSame { return villageOrder == .orderedAscending }
        if lhs.base.rawValue != rhs.base.rawValue { return lhs.base.rawValue < rhs.base.rawValue }
        let nameOrder = lhs.item.name.localizedStandardCompare(rhs.item.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// 全部村庄 × 全部 base 的未过滤投影记录（overviewRecords 唯一投影入口，
    /// 避免多处跑同一投影循环与 id 构造漂移）。
    ///
    /// `status == .unavailable` 的项（helpers/decos/obstacles 等 category == nil 的
    /// 不支持类别）在此过滤：等价旧层 UpgradeTracker.supportedSections 白名单行为，
    /// 保证 sidebar 计数（旧层）与总览（新层）一致。Issue #70 阶段 2：
    /// `status == .available` 的宇宙差集项同样不进记录（差集项无升级计时），
    /// 只供指标的完整分母消费。
    private static func allRecords(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        manualUpgradeCores: [UUID: ManualUpgradeCore],
        at now: Date
    ) -> [UpgradeDisplayRecord] {
        villages.flatMap { village in
            TrackerBase.allCases.flatMap { base in
                let projection = VillageCatalogProjection.project(
                    village: village,
                    catalog: catalog,
                    seasonalPhases: seasonalPhases,
                    base: base,
                    now: now,
                    manualUpgradeCore: manualUpgradeCores[village.id]
                )
                // Issue #70 阶段 2：消费拆分——records 只含「已观测项」
                //（排除宇宙差集 .available：差集项无升级计时，进总览列表无意义）；
                // 指标消费 tracked（含 .available），coverage 按投影
                // progressCoverage 传参（Issue #96：仅 .complete 时 stage/global
                // 用完整分母；partial/unavailable → 已观测口径 + 覆盖诊断）。
                let tracked = projection.items.filter { $0.status != .unavailable }
                let displayRecords = tracked.filter { $0.status != .available }
                // Issue #70 实现要求 6：同 village×base 的指标只算一次，全部
                // record 共享（口径与详情页一致：排除 .unavailable + 完整分母）。
                let metrics = projection.progressMetrics
                return displayRecords.map { item in
                    UpgradeDisplayRecord(
                        id: village.id.uuidString + ":" + base.rawValue + ":" + item.id,
                        villageID: village.id,
                        villageName: village.name,
                        villageTag: village.tag,
                        base: base,
                        item: item,
                        catalogVersion: projection.catalogVersion,
                        villageMetrics: metrics
                    )
                }
            }
        }
    }
}

// MARK: - Issue #144 总览状态（面板计数 / 最近完成 / 关注行）

/// 一条本地 completed 记录（总览「最近完成」面板消费）。
public struct UpgradeRecentCompletion: Identifiable, Hashable, Sendable {
    public let villageID: UUID
    public let itemKey: TrackerItemKey
    public let itemName: String
    public let targetLevel: Int
    public let quantity: Int64
    public let completedAt: Date

    public var id: String {
        itemKey.stableID + ":" + String(targetLevel) + ":" + String(completedAt.timeIntervalSince1970)
    }
}

/// 升级总览的 Issue #144 状态面板投影。
///
/// 计数口径（v1 契约）：
/// - `manualActiveCount` / `manualCompletedCount`：按本地记录计数（Core 的
///   activeRecords / completedHistory）。
/// - `importedActiveCount`：按 imported-active 展示行计数。
/// - `deduplicatedDisplayCount`：exact match 合并后的 active 展示行数。
/// 重复建筑的数量不混入以上记录数（行级只计 1）。
public struct UpgradeOverviewState: Sendable {
    public let manualActiveCount: Int
    public let importedActiveCount: Int
    public let deduplicatedDisplayCount: Int
    public let manualCompletedCount: Int
    /// 最近 7 天完成的本地记录（按完成时间降序）。
    public let completedRecently: [UpgradeRecentCompletion]
    /// active 展示行（exact match 已合并；conflict 行不隐藏）。
    public let activeRecords: [UpgradeDisplayRecord]
    /// 需要关注的展示行：conflict / unknown / needsReimport（并列显示，不隐藏）。
    public let attentionRecords: [UpgradeDisplayRecord]
    /// 待重新导入确认的行。
    public let needsReimportRecords: [UpgradeDisplayRecord]

    public init(
        manualActiveCount: Int,
        importedActiveCount: Int,
        deduplicatedDisplayCount: Int,
        manualCompletedCount: Int,
        completedRecently: [UpgradeRecentCompletion],
        activeRecords: [UpgradeDisplayRecord],
        attentionRecords: [UpgradeDisplayRecord],
        needsReimportRecords: [UpgradeDisplayRecord]
    ) {
        self.manualActiveCount = manualActiveCount
        self.importedActiveCount = importedActiveCount
        self.deduplicatedDisplayCount = deduplicatedDisplayCount
        self.manualCompletedCount = manualCompletedCount
        self.completedRecently = completedRecently
        self.activeRecords = activeRecords
        self.attentionRecords = attentionRecords
        self.needsReimportRecords = needsReimportRecords
    }
}

extension UpgradeOverviewProjection {
    /// Issue #144：总览状态面板（单趟投影，消费 `allRecords` + cores）。
    ///
    /// `recentlyCompletedWindow` 默认 7 天；超过窗口的 completed 记录仍计入
    /// `manualCompletedCount` 与项目行/进度，只是不进入「最近完成」面板。
    public static func overviewState(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable = .empty,
        manualUpgradeCores: [UUID: ManualUpgradeCore] = [:],
        at now: Date = Date(),
        recentlyCompletedWindow: TimeInterval = 7 * 24 * 3600
    ) -> UpgradeOverviewState {
        let records = allRecords(
            from: villages,
            catalog: catalog,
            seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores,
            at: now
        )

        let active = records.filter(\.item.isEffectivelyUpgrading)
            .sorted { activeOrder($0, $1, at: now) }
        let needsReimport = records.filter(\.item.effectivelyNeedsReimport)
            .sorted(by: pendingOrder)
        let attention = records.filter { record in
            guard let status = record.item.effectiveState?.status else { return false }
            return status == .conflict || status == .unknown || status == .needsReimport
        }

        let manualActiveCount = manualUpgradeCores.values.reduce(0) {
            $0 + $1.activeRecords.count
        }
        let manualCompletedCount = manualUpgradeCores.values.reduce(0) {
            $0 + $1.completedHistory.count
        }
        // review v2：只对可证明的 exact-match 合并去重（契约「只按 exact match
        // 去重；无法确认时并列显示」）。规则（按 (villageID, itemKey) 分组）：
        // - 带导入计时（timerSeconds != nil）的 active 行 = 独立导入事实，
        //   逐行计数（同 key 不同等级的两条计时 → 2，不合并）；
        // - 无计时行（active 状态来自共享 effectiveState，如 manualActive /
        //   附着状态）同 key 只计 1（合并展示）。
        // 注意 effectiveState 是 per-key 的：同 key 的 idle 行也会被标记 active，
        // 但无独立计时证据，不应计入 imported 事实。
        var importedActiveCount = 0
        var deduplicatedDisplayCount = 0
        let activeByKey = Dictionary(
            grouping: active,
            by: { Self.stableKey(villageID: $0.villageID, item: $0.item) }
        )
        for rows in activeByKey.values {
            let timerRows = rows.filter { $0.item.timerSeconds != nil }
            if !timerRows.isEmpty {
                importedActiveCount += timerRows.count
                deduplicatedDisplayCount += timerRows.count
            } else if !rows.isEmpty {
                // manual-only（无导入计时）或纯共享状态附着：同 key 合并为 1。
                deduplicatedDisplayCount += 1
            }
        }

        let completions: [UpgradeRecentCompletion] = manualUpgradeCores
            .flatMap { villageID, core in
                core.completedHistory.compactMap { record in
                    guard record.expectedEndAt >= now.addingTimeInterval(-recentlyCompletedWindow)
                    else { return nil }
                    let name = catalog?.item(
                        section: record.itemKey.rawSection,
                        dataID: record.itemKey.dataID
                    )?.name ?? record.itemKey.stableID
                    return UpgradeRecentCompletion(
                        villageID: villageID,
                        itemKey: record.itemKey,
                        itemName: name,
                        targetLevel: record.targetLevel,
                        quantity: record.quantity,
                        completedAt: record.expectedEndAt
                    )
                }
            }
            .sorted { $0.completedAt > $1.completedAt }

        return UpgradeOverviewState(
            manualActiveCount: manualActiveCount,
            importedActiveCount: importedActiveCount,
            deduplicatedDisplayCount: deduplicatedDisplayCount,
            manualCompletedCount: manualCompletedCount,
            completedRecently: completions,
            activeRecords: active,
            attentionRecords: attention,
            needsReimportRecords: needsReimport
        )
    }

    /// 展示行的 stable identity 键（villageID + effective itemKey，防御回退推导）。
    private static func stableKey(villageID: UUID, item: VillageItemState) -> String {
        let key = item.effectiveState?.itemKey.stableID
            ?? TrackerItemKey.root(
                base: item.base, rawSection: item.section, dataID: item.dataID
            ).stableID
        return villageID.uuidString + ":" + key
    }
}
