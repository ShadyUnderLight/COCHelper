import Foundation

public enum ManualReconciliationDecision: String, Codable, Hashable, Sendable {
    case applyNonConflicting
    case keepLocal
    case acceptObserved
}

public enum ManualReconciliationTimeConfidence: String, Codable, Hashable, Sendable {
    case reliableSourceTimestamp
    case sourceTimestampAbsent
    case sourceTimestampConflict
    case localAppliedAtOnly

    public var label: String {
        switch self {
        case .reliableSourceTimestamp:
            "来源时间可比较"
        case .sourceTimestampAbsent:
            "新快照未提供来源时间"
        case .sourceTimestampConflict:
            "新快照来源时间更早"
        case .localAppliedAtOnly:
            "仅有本地应用时间"
        }
    }
}

public enum ManualReconciliationClassification: String, Codable, Hashable, Sendable {
    case duplicate
    case newObservation
    case exactMatch
    case observedAhead
    case manualAhead
    case staleImport
    case observedTimerEnded
    case possibleDuplicate
    case unknown
    case conflict
    case lineageMismatch

    public var label: String {
        switch self {
        case .duplicate: "重复导入"
        case .newObservation: "新观察"
        case .exactMatch: "观察一致"
        case .observedAhead: "导入观察领先"
        case .manualAhead: "本地手动状态领先"
        case .staleImport: "旧快照"
        case .observedTimerEnded: "计时消失，结果未知"
        case .possibleDuplicate: "可能重复的进行中记录"
        case .unknown: "证据不足"
        case .conflict: "冲突"
        case .lineageMismatch: "账号身份不一致"
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .duplicate, .newObservation, .exactMatch, .observedAhead:
            false
        case .manualAhead, .staleImport, .observedTimerEnded, .possibleDuplicate,
             .unknown, .conflict, .lineageMismatch:
            true
        }
    }
}

public struct ManualReconciliationItem: Codable, Hashable, Sendable, Identifiable {
    public let itemKey: TrackerItemKey
    public let displayName: String
    public let classification: ManualReconciliationClassification
    public let message: String
    public let previousDistribution: ManualLevelDistribution?
    public let observedDistribution: ManualLevelDistribution?
    public let relatedRecordIDs: [UUID]
    public let confirmedRecordIDs: [UUID]
    public let observedTimer: Bool
    public let coverageComplete: Bool

    public init(
        itemKey: TrackerItemKey,
        displayName: String,
        classification: ManualReconciliationClassification,
        message: String,
        previousDistribution: ManualLevelDistribution? = nil,
        observedDistribution: ManualLevelDistribution? = nil,
        relatedRecordIDs: [UUID] = [],
        confirmedRecordIDs: [UUID] = [],
        observedTimer: Bool = false,
        coverageComplete: Bool = false
    ) {
        self.itemKey = itemKey
        self.displayName = displayName
        self.classification = classification
        self.message = message
        self.previousDistribution = previousDistribution
        self.observedDistribution = observedDistribution
        self.relatedRecordIDs = relatedRecordIDs.sorted { $0.uuidString < $1.uuidString }
        self.confirmedRecordIDs = confirmedRecordIDs.sorted { $0.uuidString < $1.uuidString }
        self.observedTimer = observedTimer
        self.coverageComplete = coverageComplete
    }

    public var id: String { itemKey.stableID }
}

public struct ManualReconciliationPreview: Codable, Hashable, Sendable, Identifiable {
    public let previewID: UUID
    public let villageID: UUID
    public let previousReference: ManualBaselineReference?
    public let previousSnapshotID: UUID?
    public let previousSnapshotFingerprint: String?
    public let previousLineageID: UUID?
    public let manualStateUpdatedAt: Date
    public let newReference: ManualBaselineReference
    /// Stable candidate identity independent of the random snapshot/lineage
    /// UUIDs allocated while planning a new import.
    public let newNormalizedPlayerTag: String?
    public let sourceTimestamp: Date?
    public let appliedAt: Date
    public let timeConfidence: ManualReconciliationTimeConfidence
    public let duplicate: Bool
    public let lineageComparable: Bool
    public let items: [ManualReconciliationItem]

    public init(
        previewID: UUID = UUID(),
        villageID: UUID,
        previousReference: ManualBaselineReference?,
        previousSnapshotID: UUID? = nil,
        previousSnapshotFingerprint: String? = nil,
        previousLineageID: UUID? = nil,
        manualStateUpdatedAt: Date,
        newReference: ManualBaselineReference,
        newNormalizedPlayerTag: String? = nil,
        sourceTimestamp: Date?,
        appliedAt: Date,
        timeConfidence: ManualReconciliationTimeConfidence,
        duplicate: Bool,
        lineageComparable: Bool,
        items: [ManualReconciliationItem]
    ) {
        self.previewID = previewID
        self.villageID = villageID
        self.previousReference = previousReference
        self.previousSnapshotID = previousSnapshotID
        self.previousSnapshotFingerprint = previousSnapshotFingerprint
        self.previousLineageID = previousLineageID
        self.manualStateUpdatedAt = manualStateUpdatedAt
        self.newReference = newReference
        self.newNormalizedPlayerTag = newNormalizedPlayerTag
        self.sourceTimestamp = sourceTimestamp
        self.appliedAt = appliedAt
        self.timeConfidence = timeConfidence
        self.duplicate = duplicate
        self.lineageComparable = lineageComparable
        self.items = items.sorted { $0.itemKey.stableID < $1.itemKey.stableID }
    }

    public var id: UUID { previewID }
    public var attentionCount: Int { items.filter(\.classification.needsAttention).count }
    public var safeCount: Int { items.count - attentionCount }
    public var requiresExplicitDecision: Bool { attentionCount > 0 }

    public func count(_ classification: ManualReconciliationClassification) -> Int {
        items.filter { $0.classification == classification }.count
    }
}

/// Persisted audit record. Reconciliation remains independent from a manual
/// record's active/completed/cancelled lifecycle status.
public struct ManualReconciliationRecord: Codable, Hashable, Sendable, Identifiable {
    public let reconciliationID: UUID
    public let previousReference: ManualBaselineReference?
    public let newReference: ManualBaselineReference
    public let decision: ManualReconciliationDecision
    public let timeConfidence: ManualReconciliationTimeConfidence
    public let sourceTimestamp: Date?
    public let duplicate: Bool
    public let appliedAt: Date
    public let items: [ManualReconciliationItem]

    public init(
        reconciliationID: UUID = UUID(),
        previousReference: ManualBaselineReference?,
        newReference: ManualBaselineReference,
        decision: ManualReconciliationDecision,
        timeConfidence: ManualReconciliationTimeConfidence,
        sourceTimestamp: Date?,
        duplicate: Bool,
        appliedAt: Date,
        items: [ManualReconciliationItem]
    ) {
        self.reconciliationID = reconciliationID
        self.previousReference = previousReference
        self.newReference = newReference
        self.decision = decision
        self.timeConfidence = timeConfidence
        self.sourceTimestamp = sourceTimestamp
        self.duplicate = duplicate
        self.appliedAt = appliedAt
        self.items = items.sorted { $0.itemKey.stableID < $1.itemKey.stableID }
    }

    public var id: UUID { reconciliationID }
}

public struct ManualReconciliationPlan: Sendable {
    public let preview: ManualReconciliationPreview
    public let state: ManualTrackerVillageState

    public init(preview: ManualReconciliationPreview, state: ManualTrackerVillageState) {
        self.preview = preview
        self.state = state
    }
}

public enum ManualReconciliationError: Error, LocalizedError, Equatable, Sendable {
    case villageMismatch
    case stalePreview
    case invalidObservation(String)

    public var errorDescription: String? {
        switch self {
        case .villageMismatch:
            "对账目标村庄与快照历史不一致。"
        case .stalePreview:
            "对账预览已经过期，请重新解析快照后再应用。"
        case .invalidObservation(let message):
            "导入观察无法用于对账：" + message
        }
    }
}

public enum ManualTrackerReconciliationService {
    private struct Observation {
        let distribution: ManualLevelDistribution?
        let displayName: String
        let hasTimer: Bool
        let coverageComplete: Bool
        let timerCoverageComplete: Bool
    }

    public static func reference(
        for entry: SnapshotHistoryEntry,
        in envelope: SnapshotHistoryEnvelope
    ) -> ManualBaselineReference {
        let duplicateCount = envelope.duplicateMetadata[entry.snapshotID.uuidString]?
            .duplicateImportCount ?? 0
        let revision = duplicateCount == 0
            ? entry.snapshotID.uuidString
            : entry.snapshotID.uuidString + ":observation:" + String(duplicateCount)
        return ManualBaselineReference(
            revision: revision,
            fingerprint: entry.canonicalFingerprint,
            lineageID: entry.lineageID.uuidString
        )
    }

    public static func preview(
        villageID: UUID,
        previousEntry: SnapshotHistoryEntry?,
        decision: SnapshotHistoryImportDecision,
        currentState: ManualTrackerVillageState,
        appliedAt: Date
    ) throws -> ManualReconciliationPreview {
        guard decision.entry.villageID == villageID,
              currentState.villageID == villageID,
              previousEntry == nil || previousEntry?.villageID == villageID else {
            throw ManualReconciliationError.villageMismatch
        }

        let newReference = reference(for: decision.entry, in: decision.envelope)
        let previousReference = currentState.baselineReference
        let newSourceTimestamp = sourceTimestamp(for: decision)
        let timeConfidence = timeConfidence(
            previous: previousEntry?.sourceTimestamp,
            new: newSourceTimestamp
        )
        let historyLineageComparable = previousEntry == nil || (
            previousEntry?.lineageID == decision.entry.lineageID
                && decision.lineage.comparisonAllowed
        )
        let manualLineageComparable = previousReference.map {
            $0.lineageID == newReference.lineageID
        } ?? true
        let lineageComparable = historyLineageComparable && manualLineageComparable
        let observations = try observations(in: decision.entry)
        let previousObservations = try previousEntry.map(observations(in:)) ?? [:]
        let diff = previousEntry.map { SnapshotDiffEngine.compare(from: $0, to: decision.entry) }
        let diffByKey = Dictionary(grouping: diff?.changes.compactMap { change -> (TrackerItemKey, SnapshotChange)? in
            guard let key = trackerKey(for: change.identity) else { return nil }
            return (key, change)
        } ?? [], by: { $0.0 })

        let core = currentState.core
        let existingKeys = Set(core.itemStates.map(\.itemKey))
        let allKeys = existingKeys.union(observations.keys)
        var items: [ManualReconciliationItem] = []
        items.reserveCapacity(allKeys.count)

        for key in allKeys.sorted(by: { $0.stableID < $1.stableID }) {
            let state = core.itemState(for: key)
            let records = core.records.filter { $0.itemKey == key }
            let observation = observations[key]
            let previousObservation = previousObservations[key]
            let previousDistribution = effectiveDistribution(state)
            let confirmed = lineageComparable && timeConfidence == .reliableSourceTimestamp
                ? confirmedRecords(
                    records,
                    previous: previousObservation?.distribution,
                    observed: observation?.distribution,
                    sourceTimestamp: newSourceTimestamp,
                    requireExpectedEnd: true
                )
                : []
            let relatedChanges = diffByKey[key]?.map(\.1) ?? []
            let classification = classification(
                duplicate: decision.duplicate,
                lineageComparable: lineageComparable,
                timeConfidence: timeConfidence,
                hasExistingState: state != nil,
                previousDistribution: previousDistribution,
                observation: observation,
                previousObservation: previousObservation,
                records: records,
                confirmedRecordIDs: confirmed,
                changes: relatedChanges
            )
            items.append(ManualReconciliationItem(
                itemKey: key,
                displayName: observation?.displayName
                    ?? previousObservation?.displayName
                    ?? key.stableID,
                classification: classification,
                message: message(for: classification),
                previousDistribution: previousDistribution,
                observedDistribution: observation?.distribution,
                relatedRecordIDs: records.map(\.recordID),
                confirmedRecordIDs: confirmed,
                observedTimer: observation?.hasTimer ?? false,
                coverageComplete: observation?.coverageComplete ?? false
            ))
        }

        return ManualReconciliationPreview(
            villageID: villageID,
            previousReference: previousReference,
            previousSnapshotID: previousEntry?.snapshotID,
            previousSnapshotFingerprint: previousEntry?.canonicalFingerprint,
            previousLineageID: previousEntry?.lineageID,
            manualStateUpdatedAt: currentState.stateUpdatedAt,
            newReference: newReference,
            newNormalizedPlayerTag: decision.entry.normalizedPlayerTag,
            sourceTimestamp: newSourceTimestamp,
            appliedAt: appliedAt,
            timeConfidence: timeConfidence,
            duplicate: decision.duplicate,
            lineageComparable: lineageComparable,
            items: items
        )
    }

    public static func reconcile(
        villageID: UUID,
        previousEntry: SnapshotHistoryEntry?,
        historyDecision: SnapshotHistoryImportDecision,
        currentState: ManualTrackerVillageState,
        expectedPreview: ManualReconciliationPreview? = nil,
        decision: ManualReconciliationDecision,
        appliedAt: Date
    ) throws -> ManualReconciliationPlan {
        if let expectedPreview {
            guard expectedPreview.villageID == villageID,
                  expectedPreview.previousReference == currentState.baselineReference,
                  expectedPreview.previousSnapshotID == previousEntry?.snapshotID,
                  expectedPreview.previousSnapshotFingerprint == previousEntry?.canonicalFingerprint,
                  expectedPreview.previousLineageID == previousEntry?.lineageID,
                  expectedPreview.manualStateUpdatedAt == currentState.stateUpdatedAt else {
                throw ManualReconciliationError.stalePreview
            }
        }
        let preview = try preview(
            villageID: villageID,
            previousEntry: previousEntry,
            decision: historyDecision,
            currentState: currentState,
            appliedAt: appliedAt
        )
        if let expectedPreview,
           !candidateMatches(expectedPreview, actual: preview) {
            throw ManualReconciliationError.stalePreview
        }
        let observations = try observations(in: historyDecision.entry)
        let classifications = Dictionary(uniqueKeysWithValues: preview.items.map {
            ($0.itemKey, $0)
        })

        let canCrossLineage = preview.lineageComparable || decision == .acceptObserved
        let rebuiltCore: ManualUpgradeCore
        if canCrossLineage {
            rebuiltCore = try rebuildCore(
                currentState.core,
                observations: observations,
                classifications: classifications,
                newReference: preview.newReference,
                sourceTimestamp: preview.sourceTimestamp,
                decision: decision
            )
        } else {
            rebuiltCore = currentState.core
        }

        var diagnostics = currentState.diagnostics
        if preview.requiresExplicitDecision {
            diagnostics.append(ManualTrackerDiagnostic(
                kind: .conflict,
                code: "snapshot_reconciliation_attention",
                message: "本次导入有 \(preview.attentionCount) 个项目需要保留本地状态或显式接受观察。",
                recordedAt: appliedAt
            ))
        }
        let record = ManualReconciliationRecord(
            previousReference: preview.previousReference,
            newReference: preview.newReference,
            decision: decision,
            timeConfidence: preview.timeConfidence,
            sourceTimestamp: preview.sourceTimestamp,
            duplicate: preview.duplicate,
            appliedAt: appliedAt,
            items: preview.items
        )
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: rebuiltCore,
            stateUpdatedAt: appliedAt,
            lastSettleAt: currentState.lastSettleAt,
            lastImportAt: appliedAt,
            diagnostics: diagnostics,
            reconciliationHistory: currentState.reconciliationHistory + [record],
            queueCapacityConfigs: currentState.queueCapacityConfigs
        )
        return ManualReconciliationPlan(preview: preview, state: state)
    }

    private static func rebuildCore(
        _ core: ManualUpgradeCore,
        observations: [TrackerItemKey: Observation],
        classifications: [TrackerItemKey: ManualReconciliationItem],
        newReference: ManualBaselineReference,
        sourceTimestamp: Date?,
        decision: ManualReconciliationDecision
    ) throws -> ManualUpgradeCore {
        let existingStates = Dictionary(uniqueKeysWithValues: core.itemStates.map { ($0.itemKey, $0) })
        let allKeys = Set(existingStates.keys).union(observations.keys)
        var records: [ManualUpgradeRecord] = []
        records.reserveCapacity(core.records.count)

        for oldRecord in core.records {
            let item = classifications[oldRecord.itemKey]
            let hasActiveRecord = core.records.contains {
                $0.itemKey == oldRecord.itemKey && $0.status == .active
            }
            let shouldAdopt = shouldAdopt(
                item,
                decision: decision,
                hasActiveRecord: hasActiveRecord
            )
            let confirmed = shouldAdopt && (item?.confirmedRecordIDs.contains(oldRecord.recordID) ?? false)
            records.append(try ManualUpgradeRecord(
                recordID: oldRecord.recordID,
                itemKey: oldRecord.itemKey,
                fromLevel: oldRecord.fromLevel,
                targetLevel: oldRecord.targetLevel,
                quantity: oldRecord.quantity,
                startedAt: oldRecord.startedAt,
                expectedEndAt: oldRecord.expectedEndAt,
                durationSeconds: oldRecord.durationSeconds,
                durationKind: oldRecord.durationKind,
                frozenCosts: oldRecord.frozenCosts,
                catalogProvenance: oldRecord.catalogProvenance,
                baselineReference: newReference,
                queueKind: oldRecord.queueKind,
                status: confirmed && oldRecord.status == .active ? .completed : oldRecord.status
            ))
        }

        var states: [ManualItemState] = []
        states.reserveCapacity(allKeys.count)
        for key in allKeys.sorted(by: { $0.stableID < $1.stableID }) {
            let old = existingStates[key]
            let observation = observations[key]
            let itemRecords = records.filter { $0.itemKey == key }
            let hasLocal = hasLocalState(state: old, records: core.records.filter { $0.itemKey == key })
            let item = classifications[key]
            let hasActiveRecord = itemRecords.contains { $0.status == .active }
            let adopt = shouldAdopt(
                item,
                decision: decision,
                hasActiveRecord: hasActiveRecord
            )

            if old == nil, let distribution = observation?.distribution {
                let imported = try ManualImportedObservation(
                    reference: newReference,
                    levelDistribution: distribution,
                    sourceTimestamp: sourceTimestamp
                )
                states.append(try ManualItemState(
                    itemKey: key,
                    baselineReference: newReference,
                    importedObservation: imported,
                    status: .observed
                ))
                continue
            }
            guard let old else { continue }

            // An imported observation is not a user-confirmed manual
            // completion. When the new snapshot is unknown/partial/stale, keep
            // that distinction after rebasing the baseline instead of
            // materializing it as `.manualCompleted`.
            if !hasLocal, observation?.distribution == nil {
                let imported = try ManualImportedObservation(
                    reference: newReference,
                    levelDistribution: nil,
                    sourceTimestamp: sourceTimestamp
                )
                let status: ManualItemStatus
                switch old.status {
                case .conflict:
                    status = .conflict
                case .unknown:
                    status = .unknown
                default:
                    status = .observed
                }
                states.append(try ManualItemState(
                    itemKey: key,
                    baselineReference: newReference,
                    importedObservation: imported,
                    status: status
                ))
                continue
            }

            if !hasLocal, adopt, let distribution = observation?.distribution {
                let imported = try ManualImportedObservation(
                    reference: newReference,
                    levelDistribution: distribution,
                    sourceTimestamp: sourceTimestamp
                )
                states.append(try ManualItemState(
                    itemKey: key,
                    baselineReference: newReference,
                    importedObservation: imported,
                    status: .observed
                ))
                continue
            }

            let preserved = effectiveDistribution(old) ?? old.manualCompletedDistribution
            let materialized = adopt
                ? (observation?.distribution ?? preserved)
                : preserved
            states.append(try ManualItemState(
                itemKey: key,
                baselineReference: newReference,
                importedObservation: nil,
                manualCompletedDistribution: materialized,
                status: .manualCompleted
            ))

            // ManualUpgradeCore validates active reservations against the
            // materialized distribution. If an explicit observed rebase cannot
            // retain an unconfirmed active source quantity, fail closed.
            for active in itemRecords where active.status == .active {
                guard materialized.quantity(at: active.fromLevel) >= active.quantity else {
                    throw ManualReconciliationError.invalidObservation(
                        "观察结果无法保留进行中的本地记录 \(active.recordID.uuidString)。"
                    )
                }
            }
        }
        return try ManualUpgradeCore(itemStates: states, records: records)
    }

    private static func shouldAdopt(
        _ item: ManualReconciliationItem?,
        decision: ManualReconciliationDecision,
        hasActiveRecord: Bool
    ) -> Bool {
        guard let item else { return false }
        switch decision {
        case .keepLocal:
            return item.classification == .duplicate || item.classification == .newObservation
        case .acceptObserved:
            return true
        case .applyNonConflicting:
            guard [.duplicate, .newObservation, .exactMatch, .observedAhead]
                .contains(item.classification) else { return false }
            if item.classification == .observedAhead,
               hasActiveRecord,
               item.confirmedRecordIDs.isEmpty {
                return false
            }
            return true
        }
    }

    private static func classification(
        duplicate: Bool,
        lineageComparable: Bool,
        timeConfidence: ManualReconciliationTimeConfidence,
        hasExistingState: Bool,
        previousDistribution: ManualLevelDistribution?,
        observation: Observation?,
        previousObservation: Observation?,
        records: [ManualUpgradeRecord],
        confirmedRecordIDs: [UUID],
        changes: [SnapshotChange]
    ) -> ManualReconciliationClassification {
        if duplicate { return .duplicate }
        if !lineageComparable && hasExistingState { return .lineageMismatch }
        if timeConfidence == .sourceTimestampConflict && hasExistingState { return .staleImport }
        if observation?.hasTimer == true,
           records.contains(where: { $0.status == .active }),
           confirmedRecordIDs.isEmpty {
            return .possibleDuplicate
        }
        guard let observation, observation.coverageComplete,
              let observed = observation.distribution else {
            return .unknown
        }
        guard hasExistingState else { return .newObservation }
        guard let previousDistribution else { return .newObservation }

        let timerEnded = (previousObservation?.hasTimer ?? false) && !observation.hasTimer
        if timerEnded {
            guard previousObservation?.timerCoverageComplete == true,
                  observation.timerCoverageComplete else {
                return .unknown
            }
            if observed == previousDistribution,
               records.contains(where: { $0.status == .active }) {
                return .observedTimerEnded
            }
        }
        if timeConfidence == .sourceTimestampAbsent
            || timeConfidence == .localAppliedAtOnly {
            return .unknown
        }
        if observed == previousDistribution {
            return .exactMatch
        }
        if dominates(observed, previousDistribution) {
            if records.contains(where: { $0.status == .active }),
               confirmedRecordIDs.isEmpty {
                return .unknown
            }
            return .observedAhead
        }
        if dominates(previousDistribution, observed) {
            return .manualAhead
        }
        if changes.contains(where: { $0.coverage.state != .complete }) {
            // 任一侧字段/section coverage 不完整 → 证据不足，不能断言冲突。
            // 守恒失败的 unknown change 保持 coverage.state == .complete，
            // 因此不会落到这里，而是按分布冲突处理（下方 .conflict）。
            return .unknown
        }
        return .conflict
    }

    private static func candidateMatches(
        _ expected: ManualReconciliationPreview,
        actual: ManualReconciliationPreview
    ) -> Bool {
        guard expected.duplicate == actual.duplicate,
              expected.newReference.fingerprint == actual.newReference.fingerprint,
              expected.newNormalizedPlayerTag == actual.newNormalizedPlayerTag,
              expected.sourceTimestamp == actual.sourceTimestamp,
              expected.lineageComparable == actual.lineageComparable else {
            return false
        }
        // Non-duplicate entries receive fresh snapshot/lineage UUIDs during
        // each pure plan; fingerprint + normalized tag are the stable key.
        // Duplicate revisions instead include the existing snapshot ID and
        // duplicate count, so compare the full revision in that case.
        return !expected.duplicate || expected.newReference.revision == actual.newReference.revision
    }

    private static func timeConfidence(
        previous: Date?,
        new: Date?
    ) -> ManualReconciliationTimeConfidence {
        guard let new else { return .sourceTimestampAbsent }
        guard new.timeIntervalSinceReferenceDate.isFinite else { return .sourceTimestampConflict }
        guard let previous else { return .localAppliedAtOnly }
        guard previous.timeIntervalSinceReferenceDate.isFinite, new >= previous else {
            return .sourceTimestampConflict
        }
        return .reliableSourceTimestamp
    }

    private static func sourceTimestamp(
        for decision: SnapshotHistoryImportDecision
    ) -> Date? {
        guard decision.duplicate else { return decision.entry.sourceTimestamp }
        return decision.envelope.duplicateMetadata[decision.entry.snapshotID.uuidString]?
            .lastSourceTimestamp
    }

    private static func confirmedRecords(
        _ records: [ManualUpgradeRecord],
        previous: ManualLevelDistribution?,
        observed: ManualLevelDistribution?,
        sourceTimestamp: Date?,
        requireExpectedEnd: Bool
    ) -> [UUID] {
        guard let previous, let observed else { return [] }
        let levels = Set(previous.levels.map(\.level)).union(observed.levels.map(\.level))
        var remainingDecrease = Dictionary(uniqueKeysWithValues: levels.map { level in
            (level, max(previous.quantity(at: level) - observed.quantity(at: level), 0))
        })
        var remainingIncrease = Dictionary(uniqueKeysWithValues: levels.map { level in
            (level, max(observed.quantity(at: level) - previous.quantity(at: level), 0))
        })
        let ordered = records.sorted {
            if $0.expectedEndAt != $1.expectedEndAt { return $0.expectedEndAt < $1.expectedEndAt }
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.recordID.uuidString < $1.recordID.uuidString
        }
        var confirmed: [UUID] = []
        for record in ordered {
            guard record.status == .active,
                  (remainingIncrease[record.targetLevel] ?? 0) >= record.quantity,
                  (remainingDecrease[record.fromLevel] ?? 0) >= record.quantity else {
                continue
            }
            if requireExpectedEnd {
                guard let sourceTimestamp, sourceTimestamp >= record.expectedEndAt else { continue }
            }
            remainingIncrease[record.targetLevel, default: 0] -= record.quantity
            remainingDecrease[record.fromLevel, default: 0] -= record.quantity
            confirmed.append(record.recordID)
        }
        return confirmed
    }

    private static func dominates(
        _ lhs: ManualLevelDistribution,
        _ rhs: ManualLevelDistribution
    ) -> Bool {
        guard lhs.totalQuantity == rhs.totalQuantity else { return false }
        let levels = Set(lhs.levels.map(\.level)).union(rhs.levels.map(\.level))
        return levels.allSatisfy { threshold in
            lhs.levels.filter { $0.level >= threshold }.reduce(0) { $0 + $1.quantity }
                >= rhs.levels.filter { $0.level >= threshold }.reduce(0) { $0 + $1.quantity }
        }
    }

    private static func hasLocalState(
        state: ManualItemState?,
        records: [ManualUpgradeRecord]
    ) -> Bool {
        state?.status == .manualCompleted || !records.isEmpty
    }

    private static func effectiveDistribution(
        _ state: ManualItemState?
    ) -> ManualLevelDistribution? {
        guard let state else { return nil }
        switch state.status {
        case .observed:
            return state.importedObservation?.levelDistribution
        case .manualCompleted:
            return state.manualCompletedDistribution
        case .unknown, .conflict:
            return nil
        }
    }

    private static func message(
        for classification: ManualReconciliationClassification
    ) -> String {
        switch classification {
        case .duplicate:
            "canonical fingerprint 未变化；不会重新开始或重复结算手动记录。"
        case .newObservation:
            "当前没有需要保护的本地手动状态，可以安全建立新的观察基线。"
        case .exactMatch:
            "导入观察与本地有效完成状态一致。"
        case .observedAhead:
            "导入观察明确达到或超过本地完成状态。"
        case .manualAhead:
            "本地手动状态领先于导入观察，默认不会回滚。"
        case .staleImport:
            "来源时间早于当前历史基线，默认保留本地状态。"
        case .observedTimerEnded:
            "只观察到 timer 消失，不能据此声称完成、取消或失败。"
        case .possibleDuplicate:
            "导入 timer 缺少 target/start/queue identity，不能与本地 active 自动合并。"
        case .unknown:
            "等级、数量或字段覆盖不足，缺失不能解释为删除、归零或完成。"
        case .conflict:
            "导入观察与本地状态无法形成单调升级关系。"
        case .lineageMismatch:
            "不同 village/lineage 禁止自动匹配；必须显式接受导入观察。"
        }
    }

    private static func observations(
        in entry: SnapshotHistoryEntry
    ) throws -> [TrackerItemKey: Observation] {
        let grouped = Dictionary(grouping: entry.observation.items.compactMap { item in
            trackerKey(for: item.identity).map { ($0, item) }
        }, by: { $0.0 })
        var result: [TrackerItemKey: Observation] = [:]
        for (key, values) in grouped {
            let items = values.map(\.1)
            let histogram = isHistogram(key)
            let base = snapshotBase(key.base)
            let requiredFields = ["presence", "data"]
            let coverageComplete = requiredFields.allSatisfy {
                entry.coverage.state(
                    base: base,
                    rawSection: key.rawSection,
                    field: $0
                ) == .complete
            }
            // Coverage is recorded for a whole source section, while the
            // reconciliation map is keyed by one dataID.  A partial lvl/cnt
            // or timer field therefore invalidates every key in that section;
            // allowing a complete-looking key to pass would turn a sibling's
            // missing field into a false observedAhead/manual completion.
            let sectionSafetyCoverageComplete = [
                "lvl", "cnt", "timer", "helper_timer", "helper_cooldown"
            ].allSatisfy { field in
                guard let state = entry.coverage.state(
                    base: base,
                    rawSection: key.rawSection,
                    field: field
                ) else { return false }
                return state != .partial
            }
            var quantities: [Int: Int64] = [:]
            var levelCoverageComplete = true
            var countCoverageComplete = true
            var valid = coverageComplete && sectionSafetyCoverageComplete && !items.isEmpty
            let countCoverageState = entry.coverage.state(
                base: base,
                rawSection: key.rawSection,
                field: "cnt"
            )
            let timerCoverageComplete = ["timer", "helper_timer", "helper_cooldown"].allSatisfy { field in
                guard let state = entry.coverage.state(
                    base: base,
                    rawSection: key.rawSection,
                    field: field
                ) else { return false }
                return state == .complete || state == .unavailable
            }
            for item in items {
                guard let level = item.level, level >= 0 else {
                    levelCoverageComplete = false
                    valid = false
                    continue
                }
                let quantity: Int64
                if histogram {
                    if item.count == nil, !item.rawTimerEvidence.isEmpty {
                        continue
                    }
                    guard let count = item.count, count > 0 else {
                        countCoverageComplete = false
                        valid = false
                        continue
                    }
                    quantity = Int64(count)
                } else {
                    if item.count == nil, countCoverageState == .partial {
                        countCoverageComplete = false
                        valid = false
                        continue
                    }
                    if let count = item.count, count <= 0 {
                        countCoverageComplete = false
                        valid = false
                        continue
                    }
                    quantity = Int64(max(item.count ?? 1, 1))
                }
                let (sum, overflow) = (quantities[level] ?? 0).addingReportingOverflow(quantity)
                guard !overflow else {
                    throw ManualReconciliationError.invalidObservation("项目数量溢出。")
                }
                quantities[level] = sum
            }
            if quantities.isEmpty {
                valid = false
            }
            if histogram, countCoverageState != .complete {
                // Timer-only histogram rows may explain why `cnt` is partial,
                // but the section-level partial state still makes all sibling
                // observations non-authoritative for automatic reconciliation.
                countCoverageComplete = false
            }
            valid = valid && timerCoverageComplete
            valid = valid && levelCoverageComplete && countCoverageComplete
            let distribution = valid ? try ManualLevelDistribution(levelQuantities: quantities) : nil
            result[key] = Observation(
                distribution: distribution,
                displayName: items.compactMap(\.display.displayName).first ?? key.stableID,
                hasTimer: items.contains { !$0.rawTimerEvidence.isEmpty },
                coverageComplete: valid,
                timerCoverageComplete: timerCoverageComplete
            )
        }
        return result
    }

    private static func trackerKey(
        for identity: SnapshotItemIdentity
    ) -> TrackerItemKey? {
        guard let base = trackerBase(identity.base),
              !identity.rawSection.isEmpty,
              identity.dataID > 0 else { return nil }
        switch identity.nestedKind {
        case .root:
            return .root(base: base, rawSection: identity.rawSection, dataID: identity.dataID)
        case .type, .module:
            guard let rootDataID = identity.nestedRootDataID, rootDataID > 0 else { return nil }
            let parent = identity.nestedParentPath.dropFirst().compactMap { component -> TrackerNestedPathComponent? in
                guard let kind = trackerNestedKind(component.kind), component.dataID > 0 else { return nil }
                return TrackerNestedPathComponent(kind: kind, dataID: component.dataID)
            }
            guard parent.count == max(identity.nestedParentPath.count - 1, 0),
                  let currentKind = trackerNestedKind(identity.nestedKind) else { return nil }
            return .nested(
                base: base,
                rawSection: identity.rawSection,
                dataID: identity.dataID,
                root: TrackerRootIdentity(
                    base: base,
                    rawSection: identity.rawSection,
                    dataID: rootDataID
                ),
                path: parent + [
                    TrackerNestedPathComponent(kind: currentKind, dataID: identity.dataID)
                ]
            )
        case .unknown:
            return nil
        }
    }

    private static func isHistogram(_ key: TrackerItemKey) -> Bool {
        key.nestedKind == .root
            && ["buildings", "buildings2", "traps", "traps2"].contains(key.rawSection)
    }

    private static func trackerBase(_ base: SnapshotHistoryBase) -> TrackerBase? {
        switch base {
        case .home: .home
        case .builder: .builder
        case .unknown: nil
        }
    }

    private static func snapshotBase(_ base: TrackerBase) -> SnapshotHistoryBase {
        switch base {
        case .home: .home
        case .builder: .builder
        }
    }

    private static func trackerNestedKind(_ kind: SnapshotNestedKind) -> TrackerNestedKind? {
        switch kind {
        case .root: .root
        case .type: .type
        case .module: .module
        case .unknown: nil
        }
    }
}
