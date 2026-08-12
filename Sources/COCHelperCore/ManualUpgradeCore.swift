import Foundation

/// Pure local state machine for manually tracked upgrades.
///
/// This type deliberately has no UI, persistence, UserDefaults, queue
/// capacity, or re-import reconciliation responsibilities. A caller supplies
/// the already-resolved catalog duration/cost/provenance and owns persistence.
public struct ManualUpgradeCore: Codable, Hashable, Sendable {
    public private(set) var itemStates: [ManualItemState]
    public private(set) var records: [ManualUpgradeRecord]

    public init(
        itemStates: [ManualItemState] = [],
        records: [ManualUpgradeRecord] = []
    ) throws {
        let sortedStates = itemStates.sorted { $0.itemKey.stableID < $1.itemKey.stableID }
        for state in sortedStates {
            guard state.isStructurallyValid else {
                throw ManualUpgradeError.invalidRecord
            }
        }
        if sortedStates.count > 1 {
            for index in 1..<sortedStates.count {
                guard sortedStates[index - 1].itemKey != sortedStates[index].itemKey else {
                    throw ManualUpgradeError.invalidRecord
                }
            }
        }

        let sortedRecords = records.sorted { $0.recordID.uuidString < $1.recordID.uuidString }
        var recordIDs = Set<UUID>()
        for record in sortedRecords {
            guard recordIDs.insert(record.recordID).inserted else {
                throw ManualUpgradeError.duplicateRecordID(record.recordID)
            }
            guard let state = sortedStates.first(where: { $0.itemKey == record.itemKey }) else {
                throw ManualUpgradeError.missingItemState(record.itemKey)
            }
            guard state.baselineReference == record.baselineReference else {
                throw ManualUpgradeError.baselineMismatch(record.itemKey)
            }
            if record.status == .active, state.status != .manualCompleted {
                throw ManualUpgradeError.unavailableItemState(record.itemKey)
            }
        }

        self.itemStates = sortedStates
        self.records = sortedRecords
    }

    private enum CodingKeys: String, CodingKey {
        case itemStates
        case records
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            itemStates: container.decode([ManualItemState].self, forKey: .itemStates),
            records: container.decode([ManualUpgradeRecord].self, forKey: .records)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemStates, forKey: .itemStates)
        try container.encode(records, forKey: .records)
    }

    public var activeRecords: [ManualUpgradeRecord] {
        records
            .filter { $0.status == .active }
            .sorted(by: Self.recordOrder)
    }

    public var completedHistory: [ManualUpgradeRecord] {
        records
            .filter { $0.status == .completed }
            .sorted(by: Self.recordOrder)
    }

    public var cancelledHistory: [ManualUpgradeRecord] {
        records
            .filter { $0.status == .cancelled }
            .sorted(by: Self.recordOrder)
    }

    public func itemState(for itemKey: TrackerItemKey) -> ManualItemState? {
        itemStates.first { $0.itemKey == itemKey }
    }

    /// Starts one local upgrade. The source quantity is reserved immediately
    /// by subtracting it from the current completed distribution; the target
    /// is exposed separately until settlement.
    @discardableResult
    public mutating func startUpgrade(
        itemKey: TrackerItemKey,
        fromLevel: Int,
        targetLevel: Int,
        quantity: Int64,
        startedAt: Date,
        durationState: CatalogDurationState?,
        frozenCosts: [CatalogUpgradeCost]?,
        catalogProvenance: ManualCatalogProvenance,
        baselineReference: ManualBaselineReference,
        queueKind: String? = nil,
        recordID: UUID = UUID(),
        now: Date
    ) throws -> ManualUpgradeRecord {
        var candidate = self
        let result = try candidate.startUpgradeImpl(
            itemKey: itemKey,
            fromLevel: fromLevel,
            targetLevel: targetLevel,
            quantity: quantity,
            startedAt: startedAt,
            durationState: durationState,
            frozenCosts: frozenCosts,
            catalogProvenance: catalogProvenance,
            baselineReference: baselineReference,
            queueKind: queueKind,
            recordID: recordID,
            now: now
        )
        self = candidate
        return result
    }

    /// Cancels an active record and restores its source quantity.
    @discardableResult
    public mutating func cancelUpgrade(recordID: UUID) throws -> ManualUpgradeRecord {
        var candidate = self
        let result = try candidate.cancelUpgradeImpl(recordID: recordID)
        self = candidate
        return result
    }

    /// Recomputes an active record's absolute end time from its frozen
    /// duration. A due record is settled through the same settlement path.
    @discardableResult
    public mutating func adjustStartTime(
        recordID: UUID,
        startedAt: Date,
        now: Date
    ) throws -> ManualUpgradeRecord {
        var candidate = self
        let result = try candidate.adjustStartTimeImpl(
            recordID: recordID,
            startedAt: startedAt,
            now: now
        )
        self = candidate
        return result
    }

    /// Settles every active record due at `at`, ordered by absolute end time
    /// and then record ID. Repeating the call is idempotent because completed
    /// records are no longer eligible.
    @discardableResult
    public mutating func settleDue(at: Date) throws -> [ManualUpgradeRecord] {
        var candidate = self
        let settled = try candidate.settleDueImpl(at: at)
        self = candidate
        return settled
    }

    /// Returns separate imported, manually maintained, active-target, and
    /// effective-completed views. An active target never enters the completed
    /// distribution.
    public func effectiveState(for itemKey: TrackerItemKey) -> ManualEffectiveItemState? {
        guard let state = itemState(for: itemKey) else { return nil }
        guard let activeTarget = try? activeTargetDistribution(for: itemKey) else {
            return nil
        }

        let imported = state.importedObservation?.levelDistribution
        let effectiveCompleted: ManualLevelDistribution?
        switch state.status {
        case .observed:
            effectiveCompleted = imported
        case .manualCompleted:
            effectiveCompleted = state.manualCompletedDistribution
        case .unknown, .conflict:
            effectiveCompleted = nil
        }

        return ManualEffectiveItemState(
            itemKey: state.itemKey,
            baselineReference: state.baselineReference,
            importedDistribution: imported,
            manualCompletedDistribution: state.manualCompletedDistribution,
            activeTargetDistribution: activeTarget,
            effectiveCompletedDistribution: effectiveCompleted,
            status: state.status
        )
    }

    private static func recordOrder(
        _ lhs: ManualUpgradeRecord,
        _ rhs: ManualUpgradeRecord
    ) -> Bool {
        if lhs.expectedEndAt != rhs.expectedEndAt {
            return lhs.expectedEndAt < rhs.expectedEndAt
        }
        return lhs.recordID.uuidString < rhs.recordID.uuidString
    }

    private mutating func startUpgradeImpl(
        itemKey: TrackerItemKey,
        fromLevel: Int,
        targetLevel: Int,
        quantity: Int64,
        startedAt: Date,
        durationState: CatalogDurationState?,
        frozenCosts: [CatalogUpgradeCost]?,
        catalogProvenance: ManualCatalogProvenance,
        baselineReference: ManualBaselineReference,
        queueKind: String?,
        recordID: UUID,
        now: Date
    ) throws -> ManualUpgradeRecord {
        _ = try settleDueImpl(at: now)

        guard !records.contains(where: { $0.recordID == recordID }) else {
            throw ManualUpgradeError.duplicateRecordID(recordID)
        }
        guard let stateIndex = itemStates.firstIndex(where: { $0.itemKey == itemKey }) else {
            throw ManualUpgradeError.missingItemState(itemKey)
        }
        let state = itemStates[stateIndex]
        guard state.baselineReference == baselineReference else {
            throw ManualUpgradeError.baselineMismatch(itemKey)
        }
        guard state.status != .unknown else {
            throw ManualUpgradeError.unavailableItemState(itemKey)
        }
        guard state.status != .conflict else {
            throw ManualUpgradeError.conflictingItemState(itemKey)
        }
        guard startedAt <= now else { throw ManualUpgradeError.futureStart }

        let source = try startableDistribution(for: state)
        let updatedSource = try source.subtracting(level: fromLevel, quantity: quantity)
        itemStates[stateIndex].manualCompletedDistribution = updatedSource
        itemStates[stateIndex].status = .manualCompleted

        let timing = try resolveTiming(durationState, startedAt: startedAt)
        let record = try ManualUpgradeRecord(
            recordID: recordID,
            itemKey: itemKey,
            fromLevel: fromLevel,
            targetLevel: targetLevel,
            quantity: quantity,
            startedAt: startedAt,
            expectedEndAt: timing.expectedEndAt,
            durationSeconds: timing.durationSeconds,
            durationKind: timing.kind,
            frozenCosts: frozenCosts,
            catalogProvenance: catalogProvenance,
            baselineReference: baselineReference,
            queueKind: queueKind,
            status: .active
        )
        records.append(record)
        records.sort { $0.recordID.uuidString < $1.recordID.uuidString }

        _ = try settleDueImpl(at: now)
        return try recordForRecordID(recordID)
    }

    private mutating func cancelUpgradeImpl(recordID: UUID) throws -> ManualUpgradeRecord {
        guard let recordIndex = records.firstIndex(where: { $0.recordID == recordID }) else {
            throw ManualUpgradeError.recordNotFound(recordID)
        }
        let record = records[recordIndex]
        guard record.status == .active else {
            if record.status == .completed {
                throw ManualUpgradeError.cannotCancelCompleted(recordID)
            }
            throw ManualUpgradeError.recordNotActive(recordID)
        }
        guard let stateIndex = itemStates.firstIndex(where: { $0.itemKey == record.itemKey }) else {
            throw ManualUpgradeError.missingItemState(record.itemKey)
        }
        let updated = try completedDistributionForMutation(itemStates[stateIndex])
            .adding(level: record.fromLevel, quantity: record.quantity)
        itemStates[stateIndex].manualCompletedDistribution = updated
        itemStates[stateIndex].status = .manualCompleted
        records[recordIndex].status = .cancelled
        return records[recordIndex]
    }

    private mutating func adjustStartTimeImpl(
        recordID: UUID,
        startedAt: Date,
        now: Date
    ) throws -> ManualUpgradeRecord {
        guard let recordIndex = records.firstIndex(where: { $0.recordID == recordID }) else {
            throw ManualUpgradeError.recordNotFound(recordID)
        }
        let oldRecord = records[recordIndex]
        guard oldRecord.status == .active else {
            throw ManualUpgradeError.recordNotActive(recordID)
        }
        guard startedAt <= now else { throw ManualUpgradeError.futureStart }

        let durationState: CatalogDurationState = oldRecord.durationKind == .instant
            ? .instant
            : .timed(seconds: oldRecord.durationSeconds)
        let timing = try resolveTiming(durationState, startedAt: startedAt)
        records[recordIndex] = try ManualUpgradeRecord(
            recordID: oldRecord.recordID,
            itemKey: oldRecord.itemKey,
            fromLevel: oldRecord.fromLevel,
            targetLevel: oldRecord.targetLevel,
            quantity: oldRecord.quantity,
            startedAt: startedAt,
            expectedEndAt: timing.expectedEndAt,
            durationSeconds: timing.durationSeconds,
            durationKind: timing.kind,
            frozenCosts: oldRecord.frozenCosts,
            catalogProvenance: oldRecord.catalogProvenance,
            baselineReference: oldRecord.baselineReference,
            queueKind: oldRecord.queueKind,
            status: .active
        )

        _ = try settleDueImpl(at: now)
        return try recordForRecordID(recordID)
    }

    private mutating func settleDueImpl(at: Date) throws -> [ManualUpgradeRecord] {
        let due = activeRecords
            .filter { $0.expectedEndAt <= at }
            .sorted(by: Self.recordOrder)
        var settled: [ManualUpgradeRecord] = []
        settled.reserveCapacity(due.count)

        for dueRecord in due {
            guard let recordIndex = records.firstIndex(where: {
                $0.recordID == dueRecord.recordID && $0.status == .active
            }) else {
                continue
            }
            guard let stateIndex = itemStates.firstIndex(where: {
                $0.itemKey == dueRecord.itemKey
            }) else {
                throw ManualUpgradeError.missingItemState(dueRecord.itemKey)
            }
            let updated = try completedDistributionForMutation(itemStates[stateIndex])
                .adding(level: dueRecord.targetLevel, quantity: dueRecord.quantity)
            itemStates[stateIndex].manualCompletedDistribution = updated
            itemStates[stateIndex].status = .manualCompleted
            records[recordIndex].status = .completed
            settled.append(records[recordIndex])
        }

        return settled
    }

    private func recordForRecordID(_ recordID: UUID) throws -> ManualUpgradeRecord {
        guard let record = records.first(where: { $0.recordID == recordID }) else {
            throw ManualUpgradeError.recordNotFound(recordID)
        }
        return record
    }

    private func startableDistribution(
        for state: ManualItemState
    ) throws -> ManualLevelDistribution {
        switch state.status {
        case .observed:
            guard let imported = state.importedObservation?.levelDistribution else {
                throw ManualUpgradeError.unavailableItemState(state.itemKey)
            }
            return imported
        case .manualCompleted:
            return state.manualCompletedDistribution
        case .unknown:
            throw ManualUpgradeError.unavailableItemState(state.itemKey)
        case .conflict:
            throw ManualUpgradeError.conflictingItemState(state.itemKey)
        }
    }

    private func completedDistributionForMutation(
        _ state: ManualItemState
    ) throws -> ManualLevelDistribution {
        switch state.status {
        case .observed:
            guard let imported = state.importedObservation?.levelDistribution else {
                throw ManualUpgradeError.unavailableItemState(state.itemKey)
            }
            return imported
        case .manualCompleted:
            return state.manualCompletedDistribution
        case .unknown:
            throw ManualUpgradeError.unavailableItemState(state.itemKey)
        case .conflict:
            throw ManualUpgradeError.conflictingItemState(state.itemKey)
        }
    }

    private func activeTargetDistribution(
        for itemKey: TrackerItemKey
    ) throws -> ManualLevelDistribution {
        var distribution = ManualLevelDistribution.empty
        for record in records where record.status == .active && record.itemKey == itemKey {
            distribution = try distribution.adding(
                level: record.targetLevel,
                quantity: record.quantity
            )
        }
        return distribution
    }

    private struct ResolvedTiming {
        let kind: ManualUpgradeDurationKind
        let durationSeconds: Int64
        let expectedEndAt: Date
    }

    private func resolveTiming(
        _ state: CatalogDurationState?,
        startedAt: Date
    ) throws -> ResolvedTiming {
        guard let state else {
            throw ManualUpgradeError.durationUnavailable(.unknownReason("missing_duration_state"))
        }
        switch state {
        case .timed(let seconds):
            guard seconds > 0 else { throw ManualUpgradeError.invalidDuration }
            let timeInterval = Double(seconds)
            guard timeInterval.isFinite else { throw ManualUpgradeError.arithmeticOverflow }
            let end = startedAt.addingTimeInterval(timeInterval)
            guard end >= startedAt else { throw ManualUpgradeError.arithmeticOverflow }
            return ResolvedTiming(
                kind: .timed,
                durationSeconds: seconds,
                expectedEndAt: end
            )
        case .instant:
            return ResolvedTiming(kind: .instant, durationSeconds: 0, expectedEndAt: startedAt)
        case .initialLevel, .notApplicable, .sourceMissing, .parseFailed, .unknownReason:
            throw ManualUpgradeError.durationUnavailable(state)
        }
    }
}
