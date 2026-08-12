import Foundation

/// The local tracker status of one stable item key.
///
/// This is intentionally separate from `VillageItemStatus`: the latter is the
/// catalog/import display status, while this enum records where the effective
/// local state came from.
public enum EffectiveVillageItemStatus: String, Hashable, Sendable {
    case observed
    case manualCompleted
    case manualActive
    case importedActive
    case needsReimport
    case conflict
    case unknown
    case unavailable
}

/// Provenance flags for an effective item. A state can have both imported and
/// manual activity when the two records match exactly.
public enum EffectiveVillageItemProvenance: String, Hashable, Sendable {
    case observed
    case manualCompleted
    case manualActive
    case importedActive
    case needsReimport
}

/// One stable tracker item after joining the imported observation with the
/// optional local manual ledger.
public struct EffectiveVillageItemState: Identifiable, Hashable, Sendable {
    public let itemKey: TrackerItemKey
    public let rawItemID: String?
    public let importedCurrentLevel: Int?
    public let importedCount: Int?
    /// Raw instance weight retained even when the level histogram cannot be
    /// materialized (for example, a missing level or Int64 overflow).
    public let importedInstanceWeight: Int64
    /// The raw count sum saturated while being computed. This is separate
    /// from `importedDistribution`: a malformed histogram must not erase the
    /// fact that its source still described multiple instances.
    public let importedCountOverflowed: Bool
    public let importedTimerSeconds: Int64?
    public let importedRemainingSeconds: Int64?
    public let importedDistribution: ManualLevelDistribution?
    public let manualCompletedDistribution: ManualLevelDistribution?
    public let activeManualRecords: [ManualUpgradeRecord]
    public let activeTargetDistribution: ManualLevelDistribution
    public let effectiveCompletedDistribution: ManualLevelDistribution?
    public let status: EffectiveVillageItemStatus
    public let provenance: [EffectiveVillageItemProvenance]
    public let diagnostic: String?
    public let catalogDurationState: CatalogDurationState?
    public let catalogCosts: [CatalogUpgradeCost]?
    /// Catalog next-upgrade semantics recalculated from the effective level
    /// when a manual completion changed the imported current level.
    public let catalogNextUpgrade: VillageNextUpgrade?
    public let currentStageMaxLevel: Int?
    public let globalMaxLevel: Int?

    public var id: String { itemKey.stableID }

    /// A single-level effective distribution is safe for a row-level display.
    /// Mixed duplicate/wall distributions remain nil instead of being collapsed
    /// into a guessed level.
    public var effectiveCompletedLevel: Int? {
        guard effectiveCompletedDistribution?.levels.count == 1 else { return nil }
        return effectiveCompletedDistribution?.levels.first?.level
    }

    public var effectiveCompletedCount: Int? {
        guard let quantity = effectiveCompletedDistribution?.totalQuantity,
              quantity <= Int64(Int.max) else { return nil }
        return Int(quantity)
    }

    public var activeTargetLevel: Int? {
        guard activeTargetDistribution.levels.count == 1 else { return nil }
        return activeTargetDistribution.levels.first?.level
    }

    public var isKnown: Bool {
        status != .unknown && status != .conflict && status != .unavailable
            && status != .needsReimport
            && effectiveCompletedDistribution != nil
    }
}

/// Coverage of the optional local manual tracker. It is deliberately separate
/// from `ProgressUniverseCoverage` and `snapshotCoverage`.
public struct ManualTrackerCoverage: Hashable, Sendable {
    public let observedItemCount: Int
    public let manualItemCount: Int
    public let effectiveItemCount: Int
    public let activeRecordCount: Int
    public let unknownItemCount: Int
    public let state: ProgressMetricState
    public let diagnostics: [String]

    public init(
        observedItemCount: Int,
        manualItemCount: Int,
        effectiveItemCount: Int,
        activeRecordCount: Int,
        unknownItemCount: Int,
        state: ProgressMetricState,
        diagnostics: [String] = []
    ) {
        self.observedItemCount = observedItemCount
        self.manualItemCount = manualItemCount
        self.effectiveItemCount = effectiveItemCount
        self.activeRecordCount = activeRecordCount
        self.unknownItemCount = unknownItemCount
        self.state = state
        self.diagnostics = diagnostics
    }
}

struct EffectiveVillageProjectionBuildResult {
    let items: [VillageItemState]
    let rawItems: [VillageItemState]
    let trackerItems: [EffectiveVillageItemState]
    let manualCoverage: ManualTrackerCoverage
    let progressMetrics: VillageProgressMetrics
}

/// Builds the effective sidecar for `VillageCatalogProjection`.
///
/// The builder never mutates `AccountSnapshot`, never creates a manual record
/// from an imported timer, and never treats an active target as completed.
enum EffectiveVillageProjectionBuilder {
    static func build(
        snapshot: AccountSnapshot?,
        rawItems: [VillageItemState],
        items: [VillageItemState],
        catalog: GameCatalog?,
        catalogIsUsable: Bool,
        compatibility: CatalogCompatibility,
        base: TrackerBase,
        now: Date,
        manualUpgradeCore: ManualUpgradeCore?,
        progressCoverage: ProgressUniverseCoverage
    ) -> EffectiveVillageProjectionBuildResult {
        guard let snapshot else {
            let unavailable = VillageProgressProjection.metrics(
                from: [],
                catalogIsUsable: catalogIsUsable,
                compatibility: compatibility,
                coverage: progressCoverage
            )
            return EffectiveVillageProjectionBuildResult(
                items: items,
                rawItems: rawItems,
                trackerItems: [],
                manualCoverage: ManualTrackerCoverage(
                    observedItemCount: 0,
                    manualItemCount: manualUpgradeCore?.itemStates.count ?? 0,
                    effectiveItemCount: 0,
                    activeRecordCount: manualUpgradeCore?.activeRecords.count ?? 0,
                    unknownItemCount: 0,
                    state: manualUpgradeCore == nil ? .unavailable : .unknown,
                    diagnostics: manualUpgradeCore == nil
                        ? ["未提供本地手动状态。"]
                        : ["本地手动状态没有对应的导入快照。"]
                ),
                progressMetrics: unavailable
            )
        }

        let keyMap = TrackerItemKeyAdapter.keyMap(in: snapshot, base: base)
        let keyedItems: [(TrackerItemKey, AccountItem)] = snapshot.allObjectItems.compactMap { item in
            guard let key = keyMap[item.id] else { return nil }
            return (key, item)
        }
        let groupedItems: [TrackerItemKey: [(TrackerItemKey, AccountItem)]] = Dictionary(
            grouping: keyedItems,
            by: { $0.0 }
        )

        let trackerKeys = groupedItems.keys.sorted { $0.stableID < $1.stableID }
        let rawByImportID = Dictionary(uniqueKeysWithValues: rawItems.map { ($0.id, $0) })
        let stateByKey: [TrackerItemKey: EffectiveVillageItemState] = Dictionary(
            uniqueKeysWithValues: trackerKeys.compactMap { key in
                makeState(
                    key: key,
                    observedItems: groupedItems[key, default: []].map { $0.1 },
                    rawItems: rawItems,
                    rawByImportID: rawByImportID,
                    snapshot: snapshot,
                    catalog: catalog,
                    catalogIsUsable: catalogIsUsable,
                    now: now,
                    manualUpgradeCore: manualUpgradeCore
                ).map { (key, $0) }
            }
        )

        // Preserve the imported-only item contract when no manual ledger is
        // supplied. The stable tracker states are still exposed for callers
        // that need coverage/diagnostics, but row/detail consumers should not
        // switch to effective-state semantics until they actually receive the
        // optional manual overlay.
        let attachedItems = manualUpgradeCore == nil
            ? items
            : items.map { item in
                item.attachingEffectiveState(state(for: item, keyMap: keyMap, states: stateByKey))
            }
        let attachedRawItems = manualUpgradeCore == nil
            ? rawItems
            : rawItems.map { item in
                item.attachingEffectiveState(state(for: item, keyMap: keyMap, states: stateByKey))
            }
        let trackerItems = trackerKeys.compactMap { stateByKey[$0] }
        let manualCoverage = makeCoverage(
            trackerItems: trackerItems,
            manualUpgradeCore: manualUpgradeCore
        )
        let importedMetrics = VillageProgressProjection.metrics(
            from: attachedItems.filter { $0.status != VillageItemStatus.unavailable },
            catalogIsUsable: catalogIsUsable,
            compatibility: compatibility,
            coverage: progressCoverage
        )
        let progressMetrics: VillageProgressMetrics
        if manualUpgradeCore == nil {
            // Preserve the existing imported-only metrics exactly. The
            // effective tracker metrics become a distinct overlay only when a
            // caller actually supplies local manual state.
            progressMetrics = importedMetrics
        } else {
            progressMetrics = importedMetrics.replacingTrackerMetrics(
                instanceProgress: instanceMetric(
                    trackerItems: trackerItems,
                    availableItems: attachedItems.filter { $0.status == .available },
                    catalogIsUsable: catalogIsUsable,
                    compatibility: compatibility,
                    manualCoverage: manualCoverage
                ),
                effectiveTrackerProgress: effectiveMetric(
                    trackerItems: trackerItems,
                    catalogIsUsable: catalogIsUsable,
                    compatibility: compatibility,
                    manualCoverage: manualCoverage
                )
            )
        }

        return EffectiveVillageProjectionBuildResult(
            items: attachedItems,
            rawItems: attachedRawItems,
            trackerItems: trackerItems,
            manualCoverage: manualCoverage,
            progressMetrics: progressMetrics
        )
    }

    private static func state(
        for item: VillageItemState,
        keyMap: [String: TrackerItemKey],
        states: [TrackerItemKey: EffectiveVillageItemState]
    ) -> EffectiveVillageItemState? {
        let importID = item.id.hasPrefix("agg:") ? String(item.id.dropFirst(4)) : item.id
        guard let key = keyMap[importID] else { return nil }
        return states[key]
    }

    private static func makeState(
        key: TrackerItemKey,
        observedItems: [AccountItem],
        rawItems: [VillageItemState],
        rawByImportID: [String: VillageItemState],
        snapshot: AccountSnapshot,
        catalog: GameCatalog?,
        catalogIsUsable: Bool,
        now: Date,
        manualUpgradeCore: ManualUpgradeCore?
    ) -> EffectiveVillageItemState? {
        let orderedObservedItems = observedItems.sorted { $0.id < $1.id }
        guard let firstObserved = orderedObservedItems.first else { return nil }
        let importedDistribution = levelDistribution(observedItems)
        let rawInstanceWeight = rawInstanceWeight(observedItems)
        let importedCount = importedDistribution.flatMap { distribution in
            distribution.totalQuantity <= Int64(Int.max) ? Int(distribution.totalQuantity) : nil
        }
        let representative = rawItems.first {
            $0.id == firstObserved.id || $0.id == "agg:" + firstObserved.id
        } ?? rawByImportID[firstObserved.id]
        let manualItemState = manualUpgradeCore?.itemState(for: key)
        let manualEffectiveState = manualUpgradeCore?.effectiveState(for: key)
        let activeRecords = (manualUpgradeCore?.activeRecords.filter { $0.itemKey == key } ?? [])
            .sorted { $0.recordID.uuidString < $1.recordID.uuidString }
        let activeTarget = manualEffectiveState?.activeTargetDistribution ?? .empty
        let effectiveCompleted: ManualLevelDistribution?
        switch manualItemState?.status {
        case .manualCompleted:
            effectiveCompleted = manualEffectiveState?.effectiveCompletedDistribution
        case .unknown, .conflict:
            effectiveCompleted = nil
        case .observed, nil:
            effectiveCompleted = importedDistribution
        }

        let observedActiveItems = orderedObservedItems.filter {
            VillageCatalogProjection.liveRemainingSeconds(for: $0, snapshot: snapshot, at: now) ?? 0 > 0
        }
        let observedNeedsReimport = observedItems.contains {
            $0.timerSeconds != nil
                && VillageCatalogProjection.liveRemainingSeconds(for: $0, snapshot: snapshot, at: now) == 0
        }
        let hasExactActiveMatch = hasExactActiveMatch(
            records: activeRecords,
            observedItems: observedActiveItems,
            snapshot: snapshot,
            now: now
        )
        let activeCatalogDiagnostic = activeRecords.isEmpty ? nil : Self.activeCatalogDiagnostic(
            records: activeRecords,
            key: key,
            representative: representative,
            catalog: catalog,
            catalogIsUsable: catalogIsUsable
        )

        let status: EffectiveVillageItemStatus
        var provenance: [EffectiveVillageItemProvenance] = []
        var diagnostic: String?
        if let activeCatalogDiagnostic {
            status = .unknown
            provenance = [.manualActive]
            if !observedActiveItems.isEmpty { provenance.append(.importedActive) }
            diagnostic = activeCatalogDiagnostic
        } else if representative?.status == .unavailable {
            status = .unavailable
        } else if representative?.status == .unknown || representative?.status == .unverified {
            status = .unknown
            diagnostic = representative?.missingReason ?? "导入项目的目录状态无法验证。"
        } else if manualItemState?.status == .conflict {
            status = .conflict
            diagnostic = "本地手动状态处于冲突，暂不生成有效完成等级。"
        } else if manualItemState?.status == .unknown {
            status = .unknown
            diagnostic = "本地手动状态未知，暂不把缺失解释为零级或已完成。"
        } else if !activeRecords.isEmpty && !observedActiveItems.isEmpty && !hasExactActiveMatch {
            status = .conflict
            provenance = [.manualActive, .importedActive]
            diagnostic = "导入计时与本地手动记录无法按 key、等级、数量和计时证据精确匹配。"
        } else if !activeRecords.isEmpty {
            status = .manualActive
            provenance.append(.manualActive)
            if !observedActiveItems.isEmpty { provenance.append(.importedActive) }
        } else if manualItemState?.status == .manualCompleted {
            status = .manualCompleted
            provenance.append(.manualCompleted)
            if observedNeedsReimport { provenance.append(.needsReimport) }
        } else if observedNeedsReimport {
            status = .needsReimport
            provenance.append(.needsReimport)
        } else if !observedActiveItems.isEmpty {
            status = .importedActive
            provenance.append(.importedActive)
        } else {
            status = .observed
            provenance.append(.observed)
        }

        let stageMax = representative?.currentStageMaxLevel
        let globalMax = representative?.maxLevel
        let effectiveCatalogProjection: EffectiveCatalogProjection?
        if activeRecords.isEmpty, manualItemState?.status == .manualCompleted {
            let effectiveLevel = effectiveCompleted?.levels.count == 1
                ? effectiveCompleted?.levels.first?.level
                : nil
            effectiveCatalogProjection = Self.effectiveCatalogProjection(
                key: key,
                currentLevel: effectiveLevel,
                stageMax: stageMax,
                catalog: catalog,
                catalogIsUsable: catalogIsUsable
            )
        } else {
            effectiveCatalogProjection = nil
        }
        let targetLevel = activeRecords.first?.targetLevel ?? representative?.nextLevel
        let catalogLevel = effectiveCatalogProjection?.catalogLevel
            ?? targetLevel.flatMap { level in
                catalog?.item(section: key.rawSection, dataID: key.dataID)?.levels.first {
                    $0.level == level
                }
            }
        let catalogDurationState: CatalogDurationState?
        let catalogCosts: [CatalogUpgradeCost]?
        switch status {
        case .unknown, .conflict, .needsReimport, .unavailable:
            catalogDurationState = nil
            catalogCosts = nil
        default:
            catalogDurationState = catalogLevel?.durationState ?? representative?.nextLevelDurationState
            catalogCosts = catalogLevel?.upgradeCosts
        }

        return EffectiveVillageItemState(
            itemKey: key,
            rawItemID: representative?.id,
            importedCurrentLevel: uniformValue(observedItems.map(\.level)),
            importedCount: importedCount,
            importedInstanceWeight: rawInstanceWeight.total,
            importedCountOverflowed: rawInstanceWeight.overflowed,
            importedTimerSeconds: uniformValue(observedItems.map(\.timerSeconds)),
            importedRemainingSeconds: observedActiveItems.isEmpty
                ? uniformValue(observedItems.map(\.remainingSeconds))
                : uniformValue(observedActiveItems.map {
                    VillageCatalogProjection.liveRemainingSeconds(
                        for: $0, snapshot: snapshot, at: now
                    ) ?? $0.remainingSeconds
                }),
            importedDistribution: importedDistribution,
            manualCompletedDistribution: manualItemState?.manualCompletedDistribution,
            activeManualRecords: activeRecords,
            activeTargetDistribution: activeTarget,
            effectiveCompletedDistribution: effectiveCompleted,
            status: status,
            provenance: provenance,
            diagnostic: diagnostic,
            catalogDurationState: catalogDurationState,
            catalogCosts: catalogCosts,
            catalogNextUpgrade: effectiveCatalogProjection?.nextUpgrade,
            currentStageMaxLevel: stageMax,
            globalMaxLevel: globalMax
        )
    }

    private struct EffectiveCatalogProjection {
        let nextUpgrade: VillageNextUpgrade
        let catalogLevel: CatalogLevel?
    }

    /// Reprojects the catalog-facing next-upgrade semantics after a manual
    /// completion changes the current level. The imported projection cannot be
    /// reused here because its real-next-level calculation used the stale raw
    /// snapshot level.
    private static func effectiveCatalogProjection(
        key: TrackerItemKey,
        currentLevel: Int?,
        stageMax: Int?,
        catalog: GameCatalog?,
        catalogIsUsable: Bool
    ) -> EffectiveCatalogProjection? {
        guard let catalogItem = catalog?.item(section: key.rawSection, dataID: key.dataID) else {
            return nil
        }
        guard catalogIsUsable else {
            return EffectiveCatalogProjection(nextUpgrade: .unknown, catalogLevel: nil)
        }
        guard let currentLevel, currentLevel >= 0 else {
            return EffectiveCatalogProjection(nextUpgrade: .unknown, catalogLevel: nil)
        }
        guard let stageMax, stageMax > 0 else {
            return EffectiveCatalogProjection(nextUpgrade: .unverified, catalogLevel: nil)
        }
        if currentLevel >= catalogItem.maxLevel {
            return EffectiveCatalogProjection(nextUpgrade: .globalMaxed, catalogLevel: nil)
        }

        let threshold = currentLevel >= stageMax ? stageMax : currentLevel
        let realNext = catalogItem.levels
            .sorted { $0.level < $1.level }
            .first { $0.level > threshold }
        guard let realNext else {
            return EffectiveCatalogProjection(nextUpgrade: .globalMaxed, catalogLevel: nil)
        }
        guard realNext.level > currentLevel else {
            return EffectiveCatalogProjection(nextUpgrade: .unknown, catalogLevel: nil)
        }
        if currentLevel >= stageMax {
            let requirements = realNext.requirements(base: catalogItem.base)
            guard !requirements.isEmpty else {
                return EffectiveCatalogProjection(nextUpgrade: .globalMaxed, catalogLevel: nil)
            }
            return EffectiveCatalogProjection(
                nextUpgrade: .requires(
                    nextLevel: realNext.level,
                    requirements: requirements,
                    referenceDurationSeconds: realNext.durationSeconds
                ),
                catalogLevel: realNext
            )
        }
        return EffectiveCatalogProjection(
            nextUpgrade: .available(
                level: realNext.level,
                durationSeconds: realNext.durationSeconds
            ),
            catalogLevel: realNext
        )
    }

    private static func levelDistribution(_ items: [AccountItem]) -> ManualLevelDistribution? {
        guard !items.isEmpty, items.allSatisfy({ $0.level != nil }) else { return nil }
        var quantities: [Int: Int64] = [:]
        for item in items {
            guard let level = item.level else { return nil }
            let quantity = Int64(max(item.count ?? 1, 1))
            let (sum, overflow) = (quantities[level] ?? 0).addingReportingOverflow(quantity)
            guard !overflow else { return nil }
            quantities[level] = sum
        }
        return try? ManualLevelDistribution(levelQuantities: quantities)
    }

    private struct RawInstanceWeight {
        let total: Int64
        let overflowed: Bool
    }

    /// Count instances independently from the level histogram. The histogram
    /// is intentionally fail-closed for malformed levels, but the raw count
    /// remains valid evidence for metric denominators and unknown diagnostics.
    private static func rawInstanceWeight(_ items: [AccountItem]) -> RawInstanceWeight {
        var total: Int64 = 0
        var overflowed = false
        for item in items {
            let quantity = Int64(max(item.count ?? 1, 1))
            let result = total.addingReportingOverflow(quantity)
            if result.overflow {
                total = Int64.max
                overflowed = true
            } else {
                total = result.partialValue
            }
        }
        return RawInstanceWeight(total: total, overflowed: overflowed)
    }

    private static func uniformValue<T: Equatable>(_ values: [T?]) -> T? {
        guard let first = values.first,
              values.dropFirst().allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }

    /// Existing manual records keep their frozen values, but a currently
    /// active operation must not be treated as actionable when the current
    /// catalog cannot prove the same source, lifecycle, or duration. This is
    /// intentionally scoped to active records; completed history remains
    /// usable as historical effective progress.
    private static func activeCatalogDiagnostic(
        records: [ManualUpgradeRecord],
        key: TrackerItemKey,
        representative: VillageItemState?,
        catalog: GameCatalog?,
        catalogIsUsable: Bool
    ) -> String? {
        guard catalogIsUsable, let catalog else {
            return "当前静态目录不可用于验证本地进行中的手动升级。"
        }
        guard let manifest = catalog.manifest else {
            return "当前目录缺少 manifest，无法验证本地手动升级来源。"
        }
        switch representative?.availability {
        case .permanent, .seasonal(_, _, .active):
            break
        case .seasonal(_, _, let status):
            return "当前目录生命周期状态为 \(status)，不能把本地进行中升级视为可验证状态。"
        case .unconfigured:
            return "当前目录未配置该项目的生命周期，不能验证本地进行中升级。"
        case .conflict:
            return "当前目录的项目生命周期存在冲突，不能验证本地进行中升级。"
        case nil:
            return "当前项目没有可验证的目录生命周期。"
        }

        for record in records {
            let provenance = record.catalogProvenance
            guard provenance.gameVersion == catalog.gameVersion else {
                return "本地手动升级记录的目录版本与当前目录不一致。"
            }
            guard provenance.buildTag == manifest.buildTag,
                  provenance.sourceFingerprint == manifest.sourceFingerprint,
                  provenance.manifestSchemaVersion == manifest.schemaVersion else {
                return "本地手动升级记录的目录 manifest 或 source fingerprint 与当前目录不一致。"
            }
            guard let catalogItem = catalog.item(section: key.rawSection, dataID: key.dataID),
                  let level = catalogItem.levels.first(where: { $0.level == record.targetLevel }),
                  let durationState = level.durationState else {
                return "当前目录缺少本地手动升级目标等级的可信时长。"
            }
            switch durationState {
            case .timed(let seconds):
                guard record.durationKind == .timed, record.durationSeconds == seconds else {
                    return "本地手动升级冻结时长与当前目录不一致。"
                }
            case .instant:
                guard record.durationKind == .instant, record.durationSeconds == 0 else {
                    return "本地手动升级冻结时长与当前目录的即时升级语义不一致。"
                }
            case .initialLevel, .notApplicable, .sourceMissing, .parseFailed, .unknownReason:
                return "当前目录的升级时长状态不可用于本地手动升级。"
            }
        }
        return nil
    }

    private static func matches(
        record: ManualUpgradeRecord,
        item: AccountItem,
        snapshot: AccountSnapshot,
        now: Date
    ) -> Bool {
        guard let level = item.level,
              record.fromLevel == level,
              record.targetLevel == level + 1,
              record.quantity == Int64(max(item.count ?? 1, 1)),
              item.timerSeconds != nil,
              let remaining = VillageCatalogProjection.liveRemainingSeconds(
                for: item, snapshot: snapshot, at: now
              ) else { return false }
        guard let rawExpectedRemaining = VillageCatalogProjection.safeFloorInt64(
            record.expectedEndAt.timeIntervalSince(now)
        ) else { return false }
        let expectedRemaining = max(0, rawExpectedRemaining)
        return abs(expectedRemaining - remaining) <= 1
    }

    /// Checks exact imported/manual activity with one-to-one evidence usage.
    /// A plain `allSatisfy { contains(...) }` is insufficient because two local
    /// records could otherwise reuse one imported timer and be reported as an
    /// exact match.
    private static func hasExactActiveMatch(
        records: [ManualUpgradeRecord],
        observedItems: [AccountItem],
        snapshot: AccountSnapshot,
        now: Date
    ) -> Bool {
        guard !records.isEmpty, !observedItems.isEmpty,
              records.count <= observedItems.count else { return false }

        let candidates = records.map { record in
            observedItems.indices.filter { index in
                matches(
                    record: record,
                    item: observedItems[index],
                    snapshot: snapshot,
                    now: now
                )
            }
        }
        guard candidates.allSatisfy({ !$0.isEmpty }) else { return false }

        // Process the most constrained records first. The augmenting-path
        // search remains deterministic because both records and candidates
        // retain their stable sorted/index order.
        let order = candidates.indices.sorted { lhs, rhs in
            if candidates[lhs].count != candidates[rhs].count {
                return candidates[lhs].count < candidates[rhs].count
            }
            return lhs < rhs
        }
        var owner = Array(repeating: nil as Int?, count: observedItems.count)

        func augment(recordIndex: Int, visited: inout Set<Int>) -> Bool {
            for itemIndex in candidates[recordIndex] where visited.insert(itemIndex).inserted {
                if let previousRecord = owner[itemIndex] {
                    if augment(recordIndex: previousRecord, visited: &visited) {
                        owner[itemIndex] = recordIndex
                        return true
                    }
                } else {
                    owner[itemIndex] = recordIndex
                    return true
                }
            }
            return false
        }

        for recordIndex in order {
            var visited = Set<Int>()
            guard augment(recordIndex: recordIndex, visited: &visited) else { return false }
        }
        return true
    }

    private static func makeCoverage(
        trackerItems: [EffectiveVillageItemState],
        manualUpgradeCore: ManualUpgradeCore?
    ) -> ManualTrackerCoverage {
        guard let manualUpgradeCore else {
            return ManualTrackerCoverage(
                observedItemCount: trackerItems.count,
                manualItemCount: 0,
                effectiveItemCount: 0,
                activeRecordCount: 0,
                unknownItemCount: 0,
                state: .unavailable,
                diagnostics: ["未提供本地手动状态。"]
            )
        }
        let supportedItems = trackerItems.filter { $0.status != .unavailable }
        let trackerKeys = Set(supportedItems.map(\.itemKey))
        let unmatched = manualUpgradeCore.itemStates.filter { !trackerKeys.contains($0.itemKey) }.count
        let unknown = supportedItems.filter { $0.status == .unknown || $0.status == .conflict }.count
        let effective = supportedItems.filter { $0.effectiveCompletedDistribution != nil }.count
        var diagnostics: [String] = []
        if unmatched > 0 {
            diagnostics.append("有 \(unmatched) 条本地手动状态没有对应的当前快照项目。")
        }
        if unknown > 0 {
            diagnostics.append("有 \(unknown) 个项目的本地有效状态未知或冲突。")
        }
        let state: ProgressMetricState
        if supportedItems.isEmpty {
            state = .unknown
        } else if unmatched > 0 || unknown > 0 || effective < supportedItems.count {
            state = .partial
        } else {
            state = .ready
        }
        return ManualTrackerCoverage(
            observedItemCount: supportedItems.count,
            manualItemCount: manualUpgradeCore.itemStates.count,
            effectiveItemCount: effective,
            activeRecordCount: manualUpgradeCore.activeRecords.count,
            unknownItemCount: unknown,
            state: state,
            diagnostics: diagnostics
        )
    }

    private static func instanceMetric(
        trackerItems: [EffectiveVillageItemState],
        availableItems: [VillageItemState],
        catalogIsUsable: Bool,
        compatibility: CatalogCompatibility,
        manualCoverage: ManualTrackerCoverage
    ) -> ProgressMetric {
        guard catalogIsUsable else {
            return unavailableMetric(kind: .instanceProgress)
        }
        var numerator = 0
        var denominator = 0
        var unknown = 0
        var saturated = false
        // Stable tracker items are already one row per key. Do not iterate
        // aggregated VillageItemState rows here: duplicate levels can attach
        // the same effective distribution to more than one display row and
        // would otherwise multiply both the denominator and unknown weight.
        for item in trackerItems where item.status != .unavailable {
            let distribution = trackerDistribution(for: item)
            // The denominator is the complete observed instance universe. An
            // active reservation is still an instance, so use the imported
            // distribution rather than the reservation-adjusted distribution.
            let weight = item.importedInstanceWeight
            saturated = saturated || item.importedCountOverflowed
            let weightInfo = add(&denominator, weight)
            saturated = saturated || weightInfo
            guard item.isKnown,
                  let distribution,
                  !distribution.isEmpty,
                  let stageMax = item.currentStageMaxLevel,
                  stageMax > 0 else {
                saturated = saturated || add(&unknown, weight)
                continue
            }
            let completed = distribution.levels
                .filter { $0.level >= stageMax }
                .reduce(Int64(0)) { total, entry in
                    total.addingReportingOverflow(entry.quantity).partialValue
                }
            saturated = saturated || add(&numerator, completed)
        }
        // `.available` is a known universe gap, not an unknown observation;
        // it contributes to the denominator but not to the numerator or
        // unknown-weight diagnostic, matching VillageProgressProjection.
        for item in availableItems {
            saturated = saturated || add(&denominator, Int64(item.instanceWeight))
        }
        let reason = manualCoverage.diagnostics.joined(separator: " ")
        return makeMetric(
            kind: .instanceProgress,
            numerator: numerator,
            denominator: denominator,
            saturated: saturated,
            unknownWeight: unknown,
            compatibility: compatibility,
            extraReason: reason.isEmpty ? nil : reason,
            units: "实例"
        )
    }

    private static func effectiveMetric(
        trackerItems: [EffectiveVillageItemState],
        catalogIsUsable: Bool,
        compatibility: CatalogCompatibility,
        manualCoverage: ManualTrackerCoverage
    ) -> ProgressMetric {
        guard catalogIsUsable else {
            return unavailableMetric(kind: .effectiveTrackerProgress)
        }
        var numerator = 0
        var denominator = 0
        var unknown = 0
        var saturated = false
        for item in trackerItems where item.status != .unavailable {
            saturated = saturated || item.importedCountOverflowed
            guard item.isKnown,
                  let maxLevel = item.globalMaxLevel,
                  maxLevel > 0,
                  let distribution = trackerDistribution(for: item),
                  !distribution.isEmpty else {
                saturated = saturated || add(&unknown, item.importedInstanceWeight)
                continue
            }
            for entry in distribution.levels {
                let denominatorProduct = multiply(entry.quantity, Int64(maxLevel))
                let denominatorOverflowed = add(&denominator, denominatorProduct.value)
                saturated = saturated
                    || denominatorProduct.overflowed
                    || denominatorOverflowed

                let numeratorProduct = multiply(
                    entry.quantity,
                    Int64(min(max(0, entry.level), maxLevel))
                )
                let numeratorOverflowed = add(&numerator, numeratorProduct.value)
                saturated = saturated
                    || numeratorProduct.overflowed
                    || numeratorOverflowed
            }
        }
        let reason = manualCoverage.diagnostics.joined(separator: " ")
        return makeMetric(
            kind: .effectiveTrackerProgress,
            numerator: numerator,
            denominator: denominator,
            saturated: saturated,
            unknownWeight: unknown,
            compatibility: compatibility,
            extraReason: reason.isEmpty ? nil : reason,
            units: "级"
        )
    }

    /// A current manual upgrade keeps its target out of completed progress,
    /// but the imported source level remains the last observed level until
    /// settlement. ManualUpgradeCore's effective distribution intentionally
    /// removes reserved source quantities, so restore those source quantities
    /// for progress calculations without treating the target as completed.
    private static func trackerDistribution(
        for item: EffectiveVillageItemState
    ) -> ManualLevelDistribution? {
        guard let effective = item.effectiveCompletedDistribution else {
            return item.status == .manualActive ? item.importedDistribution : nil
        }
        guard item.status == .manualActive else { return effective }
        do {
            var restored = effective
            for record in item.activeManualRecords {
                restored = try restored.adding(level: record.fromLevel, quantity: record.quantity)
            }
            return restored
        } catch {
            // The core validates conservation. If persisted data is nevertheless
            // inconsistent, retain the imported distribution and let isKnown
            // keep the effective metric fail-closed when the state is unknown.
            return item.importedDistribution
        }
    }

    private static func makeMetric(
        kind: ProgressMetric.Kind,
        numerator: Int,
        denominator: Int,
        saturated: Bool,
        unknownWeight: Int,
        compatibility: CatalogCompatibility,
        extraReason: String?,
        units: String
    ) -> ProgressMetric {
        var reasons: [String] = []
        if denominator == 0 {
            reasons.append("无可确认项目，暂无法计算")
        }
        if unknownWeight > 0 {
            reasons.append("\(unknownWeight) 个实例未知或无法验证，结果仅为可确认项目。")
        }
        if let extraReason { reasons.append(extraReason) }
        if compatibility.isUnverified {
            reasons.append("目录与玩家版本未验证，百分比可能过时。")
        }
        let state: ProgressMetricState
        if denominator == 0 {
            state = .unknown
        } else if reasons.isEmpty {
            state = .ready
        } else {
            state = .partial
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

    private static func unavailableMetric(kind: ProgressMetric.Kind) -> ProgressMetric {
        ProgressMetric(
            kind: kind,
            numerator: 0,
            denominator: 0,
            state: .unavailable,
            units: kind == .instanceProgress ? "实例" : "级",
            degradedReason: "目录不可用或版本不匹配，暂无法计算该指标。"
        )
    }

    private static func add(_ target: inout Int, _ value: Int64) -> Bool {
        let exceedsIntRange = value > Int64(Int.max)
        let converted = exceedsIntRange ? Int.max : Int(max(0, value))
        let result = target.addingReportingOverflow(converted)
        target = result.overflow ? Int.max : result.partialValue
        return result.overflow || exceedsIntRange
    }

    private static func multiply(_ lhs: Int64, _ rhs: Int64) -> (value: Int64, overflowed: Bool) {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return (
            value: result.overflow ? Int64.max : result.partialValue,
            overflowed: result.overflow
        )
    }
}

private extension VillageItemState {
    func attachingEffectiveState(_ effectiveState: EffectiveVillageItemState?) -> VillageItemState {
        VillageItemState(
            id: id,
            section: section,
            dataID: dataID,
            base: base,
            name: name,
            category: category,
            currentLevel: currentLevel,
            count: count,
            timerSeconds: timerSeconds,
            remainingSeconds: remainingSeconds,
            nextLevel: nextLevel,
            nextLevelDurationSeconds: nextLevelDurationSeconds,
            nextLevelDurationState: nextLevelDurationState,
            maxLevel: maxLevel,
            currentStageMaxLevel: currentStageMaxLevel,
            nextUpgrade: nextUpgrade,
            status: status,
            missingReason: missingReason,
            catalogItemMissingReason: catalogItemMissingReason,
            availability: availability,
            icon: icon,
            levelVisual: levelVisual,
            currentLevelIcon: currentLevelIcon,
            currentLevelVisual: currentLevelVisual,
            isNested: isNested,
            displayCategory: displayCategory,
            countOverflowed: countOverflowed,
            effectiveState: effectiveState
        )
    }
}

extension PlayerUnlockLevels {
    /// Replaces only explicitly accepted manual-completed prerequisite levels.
    /// Active targets and unknown/conflicting local states remain unknown.
    static func effective(
        snapshot: AccountSnapshot?,
        manualUpgradeCore: ManualUpgradeCore?
    ) -> PlayerUnlockLevels {
        let homeKeys = snapshot.map { TrackerItemKeyAdapter.keyMap(in: $0, base: .home) } ?? [:]
        let builderKeys = snapshot.map { TrackerItemKeyAdapter.keyMap(in: $0, base: .builder) } ?? [:]

        func level(section: String, dataID: Int64, keys: [String: TrackerItemKey]) -> Int? {
            guard let item = snapshot?.objectSections[section]?.first(where: { $0.dataID == dataID }) else {
                return nil
            }
            guard let manualUpgradeCore,
                  let key = keys[item.id],
                  let manualState = manualUpgradeCore.itemState(for: key) else {
                return item.level
            }
            switch manualState.status {
            case .observed:
                return item.level
            case .unknown, .conflict:
                return nil
            case .manualCompleted:
                guard let distribution = manualUpgradeCore
                    .effectiveState(for: key)?.effectiveCompletedDistribution,
                    distribution.levels.count == 1 else { return nil }
                return distribution.levels.first?.level
            }
        }

        return PlayerUnlockLevels(
            townHall: level(section: "buildings", dataID: UnlockBuildingDataID.townHall, keys: homeKeys),
            builderHall: level(section: "buildings2", dataID: UnlockBuildingDataID.builderHall, keys: builderKeys),
            laboratory: level(section: "buildings", dataID: UnlockBuildingDataID.laboratory, keys: homeKeys),
            starLaboratory: level(section: "buildings2", dataID: UnlockBuildingDataID.starLaboratory, keys: builderKeys),
            heroHall: level(section: "buildings", dataID: UnlockBuildingDataID.heroHall, keys: homeKeys),
            blacksmith: level(section: "buildings", dataID: UnlockBuildingDataID.blacksmith, keys: homeKeys)
        )
    }
}

private extension VillageProgressMetrics {
    func replacingTrackerMetrics(
        instanceProgress: ProgressMetric,
        effectiveTrackerProgress: ProgressMetric
    ) -> VillageProgressMetrics {
        VillageProgressMetrics(
            currentStageProgress: currentStageProgress,
            globalProgress: globalProgress,
            snapshotCoverage: snapshotCoverage,
            instanceProgress: instanceProgress,
            effectiveTrackerProgress: effectiveTrackerProgress
        )
    }
}
