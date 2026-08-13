import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

final class VillageStoreTests: XCTestCase {
    private final class CountingManualStore: ManualTrackerStore, @unchecked Sendable {
        var transactionJournalURL: URL?
        var rawData: Data?
        var writeCount = 0
        var restoreCount = 0

        func load() throws -> ManualTrackerEnvelope? {
            guard let rawData else { return nil }
            do {
                return try JSONDecoder()
                    .decode(ManualTrackerEnvelope.self, from: rawData)
                    .validated()
            } catch let error as ManualTrackerStoreError {
                throw error
            } catch {
                throw ManualTrackerStoreError.corrupt(error.localizedDescription)
            }
        }

        func save(_ envelope: ManualTrackerEnvelope) throws {
            try writeRawData(envelope.encodedData())
        }

        func readRawData() throws -> Data? { rawData }

        func writeRawData(_ data: Data) throws {
            writeCount += 1
            rawData = data
        }

        func restoreRawData(_ data: Data?) throws {
            restoreCount += 1
            rawData = data
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "VillageStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func stores(
        currentData: Data,
        history: TestSnapshotHistoryStore = TestSnapshotHistoryStore()
    ) -> (TestCurrentVillagePersistence, TestSnapshotHistoryStore, CountingManualStore) {
        let current = TestCurrentVillagePersistence(data: currentData)
        let manual = CountingManualStore()
        return (current, history, manual)
    }

    private func validVillagesData(_ villages: [VillageProfile] = [VillageProfile(name: "主村")]) throws -> Data {
        try JSONEncoder().encode(villages)
    }

    private func migratedHistoryData(completedAt: TimeInterval) throws -> Data {
        try SnapshotHistoryEnvelope(
            migrationMarker: SnapshotHistoryMigrationMarker(
                completedAt: Date(timeIntervalSince1970: completedAt)
            )
        ).encodedData()
    }

    private func makeTransactionJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-VillageRecovery-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("transaction.json")
    }

    private func writeSnapshotImportJournal(
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
            let previousManualData: Data?
            let manualIncluded: Bool?
            let newManualData: Data?
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(JournalFixture(
            phase: phase,
            previousCurrentData: previousCurrentData,
            newCurrentData: newCurrentData,
            previousHistoryData: previousHistoryData,
            newHistoryData: newHistoryData,
            previousManualData: nil,
            manualIncluded: false,
            newManualData: nil
        )).write(to: url, options: .atomic)
    }

    @MainActor
    private func makeModel(
        current: TestCurrentVillagePersistence,
        history: TestSnapshotHistoryStore,
        manual: CountingManualStore
    ) -> AppModel {
        AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: manual,
            currentVillagePersistence: current
        )
    }

    func testLoadResultDistinguishesMissingEmptyCorruptAndFutureSchema() throws {
        if case .missing = VillageStoreCodec.load(nil) {
            // expected
        } else {
            XCTFail("缺失 key 必须是 missing")
        }

        let empty = try validVillagesData([])
        if case .loaded(let villages) = VillageStoreCodec.load(empty) {
            XCTAssertTrue(villages.isEmpty)
        } else {
            XCTFail("合法空数组必须是 loaded([])")
        }

        let corrupt = Data("{\"villages\":".utf8)
        if case .corrupt(let rawData, _) = VillageStoreCodec.load(corrupt) {
            XCTAssertEqual(rawData, corrupt)
        } else {
            XCTFail("截断 JSON 必须是 corrupt")
        }

        let duplicateVillage = VillageProfile(name: "重复")
        let duplicate = try validVillagesData([duplicateVillage, duplicateVillage])
        if case .corrupt = VillageStoreCodec.load(duplicate) {
            // expected
        } else {
            XCTFail("重复村庄 ID 必须是 corrupt")
        }

        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": VillageStoreSchema.current + 1,
            "villages": [],
        ])
        if case .unsupportedSchema(let rawData, let version) = VillageStoreCodec.load(future) {
            XCTAssertEqual(rawData, future)
            XCTAssertEqual(version, VillageStoreSchema.current + 1)
        } else {
            XCTFail("未来 schema 必须是 unsupportedSchema")
        }
    }

    @MainActor
    func testCorruptStartupPreservesBytesAndDoesNotInitializeDerivedStores() {
        let corrupt = Data("not-json".utf8)
        let (current, history, manual) = stores(currentData: corrupt)
        let model = makeModel(current: current, history: history, manual: manual)

        XCTAssertEqual(model.villageStoreStatus, .corrupt)
        XCTAssertEqual(model.villageStoreRecoveryDataForExport, corrupt)
        XCTAssertTrue(model.isVillageStoreRecoveryRequired)
        XCTAssertEqual(current.writeCount, 0)
        XCTAssertEqual(history.writeCount, 0)
        XCTAssertEqual(manual.writeCount, 0)
        XCTAssertEqual(model.manualTrackerStatus, .unavailable)
    }

    @MainActor
    func testFutureSchemaStartupPreservesBytesAndDoesNotInitializeDerivedStores() throws {
        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": VillageStoreSchema.current + 10,
            "villages": [],
        ])
        let (current, history, manual) = stores(currentData: future)
        let model = makeModel(current: current, history: history, manual: manual)

        XCTAssertEqual(model.villageStoreStatus, .unsupported)
        XCTAssertEqual(model.villageStoreRecoveryDataForExport, future)
        XCTAssertEqual(current.writeCount, 0)
        XCTAssertEqual(history.writeCount, 0)
        XCTAssertEqual(manual.writeCount, 0)
    }

    @MainActor
    func testLegalEmptyStoreIsCanonicalizedWithoutLegacyMigration() throws {
        let empty = try validVillagesData([])
        let current = TestCurrentVillagePersistence(data: empty)
        let history = TestSnapshotHistoryStore()
        let manual = CountingManualStore()
        let legacy = AccountSnapshot(
            tag: "#LEGACY",
            capturedAt: nil,
            importedAt: Date(timeIntervalSince1970: 1),
            ageSeconds: nil,
            originalText: "legacy",
            objectSections: [:],
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: "coc-helper.account-snapshot.v1")

        let model = makeModel(current: current, history: history, manual: manual)

        XCTAssertEqual(model.villageStoreStatus, .available)
        XCTAssertEqual(model.villages.count, 1)
        XCTAssertNil(model.villages[0].accountSnapshot)
        XCTAssertNotEqual(model.villages[0].name, "#LEGACY")
        XCTAssertEqual(current.writeCount, 1)
    }

    @MainActor
    func testRestoreValidDataReplacesCorruptStateAndReopensNormalModel() throws {
        let corrupt = Data("not-json".utf8)
        let (current, history, manual) = stores(currentData: corrupt)
        let model = makeModel(current: current, history: history, manual: manual)
        let restored = try validVillagesData([
            VillageProfile(name: "恢复村庄"),
            VillageProfile(name: "第二村庄"),
        ])

        XCTAssertTrue(model.restoreVillageStore(from: restored))
        XCTAssertEqual(model.villageStoreStatus, .available)
        XCTAssertFalse(model.isVillageStoreRecoveryRequired)
        XCTAssertEqual(current.data, restored)
        XCTAssertEqual(model.villages.map(\.name), ["恢复村庄", "第二村庄"])
        XCTAssertNil(model.villageStoreRecoveryDataForExport)
        XCTAssertGreaterThanOrEqual(history.writeCount, 1)
        XCTAssertGreaterThanOrEqual(manual.writeCount, 1)
    }

    @MainActor
    func testCorruptStartupCanExplicitlyRecoverCommittedTransactionJournal() throws {
        let corrupt = Data("not-json".utf8)
        let oldVillages = [VillageProfile(name: "事务旧村")]
        let journalVillages = [VillageProfile(name: "事务新村")]
        let oldCurrent = try validVillagesData(oldVillages)
        let journalCurrent = try validVillagesData(journalVillages)
        let oldHistory = try migratedHistoryData(completedAt: 1)
        let journalHistory = try migratedHistoryData(completedAt: 2)
        let journalURL = makeTransactionJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        try writeSnapshotImportJournal(
            phase: "committed",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: journalCurrent,
            previousHistoryData: oldHistory,
            newHistoryData: journalHistory
        )

        let current = TestCurrentVillagePersistence(data: corrupt)
        let history = TestSnapshotHistoryStore(
            envelope: try JSONDecoder().decode(SnapshotHistoryEnvelope.self, from: oldHistory),
            transactionJournalURL: journalURL
        )
        let manual = CountingManualStore()
        let model = makeModel(current: current, history: history, manual: manual)

        XCTAssertTrue(model.isVillageStoreRecoveryRequired)
        XCTAssertTrue(model.hasPendingVillageTransactionJournal)
        XCTAssertTrue(model.recoverVillageStoreFromTransactionJournal())
        XCTAssertEqual(current.data, journalCurrent)
        XCTAssertEqual(model.villages.map(\.name), ["事务新村"])
        XCTAssertEqual(model.villageStoreStatus, .available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertFalse(model.hasPendingVillageTransactionJournal)

        let restarted = makeModel(current: current, history: history, manual: manual)
        XCTAssertEqual(restarted.villageStoreStatus, .available)
        XCTAssertEqual(restarted.villages.map(\.name), ["事务新村"])
        XCTAssertEqual(current.data, journalCurrent)
    }

    @MainActor
    func testRestoreQuarantinesPendingJournalSoRestartCannotReplayIt() throws {
        let corrupt = Data("not-json".utf8)
        let oldCurrent = try validVillagesData([VillageProfile(name: "旧村")])
        let journalCurrent = try validVillagesData([VillageProfile(name: "旧 journal 村")])
        let oldHistory = try migratedHistoryData(completedAt: 1)
        let journalHistory = try migratedHistoryData(completedAt: 2)
        let journalURL = makeTransactionJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        try writeSnapshotImportJournal(
            phase: "committed",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: journalCurrent,
            previousHistoryData: oldHistory,
            newHistoryData: journalHistory
        )
        let journalData = try Data(contentsOf: journalURL)

        let current = TestCurrentVillagePersistence(data: corrupt)
        let history = TestSnapshotHistoryStore(
            envelope: try JSONDecoder().decode(SnapshotHistoryEnvelope.self, from: oldHistory),
            transactionJournalURL: journalURL
        )
        let manual = CountingManualStore()
        let model = makeModel(current: current, history: history, manual: manual)
        let selectedRestore = try validVillagesData([VillageProfile(name: "用户恢复村")])

        XCTAssertTrue(model.restoreVillageStore(from: selectedRestore))
        XCTAssertEqual(current.data, selectedRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(
            try Data(contentsOf: journalURL.appendingPathExtension("quarantined")),
            journalData
        )

        let restarted = makeModel(current: current, history: history, manual: manual)
        XCTAssertEqual(restarted.villageStoreStatus, .available)
        XCTAssertEqual(restarted.villages.map(\.name), ["用户恢复村"])
        XCTAssertEqual(current.data, selectedRestore)
    }

    @MainActor
    func testResetQuarantinesCorruptPendingJournalAndRestartStaysAvailable() throws {
        let corrupt = Data("not-json".utf8)
        let journalURL = makeTransactionJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corruptJournal = Data("corrupt-transaction-journal".utf8)
        try corruptJournal.write(to: journalURL, options: .atomic)

        let current = TestCurrentVillagePersistence(data: corrupt)
        let history = TestSnapshotHistoryStore(
            envelope: SnapshotHistoryEnvelope(
                migrationMarker: SnapshotHistoryMigrationMarker(
                    completedAt: Date(timeIntervalSince1970: 1)
                )
            ),
            transactionJournalURL: journalURL
        )
        let manual = CountingManualStore()
        let model = makeModel(current: current, history: history, manual: manual)

        XCTAssertTrue(model.resetVillageStore())
        XCTAssertEqual(model.villageStoreStatus, .available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(
            try Data(contentsOf: journalURL.appendingPathExtension("quarantined")),
            corruptJournal
        )

        let restarted = makeModel(current: current, history: history, manual: manual)
        XCTAssertEqual(restarted.villageStoreStatus, .available)
        XCTAssertEqual(restarted.villages.count, 1)
        XCTAssertEqual(restarted.villages[0].name, "我的村庄")
        XCTAssertEqual(current.data, try validVillagesData(restarted.villages))
    }

    @MainActor
    func testInvalidRestorePreservesCurrentBytesWithoutWriting() throws {
        let corrupt = Data("not-json".utf8)
        let (current, history, manual) = stores(currentData: corrupt)
        let model = makeModel(current: current, history: history, manual: manual)
        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": VillageStoreSchema.current + 1,
            "villages": [],
        ])

        XCTAssertFalse(model.restoreVillageStore(from: Data("also-not-json".utf8)))
        XCTAssertFalse(model.restoreVillageStore(from: future))
        XCTAssertEqual(current.data, corrupt)
        XCTAssertEqual(current.writeCount, 0)
        XCTAssertEqual(model.villageStoreStatus, .corrupt)
    }

    @MainActor
    func testDuplicateRestoreIsRejectedWithoutWriting() throws {
        let corrupt = Data("not-json".utf8)
        let (current, history, manual) = stores(currentData: corrupt)
        let model = makeModel(current: current, history: history, manual: manual)
        let duplicateVillage = VillageProfile(name: "重复")
        let duplicate = try validVillagesData([duplicateVillage, duplicateVillage])

        XCTAssertFalse(model.restoreVillageStore(from: duplicate))
        XCTAssertEqual(current.data, corrupt)
        XCTAssertEqual(current.writeCount, 0)
        XCTAssertEqual(model.villageStoreStatus, .corrupt)
    }

    @MainActor
    func testResetKeepsCorruptBytesInRecoveryCopy() {
        let corrupt = Data("not-json".utf8)
        let (current, history, manual) = stores(currentData: corrupt)
        let model = makeModel(current: current, history: history, manual: manual)

        XCTAssertTrue(model.resetVillageStore())
        XCTAssertEqual(model.villageStoreStatus, .available)
        XCTAssertEqual(model.villages.count, 1)
        XCTAssertEqual(defaults.data(forKey: "coc-helper.villages.v1.recovery"), corrupt)
        XCTAssertNotEqual(current.data, corrupt)
    }

    @MainActor
    func testResetIsGuardedWhenStoreIsHealthy() throws {
        let original = try validVillagesData()
        let (current, history, manual) = stores(currentData: original)
        let model = makeModel(current: current, history: history, manual: manual)

        XCTAssertFalse(model.resetVillageStore())
        XCTAssertEqual(current.data, original)
        XCTAssertEqual(current.writeCount, 0)
        XCTAssertNil(defaults.data(forKey: "coc-helper.villages.v1.recovery"))
        XCTAssertEqual(model.villageStoreStatus, .available)
    }

    @MainActor
    func testWriteFailureLeavesRenameMemoryAndRawBytesUnchanged() throws {
        let original = try validVillagesData([VillageProfile(name: "原名称")])
        let current = TestCurrentVillagePersistence(data: original)
        current.failWrite = true
        current.writeBeforeFailure = true
        let history = TestSnapshotHistoryStore(
            envelope: SnapshotHistoryEnvelope(
                migrationMarker: SnapshotHistoryMigrationMarker(
                    completedAt: Date(timeIntervalSince1970: 1)
                )
            )
        )
        let manual = CountingManualStore()
        let model = makeModel(current: current, history: history, manual: manual)
        let before = model.villages

        model.renameSelectedVillage("新名称")

        XCTAssertEqual(model.villages, before)
        XCTAssertEqual(current.data, original)
        XCTAssertGreaterThanOrEqual(current.restoreCount, 1)
        XCTAssertEqual(model.villageStoreStatus, .writeFailed)
        XCTAssertNotNil(model.villageStoreError)
    }

    @MainActor
    func testCurrentWriteFailureRejectsVillageCreationWithoutHalfCommit() throws {
        let original = try validVillagesData()
        let current = TestCurrentVillagePersistence(data: original)
        current.failWrite = true
        let history = TestSnapshotHistoryStore(
            envelope: SnapshotHistoryEnvelope(
                migrationMarker: SnapshotHistoryMigrationMarker(
                    completedAt: Date(timeIntervalSince1970: 1)
                )
            )
        )
        let manual = CountingManualStore()
        let model = makeModel(current: current, history: history, manual: manual)
        let beforeVillages = model.villages
        let beforeManual = manual.rawData

        model.addVillageForImport()

        XCTAssertEqual(model.villages, beforeVillages)
        XCTAssertEqual(current.data, original)
        XCTAssertEqual(manual.rawData, beforeManual)
        XCTAssertEqual(model.villageStoreStatus, .writeFailed)
        XCTAssertNotNil(model.accountImportError)
    }
}
