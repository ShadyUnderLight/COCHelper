import Foundation
import COCHelperCore

/// Coordinates the legacy village blob and the independent manual-tracker
/// envelope for mutations that change both domains (village creation and
/// deletion).  Manual-only commands are candidate-then-save operations in
/// `AppModel` and do not need to rewrite the villages blob.
struct ManualTrackerTransactionCoordinator {
    let current: any CurrentVillagePersistence
    let manual: any ManualTrackerStore
    let journalURL: URL?

    func recoverIfNeeded() throws {
        guard let journalURL,
              FileManager.default.fileExists(atPath: journalURL.path) else { return }

        let journal: ManualTrackerJournal
        do {
            journal = try JSONDecoder().decode(
                ManualTrackerJournal.self,
                from: Data(contentsOf: journalURL)
            )
        } catch {
            throw ManualTrackerTransactionError.journalCorrupt(error.localizedDescription)
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
        } catch {
            throw ManualTrackerTransactionError.journalCorrupt(error.localizedDescription)
        }

        switch journal.phase {
        case .prepared:
            try restore(journal.previousCurrentData, manualData: journal.previousManualData)
        case .committed:
            do {
                let envelope = try JSONDecoder().decode(
                    ManualTrackerEnvelope.self,
                    from: journal.newManualData
                )
                _ = try envelope.validated()
            } catch {
                throw ManualTrackerTransactionError.journalCorrupt(
                    "事务记录中的新手动状态无效：" + error.localizedDescription
                )
            }
            try current.writeData(journal.newCurrentData)
            try manual.writeRawData(journal.newManualData)
        }

        try FileManager.default.removeItem(at: journalURL)
    }

    func commit(
        currentData: Data,
        envelope: ManualTrackerEnvelope
    ) throws {
        let newManualData = try envelope.encodedData()
        let previousCurrentData = current.readData()
        let previousManualData = try manual.readRawData()
        do {
            try CurrentVillageDataValidator.validate(
                previousCurrentData,
                label: "旧当前村庄数据"
            )
            try CurrentVillageDataValidator.validate(currentData, label: "新当前村庄数据")
        } catch {
            throw ManualTrackerTransactionError.journalCorrupt(error.localizedDescription)
        }

        let prepared = ManualTrackerJournal(
            phase: .prepared,
            previousCurrentData: previousCurrentData,
            newCurrentData: currentData,
            previousManualData: previousManualData,
            newManualData: newManualData
        )
        try writeJournal(prepared)

        do {
            try current.writeData(currentData)
            try manual.writeRawData(newManualData)
        } catch {
            do {
                try restore(previousCurrentData, manualData: previousManualData)
                try removeJournalIfPresent()
            } catch {
                throw ManualTrackerTransactionError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }

        guard journalURL != nil else { return }
        do {
            try writeJournal(ManualTrackerJournal(
                phase: .committed,
                previousCurrentData: previousCurrentData,
                newCurrentData: currentData,
                previousManualData: previousManualData,
                newManualData: newManualData
            ))
        } catch {
            do {
                try restore(previousCurrentData, manualData: previousManualData)
                try removeJournalIfPresent()
            } catch {
                throw ManualTrackerTransactionError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }

        // A valid committed journal is safe to replay.  Cleanup failure must
        // not turn a successful two-store commit into a reported failure.
        try? removeJournalIfPresent()
    }

    private func restore(_ currentData: Data?, manualData: Data?) throws {
        do {
            try CurrentVillageDataValidator.validate(
                currentData,
                label: "待恢复的当前村庄数据"
            )
            try current.restoreData(currentData)
            try manual.restoreRawData(manualData)
        } catch let error as CurrentVillageDataValidationError {
            throw ManualTrackerTransactionError.journalCorrupt(error.localizedDescription)
        } catch {
            throw ManualTrackerTransactionError.rollbackFailed(error.localizedDescription)
        }
    }

    private func writeJournal(_ journal: ManualTrackerJournal) throws {
        guard let journalURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: journalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        } catch {
            throw ManualTrackerTransactionError.journalWriteFailed(error.localizedDescription)
        }
    }

    private func removeJournalIfPresent() throws {
        guard let journalURL,
              FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try FileManager.default.removeItem(at: journalURL)
    }
}

private enum ManualTrackerJournalPhase: String, Codable {
    case prepared
    case committed
}

private struct ManualTrackerJournal: Codable {
    let phase: ManualTrackerJournalPhase
    let previousCurrentData: Data?
    let newCurrentData: Data
    let previousManualData: Data?
    let newManualData: Data
}

enum ManualTrackerTransactionError: Error, LocalizedError, Equatable {
    case rollbackFailed(String)
    case journalCorrupt(String)
    case journalWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .rollbackFailed(let message):
            "手动升级事务回滚失败：" + message
        case .journalCorrupt(let message):
            "手动升级事务记录损坏：" + message
        case .journalWriteFailed(let message):
            "手动升级事务记录写入失败：" + message
        }
    }
}
