import CryptoKit
import Foundation

/// Pure local state machine for manually tracked upgrades.
///
/// This type deliberately has no UI, persistence, UserDefaults, queue
/// capacity, or re-import reconciliation responsibilities. A caller supplies
/// the already-resolved catalog duration/cost/provenance and owns persistence.
public struct ManualUpgradeCore: Codable, Hashable, Sendable {
    public private(set) var itemStates: [ManualItemState]
    public private(set) var records: [ManualUpgradeRecord]

    /// Issue #210：内容身份指纹（SHA-256 over canonical JSON，`sha256:` 前缀）。
    ///
    /// init 与每次 mutating 操作（start/cancel/adjust/settle）后重算：
    /// manual 状态变化必然得到新指纹，使村庄投影缓存 miss 重建
    /// （issue #210 失效边界）。tick 之间的只读访问直接读存储值，
    /// 不重算、不遍历 payload（records 随历史持续增长）。
    /// 编码时跳过（不进入持久化 JSON）；解码后按内容重算，旧数据无需迁移。
    /// `==`/`hash(into:)` 手写排除指纹字段：指纹是内容的确定性函数，
    /// 比较语义不变。
    public private(set) var contentFingerprint: String

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
        for state in sortedStates {
            let stateRecords = sortedRecords.filter { $0.itemKey == state.itemKey }
            try Self.validateConservation(for: state, records: stateRecords)
        }

        self.itemStates = sortedStates
        self.records = sortedRecords
        self.contentFingerprint = Self.fingerprint(
            itemStates: sortedStates, records: sortedRecords
        )
    }

    /// Issue #210：内容相等（排除指纹字段；指纹是内容的确定性函数）。
    public static func == (lhs: ManualUpgradeCore, rhs: ManualUpgradeCore) -> Bool {
        lhs.itemStates == rhs.itemStates && lhs.records == rhs.records
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(itemStates)
        hasher.combine(records)
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

    /// The single baseline carried by a valid per-village tracker state.
    ///
    /// `ManualTrackerVillageState` enforces this invariant at the storage
    /// boundary.  Keeping the derived value here lets projection callers gate
    /// a loaded core before joining it to a newer snapshot lineage.
    public var baselineReference: ManualBaselineReference? {
        let references = Set(
            itemStates.map(\.baselineReference) + records.map(\.baselineReference)
        )
        return references.count == 1 ? references.first : nil
    }

    /// Returns a projection-only copy for a snapshot that has not been
    /// reconciled with this core yet.
    ///
    /// The persisted core is deliberately left untouched: its original bytes
    /// remain available for a future reconcile.  The copy drops imported
    /// observations, completed distributions, and active records so callers
    /// can expose `unknown` without accidentally showing stale progress or
    /// making an old active record actionable.
    public func gatedForUnreconciledSnapshot() -> Self {
        let states = itemStates.map { state in
            try! ManualItemState(
                itemKey: state.itemKey,
                baselineReference: state.baselineReference,
                status: .unknown
            )
        }
        return try! Self(itemStates: states)
    }

    public func itemState(for itemKey: TrackerItemKey) -> ManualItemState? {
        itemStates.first { $0.itemKey == itemKey }
    }

    /// Starts one local upgrade. The source quantity is reserved by the active
    /// record; the materialized completed distribution is transferred only at
    /// settlement, while the effective view excludes active reservations.
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
        refreshContentFingerprint()
        return result
    }

    /// Cancels an active record and releases its source reservation.
    @discardableResult
    public mutating func cancelUpgrade(recordID: UUID) throws -> ManualUpgradeRecord {
        var candidate = self
        let result = try candidate.cancelUpgradeImpl(recordID: recordID)
        self = candidate
        refreshContentFingerprint()
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
        refreshContentFingerprint()
        return result
    }

    /// Settles every active record due at `at`, ordered by absolute end time
    /// and then record ID. Repeating the call is idempotent because completed
    /// records are no longer eligible.
    @discardableResult
    public mutating func settleDue(at: Date) throws -> [ManualUpgradeRecord] {
        var candidate = self
        let settled = try candidate.settleDueImpl(at: at)
        // Issue #220：empty settled means candidate is semantically unchanged.
        guard !settled.isEmpty else { return [] }
        self = candidate
        refreshContentFingerprint()
        return settled
    }

    /// Issue #220：仅供测试观察 `refreshContentFingerprint()` 调用次数；
    /// 不参与 Codable / Equatable / Hashable。
    nonisolated(unsafe) internal private(set) static var fingerprintComputationCountForTesting = 0

    internal static func resetFingerprintComputationCountForTesting() {
        fingerprintComputationCountForTesting = 0
    }

    /// Issue #210：mutating 操作后重算内容指纹（缓存 key 依赖它识别
    /// manual 状态变化；tick 只读路径不重算）。
    private mutating func refreshContentFingerprint() {
        Self.fingerprintComputationCountForTesting += 1
        contentFingerprint = Self.fingerprint(itemStates: itemStates, records: records)
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
            effectiveCompleted = try? availableDistribution(for: state)
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

    /// Validates the persisted balance before accepting a Core instance.
    /// `manualCompletedDistribution` is the materialized distribution before
    /// active reservations. Completed records transfer source to target;
    /// active records reserve source only; cancelled records have no net
    /// effect. When an imported distribution is known, replaying that ledger
    /// must reproduce the materialized state exactly.
    private static func validateConservation(
        for state: ManualItemState,
        records: [ManualUpgradeRecord]
    ) throws {
        guard !records.isEmpty else { return }
        guard state.status == .manualCompleted else {
            throw ManualUpgradeError.invalidRecord
        }

        let completed = records
            .filter { $0.status == .completed }
            .sorted(by: Self.recordOrder)
        let active = records
            .filter { $0.status == .active }
            .sorted(by: Self.recordOrder)

        if let imported = state.importedObservation?.levelDistribution {
            var expected = imported
            for record in completed {
                expected = try expected.subtracting(
                    level: record.fromLevel,
                    quantity: record.quantity
                )
                expected = try expected.adding(
                    level: record.targetLevel,
                    quantity: record.quantity
                )
            }
            guard expected == state.manualCompletedDistribution else {
                throw ManualUpgradeError.invalidRecord
            }
            try validateActiveReservations(active, against: expected)
        } else {
            try validateActiveReservations(active, against: state.manualCompletedDistribution)
        }
    }

    private static func validateActiveReservations(
        _ records: [ManualUpgradeRecord],
        against distribution: ManualLevelDistribution
    ) throws {
        var available = distribution
        for record in records {
            available = try available.subtracting(
                level: record.fromLevel,
                quantity: record.quantity
            )
        }
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
        let available = try availableDistribution(for: state)
        _ = try available.subtracting(level: fromLevel, quantity: quantity)
        itemStates[stateIndex].manualCompletedDistribution = source
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
        _ = try completedDistributionForMutation(itemStates[stateIndex])
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
                .subtracting(level: dueRecord.fromLevel, quantity: dueRecord.quantity)
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

    private func availableDistribution(
        for state: ManualItemState
    ) throws -> ManualLevelDistribution {
        var available = try completedDistributionForMutation(state)
        for record in records where record.status == .active && record.itemKey == state.itemKey {
            available = try available.subtracting(
                level: record.fromLevel,
                quantity: record.quantity
            )
        }
        return available
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

    // MARK: - Issue #210 内容指纹

    /// 确定性内容摘要：`JSONEncoder + .sortedKeys` 的 canonical JSON →
    /// SHA-256（与 `SnapshotHistoryCanonicalizer.integrityFingerprint` 同机制）。
    /// 不依赖 Swift 合成 Hashable（每次进程随机种子，跨启动不稳定）。
    private static func fingerprint(
        itemStates: [ManualItemState],
        records: [ManualUpgradeRecord]
    ) -> String {
        let material = ManualCoreFingerprintMaterial(itemStates: itemStates, records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(material)
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 内容指纹的 canonical 镜像（与存储字段一致；init 已排序，输出确定）。
private struct ManualCoreFingerprintMaterial: Encodable {
    let itemStates: [ManualItemState]
    let records: [ManualUpgradeRecord]
}
