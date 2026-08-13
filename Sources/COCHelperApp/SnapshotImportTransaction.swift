import Foundation
import COCHelperCore

enum CurrentVillageDataValidationError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            message
        }
    }
}

enum CurrentVillageDataValidator {
    /// Validates the persisted villages blob before a transaction can restore
    /// or replay it.  A legal empty array is distinct from a missing store and
    /// must not be turned into a decode failure.
    static func validate(_ data: Data?, label: String) throws {
        do {
            try VillageStoreCodec.validate(data, label: label)
            guard let data else { return }
            let villages = try JSONDecoder().decode([VillageProfile].self, from: data)
            guard Set(villages.map(\.id)).count == villages.count else {
                throw CurrentVillageDataValidationError.invalid(
                    "\(label) 包含重复的村庄 ID。"
                )
            }
        } catch let error as CurrentVillageDataValidationError {
            throw error
        } catch {
            if let localized = error as? LocalizedError,
               let description = localized.errorDescription {
                throw CurrentVillageDataValidationError.invalid(description)
            }
            throw CurrentVillageDataValidationError.invalid(error.localizedDescription)
        }
    }
}

enum SnapshotHistoryDataValidator {
    static func validate(_ data: Data?, label: String) throws {
        guard let data else { return }
        do {
            let envelope = try JSONDecoder().decode(SnapshotHistoryEnvelope.self, from: data)
            _ = try envelope.validated()
        } catch {
            throw SnapshotImportTransactionError.journalCorrupt(
                "\(label) 无效：\(error.localizedDescription)"
            )
        }
    }
}

enum ManualTrackerDataValidator {
    static func validate(_ data: Data?, label: String) throws {
        guard let data else { return }
        do {
            let envelope = try JSONDecoder().decode(ManualTrackerEnvelope.self, from: data)
            _ = try envelope.validated()
        } catch {
            throw SnapshotImportTransactionError.journalCorrupt(
                "\(label) 无效：\(error.localizedDescription)"
            )
        }
    }
}

/// The current village blob is kept behind a tiny injectable adapter so the
/// import transaction can test partial writes without coupling Core to
/// UserDefaults.
protocol CurrentVillagePersistence {
    func readData() -> Data?
    func writeData(_ data: Data) throws
    func restoreData(_ data: Data?) throws
}

struct UserDefaultsCurrentVillagePersistence: CurrentVillagePersistence {
    let defaults: UserDefaults
    let key: String

    func readData() -> Data? {
        defaults.data(forKey: key)
    }

    func writeData(_ data: Data) throws {
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw VillageStoreError.writeFailed("写入后读回的村庄数据与候选数据不一致。")
        }
    }

    func restoreData(_ data: Data?) throws {
        if let data {
            defaults.set(data, forKey: key)
            guard defaults.data(forKey: key) == data else {
                throw VillageStoreError.writeFailed("恢复后读回的村庄数据与原始数据不一致。")
            }
        } else {
            defaults.removeObject(forKey: key)
            guard defaults.data(forKey: key) == nil else {
                throw VillageStoreError.writeFailed("删除村庄数据后仍能读到旧数据。")
            }
        }
    }
}

private enum SnapshotImportJournalPhase: String, Codable {
    case prepared
    case committed
}

private struct SnapshotImportJournal: Codable {
    let phase: SnapshotImportJournalPhase
    let previousCurrentData: Data?
    let newCurrentData: Data
    let previousHistoryData: Data?
    let newHistoryData: Data
    let previousManualData: Data?
    /// Explicitly distinguishes "no manual transaction" from a journal that
    /// claims to include one but lost its payload.
    let manualIncluded: Bool
    let newManualData: Data?

    init(
        phase: SnapshotImportJournalPhase,
        previousCurrentData: Data?,
        newCurrentData: Data,
        previousHistoryData: Data?,
        newHistoryData: Data,
        previousManualData: Data? = nil,
        manualIncluded: Bool = false,
        newManualData: Data? = nil
    ) {
        self.phase = phase
        self.previousCurrentData = previousCurrentData
        self.newCurrentData = newCurrentData
        self.previousHistoryData = previousHistoryData
        self.newHistoryData = newHistoryData
        self.previousManualData = previousManualData
        self.manualIncluded = manualIncluded
        self.newManualData = newManualData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let newManualData = try container.decodeIfPresent(Data.self, forKey: .newManualData)
        self.init(
            phase: try container.decode(SnapshotImportJournalPhase.self, forKey: .phase),
            previousCurrentData: try container.decodeIfPresent(Data.self, forKey: .previousCurrentData),
            newCurrentData: try container.decode(Data.self, forKey: .newCurrentData),
            previousHistoryData: try container.decodeIfPresent(Data.self, forKey: .previousHistoryData),
            newHistoryData: try container.decode(Data.self, forKey: .newHistoryData),
            previousManualData: try container.decodeIfPresent(Data.self, forKey: .previousManualData),
            manualIncluded: try container.decodeIfPresent(Bool.self, forKey: .manualIncluded)
                ?? (newManualData != nil),
            newManualData: newManualData
        )
    }

    private enum CodingKeys: String, CodingKey {
        case phase
        case previousCurrentData
        case newCurrentData
        case previousHistoryData
        case newHistoryData
        case previousManualData
        case manualIncluded
        case newManualData
    }
}

enum SnapshotImportTransactionError: Error, LocalizedError, Equatable {
    case rollbackFailed(String)
    case journalCorrupt(String)

    var errorDescription: String? {
        switch self {
        case .rollbackFailed(let message):
            "导入事务回滚失败：" + message
        case .journalCorrupt(let message):
            "导入事务记录损坏：" + message
        }
    }
}

/// Coordinates the legacy UserDefaults blob and the standalone history file.
/// The journal makes an interrupted process recover to either the previous
/// state or the complete new state; a normal error is rolled back in-process.
struct SnapshotImportTransactionCoordinator {
    let current: any CurrentVillagePersistence
    let history: any SnapshotHistoryStore
    let journalURL: URL?
    let manual: (any ManualTrackerStore)?

    init(
        current: any CurrentVillagePersistence,
        history: any SnapshotHistoryStore,
        journalURL: URL?,
        manual: (any ManualTrackerStore)? = nil
    ) {
        self.current = current
        self.history = history
        self.journalURL = journalURL
        self.manual = manual
    }

    func recoverIfNeeded() throws {
        guard let journalURL,
              FileManager.default.fileExists(atPath: journalURL.path) else { return }

        let journal: SnapshotImportJournal
        do {
            let data = try Data(contentsOf: journalURL)
            journal = try JSONDecoder().decode(SnapshotImportJournal.self, from: data)
        } catch {
            throw SnapshotImportTransactionError.journalCorrupt(error.localizedDescription)
        }

        guard journal.manualIncluded == (journal.newManualData != nil) else {
            throw SnapshotImportTransactionError.journalCorrupt(
                "事务记录的 manualIncluded 与手动状态 payload 不一致。"
            )
        }
        guard journal.manualIncluded || journal.previousManualData == nil else {
            throw SnapshotImportTransactionError.journalCorrupt(
                "无 manual 事务的记录不应包含 previousManualData。"
            )
        }
        do {
            try CurrentVillageDataValidator.validate(
                journal.previousCurrentData,
                label: "事务记录中的旧当前村庄数据"
            )
            try CurrentVillageDataValidator.validate(
                journal.newCurrentData,
                label: "事务记录中的新当前村庄数据"
            )
            try SnapshotHistoryDataValidator.validate(
                journal.previousHistoryData,
                label: "事务记录中的旧历史"
            )
            try SnapshotHistoryDataValidator.validate(
                journal.newHistoryData,
                label: "事务记录中的新历史"
            )
        } catch {
            if let transactionError = error as? SnapshotImportTransactionError {
                throw transactionError
            }
            throw SnapshotImportTransactionError.journalCorrupt(error.localizedDescription)
        }

        let recoveryManualStore: (any ManualTrackerStore)?
        let recoveryManualData: Data?
        if journal.manualIncluded {
            guard let manual else {
                throw SnapshotImportTransactionError.journalCorrupt(
                    "事务记录包含手动状态，但当前未配置手动存储。"
                )
            }
            guard let newManualData = journal.newManualData else {
                throw SnapshotImportTransactionError.journalCorrupt(
                    "事务记录声明包含手动状态，但缺少 newManualData。"
                )
            }
            try ManualTrackerDataValidator.validate(
                journal.previousManualData,
                label: "事务记录中的旧手动状态"
            )
            try ManualTrackerDataValidator.validate(
                newManualData,
                label: "事务记录中的新手动状态"
            )
            recoveryManualStore = manual
            recoveryManualData = newManualData
        } else {
            recoveryManualStore = nil
            recoveryManualData = nil
        }

        switch journal.phase {
        case .prepared:
            try current.restoreData(journal.previousCurrentData)
            try history.restoreRawData(journal.previousHistoryData)
            if let recoveryManualStore {
                try recoveryManualStore.restoreRawData(journal.previousManualData)
            }
        case .committed:
            try current.writeData(journal.newCurrentData)
            try history.writeRawData(journal.newHistoryData)
            if let recoveryManualStore, let recoveryManualData {
                try recoveryManualStore.writeRawData(recoveryManualData)
            }
        }
        try FileManager.default.removeItem(at: journalURL)
    }

    func commit(
        currentData: Data,
        envelope: SnapshotHistoryEnvelope,
        manualEnvelope: ManualTrackerEnvelope? = nil
    ) throws {
        let newHistoryData = try envelope.encodedData()
        guard let existingHistory = try history.load(), existingHistory.isMigrated else {
            throw SnapshotHistoryStoreError.unavailable("导入前未找到可用的已迁移历史。")
        }
        let previousCurrentData = current.readData()
        let previousHistoryData = try history.readRawData()
        guard manualEnvelope == nil || manual != nil else {
            throw SnapshotImportTransactionError.journalCorrupt(
                "提交手动状态时未配置手动存储。"
            )
        }
        let previousManualData: Data?
        if manualEnvelope != nil {
            previousManualData = try manual?.readRawData()
        } else {
            previousManualData = nil
        }
        let newManualData = try manualEnvelope?.encodedData()
        do {
            try CurrentVillageDataValidator.validate(
                previousCurrentData,
                label: "旧当前村庄数据"
            )
            try CurrentVillageDataValidator.validate(currentData, label: "新当前村庄数据")
            try SnapshotHistoryDataValidator.validate(
                previousHistoryData,
                label: "旧历史"
            )
            try SnapshotHistoryDataValidator.validate(newHistoryData, label: "新历史")
            if manualEnvelope != nil {
                try ManualTrackerDataValidator.validate(
                    previousManualData,
                    label: "旧手动状态"
                )
                try ManualTrackerDataValidator.validate(newManualData, label: "新手动状态")
            }
        } catch {
            if let transactionError = error as? SnapshotImportTransactionError {
                throw transactionError
            }
            throw SnapshotImportTransactionError.journalCorrupt(error.localizedDescription)
        }

        let journal = SnapshotImportJournal(
            phase: .prepared,
            previousCurrentData: previousCurrentData,
            newCurrentData: currentData,
            previousHistoryData: previousHistoryData,
            newHistoryData: newHistoryData,
            previousManualData: previousManualData,
            manualIncluded: manualEnvelope != nil,
            newManualData: newManualData
        )
        try writeJournal(journal)

        do {
            try current.writeData(currentData)
            try history.writeRawData(newHistoryData)
            if let newManualData {
                try manual?.writeRawData(newManualData)
            }
        } catch {
            do {
                try current.restoreData(previousCurrentData)
                try history.restoreRawData(previousHistoryData)
                if newManualData != nil {
                    try manual?.restoreRawData(previousManualData)
                }
                try removeJournalIfPresent()
            } catch {
                throw SnapshotImportTransactionError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }

        guard journalURL != nil else { return }
        do {
            try writeJournal(SnapshotImportJournal(
                phase: .committed,
                previousCurrentData: previousCurrentData,
                newCurrentData: currentData,
                previousHistoryData: previousHistoryData,
                newHistoryData: newHistoryData,
                previousManualData: previousManualData,
                manualIncluded: manualEnvelope != nil,
                newManualData: newManualData
            ))
        } catch {
            do {
                try current.restoreData(previousCurrentData)
                try history.restoreRawData(previousHistoryData)
                if newManualData != nil {
                    try manual?.restoreRawData(previousManualData)
                }
                try removeJournalIfPresent()
            } catch {
                throw SnapshotImportTransactionError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }

        // The committed journal is itself a valid recovery record.  If only
        // cleanup fails, keep the new state and let the next launch replay it
        // idempotently rather than reporting a false import failure.
        try? removeJournalIfPresent()
    }

    private func writeJournal(_ journal: SnapshotImportJournal) throws {
        guard let journalURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: journalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(journal)
            try data.write(to: journalURL, options: .atomic)
        } catch {
            throw SnapshotImportTransactionError.journalCorrupt(error.localizedDescription)
        }
    }

    private func removeJournalIfPresent() throws {
        guard let journalURL,
              FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try FileManager.default.removeItem(at: journalURL)
    }
}
