import Foundation

// MARK: - Stable item identity

/// The semantic kind of a snapshot item in a nested `types`/`modules` tree.
///
/// `AccountItem.id` remains an import-trace path and is intentionally not used
/// here because it contains array indexes. This key is the reusable identity
/// for local tracker state; village identity is owned by the enclosing store.
public enum TrackerNestedKind: String, Codable, Hashable, Sendable {
    case root
    case type
    case module
}

/// A stable identity for the root item that owns a nested item.
public struct TrackerRootIdentity: Codable, Hashable, Sendable {
    public let base: TrackerBase
    public let rawSection: String
    public let dataID: Int64

    public init(base: TrackerBase, rawSection: String, dataID: Int64) {
        self.base = base
        self.rawSection = rawSection
        self.dataID = dataID
    }

    public var isStructurallyValid: Bool {
        !rawSection.isEmpty && dataID > 0
    }
}

/// One semantic component of a nested path. It contains data IDs, never array
/// positions, display names, or localized labels.
public struct TrackerNestedPathComponent: Codable, Hashable, Sendable {
    public let kind: TrackerNestedKind
    public let dataID: Int64

    public init(kind: TrackerNestedKind, dataID: Int64) {
        self.kind = kind
        self.dataID = dataID
    }

    public var isStructurallyValid: Bool {
        kind != .root && dataID > 0
    }
}

/// Codable identity used by manual upgrade records.
///
/// For a root item, `nestedKind == .root`, `nestedRootIdentity == nil`, and
/// `nestedPath` is empty. For a nested item, the root identity and the full
/// semantic path are retained. Duplicate buildings/walls intentionally share
/// one key and are represented by a level distribution instead of an array
/// index.
public struct TrackerItemKey: Codable, Hashable, Sendable {
    public let base: TrackerBase
    public let rawSection: String
    public let dataID: Int64
    public let nestedKind: TrackerNestedKind
    public let nestedRootIdentity: TrackerRootIdentity?
    public let nestedPath: [TrackerNestedPathComponent]

    public init(
        base: TrackerBase,
        rawSection: String,
        dataID: Int64,
        nestedKind: TrackerNestedKind = .root,
        nestedRootIdentity: TrackerRootIdentity? = nil,
        nestedPath: [TrackerNestedPathComponent] = []
    ) {
        self.base = base
        self.rawSection = rawSection
        self.dataID = dataID
        self.nestedKind = nestedKind
        self.nestedRootIdentity = nestedRootIdentity
        self.nestedPath = nestedPath
    }

    public static func root(base: TrackerBase, rawSection: String, dataID: Int64) -> Self {
        Self(base: base, rawSection: rawSection, dataID: dataID)
    }

    public static func nested(
        base: TrackerBase,
        rawSection: String,
        dataID: Int64,
        root: TrackerRootIdentity,
        path: [TrackerNestedPathComponent]
    ) -> Self {
        Self(
            base: base,
            rawSection: rawSection,
            dataID: dataID,
            nestedKind: path.last?.kind ?? .root,
            nestedRootIdentity: root,
            nestedPath: path
        )
    }

    /// A deterministic printable key for sorting and diagnostics. Equality is
    /// still structural; this string is not used as the persisted identity.
    public var stableID: String {
        let root = nestedRootIdentity.map {
            $0.base.rawValue + ":" + $0.rawSection + ":" + String($0.dataID)
        } ?? "-"
        let path = nestedPath.map { $0.kind.rawValue + ":" + String($0.dataID) }
            .joined(separator: "/")
        return [base.rawValue, rawSection, String(dataID), nestedKind.rawValue, root, path]
            .joined(separator: "|")
    }

    public var isStructurallyValid: Bool {
        guard !rawSection.isEmpty, dataID > 0 else { return false }

        switch nestedKind {
        case .root:
            return nestedRootIdentity == nil && nestedPath.isEmpty
        case .type, .module:
            guard let root = nestedRootIdentity,
                  root.isStructurallyValid,
                  root.base == base,
                  root.rawSection == rawSection,
                  !nestedPath.isEmpty,
                  nestedPath.allSatisfy(\.isStructurallyValid),
                  nestedPath.last?.kind == nestedKind,
                  nestedPath.last?.dataID == dataID else {
                return false
            }
            return true
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            base: try container.decode(TrackerBase.self, forKey: .base),
            rawSection: try container.decode(String.self, forKey: .rawSection),
            dataID: try container.decode(Int64.self, forKey: .dataID),
            nestedKind: try container.decode(TrackerNestedKind.self, forKey: .nestedKind),
            nestedRootIdentity: try container.decodeIfPresent(
                TrackerRootIdentity.self, forKey: .nestedRootIdentity),
            nestedPath: try container.decodeIfPresent(
                [TrackerNestedPathComponent].self, forKey: .nestedPath) ?? []
        )
        guard isStructurallyValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .dataID,
                in: container,
                debugDescription: "invalid TrackerItemKey"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case base
        case rawSection
        case dataID
        case nestedKind
        case nestedRootIdentity
        case nestedPath
    }
}

/// Converts the existing imported tree into stable semantic keys without
/// changing `AccountItem.id` or the snapshot representation.
public enum TrackerItemKeyAdapter {
    public static func keys(in snapshot: AccountSnapshot, base: TrackerBase) -> [TrackerItemKey] {
        Array(keyMap(in: snapshot, base: base).values)
            .sorted { $0.stableID < $1.stableID }
    }

    /// Maps import-trace ids to the same semantic keys returned by `keys(in:base:)`.
    ///
    /// The import id is used only as an in-memory join handle for the current
    /// snapshot. It is not persisted and is never used as the tracker identity.
    public static func keyMap(
        in snapshot: AccountSnapshot,
        base: TrackerBase
    ) -> [String: TrackerItemKey] {
        var result: [String: TrackerItemKey] = [:]

        func visit(
            _ item: AccountItem,
            section: String,
            root: TrackerRootIdentity?,
            path: [TrackerNestedPathComponent]
        ) {
            let key: TrackerItemKey
            let childRoot: TrackerRootIdentity
            if let root {
                key = .nested(
                    base: base,
                    rawSection: section,
                    dataID: item.dataID,
                    root: root,
                    path: path
                )
                childRoot = root
            } else {
                let rootIdentity = TrackerRootIdentity(
                    base: base,
                    rawSection: section,
                    dataID: item.dataID
                )
                key = .root(
                    base: base,
                    rawSection: section,
                    dataID: item.dataID
                )
                childRoot = rootIdentity
            }

            result[item.id] = key
            for child in item.types {
                let childPath = path + [
                    TrackerNestedPathComponent(kind: .type, dataID: child.dataID)
                ]
                visit(
                    child,
                    section: section,
                    root: childRoot,
                    path: childPath
                )
            }
            for child in item.modules {
                let childPath = path + [
                    TrackerNestedPathComponent(kind: .module, dataID: child.dataID)
                ]
                visit(
                    child,
                    section: section,
                    root: childRoot,
                    path: childPath
                )
            }
        }

        for section in snapshot.objectSections.keys.sorted() {
            let isBuilderSection = section.hasSuffix("2")
            guard isBuilderSection == (base == .builder) else { continue }
            for item in snapshot.objectSections[section, default: []] {
                visit(item, section: section, root: nil, path: [])
            }
        }

        return result
    }

    public static func uniqueKeys(in snapshot: AccountSnapshot, base: TrackerBase) -> [TrackerItemKey] {
        Array(Set(keys(in: snapshot, base: base))).sorted { $0.stableID < $1.stableID }
    }
}

// MARK: - Shared errors

public enum ManualUpgradeError: Error, Equatable, Sendable {
    case invalidItemKey
    case invalidBaselineReference
    case invalidCatalogProvenance
    case invalidLevel
    case invalidQuantity
    case arithmeticOverflow
    case missingItemState(TrackerItemKey)
    case unavailableItemState(TrackerItemKey)
    case conflictingItemState(TrackerItemKey)
    case baselineMismatch(TrackerItemKey)
    case insufficientQuantity(level: Int, requested: Int64, available: Int64)
    case futureStart
    case invalidDuration
    case durationUnavailable(CatalogDurationState)
    case duplicateRecordID(UUID)
    case recordNotFound(UUID)
    case recordNotActive(UUID)
    case cannotCancelCompleted(UUID)
    case invalidRecord
}

// MARK: - Deterministic level distributions

public struct ManualLevelQuantity: Codable, Hashable, Sendable {
    public let level: Int
    public let quantity: Int64

    public init(level: Int, quantity: Int64) throws {
        guard level >= 0 else { throw ManualUpgradeError.invalidLevel }
        guard quantity > 0 else { throw ManualUpgradeError.invalidQuantity }
        self.level = level
        self.quantity = quantity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            level: try container.decode(Int.self, forKey: .level),
            quantity: try container.decode(Int64.self, forKey: .quantity)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case quantity
    }
}

/// A sorted, duplicate-free level histogram.
public struct ManualLevelDistribution: Codable, Hashable, Sendable {
    public let levels: [ManualLevelQuantity]

    public static let empty = try! ManualLevelDistribution(levels: [])

    public init(levels: [ManualLevelQuantity] = []) throws {
        let sorted = levels.sorted { $0.level < $1.level }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.level != $1.level }) else {
            throw ManualUpgradeError.invalidRecord
        }
        var total: Int64 = 0
        for entry in sorted {
            let (next, overflow) = total.addingReportingOverflow(entry.quantity)
            guard !overflow else { throw ManualUpgradeError.arithmeticOverflow }
            total = next
        }
        self.levels = sorted
    }

    public init(levelQuantities: [Int: Int64]) throws {
        var entries: [ManualLevelQuantity] = []
        entries.reserveCapacity(levelQuantities.count)
        for level in levelQuantities.keys.sorted() {
            guard let quantity = levelQuantities[level] else {
                throw ManualUpgradeError.invalidRecord
            }
            entries.append(try ManualLevelQuantity(level: level, quantity: quantity))
        }
        try self.init(levels: entries)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer().decode([ManualLevelQuantity].self)
        try self.init(levels: values)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(levels)
    }

    public var isEmpty: Bool { levels.isEmpty }

    public var totalQuantity: Int64 {
        levels.reduce(0) { $0 + $1.quantity }
    }

    public func quantity(at level: Int) -> Int64 {
        levels.first(where: { $0.level == level })?.quantity ?? 0
    }

    public func adding(level: Int, quantity: Int64) throws -> Self {
        guard quantity > 0 else { throw ManualUpgradeError.invalidQuantity }
        var updated = levels
        if let index = updated.firstIndex(where: { $0.level == level }) {
            let (sum, overflow) = updated[index].quantity.addingReportingOverflow(quantity)
            guard !overflow else { throw ManualUpgradeError.arithmeticOverflow }
            updated[index] = try ManualLevelQuantity(level: level, quantity: sum)
        } else {
            updated.append(try ManualLevelQuantity(level: level, quantity: quantity))
        }
        return try Self(levels: updated)
    }

    public func subtracting(level: Int, quantity: Int64) throws -> Self {
        guard quantity > 0 else { throw ManualUpgradeError.invalidQuantity }
        let available = self.quantity(at: level)
        guard available >= quantity else {
            throw ManualUpgradeError.insufficientQuantity(
                level: level,
                requested: quantity,
                available: available
            )
        }
        var updated = levels
        guard let index = updated.firstIndex(where: { $0.level == level }) else {
            throw ManualUpgradeError.insufficientQuantity(
                level: level,
                requested: quantity,
                available: 0
            )
        }
        let remaining = available - quantity
        if remaining == 0 {
            updated.remove(at: index)
        } else {
            updated[index] = try ManualLevelQuantity(level: level, quantity: remaining)
        }
        return try Self(levels: updated)
    }
}

// MARK: - Provenance and item state

public struct ManualBaselineReference: Codable, Hashable, Sendable {
    public let revision: String
    public let fingerprint: String?
    public let lineageID: String?

    public init(revision: String, fingerprint: String? = nil, lineageID: String? = nil) {
        self.revision = revision
        self.fingerprint = fingerprint
        self.lineageID = lineageID
    }

    public var isStructurallyValid: Bool {
        !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct ManualImportedObservation: Codable, Hashable, Sendable {
    public let reference: ManualBaselineReference
    /// Nil means that this item was imported but its level distribution was not
    /// sufficiently observable; it must not be interpreted as zero.
    public let levelDistribution: ManualLevelDistribution?
    public let sourceTimestamp: Date?
    /// Issue #183 review P1：本次导入是否观察到该条目的进行中计时证据。
    /// 只有 `observedTimer == true` 且覆盖完整的观察才允许用户确认本地队列
    /// 映射（`QueueAssignmentDecision.userAssigned`）。默认 false，旧数据兼容。
    public let observedTimer: Bool

    public init(
        reference: ManualBaselineReference,
        levelDistribution: ManualLevelDistribution?,
        sourceTimestamp: Date? = nil,
        observedTimer: Bool = false
    ) throws {
        guard reference.isStructurallyValid else {
            throw ManualUpgradeError.invalidBaselineReference
        }
        self.reference = reference
        self.levelDistribution = levelDistribution
        self.sourceTimestamp = sourceTimestamp
        self.observedTimer = observedTimer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: try container.decode(ManualBaselineReference.self, forKey: .reference),
            levelDistribution: try container.decodeIfPresent(
                ManualLevelDistribution.self, forKey: .levelDistribution),
            sourceTimestamp: try container.decodeIfPresent(Date.self, forKey: .sourceTimestamp),
            observedTimer: try container.decodeIfPresent(
                Bool.self, forKey: .observedTimer) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case reference
        case levelDistribution
        case sourceTimestamp
        case observedTimer
    }
}

public enum ManualItemStatus: String, Codable, Hashable, Sendable {
    case observed
    case manualCompleted
    case unknown
    case conflict
}

public struct ManualItemState: Codable, Hashable, Sendable {
    public let itemKey: TrackerItemKey
    public let baselineReference: ManualBaselineReference
    public var importedObservation: ManualImportedObservation?
    /// The materialized completed distribution before active reservations.
    /// Active source quantities are held by records and removed only when a
    /// record settles; importedObservation remains the immutable provenance.
    public var manualCompletedDistribution: ManualLevelDistribution
    public var status: ManualItemStatus

    public var isStructurallyValid: Bool {
        guard itemKey.isStructurallyValid,
              baselineReference.isStructurallyValid else { return false }
        guard let importedObservation else {
            return status != .observed
        }
        return importedObservation.reference.isStructurallyValid
            && importedObservation.reference == baselineReference
    }

    public init(
        itemKey: TrackerItemKey,
        baselineReference: ManualBaselineReference,
        importedObservation: ManualImportedObservation? = nil,
        manualCompletedDistribution: ManualLevelDistribution = .empty,
        status: ManualItemStatus = .unknown
    ) throws {
        guard itemKey.isStructurallyValid else { throw ManualUpgradeError.invalidItemKey }
        guard baselineReference.isStructurallyValid else {
            throw ManualUpgradeError.invalidBaselineReference
        }
        if let importedObservation,
           !importedObservation.reference.isStructurallyValid {
            throw ManualUpgradeError.invalidBaselineReference
        }
        if let importedObservation,
           importedObservation.reference != baselineReference {
            throw ManualUpgradeError.baselineMismatch(itemKey)
        }
        if status == .observed && importedObservation == nil {
            throw ManualUpgradeError.invalidRecord
        }
        self.itemKey = itemKey
        self.baselineReference = baselineReference
        self.importedObservation = importedObservation
        self.manualCompletedDistribution = manualCompletedDistribution
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            itemKey: try container.decode(TrackerItemKey.self, forKey: .itemKey),
            baselineReference: try container.decode(
                ManualBaselineReference.self, forKey: .baselineReference),
            importedObservation: try container.decodeIfPresent(
                ManualImportedObservation.self, forKey: .importedObservation),
            manualCompletedDistribution: try container.decode(
                ManualLevelDistribution.self, forKey: .manualCompletedDistribution),
            status: try container.decode(ManualItemStatus.self, forKey: .status)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case itemKey
        case baselineReference
        case importedObservation
        case manualCompletedDistribution
        case status
    }
}

public struct ManualCatalogProvenance: Codable, Hashable, Sendable {
    public let gameVersion: String
    public let buildTag: String?
    public let sourceFingerprint: String?
    public let manifestSchemaVersion: Int?

    public init(
        gameVersion: String,
        buildTag: String? = nil,
        sourceFingerprint: String? = nil,
        manifestSchemaVersion: Int? = nil
    ) {
        self.gameVersion = gameVersion
        self.buildTag = buildTag
        self.sourceFingerprint = sourceFingerprint
        self.manifestSchemaVersion = manifestSchemaVersion
    }

    public init(catalog: GameCatalog) {
        self.init(
            gameVersion: catalog.gameVersion,
            buildTag: catalog.manifest?.buildTag,
            sourceFingerprint: catalog.manifest?.sourceFingerprint,
            manifestSchemaVersion: catalog.manifest?.schemaVersion
        )
    }

    public var isStructurallyValid: Bool {
        !gameVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ManualUpgradeDurationKind: String, Codable, Hashable, Sendable {
    case timed
    case instant
}

public enum ManualUpgradeRecordStatus: String, Codable, Hashable, Sendable {
    case active
    case completed
    case cancelled
}

public struct ManualUpgradeRecord: Identifiable, Codable, Hashable, Sendable {
    public let recordID: UUID
    public let itemKey: TrackerItemKey
    public let fromLevel: Int
    public let targetLevel: Int
    public let quantity: Int64
    public let startedAt: Date
    public let expectedEndAt: Date
    public let durationSeconds: Int64
    public let durationKind: ManualUpgradeDurationKind
    public let frozenCosts: [CatalogUpgradeCost]?
    public let catalogProvenance: ManualCatalogProvenance
    public let baselineReference: ManualBaselineReference
    public let queueKind: String?
    public var status: ManualUpgradeRecordStatus

    public var id: UUID { recordID }

    public init(
        recordID: UUID = UUID(),
        itemKey: TrackerItemKey,
        fromLevel: Int,
        targetLevel: Int,
        quantity: Int64,
        startedAt: Date,
        expectedEndAt: Date,
        durationSeconds: Int64,
        durationKind: ManualUpgradeDurationKind,
        frozenCosts: [CatalogUpgradeCost]?,
        catalogProvenance: ManualCatalogProvenance,
        baselineReference: ManualBaselineReference,
        queueKind: String? = nil,
        status: ManualUpgradeRecordStatus = .active
    ) throws {
        guard itemKey.isStructurallyValid else { throw ManualUpgradeError.invalidItemKey }
        guard fromLevel >= 0, targetLevel > fromLevel else {
            throw ManualUpgradeError.invalidLevel
        }
        guard quantity > 0 else { throw ManualUpgradeError.invalidQuantity }
        guard durationSeconds >= 0 else { throw ManualUpgradeError.invalidDuration }
        switch durationKind {
        case .timed:
            guard durationSeconds > 0 else { throw ManualUpgradeError.invalidDuration }
        case .instant:
            guard durationSeconds == 0 else { throw ManualUpgradeError.invalidDuration }
        }
        guard expectedEndAt >= startedAt else { throw ManualUpgradeError.invalidRecord }
        switch durationKind {
        case .timed:
            let expected = try Self.expectedEndAt(
                startedAt: startedAt,
                durationSeconds: durationSeconds
            )
            guard expectedEndAt == expected else {
                throw ManualUpgradeError.invalidRecord
            }
        case .instant:
            guard expectedEndAt == startedAt else {
                throw ManualUpgradeError.invalidRecord
            }
        }
        guard catalogProvenance.isStructurallyValid else {
            throw ManualUpgradeError.invalidCatalogProvenance
        }
        guard baselineReference.isStructurallyValid else {
            throw ManualUpgradeError.invalidBaselineReference
        }
        self.recordID = recordID
        self.itemKey = itemKey
        self.fromLevel = fromLevel
        self.targetLevel = targetLevel
        self.quantity = quantity
        self.startedAt = startedAt
        self.expectedEndAt = expectedEndAt
        self.durationSeconds = durationSeconds
        self.durationKind = durationKind
        self.frozenCosts = frozenCosts
        self.catalogProvenance = catalogProvenance
        self.baselineReference = baselineReference
        self.queueKind = queueKind
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordID: try container.decode(UUID.self, forKey: .recordID),
            itemKey: try container.decode(TrackerItemKey.self, forKey: .itemKey),
            fromLevel: try container.decode(Int.self, forKey: .fromLevel),
            targetLevel: try container.decode(Int.self, forKey: .targetLevel),
            quantity: try container.decode(Int64.self, forKey: .quantity),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            expectedEndAt: try container.decode(Date.self, forKey: .expectedEndAt),
            durationSeconds: try container.decode(Int64.self, forKey: .durationSeconds),
            durationKind: try container.decode(
                ManualUpgradeDurationKind.self, forKey: .durationKind),
            frozenCosts: try container.decodeIfPresent(
                [CatalogUpgradeCost].self, forKey: .frozenCosts),
            catalogProvenance: try container.decode(
                ManualCatalogProvenance.self, forKey: .catalogProvenance),
            baselineReference: try container.decode(
                ManualBaselineReference.self, forKey: .baselineReference),
            queueKind: try container.decodeIfPresent(String.self, forKey: .queueKind),
            status: try container.decode(ManualUpgradeRecordStatus.self, forKey: .status)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case recordID
        case itemKey
        case fromLevel
        case targetLevel
        case quantity
        case startedAt
        case expectedEndAt
        case durationSeconds
        case durationKind
        case frozenCosts
        case catalogProvenance
        case baselineReference
        case queueKind
        case status
    }

    private static func expectedEndAt(
        startedAt: Date,
        durationSeconds: Int64
    ) throws -> Date {
        let interval = Double(durationSeconds)
        guard interval.isFinite else { throw ManualUpgradeError.arithmeticOverflow }
        let expected = startedAt.addingTimeInterval(interval)
        guard expected.timeIntervalSinceReferenceDate.isFinite,
              expected >= startedAt else {
            throw ManualUpgradeError.arithmeticOverflow
        }
        return expected
    }
}

public struct ManualEffectiveItemState: Codable, Hashable, Sendable {
    public let itemKey: TrackerItemKey
    public let baselineReference: ManualBaselineReference
    public let importedDistribution: ManualLevelDistribution?
    public let manualCompletedDistribution: ManualLevelDistribution
    public let activeTargetDistribution: ManualLevelDistribution
    public let effectiveCompletedDistribution: ManualLevelDistribution?
    public let status: ManualItemStatus

    public var activeTargetLevel: Int? {
        guard activeTargetDistribution.levels.count == 1 else { return nil }
        return activeTargetDistribution.levels.first?.level
    }
}
