import Foundation

public enum SnapshotHistoryDiagnosticKind: String, Codable, Hashable, Sendable {
    case corrupt
    case unsupportedSchema
    case unavailable
    case writeFailed
}

public struct SnapshotHistoryDiagnostic: Codable, Hashable, Sendable {
    public let kind: SnapshotHistoryDiagnosticKind
    public let message: String
    public let recordedAt: Date

    public init(
        kind: SnapshotHistoryDiagnosticKind,
        message: String,
        recordedAt: Date = Date()
    ) {
        self.kind = kind
        self.message = message
        self.recordedAt = recordedAt
    }
}

public struct SnapshotHistoryMigrationMarker: Codable, Hashable, Sendable {
    public let version: Int
    public let completedAt: Date

    public init(
        version: Int = SnapshotHistorySchema.envelope,
        completedAt: Date
    ) {
        self.version = version
        self.completedAt = completedAt
    }
}

public struct SnapshotHistoryDuplicateMetadata: Codable, Hashable, Sendable {
    public var lastSeenAt: Date
    public var lastSourceTimestamp: Date?
    public var duplicateImportCount: Int

    public init(
        lastSeenAt: Date,
        lastSourceTimestamp: Date?,
        duplicateImportCount: Int = 1
    ) {
        self.lastSeenAt = lastSeenAt
        self.lastSourceTimestamp = lastSourceTimestamp
        self.duplicateImportCount = max(1, duplicateImportCount)
    }
}

/// Mutable index metadata for the active tail of each village lineage.
/// `SnapshotHistoryEntry` itself remains immutable once appended.
public struct SnapshotHistoryLineageMetadata: Codable, Hashable, Sendable {
    public let villageID: UUID
    public let lineageID: UUID
    public let normalizedPlayerTag: String?
    public let lastEntryID: UUID
    public let lastFingerprint: String
    public let lastAppliedAt: Date
    public let hasConflict: Bool
    public var isActive: Bool

    public init(
        villageID: UUID,
        lineageID: UUID,
        normalizedPlayerTag: String?,
        lastEntryID: UUID,
        lastFingerprint: String,
        lastAppliedAt: Date,
        hasConflict: Bool,
        isActive: Bool = true
    ) {
        self.villageID = villageID
        self.lineageID = lineageID
        self.normalizedPlayerTag = normalizedPlayerTag
        self.lastEntryID = lastEntryID
        self.lastFingerprint = lastFingerprint
        self.lastAppliedAt = lastAppliedAt
        self.hasConflict = hasConflict
        self.isActive = isActive
    }
}

/// The standalone history file.  Entries are append-only; indexes and
/// duplicate metadata are deliberately separate mutable structures.
public struct SnapshotHistoryEnvelope: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public var entries: [SnapshotHistoryEntry]
    public var lineages: [SnapshotHistoryLineageMetadata]
    public var duplicateMetadata: [String: SnapshotHistoryDuplicateMetadata]
    public var migrationMarker: SnapshotHistoryMigrationMarker?
    public var lastDiagnostic: SnapshotHistoryDiagnostic?

    public init(
        schemaVersion: Int = SnapshotHistorySchema.envelope,
        entries: [SnapshotHistoryEntry] = [],
        lineages: [SnapshotHistoryLineageMetadata] = [],
        duplicateMetadata: [String: SnapshotHistoryDuplicateMetadata] = [:],
        migrationMarker: SnapshotHistoryMigrationMarker? = nil,
        lastDiagnostic: SnapshotHistoryDiagnostic? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.lineages = lineages
        self.duplicateMetadata = duplicateMetadata
        self.migrationMarker = migrationMarker
        self.lastDiagnostic = lastDiagnostic
    }

    public var isMigrated: Bool {
        migrationMarker?.version == SnapshotHistorySchema.envelope
    }

    public func entry(id: UUID) -> SnapshotHistoryEntry? {
        entries.first { $0.snapshotID == id }
    }

    public func activeLineage(for villageID: UUID) -> SnapshotHistoryLineageMetadata? {
        lineages.first { $0.villageID == villageID && $0.isActive }
    }

    public func validated() throws -> SnapshotHistoryEnvelope {
        guard schemaVersion == SnapshotHistorySchema.envelope else {
            throw SnapshotHistoryStoreError.unsupportedSchema(schemaVersion)
        }

        var entryIDs = Set<UUID>()
        for entry in entries {
            guard entryIDs.insert(entry.snapshotID).inserted else {
                throw SnapshotHistoryStoreError.invalidEntry("存在重复的 snapshotID。")
            }
            guard entry.schemaVersion == SnapshotHistorySchema.entry else {
                throw SnapshotHistoryStoreError.unsupportedSchema(entry.schemaVersion)
            }
            guard entry.observationVersion == SnapshotHistorySchema.observation else {
                throw SnapshotHistoryStoreError.unsupportedSchema(entry.observationVersion)
            }
            guard entry.fingerprintVersion == SnapshotHistorySchema.fingerprint else {
                throw SnapshotHistoryStoreError.unsupportedSchema(entry.fingerprintVersion)
            }
            guard entry.integrityVersion == SnapshotHistorySchema.integrity else {
                throw SnapshotHistoryStoreError.unsupportedSchema(entry.integrityVersion)
            }
            guard !entry.rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SnapshotHistoryStoreError.invalidEntry("历史 entry 缺少 rawJSON。")
            }
            guard Self.isSHA256Fingerprint(entry.canonicalFingerprint) else {
                throw SnapshotHistoryStoreError.invalidEntry("历史 entry 的 fingerprint 格式无效。")
            }
            guard Self.isSHA256Fingerprint(entry.integrityFingerprint) else {
                throw SnapshotHistoryStoreError.invalidEntry("历史 entry 的完整性摘要格式无效。")
            }
            try Self.validateIntegrity(of: entry)
        }

        var lineageIDs = Set<UUID>()
        var activeVillages = Set<UUID>()
        for lineage in lineages {
            guard lineageIDs.insert(lineage.lineageID).inserted else {
                throw SnapshotHistoryStoreError.invalidEntry("存在重复的 lineageID。")
            }
            if lineage.isActive && !activeVillages.insert(lineage.villageID).inserted {
                throw SnapshotHistoryStoreError.invalidEntry("同一村庄存在多个 active lineage。")
            }
            guard let lastEntry = entry(id: lineage.lastEntryID),
                  lastEntry.villageID == lineage.villageID,
                  lastEntry.lineageID == lineage.lineageID,
                  lastEntry.canonicalFingerprint == lineage.lastFingerprint else {
                throw SnapshotHistoryStoreError.invalidEntry("lineage index 指向不存在或不匹配的 entry。")
            }
        }

        for (rawID, metadata) in duplicateMetadata {
            guard let snapshotID = UUID(uuidString: rawID),
                  entry(id: snapshotID) != nil else {
                throw SnapshotHistoryStoreError.invalidEntry("duplicate metadata 指向不存在的 entry。")
            }
            guard metadata.duplicateImportCount > 0 else {
                throw SnapshotHistoryStoreError.invalidEntry("duplicateImportCount 必须为正数。")
            }
        }

        if let marker = migrationMarker,
           marker.version != SnapshotHistorySchema.envelope {
            throw SnapshotHistoryStoreError.unsupportedSchema(marker.version)
        }
        if migrationMarker == nil,
           !entries.isEmpty || !lineages.isEmpty || !duplicateMetadata.isEmpty {
            throw SnapshotHistoryStoreError.invalidEntry("未完成迁移的历史 envelope 不得包含 entries。")
        }

        return self
    }

    public func encodedData() throws -> Data {
        try JSONEncoder().encode(try validated())
    }

    private static func isSHA256Fingerprint(_ value: String) -> Bool {
        guard value.count == 71, value.hasPrefix("sha256:") else { return false }
        return value.dropFirst(7).allSatisfy { $0.isHexDigit }
    }

    private static func validateIntegrity(of entry: SnapshotHistoryEntry) throws {
        let expectedIntegrityFingerprint = SnapshotHistoryCanonicalizer.integrityFingerprint(
            integrityVersion: entry.integrityVersion,
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            fingerprintVersion: entry.fingerprintVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: entry.canonicalFingerprint,
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason
        )
        guard expectedIntegrityFingerprint == entry.integrityFingerprint else {
            throw SnapshotHistoryStoreError.invalidEntry("历史 entry 的完整性摘要不一致。")
        }

        let rebuilt: SnapshotHistoryEntry
        do {
            let snapshot = try AccountSnapshotImporter.parse(entry.rawJSON)
            rebuilt = try SnapshotHistoryCanonicalizer.canonicalize(
                snapshot: snapshot,
                villageID: entry.villageID,
                lineageID: entry.lineageID,
                appliedAt: entry.appliedAt,
                snapshotID: entry.snapshotID,
                isBaseline: entry.isBaseline,
                baselineReason: entry.baselineReason
            )
        } catch let error as SnapshotHistoryStoreError {
            throw error
        } catch let error as LocalizedError {
            throw SnapshotHistoryStoreError.invalidEntry(
                "历史 entry 的 rawJSON 无法重建 observation："
                    + (error.errorDescription ?? error.localizedDescription)
            )
        } catch {
            throw SnapshotHistoryStoreError.invalidEntry(
                "历史 entry 的 rawJSON 无法重建 observation：" + error.localizedDescription
            )
        }

        let storedObservationFingerprint = SnapshotHistoryCanonicalizer.fingerprint(
            for: entry.observation
        )
        guard storedObservationFingerprint == entry.canonicalFingerprint else {
            throw SnapshotHistoryStoreError.invalidEntry(
                "历史 entry 的 observation 与 canonicalFingerprint 不一致。"
            )
        }
        guard rebuilt.canonicalFingerprint == entry.canonicalFingerprint else {
            throw SnapshotHistoryStoreError.invalidEntry(
                "历史 entry 的 rawJSON 与 canonicalFingerprint 不一致。"
            )
        }
    }
}

public enum SnapshotHistoryStoreError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case corrupt(String)
    case unsupportedSchema(Int)
    case invalidEntry(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            "历史不可用：" + message
        case .corrupt(let message):
            "历史文件损坏：" + message
        case .unsupportedSchema(let version):
            "历史文件版本不受支持：" + String(version)
        case .invalidEntry(let message):
            "历史文件内容无效：" + message
        case .writeFailed(let message):
            "历史写入失败：" + message
        }
    }
}

public protocol SnapshotHistoryStore: Sendable {
    /// A sibling journal path is used by the AppModel transaction coordinator.
    /// Test stores may return nil and still receive in-process rollback checks.
    var transactionJournalURL: URL? { get }

    func load() throws -> SnapshotHistoryEnvelope?
    func save(_ envelope: SnapshotHistoryEnvelope) throws
    func readRawData() throws -> Data?
    func writeRawData(_ data: Data) throws
    func restoreRawData(_ data: Data?) throws
}

/// File-backed history store.  A corrupt file is never replaced by an empty
/// envelope: loading throws while leaving the original bytes in place for
/// recovery or manual inspection.
public final class FileSnapshotHistoryStore: SnapshotHistoryStore, @unchecked Sendable {
    public let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public var transactionJournalURL: URL? {
        fileURL?.deletingLastPathComponent()
            .appendingPathComponent("snapshot-history-v1.transaction.json")
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return directory
            .appendingPathComponent("COCHelper", isDirectory: true)
            .appendingPathComponent("snapshot-history-v1.json")
    }

    public func load() throws -> SnapshotHistoryEnvelope? {
        guard let data = try readRawData() else { return nil }
        do {
            let envelope = try JSONDecoder().decode(SnapshotHistoryEnvelope.self, from: data)
            return try envelope.validated()
        } catch let error as SnapshotHistoryStoreError {
            throw error
        } catch {
            throw SnapshotHistoryStoreError.corrupt(error.localizedDescription)
        }
    }

    public func save(_ envelope: SnapshotHistoryEnvelope) throws {
        do {
            try writeRawData(envelope.encodedData())
        } catch let error as SnapshotHistoryStoreError {
            throw error
        } catch {
            throw SnapshotHistoryStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func readRawData() throws -> Data? {
        guard let fileURL else {
            throw SnapshotHistoryStoreError.unavailable("没有可用的历史文件路径。")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw SnapshotHistoryStoreError.unavailable(error.localizedDescription)
        }
    }

    public func writeRawData(_ data: Data) throws {
        guard let fileURL else {
            throw SnapshotHistoryStoreError.unavailable("没有可用的历史文件路径。")
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw SnapshotHistoryStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func restoreRawData(_ data: Data?) throws {
        guard let fileURL else {
            throw SnapshotHistoryStoreError.unavailable("没有可用的历史文件路径。")
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
            throw SnapshotHistoryStoreError.writeFailed("回滚历史文件失败：" + error.localizedDescription)
        }
    }
}

public enum SnapshotHistoryServiceError: Error, LocalizedError, Equatable, Sendable {
    case historyUnavailable(String)
    case lineageConflict(String)

    public var errorDescription: String? {
        switch self {
        case .historyUnavailable(let message):
            "历史不可用，导入已拒绝：" + message
        case .lineageConflict(let message):
            "历史身份冲突，导入已拒绝：" + message
        }
    }
}

public struct SnapshotHistoryImportDecision: Sendable {
    public let envelope: SnapshotHistoryEnvelope
    public let entry: SnapshotHistoryEntry
    public let lineage: SnapshotLineageResolution
    public let appended: Bool
    public let duplicate: Bool

    public init(
        envelope: SnapshotHistoryEnvelope,
        entry: SnapshotHistoryEntry,
        lineage: SnapshotLineageResolution,
        appended: Bool,
        duplicate: Bool
    ) {
        self.envelope = envelope
        self.entry = entry
        self.lineage = lineage
        self.appended = appended
        self.duplicate = duplicate
    }
}

public struct SnapshotHistoryService: Sendable {
    public let store: any SnapshotHistoryStore

    public init(store: any SnapshotHistoryStore) {
        self.store = store
    }

    public func loadOrMigrate(
        villages: [VillageProfile],
        now: Date = Date(),
        catalog: GameCatalog? = nil,
        craftTableCatalog: CraftTableCatalog? = nil
    ) throws -> SnapshotHistoryEnvelope {
        if let existing = try store.load() {
            if existing.isMigrated { return existing }
            // A pre-migration empty envelope is a valid starting point.  A
            // non-empty envelope without a marker is rejected by validation.
        }

        var envelope = SnapshotHistoryEnvelope()
        for village in villages {
            guard let snapshot = village.accountSnapshot else { continue }
            let lineage = SnapshotLineageResolver.resolve(
                villageID: village.id,
                normalizedPlayerTag: snapshot.tag,
                previous: nil
            )
            let entry = try SnapshotHistoryCanonicalizer.canonicalize(
                snapshot: snapshot,
                villageID: village.id,
                lineage: lineage,
                appliedAt: now,
                catalog: catalog,
                craftTableCatalog: craftTableCatalog
            )
            envelope.append(entry: entry, lineage: lineage)
        }
        envelope.migrationMarker = SnapshotHistoryMigrationMarker(completedAt: now)
        envelope.lastDiagnostic = nil
        try store.save(envelope)
        return envelope
    }

    public func planImport(
        snapshot: AccountSnapshot,
        villageID: UUID,
        currentTag: String?,
        hasCurrentSnapshot: Bool,
        envelope: SnapshotHistoryEnvelope,
        appliedAt: Date = Date(),
        catalog: GameCatalog? = nil,
        craftTableCatalog: CraftTableCatalog? = nil
    ) throws -> SnapshotHistoryImportDecision {
        guard envelope.isMigrated else {
            throw SnapshotHistoryServiceError.historyUnavailable("历史尚未完成迁移。")
        }

        let active = envelope.activeLineage(for: villageID)
        if hasCurrentSnapshot,
           let active,
           OfficialPlayerTagValidator.normalized(currentTag) != active.normalizedPlayerTag {
            throw SnapshotHistoryServiceError.lineageConflict(
                "当前村庄 Tag 与历史 active lineage 不一致。"
            )
        }

        let previous = active.map {
            SnapshotLineageContext(
                villageID: $0.villageID,
                lineageID: $0.lineageID,
                normalizedPlayerTag: $0.normalizedPlayerTag,
                hasConflict: $0.hasConflict
            )
        }
        let lineage = SnapshotLineageResolver.resolve(
            villageID: villageID,
            normalizedPlayerTag: snapshot.tag,
            previous: previous
        )
        let candidate = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: villageID,
            lineage: lineage,
            appliedAt: appliedAt,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog
        )

        var updated = envelope
        if lineage.outcome == .continued,
           let active,
           let previousEntry = envelope.entry(id: active.lastEntryID),
           previousEntry.canonicalFingerprint == candidate.canonicalFingerprint {
            let key = previousEntry.snapshotID.uuidString
            let previousMetadata = updated.duplicateMetadata[key]
            updated.duplicateMetadata[key] = SnapshotHistoryDuplicateMetadata(
                lastSeenAt: appliedAt,
                lastSourceTimestamp: snapshot.capturedAt,
                duplicateImportCount: (previousMetadata?.duplicateImportCount ?? 0) + 1
            )
            updated.lastDiagnostic = nil
            return SnapshotHistoryImportDecision(
                envelope: updated,
                entry: previousEntry,
                lineage: lineage,
                appended: false,
                duplicate: true
            )
        }

        updated.entries.append(candidate)
        updated.upsertLineage(
            villageID: villageID,
            entry: candidate,
            hasConflict: lineage.reason == .missingTag
                || lineage.reason == .invalidTag
                || lineage.reason == .previousConflict
        )
        updated.lastDiagnostic = nil
        return SnapshotHistoryImportDecision(
            envelope: updated,
            entry: candidate,
            lineage: lineage,
            appended: true,
            duplicate: false
        )
    }
}

private extension SnapshotHistoryEnvelope {
    mutating func append(
        entry: SnapshotHistoryEntry,
        lineage: SnapshotLineageResolution
    ) {
        entries.append(entry)
        upsertLineage(
            villageID: entry.villageID,
            entry: entry,
            hasConflict: lineage.reason == .missingTag
                || lineage.reason == .invalidTag
                || lineage.reason == .previousConflict
        )
    }

    mutating func upsertLineage(
        villageID: UUID,
        entry: SnapshotHistoryEntry,
        hasConflict: Bool
    ) {
        for index in lineages.indices where lineages[index].villageID == villageID {
            lineages[index].isActive = false
        }
        if let index = lineages.firstIndex(where: { $0.lineageID == entry.lineageID }) {
            lineages[index] = SnapshotHistoryLineageMetadata(
                villageID: villageID,
                lineageID: entry.lineageID,
                normalizedPlayerTag: entry.normalizedPlayerTag,
                lastEntryID: entry.snapshotID,
                lastFingerprint: entry.canonicalFingerprint,
                lastAppliedAt: entry.appliedAt,
                hasConflict: hasConflict
            )
        } else {
            lineages.append(SnapshotHistoryLineageMetadata(
                villageID: villageID,
                lineageID: entry.lineageID,
                normalizedPlayerTag: entry.normalizedPlayerTag,
                lastEntryID: entry.snapshotID,
                lastFingerprint: entry.canonicalFingerprint,
                lastAppliedAt: entry.appliedAt,
                hasConflict: hasConflict
            ))
        }
    }
}
