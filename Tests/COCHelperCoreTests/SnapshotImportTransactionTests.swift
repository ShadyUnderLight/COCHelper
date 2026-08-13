import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

final class SnapshotImportTransactionTests: XCTestCase {
    private let oldVillage = VillageProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "旧村",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    private let newVillage = VillageProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "新村",
        createdAt: Date(timeIntervalSince1970: 2),
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    private var oldCurrent: Data {
        try! JSONEncoder().encode([oldVillage])
    }
    private var newCurrent: Data {
        try! JSONEncoder().encode([newVillage])
    }
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
        XCTAssertEqual(try history.load(), migratedEnvelope())
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

    func testPreparedJournalWithCorruptCurrentBlobFailsClosed() throws {
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let current = TestCurrentVillagePersistence(data: oldCurrent)
        let history = TestSnapshotHistoryStore()
        history.rawData = oldHistory
        try writeJournal(
            phase: "prepared",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: Data("corrupt-current".utf8),
            previousHistoryData: oldHistory,
            newHistoryData: newHistory
        )
        let coordinator = SnapshotImportTransactionCoordinator(
            current: current,
            history: history,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.recoverIfNeeded()) { error in
            guard case .journalCorrupt = error as? SnapshotImportTransactionError else {
                return XCTFail("prepared journal 的损坏 currentData 必须 fail closed：\(error)")
            }
        }
        XCTAssertEqual(current.data, oldCurrent)
        XCTAssertEqual(history.rawData, oldHistory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testCommittedJournalWithCorruptCurrentBlobFailsClosed() throws {
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let current = TestCurrentVillagePersistence(data: oldCurrent)
        let history = TestSnapshotHistoryStore()
        history.rawData = oldHistory
        try writeJournal(
            phase: "committed",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: Data("corrupt-current".utf8),
            previousHistoryData: oldHistory,
            newHistoryData: newHistory
        )
        let coordinator = SnapshotImportTransactionCoordinator(
            current: current,
            history: history,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.recoverIfNeeded()) { error in
            guard case .journalCorrupt = error as? SnapshotImportTransactionError else {
                return XCTFail("committed journal 的损坏 currentData 必须 fail closed：\(error)")
            }
        }
        XCTAssertEqual(current.data, oldCurrent)
        XCTAssertEqual(history.rawData, oldHistory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testManualIncludedWithoutPayloadFailsClosedBeforeCurrentRestore() throws {
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let current = TestCurrentVillagePersistence(data: newCurrent)
        let history = TestSnapshotHistoryStore()
        history.rawData = newHistory
        try writeJournal(
            phase: "prepared",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: newCurrent,
            previousHistoryData: oldHistory,
            newHistoryData: newHistory,
            manualIncluded: true
        )
        let coordinator = SnapshotImportTransactionCoordinator(
            current: current,
            history: history,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.recoverIfNeeded()) { error in
            guard case .journalCorrupt = error as? SnapshotImportTransactionError else {
                return XCTFail("缺少手动 payload 的 journal 必须被拒绝：\(error)")
            }
        }
        XCTAssertEqual(current.data, newCurrent)
        XCTAssertEqual(history.rawData, newHistory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    private func writeJournal(
        phase: String,
        to url: URL,
        previousCurrentData: Data?,
        newCurrentData: Data,
        previousHistoryData: Data?,
        newHistoryData: Data,
        manualIncluded: Bool? = nil,
        newManualData: Data? = nil
    ) throws {
        struct JournalFixture: Codable {
            let phase: String
            let previousCurrentData: Data?
            let newCurrentData: Data
            let previousHistoryData: Data?
            let newHistoryData: Data
            let manualIncluded: Bool?
            let newManualData: Data?
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
            newHistoryData: newHistoryData,
            manualIncluded: manualIncluded,
            newManualData: newManualData
        ))
        try data.write(to: url, options: .atomic)
    }
}
