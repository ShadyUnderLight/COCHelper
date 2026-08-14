import Foundation

// MARK: - Schema and diagnostics

public enum ManualTrackerSchema {
    public static let envelope = 1
    public static let store = 1
    public static let village = 1
}

public enum ManualTrackerStoreStatus: String, Codable, Hashable, Sendable {
    /// There is no persisted manual state yet.  This is distinct from a valid
    /// store whose villages simply have no active records.
    case empty
    case available
    case unavailable
    case migrationRequired
}

public enum ManualTrackerDiagnosticKind: String, Codable, Hashable, Sendable {
    case invalidState
    case migration
    case conflict
    case unavailable
}

public struct ManualTrackerDiagnostic: Codable, Hashable, Sendable {
    public let kind: ManualTrackerDiagnosticKind
    public let code: String
    public let message: String
    public let recordedAt: Date

    public init(
        kind: ManualTrackerDiagnosticKind,
        code: String,
        message: String,
        recordedAt: Date = Date()
    ) {
        self.kind = kind
        self.code = code
        self.message = message
        self.recordedAt = recordedAt
    }
}

public struct ManualTrackerMigrationMarker: Codable, Hashable, Sendable {
    public let version: Int
    public let completedAt: Date

    public init(
        version: Int = ManualTrackerSchema.envelope,
        completedAt: Date
    ) {
        self.version = version
        self.completedAt = completedAt
    }
}

// MARK: - Persisted state

/// The persisted state for one village.  `ManualUpgradeCore` owns the item
/// ledger and active/completed/cancelled records; this wrapper owns the
/// village boundary and storage metadata.
public struct ManualTrackerVillageState: Codable, Hashable, Sendable {
    public let villageID: UUID
    public let schemaVersion: Int
    public let baselineReference: ManualBaselineReference?
    public let core: ManualUpgradeCore
    public var stateUpdatedAt: Date
    public var lastSettleAt: Date?
    /// Local time of the last successfully applied snapshot reconciliation;
    /// never treated as the source snapshot's game time.
    public var lastImportAt: Date?
    public var diagnostics: [ManualTrackerDiagnostic]
    public var reconciliationHistory: [ManualReconciliationRecord]
    /// Issue #145：用户配置的本地队列容量（source = userConfigured）。
    /// 只约束未来 local manual start，不修改历史 record 或 imported 快照。
    public var queueCapacityConfigs: [LocalQueueCapacityConfig]
    /// Issue #183：用户确认的导入观察本地队列映射 overlay。
    /// 独立于 core 与 reconciliationHistory；只记录用户显式分配决定，
    /// 对账只降级不创建/删除。
    public var queueAssignments: [QueueAssignmentDecision]

    /// The source snapshot reference currently used by the manual ledger.
    /// Reconciliation outcomes remain separately auditable in history.
    public var baselineRevision: String? { baselineReference?.revision }
    public var baselineFingerprint: String? { baselineReference?.fingerprint }

    public init(
        villageID: UUID,
        core: ManualUpgradeCore,
        stateUpdatedAt: Date = Date(),
        lastSettleAt: Date? = nil,
        lastImportAt: Date? = nil,
        diagnostics: [ManualTrackerDiagnostic] = [],
        reconciliationHistory: [ManualReconciliationRecord] = [],
        queueCapacityConfigs: [LocalQueueCapacityConfig] = [],
        queueAssignments: [QueueAssignmentDecision] = []
    ) throws {
        guard stateUpdatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualTrackerStoreError.invalidEnvelope("stateUpdatedAt 无效。")
        }
        if let lastSettleAt,
           !lastSettleAt.timeIntervalSinceReferenceDate.isFinite {
            throw ManualTrackerStoreError.invalidEnvelope("lastSettleAt 无效。")
        }
        if let lastImportAt,
           !lastImportAt.timeIntervalSinceReferenceDate.isFinite {
            throw ManualTrackerStoreError.invalidEnvelope("lastImportAt 无效。")
        }
        guard diagnostics.allSatisfy({
            $0.recordedAt.timeIntervalSinceReferenceDate.isFinite
        }) else {
            throw ManualTrackerStoreError.invalidEnvelope("村庄诊断时间无效。")
        }
        guard reconciliationHistory.allSatisfy({
            $0.appliedAt.timeIntervalSinceReferenceDate.isFinite
                && ($0.sourceTimestamp?.timeIntervalSinceReferenceDate.isFinite ?? true)
                && $0.newReference.isStructurallyValid
                && ($0.previousReference?.isStructurallyValid ?? true)
        }) else {
            throw ManualTrackerStoreError.invalidEnvelope("对账历史无效。")
        }
        guard Set(reconciliationHistory.map(\.reconciliationID)).count
                == reconciliationHistory.count else {
            throw ManualTrackerStoreError.invalidEnvelope("存在重复的 reconciliationID。")
        }
        guard queueCapacityConfigs.count <= 64 else {
            throw ManualTrackerStoreError.invalidEnvelope("队列容量配置数量超过上限。")
        }
        for config in queueCapacityConfigs {
            guard config.villageID == villageID else {
                throw ManualTrackerStoreError.invalidEnvelope(
                    "队列容量配置的村庄与所属村庄不一致。"
                )
            }
            guard config.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ManualTrackerStoreError.invalidEnvelope("队列容量配置时间无效。")
            }
        }
        guard Set(queueCapacityConfigs.map(\.queueKind.rawValue)).count
                == queueCapacityConfigs.count else {
            throw ManualTrackerStoreError.invalidEnvelope("存在重复的队列类别容量配置。")
        }
        guard queueAssignments.count <= 4096 else {
            throw ManualTrackerStoreError.invalidEnvelope("队列分配数量超过上限。")
        }
        for assignment in queueAssignments {
            guard assignment.villageID == villageID else {
                throw ManualTrackerStoreError.invalidEnvelope(
                    "队列分配的村庄与所属村庄不一致。"
                )
            }
            guard assignment.decidedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ManualTrackerStoreError.invalidEnvelope("队列分配时间无效。")
            }
            guard assignment.itemKey.isStructurallyValid,
                  assignment.baselineReference.isStructurallyValid else {
                throw ManualTrackerStoreError.invalidEnvelope("队列分配身份无效。")
            }
        }
        guard Set(queueAssignments.map(\.decisionID)).count
                == queueAssignments.count else {
            throw ManualTrackerStoreError.invalidEnvelope("存在重复的队列分配 ID。")
        }

        let references = Set(
            core.itemStates.map(\.baselineReference)
                + core.records.map(\.baselineReference)
        )
        guard references.count <= 1 else {
            throw ManualTrackerStoreError.invalidEnvelope(
                "同一村庄包含多个 baseline reference。"
            )
        }
        guard core.records.allSatisfy({ $0.startedAt <= stateUpdatedAt }) else {
            throw ManualTrackerStoreError.invalidEnvelope(
                "升级记录的 startedAt 不能晚于 stateUpdatedAt。"
            )
        }

        self.villageID = villageID
        self.schemaVersion = ManualTrackerSchema.village
        self.baselineReference = references.first
        self.core = core
        self.stateUpdatedAt = stateUpdatedAt
        self.lastSettleAt = lastSettleAt
        self.lastImportAt = lastImportAt
        self.diagnostics = diagnostics
        self.reconciliationHistory = reconciliationHistory
        self.queueCapacityConfigs = queueCapacityConfigs
        self.queueAssignments = queueAssignments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == ManualTrackerSchema.village else {
            throw ManualTrackerStoreError.unsupportedSchema(schemaVersion)
        }

        let core = try container.decode(ManualUpgradeCore.self, forKey: .core)
        let decodedBaseline = try container.decodeIfPresent(
            ManualBaselineReference.self,
            forKey: .baselineReference
        )
        try self.init(
            villageID: try container.decode(UUID.self, forKey: .villageID),
            core: core,
            stateUpdatedAt: try container.decode(Date.self, forKey: .stateUpdatedAt),
            lastSettleAt: try container.decodeIfPresent(Date.self, forKey: .lastSettleAt),
            lastImportAt: try container.decodeIfPresent(Date.self, forKey: .lastImportAt),
            diagnostics: try container.decodeIfPresent(
                [ManualTrackerDiagnostic].self,
                forKey: .diagnostics
            ) ?? [],
            reconciliationHistory: try container.decodeIfPresent(
                [ManualReconciliationRecord].self,
                forKey: .reconciliationHistory
            ) ?? [],
            queueCapacityConfigs: try container.decodeIfPresent(
                [LocalQueueCapacityConfig].self,
                forKey: .queueCapacityConfigs
            ) ?? [],
            queueAssignments: try container.decodeIfPresent(
                [QueueAssignmentDecision].self,
                forKey: .queueAssignments
            ) ?? []
        )
        guard self.baselineReference == decodedBaseline else {
            throw ManualTrackerStoreError.invalidEnvelope(
                "村庄 \(self.villageID.uuidString) 的 baseline reference 与 core 不一致。"
            )
        }
    }

    public init(
        villageID: UUID,
        stateUpdatedAt: Date = Date(),
        lastSettleAt: Date? = nil,
        lastImportAt: Date? = nil,
        diagnostics: [ManualTrackerDiagnostic] = [],
        reconciliationHistory: [ManualReconciliationRecord] = [],
        queueCapacityConfigs: [LocalQueueCapacityConfig] = [],
        queueAssignments: [QueueAssignmentDecision] = []
    ) throws {
        try self.init(
            villageID: villageID,
            core: ManualUpgradeCore(),
            stateUpdatedAt: stateUpdatedAt,
            lastSettleAt: lastSettleAt,
            lastImportAt: lastImportAt,
            diagnostics: diagnostics,
            reconciliationHistory: reconciliationHistory,
            queueCapacityConfigs: queueCapacityConfigs,
            queueAssignments: queueAssignments
        )
    }

    public static func empty(villageID: UUID, now: Date = Date()) -> Self {
        let safeNow = now.timeIntervalSinceReferenceDate.isFinite
            ? now
            : Date(timeIntervalSinceReferenceDate: 0)
        return try! Self(villageID: villageID, stateUpdatedAt: safeNow)
    }

    private enum CodingKeys: String, CodingKey {
        case villageID
        case schemaVersion
        case baselineReference
        case core
        case stateUpdatedAt
        case lastSettleAt
        case lastImportAt
        case diagnostics
        case reconciliationHistory
        case queueCapacityConfigs
        case queueAssignments
    }
}

/// Versioned manual-tracker envelope.  The array is intentionally persisted
/// as records rather than a UUID-keyed Swift dictionary so the JSON remains
/// explicit, deterministic, and independently validateable.
public struct ManualTrackerEnvelope: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let storeVersion: Int
    public var villages: [ManualTrackerVillageState]
    public var migrationMarker: ManualTrackerMigrationMarker?
    public var lastDiagnostic: ManualTrackerDiagnostic?

    public init(
        schemaVersion: Int = ManualTrackerSchema.envelope,
        storeVersion: Int = ManualTrackerSchema.store,
        villages: [ManualTrackerVillageState] = [],
        migrationMarker: ManualTrackerMigrationMarker? = nil,
        lastDiagnostic: ManualTrackerDiagnostic? = nil
    ) throws {
        self.schemaVersion = schemaVersion
        self.storeVersion = storeVersion
        self.villages = villages.sorted { $0.villageID.uuidString < $1.villageID.uuidString }
        self.migrationMarker = migrationMarker
        self.lastDiagnostic = lastDiagnostic
        _ = try validated()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            storeVersion: try container.decode(Int.self, forKey: .storeVersion),
            villages: try container.decode(
                [ManualTrackerVillageState].self,
                forKey: .villages
            ),
            migrationMarker: try container.decodeIfPresent(
                ManualTrackerMigrationMarker.self,
                forKey: .migrationMarker
            ),
            lastDiagnostic: try container.decodeIfPresent(
                ManualTrackerDiagnostic.self,
                forKey: .lastDiagnostic
            )
        )
    }

    public static func empty(
        for villageIDs: [UUID],
        now: Date = Date()
    ) -> Self {
        let safeNow = now.timeIntervalSinceReferenceDate.isFinite
            ? now
            : Date(timeIntervalSinceReferenceDate: 0)
        let uniqueVillageIDs = Set(villageIDs).sorted {
            $0.uuidString < $1.uuidString
        }
        return try! Self(
            villages: uniqueVillageIDs.map {
                ManualTrackerVillageState.empty(villageID: $0, now: safeNow)
            },
            migrationMarker: ManualTrackerMigrationMarker(completedAt: safeNow)
        )
    }

    public var isMigrated: Bool {
        migrationMarker?.version == ManualTrackerSchema.envelope
    }

    public var isEmpty: Bool {
        villages.isEmpty || villages.allSatisfy {
            $0.core.itemStates.isEmpty && $0.core.records.isEmpty
        }
    }

    public func state(for villageID: UUID) -> ManualTrackerVillageState? {
        villages.first { $0.villageID == villageID }
    }

    public mutating func upsert(_ state: ManualTrackerVillageState) throws {
        guard schemaVersion == ManualTrackerSchema.envelope,
              storeVersion == ManualTrackerSchema.store else {
            throw ManualTrackerStoreError.unsupportedSchema(schemaVersion)
        }
        if let index = villages.firstIndex(where: { $0.villageID == state.villageID }) {
            villages[index] = state
        } else {
            villages.append(state)
        }
        villages.sort { $0.villageID.uuidString < $1.villageID.uuidString }
        _ = try validated()
    }

    public mutating func remove(villageID: UUID) {
        villages.removeAll { $0.villageID == villageID }
    }

    public func validated() throws -> Self {
        guard schemaVersion == ManualTrackerSchema.envelope else {
            throw ManualTrackerStoreError.unsupportedSchema(schemaVersion)
        }
        guard storeVersion == ManualTrackerSchema.store else {
            throw ManualTrackerStoreError.unsupportedSchema(storeVersion)
        }
        if let migrationMarker,
           migrationMarker.version != ManualTrackerSchema.envelope {
            throw ManualTrackerStoreError.unsupportedSchema(migrationMarker.version)
        }
        if let migrationMarker,
           !migrationMarker.completedAt.timeIntervalSinceReferenceDate.isFinite {
            throw ManualTrackerStoreError.invalidEnvelope("migration marker 时间无效。")
        }
        if let lastDiagnostic,
           !lastDiagnostic.recordedAt.timeIntervalSinceReferenceDate.isFinite {
            throw ManualTrackerStoreError.invalidEnvelope("store 诊断时间无效。")
        }
        if migrationMarker == nil, !villages.isEmpty {
            throw ManualTrackerStoreError.invalidEnvelope(
                "非空 store 缺少 migration marker。"
            )
        }

        var villageIDs = Set<UUID>()
        var recordIDs = Set<UUID>()
        for state in villages {
            guard villageIDs.insert(state.villageID).inserted else {
                throw ManualTrackerStoreError.invalidEnvelope("存在重复的 villageID。")
            }
            guard state.schemaVersion == ManualTrackerSchema.village else {
                throw ManualTrackerStoreError.unsupportedSchema(state.schemaVersion)
            }
            if let baselineReference = state.baselineReference {
                guard baselineReference.isStructurallyValid else {
                    throw ManualTrackerStoreError.invalidEnvelope("baseline reference 无效。")
                }
            } else if !state.core.itemStates.isEmpty || !state.core.records.isEmpty {
                throw ManualTrackerStoreError.invalidEnvelope(
                    "非空村庄状态缺少 baseline reference。"
                )
            }
            for record in state.core.records {
                guard recordIDs.insert(record.recordID).inserted else {
                    throw ManualTrackerStoreError.invalidEnvelope("存在重复的 recordID。")
                }
                guard record.baselineReference == state.baselineReference else {
                    throw ManualTrackerStoreError.invalidEnvelope(
                        "record 的 baseline 不属于其 village state。"
                    )
                }
            }
        }

        return self
    }

    public func encodedData() throws -> Data {
        try JSONEncoder().encode(try validated())
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storeVersion
        case villages
        case migrationMarker
        case lastDiagnostic
    }
}

// MARK: - Store contract

public enum ManualTrackerStoreError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case corrupt(String)
    case unsupportedSchema(Int)
    case invalidEnvelope(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            "手动升级存储不可用：" + message
        case .corrupt(let message):
            "手动升级存储损坏：" + message
        case .unsupportedSchema(let version):
            "手动升级存储版本不受支持：" + String(version)
        case .invalidEnvelope(let message):
            "手动升级存储内容无效：" + message
        case .writeFailed(let message):
            "手动升级存储写入失败：" + message
        }
    }
}

public protocol ManualTrackerStore: Sendable {
    var transactionJournalURL: URL? { get }

    func load() throws -> ManualTrackerEnvelope?
    func save(_ envelope: ManualTrackerEnvelope) throws
    func readRawData() throws -> Data?
    func writeRawData(_ data: Data) throws
    func restoreRawData(_ data: Data?) throws
}

/// File-backed manual state store.  The file is independent from the legacy
/// `coc-helper.villages.v1` UserDefaults blob and is never replaced by an
/// empty store when decoding fails.
public final class FileManualTrackerStore: ManualTrackerStore, @unchecked Sendable {
    public let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public var transactionJournalURL: URL? {
        fileURL?.deletingLastPathComponent()
            .appendingPathComponent("manual-tracker-v1.transaction.json")
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return directory
            .appendingPathComponent("COCHelper", isDirectory: true)
            .appendingPathComponent("manual-tracker-v1.json")
    }

    public func load() throws -> ManualTrackerEnvelope? {
        guard let data = try readRawData() else { return nil }
        do {
            return try JSONDecoder()
                .decode(ManualTrackerEnvelope.self, from: data)
                .validated()
        } catch let error as ManualTrackerStoreError {
            throw error
        } catch {
            throw ManualTrackerStoreError.corrupt(error.localizedDescription)
        }
    }

    public func save(_ envelope: ManualTrackerEnvelope) throws {
        do {
            try writeRawData(envelope.encodedData())
        } catch let error as ManualTrackerStoreError {
            throw error
        } catch {
            throw ManualTrackerStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func readRawData() throws -> Data? {
        guard let fileURL else {
            throw ManualTrackerStoreError.unavailable("没有可用的手动升级文件路径。")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw ManualTrackerStoreError.unavailable(error.localizedDescription)
        }
    }

    public func writeRawData(_ data: Data) throws {
        guard let fileURL else {
            throw ManualTrackerStoreError.unavailable("没有可用的手动升级文件路径。")
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Foundation's atomic write uses a sibling temporary file and an
            // atomic replacement, so a failed encode/write leaves old bytes.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ManualTrackerStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func restoreRawData(_ data: Data?) throws {
        guard let fileURL else {
            throw ManualTrackerStoreError.unavailable("没有可用的手动升级文件路径。")
        }
        do {
            if let data {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            throw ManualTrackerStoreError.writeFailed(
                "恢复手动升级文件失败：" + error.localizedDescription
            )
        }
    }
}
