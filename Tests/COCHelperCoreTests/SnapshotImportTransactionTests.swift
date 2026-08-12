import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

final class SnapshotImportTransactionTests: XCTestCase {
    private let oldCurrent = Data("old-current".utf8)
    private let newCurrent = Data("new-current".utf8)
    private let oldHistory = Data("old-history".utf8)
    private var newHistory: Data {
        (try? migratedEnvelope().encodedData()) ?? Data()
    }

    private func migratedEnvelope() -> SnapshotHistoryEnvelope {
        SnapshotHistoryEnvelope(
            migrationMarker: SnapshotHistoryMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )
    }

    private func makeJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-SnapshotImportTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("transaction.json")
    }

    func testCommitUpdatesCurrentAndHistoryAndRemovesJournal() throws {
        let current = TestCurrentVillagePersistence(data: oldCurrent)
        let history = TestSnapshotHistoryStore()
        history.rawData = try migratedEnvelope().encodedData()
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let coordinator = SnapshotImportTransactionCoordinator(
            current: current,
            history: history,
            journalURL: journalURL
        )

        try coordinator.commit(currentData: newCurrent, envelope: migratedEnvelope())

        XCTAssertEqual(current.data, newCurrent)
        XCTAssertEqual(try history.load(), migratedEnvelope())
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testCurrentWriteFailureRestoresBothStores() throws {
        let current = TestCurrentVillagePersistence(data: oldCurrent)
        current.failWrite = true
        current.writeBeforeFailure = true
        let history = TestSnapshotHistoryStore()
        history.rawData = try migratedEnvelope().encodedData()
        let previousHistory = history.rawData
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let coordinator = SnapshotImportTransactionCoordinator(
            current: current,
            history: history,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.commit(currentData: newCurrent, envelope: migratedEnvelope()))
        XCTAssertEqual(current.data, oldCurrent)
        XCTAssertEqual(history.rawData, previousHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testHistoryWriteFailureAfterCurrentWriteRestoresBothStores() throws {
        let current = TestCurrentVillagePersistence(data: oldCurrent)
        let history = TestSnapshotHistoryStore()
        history.rawData = try migratedEnvelope().encodedData()
        let previousHistory = history.rawData
        history.failWrite = true
        history.writeBeforeFailure = true
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let coordinator = SnapshotImportTransactionCoordinator(
            current: current,
            history: history,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.commit(currentData: newCurrent, envelope: migratedEnvelope()))
        XCTAssertEqual(current.data, oldCurrent)
        XCTAssertEqual(history.rawData, previousHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testCorruptExistingHistoryStopsBeforeCurrentWrite() throws {
        let current = TestCurrentVillagePersistence(data: oldCurrent)
        let history = TestSnapshotHistoryStore()
        let corrupt = Data("not-json".utf8)
        history.rawData = corrupt
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let coordinator = SnapshotImportTransactionCoordinator(
            current: current,
            history: history,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.commit(currentData: newCurrent, envelope: migratedEnvelope()))
        XCTAssertEqual(current.data, oldCurrent)
        XCTAssertEqual(history.rawData, corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRecoveryRollsPreparedJournalBackAndCompletesCommittedJournal() throws {
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let current = TestCurrentVillagePersistence(data: newCurrent)
        let history = TestSnapshotHistoryStore()
        history.rawData = newHistory
        let coordinator = SnapshotImportTransactionCoordinator(
            current: current,
            history: history,
            journalURL: journalURL
        )

        try writeJournal(
            phase: "prepared",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: newCurrent,
            previousHistoryData: oldHistory,
            newHistoryData: newHistory
        )
        try coordinator.recoverIfNeeded()
        XCTAssertEqual(current.data, oldCurrent)
        XCTAssertEqual(history.rawData, oldHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        try writeJournal(
            phase: "committed",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: newCurrent,
            previousHistoryData: oldHistory,
            newHistoryData: newHistory
        )
        try coordinator.recoverIfNeeded()
        XCTAssertEqual(current.data, newCurrent)
        XCTAssertEqual(history.rawData, newHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testCorruptJournalStopsStartupRecoveryWithoutDeletingEvidence() throws {
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: journalURL, options: .atomic)
        let coordinator = SnapshotImportTransactionCoordinator(
            current: TestCurrentVillagePersistence(data: oldCurrent),
            history: TestSnapshotHistoryStore(),
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.recoverIfNeeded()) { error in
            guard case .journalCorrupt = error as? SnapshotImportTransactionError else {
                return XCTFail("损坏事务记录应被拒绝，实际为 \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: journalURL), corrupt)
    }

    private func writeJournal(
        phase: String,
        to url: URL,
        previousCurrentData: Data?,
        newCurrentData: Data,
        previousHistoryData: Data?,
        newHistoryData: Data
    ) throws {
        struct JournalFixture: Codable {
            let phase: String
            let previousCurrentData: Data?
            let newCurrentData: Data
            let previousHistoryData: Data?
            let newHistoryData: Data
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(JournalFixture(
            phase: phase,
            previousCurrentData: previousCurrentData,
            newCurrentData: newCurrentData,
            previousHistoryData: previousHistoryData,
            newHistoryData: newHistoryData
        ))
        try data.write(to: url, options: .atomic)
    }
}
