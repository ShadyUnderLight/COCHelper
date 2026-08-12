import Foundation
import COCHelperCore

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
    }

    func restoreData(_ data: Data?) throws {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
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
    let newManualData: Data?

    init(
        phase: SnapshotImportJournalPhase,
        previousCurrentData: Data?,
        newCurrentData: Data,
        previousHistoryData: Data?,
        newHistoryData: Data,
        previousManualData: Data? = nil,
        newManualData: Data? = nil
    ) {
        self.phase = phase
        self.previousCurrentData = previousCurrentData
        self.newCurrentData = newCurrentData
        self.previousHistoryData = previousHistoryData
        self.newHistoryData = newHistoryData
        self.previousManualData = previousManualData
        self.newManualData = newManualData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            phase: try container.decode(SnapshotImportJournalPhase.self, forKey: .phase),
            previousCurrentData: try container.decodeIfPresent(Data.self, forKey: .previousCurrentData),
            newCurrentData: try container.decode(Data.self, forKey: .newCurrentData),
            previousHistoryData: try container.decodeIfPresent(Data.self, forKey: .previousHistoryData),
            newHistoryData: try container.decode(Data.self, forKey: .newHistoryData),
            previousManualData: try container.decodeIfPresent(Data.self, forKey: .previousManualData),
            newManualData: try container.decodeIfPresent(Data.self, forKey: .newManualData)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case phase
        case previousCurrentData
        case newCurrentData
        case previousHistoryData
        case newHistoryData
        case previousManualData
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

        switch journal.phase {
        case .prepared:
            try current.restoreData(journal.previousCurrentData)
            try history.restoreRawData(journal.previousHistoryData)
            if journal.newManualData != nil {
                guard let manual else {
                    throw SnapshotImportTransactionError.journalCorrupt(
                        "事务记录包含手动状态，但当前未配置手动存储。"
                    )
                }
                try manual.restoreRawData(journal.previousManualData)
            }
        case .committed:
            do {
                let envelope = try JSONDecoder().decode(
                    SnapshotHistoryEnvelope.self,
                    from: journal.newHistoryData
                )
                _ = try envelope.validated()
            } catch {
                throw SnapshotImportTransactionError.journalCorrupt(
                    "事务记录中的新历史无效：" + error.localizedDescription
                )
            }
            if let newManualData = journal.newManualData {
                guard manual != nil else {
                    throw SnapshotImportTransactionError.journalCorrupt(
                        "事务记录包含手动状态，但当前未配置手动存储。"
                    )
                }
                do {
                    let envelope = try JSONDecoder().decode(
                        ManualTrackerEnvelope.self,
                        from: newManualData
                    )
                    _ = try envelope.validated()
                } catch {
                    throw SnapshotImportTransactionError.journalCorrupt(
                        "事务记录中的新手动状态无效：" + error.localizedDescription
                    )
                }
            }
            try current.writeData(journal.newCurrentData)
            try history.writeRawData(journal.newHistoryData)
            if let newManualData = journal.newManualData {
                try manual?.writeRawData(newManualData)
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

        let journal = SnapshotImportJournal(
            phase: .prepared,
            previousCurrentData: previousCurrentData,
            newCurrentData: currentData,
            previousHistoryData: previousHistoryData,
            newHistoryData: newHistoryData,
            previousManualData: previousManualData,
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
