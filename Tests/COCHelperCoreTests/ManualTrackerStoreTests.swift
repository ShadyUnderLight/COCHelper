import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

final class ManualTrackerStoreTests: XCTestCase {
    private final class TestStore: ManualTrackerStore, @unchecked Sendable {
        var transactionJournalURL: URL?
        var rawData: Data?
        var failWrite = false
        var writeBeforeFailure = false
        var failRestore = false

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
            if failWrite {
                if writeBeforeFailure { rawData = data }
                throw ManualTrackerStoreError.writeFailed("测试手动状态写入失败")
            }
            rawData = data
        }

        func restoreRawData(_ data: Data?) throws {
            if failRestore {
                throw ManualTrackerStoreError.writeFailed("测试手动状态回滚失败")
            }
            rawData = data
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ManualTrackerStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-ManualTracker-\(UUID().uuidString)")
            .appendingPathComponent("manual-tracker-v1.json")
    }

    private func makeJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-ManualTransaction-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("transaction.json")
    }

    private func currentData(name: String) throws -> Data {
        try JSONEncoder().encode([
            VillageProfile(
                id: UUID(uuidString: name == "old"
                    ? "00000000-0000-0000-0000-000000000011"
                    : "00000000-0000-0000-0000-000000000012")!,
                name: name,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
        ])
    }

    private func historyStore() -> TestSnapshotHistoryStore {
        TestSnapshotHistoryStore(
            envelope: SnapshotHistoryEnvelope(
                migrationMarker: SnapshotHistoryMigrationMarker(
                    completedAt: Date(timeIntervalSince1970: 1)
                )
            )
        )
    }

    private let key = TrackerItemKey.root(
        base: .home,
        rawSection: "buildings",
        dataID: 100
    )
    private let baseline = ManualBaselineReference(
        revision: "snapshot-1",
        fingerprint: "sha256:baseline",
        lineageID: "lineage-1"
    )
    private let provenance = ManualCatalogProvenance(
        gameVersion: "18.400.13",
        sourceFingerprint: "sha256:catalog"
    )

    private func manualCompletedCore(
        for baselineReference: ManualBaselineReference
    ) throws -> ManualUpgradeCore {
        let itemState = try ManualItemState(
            itemKey: key,
            baselineReference: baselineReference,
            manualCompletedDistribution: try ManualLevelDistribution(
                levelQuantities: [10: 1]
            ),
            status: .manualCompleted
        )
        return try ManualUpgradeCore(itemStates: [itemState])
    }

    private func manualCompletedCore() throws -> ManualUpgradeCore {
        try manualCompletedCore(for: baseline)
    }

    private func importedSnapshot(tag: String) throws -> AccountSnapshot {
        try AccountSnapshotImporter.parse(
            "{\"tag\":\"\(tag)\",\"buildings\":[{\"data\":100,\"lvl\":10}]}",
            now: Date(timeIntervalSince1970: 1)
        )
    }

    @MainActor
    private func makeModel(
        store: TestStore,
        villages: [VillageProfile] = [VillageProfile(name: "主村")],
        injectedHistoryStore: TestSnapshotHistoryStore? = nil
    ) throws -> AppModel {
        defaults.set(
            try JSONEncoder().encode(villages),
            forKey: "coc-helper.villages.v1"
        )
        return AppModel(
            defaults: defaults,
            historyStore: injectedHistoryStore ?? historyStore(),
            manualTrackerStore: store
        )
    }

    func testFileStoreRoundTripsVersionedEnvelopeWithoutRemainingSeconds() throws {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileManualTrackerStore(fileURL: url)
        let villageID = UUID()
        let empty = ManualTrackerEnvelope.empty(for: [villageID])

        try store.save(empty)
        XCTAssertEqual(try store.load(), empty)

        var core = try manualCompletedCore()
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: Date(timeIntervalSince1970: 100),
            durationState: .timed(seconds: 60),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            recordID: UUID(),
            now: Date(timeIntervalSince1970: 100)
        )
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: Date(timeIntervalSince1970: 100),
            reconciliationHistory: [ManualReconciliationRecord(
                previousReference: baseline,
                newReference: baseline,
                decision: .keepLocal,
                timeConfidence: .reliableSourceTimestamp,
                sourceTimestamp: Date(timeIntervalSince1970: 90),
                duplicate: false,
                appliedAt: Date(timeIntervalSince1970: 100),
                items: []
            )]
        )
        var envelope = empty
        try envelope.upsert(state)
        try store.save(envelope)

        let raw = try XCTUnwrap(store.readRawData())
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("remainingSeconds"))
        XCTAssertEqual(try store.load(), envelope)
        XCTAssertEqual(try XCTUnwrap(try store.load()?.state(for: villageID)).baselineRevision, "snapshot-1")
    }

    @MainActor
    func testReimportPreviewAndCancelLeaveAllThreeStoresUnchanged() throws {
        let raw = "{\"tag\":\"#2QJQ8J88\",\"timestamp\":1700000000,\"buildings\":[{\"data\":100,\"lvl\":10,\"cnt\":1}]}"
        let nextRaw = "{\"tag\":\"#2QJQ8J88\",\"timestamp\":1700000200,\"buildings\":[{\"data\":100,\"lvl\":11,\"cnt\":1}]}"
        let village = VillageProfile(
            name: "主村",
            accountSnapshot: try AccountSnapshotImporter.parse(
                raw,
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        let manualStore = TestStore()
        let snapshotHistoryStore = historyStore()
        let model = try makeModel(
            store: manualStore,
            villages: [village],
            injectedHistoryStore: snapshotHistoryStore
        )
        let currentBefore = defaults.data(forKey: "coc-helper.villages.v1")
        let historyBefore = snapshotHistoryStore.rawData
        let manualBefore = manualStore.rawData

        model.importText = nextRaw
        model.parseAccountText()
        XCTAssertNotNil(model.pendingReconciliationPreview)
        model.discardPendingAccountSnapshot()

        XCTAssertEqual(defaults.data(forKey: "coc-helper.villages.v1"), currentBefore)
        XCTAssertEqual(snapshotHistoryStore.rawData, historyBefore)
        XCTAssertEqual(manualStore.rawData, manualBefore)
        XCTAssertNil(model.pendingAccountSnapshot)
        XCTAssertNil(model.pendingReconciliationPreview)
    }

    func testCorruptAndFutureSchemaAreRejectedWithoutReplacingBytes() throws {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileManualTrackerStore(fileURL: url)

        let corrupt = Data("not-json".utf8)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try corrupt.write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.load()) { error in
            guard case .corrupt = error as? ManualTrackerStoreError else {
                return XCTFail("损坏手动状态必须 fail closed：\(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)

        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "storeVersion": 1,
            "villages": []
        ])
        try future.write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ManualTrackerStoreError, .unsupportedSchema(99))
        }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testPreparedManualJournalWithCorruptCurrentBlobFailsClosed() throws {
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let oldCurrent = try currentData(name: "old")
        let manualData = try ManualTrackerEnvelope.empty(for: []).encodedData()
        try writeTransactionJournal(
            phase: "prepared",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: Data("corrupt-current".utf8),
            previousManualData: nil,
            newManualData: manualData
        )
        let current = TestCurrentVillagePersistence(data: oldCurrent)
        let store = TestStore()
        store.rawData = manualData
        let coordinator = ManualTrackerTransactionCoordinator(
            current: current,
            manual: store,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.recoverIfNeeded()) { error in
            guard case .journalCorrupt = error as? ManualTrackerTransactionError else {
                return XCTFail("prepared manual journal 的损坏 currentData 必须 fail closed：\(error)")
            }
        }
        XCTAssertEqual(current.data, oldCurrent)
        XCTAssertEqual(store.rawData, manualData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testCommittedManualJournalWithCorruptCurrentBlobFailsClosed() throws {
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let oldCurrent = try currentData(name: "old")
        let manualData = try ManualTrackerEnvelope.empty(for: []).encodedData()
        try writeTransactionJournal(
            phase: "committed",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: Data("corrupt-current".utf8),
            previousManualData: nil,
            newManualData: manualData
        )
        let current = TestCurrentVillagePersistence(data: oldCurrent)
        let store = TestStore()
        store.rawData = manualData
        let coordinator = ManualTrackerTransactionCoordinator(
            current: current,
            manual: store,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.recoverIfNeeded()) { error in
            guard case .journalCorrupt = error as? ManualTrackerTransactionError else {
                return XCTFail("committed manual journal 的损坏 currentData 必须 fail closed：\(error)")
            }
        }
        XCTAssertEqual(current.data, oldCurrent)
        XCTAssertEqual(store.rawData, manualData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testPreparedManualJournalWithCorruptPreviousManualPayloadFailsClosed() throws {
        let journalURL = makeJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let oldCurrent = try currentData(name: "old")
        let newCurrent = try currentData(name: "new")
        let validManualData = try ManualTrackerEnvelope.empty(for: [UUID()]).encodedData()
        let corruptPreviousManualData = Data("corrupt-previous-manual".utf8)
        try writeTransactionJournal(
            phase: "prepared",
            to: journalURL,
            previousCurrentData: oldCurrent,
            newCurrentData: newCurrent,
            previousManualData: corruptPreviousManualData,
            newManualData: validManualData
        )
        let current = TestCurrentVillagePersistence(data: newCurrent)
        let store = TestStore()
        store.rawData = validManualData
        let coordinator = ManualTrackerTransactionCoordinator(
            current: current,
            manual: store,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try coordinator.recoverIfNeeded()) { error in
            guard case .journalCorrupt = error as? ManualTrackerTransactionError else {
                return XCTFail("损坏的 previousManualData 必须在恢复写入前 fail closed：\(error)")
            }
        }
        XCTAssertEqual(current.data, newCurrent)
        XCTAssertEqual(store.rawData, validManualData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @MainActor
    func testClearAndReimportReconcilesWithoutRollingBackManualState() throws {
        let history = TestSnapshotHistoryStore()
        let store = TestStore()
        let snapshot = try importedSnapshot(tag: "#2QJQ8J88")
        let village = VillageProfile(name: "主村", accountSnapshot: snapshot)
        defaults.set(
            try JSONEncoder().encode([village]),
            forKey: "coc-helper.villages.v1"
        )
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        let active = try XCTUnwrap(try history.load()?.activeLineage(for: villageID))
        let entry = try XCTUnwrap(try history.load()?.entry(id: active.lastEntryID))
        let currentBaseline = ManualBaselineReference(
            revision: entry.snapshotID.uuidString,
            fingerprint: entry.canonicalFingerprint,
            lineageID: entry.lineageID.uuidString
        )
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try self.manualCompletedCore(for: currentBaseline)
        }
        XCTAssertEqual(
            model.manualUpgradeCores[villageID]?.itemState(for: self.key)?.status,
            .manualCompleted
        )
        let persistedBeforeReset = try XCTUnwrap(store.rawData)

        model.clearAccountSnapshot()

        XCTAssertEqual(store.rawData, persistedBeforeReset)
        XCTAssertEqual(
            model.manualUpgradeCore(for: villageID)?.itemState(for: self.key)?.status,
            .manualCompleted
        )
        XCTAssertEqual(
            model.manualUpgradeCores[villageID]?.itemState(for: self.key)?.status,
            .unknown
        )
        XCTAssertTrue(model.manualUpgradeCores[villageID]?.activeRecords.isEmpty == true)

        model.importIntoCurrentVillage = true
        model.importText = snapshot.originalText
        model.parseAccountText()
        XCTAssertTrue(model.applyPendingAccountSnapshot())

        XCTAssertNotEqual(store.rawData, persistedBeforeReset)
        XCTAssertEqual(
            model.manualUpgradeCores[villageID]?.itemState(for: self.key)?.status,
            .manualCompleted,
            "完全相同的同 Tag snapshot 重导入应只更新 baseline，不降级本地状态"
        )
        XCTAssertEqual(
            try history.load()?.duplicateMetadata.values.first?.duplicateImportCount,
            1
        )

        model.importText = "{\"tag\":\"#2QJQ8J88\",\"buildings\":[{\"data\":100,\"lvl\":11}]}"
        model.parseAccountText()
        XCTAssertTrue(model.applyPendingAccountSnapshot())

        XCTAssertNotEqual(store.rawData, persistedBeforeReset)
        XCTAssertEqual(
            model.manualUpgradeCores[villageID]?.itemState(for: self.key)?.status,
            .manualCompleted,
            "缺少来源时间的新 snapshot 不能回滚已完成的本地状态"
        )
        XCTAssertEqual(try store.load()?.state(for: villageID)?.reconciliationHistory.count, 2)
    }

    @MainActor
    func testChangingTagStartsNewLineageAndGatesOldManualProjection() throws {
        let history = TestSnapshotHistoryStore()
        let store = TestStore()
        let snapshot = try importedSnapshot(tag: "#2QJQ8J88")
        let village = VillageProfile(name: "主村", accountSnapshot: snapshot)
        defaults.set(
            try JSONEncoder().encode([village]),
            forKey: "coc-helper.villages.v1"
        )
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        let active = try XCTUnwrap(try history.load()?.activeLineage(for: villageID))
        let entry = try XCTUnwrap(try history.load()?.entry(id: active.lastEntryID))
        let currentBaseline = ManualBaselineReference(
            revision: entry.snapshotID.uuidString,
            fingerprint: entry.canonicalFingerprint,
            lineageID: entry.lineageID.uuidString
        )
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try self.manualCompletedCore(for: currentBaseline)
        }
        let persistedBeforeImport = try XCTUnwrap(store.rawData)

        model.importIntoCurrentVillage = true
        model.importText = "{\"tag\":\"#2QJQ8J87\",\"buildings\":[{\"data\":100,\"lvl\":10}]}"
        model.parseAccountText()
        XCTAssertTrue(model.applyPendingAccountSnapshot())

        XCTAssertNotEqual(store.rawData, persistedBeforeImport)
        XCTAssertEqual(
            model.manualUpgradeCores[villageID]?.itemState(for: self.key)?.status,
            .unknown,
            "换 Tag 进入新 lineage 后，旧 manual state 必须隔离"
        )
        XCTAssertTrue(model.manualUpgradeCores[villageID]?.activeRecords.isEmpty == true)
        let items = try store.load()?.state(for: villageID)?.reconciliationHistory.last?.items
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?.classification, .lineageMismatch)
    }

    func testVillageStateRejectsRecordStartingAfterStateUpdatedAt() throws {
        let startedAt = Date(timeIntervalSince1970: 200)
        var core = try manualCompletedCore()
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: startedAt,
            durationState: .timed(seconds: 60),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            recordID: UUID(),
            now: startedAt
        )

        XCTAssertThrowsError(try ManualTrackerVillageState(
            villageID: UUID(),
            core: core,
            stateUpdatedAt: Date(timeIntervalSince1970: 100)
        )) { error in
            guard case .invalidEnvelope = error as? ManualTrackerStoreError else {
                return XCTFail("future startedAt 必须在存储边界 fail closed：\(error)")
            }
        }
    }

    func testEnvelopeRejectsDuplicateRecordIDAcrossVillages() throws {
        var core = try manualCompletedCore()
        let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000000142")!
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: Date(timeIntervalSince1970: 100),
            durationState: .timed(seconds: 60),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            recordID: recordID,
            now: Date(timeIntervalSince1970: 100)
        )
        let first = try ManualTrackerVillageState(villageID: UUID(), core: core)
        let second = try ManualTrackerVillageState(villageID: UUID(), core: core)

        let raw = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": ManualTrackerSchema.envelope,
            "storeVersion": ManualTrackerSchema.store,
            "villages": [
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)),
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(second))
            ],
            "migrationMarker": [
                "version": ManualTrackerSchema.envelope,
                "completedAt": 0
            ]
        ])
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileManualTrackerStore(fileURL: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try raw.write(to: url, options: .atomic)

        XCTAssertThrowsError(try store.load()) { error in
            guard case .invalidEnvelope = error as? ManualTrackerStoreError else {
                return XCTFail("跨村庄重复 recordID 必须被拒绝：\(error)")
            }
        }
    }

    private func writeTransactionJournal(
        phase: String,
        to url: URL,
        previousCurrentData: Data?,
        newCurrentData: Data,
        previousManualData: Data?,
        newManualData: Data
    ) throws {
        struct JournalFixture: Codable {
            let phase: String
            let previousCurrentData: Data?
            let newCurrentData: Data
            let previousManualData: Data?
            let newManualData: Data
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(JournalFixture(
            phase: phase,
            previousCurrentData: previousCurrentData,
            newCurrentData: newCurrentData,
            previousManualData: previousManualData,
            newManualData: newManualData
        ))
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    func testAppModelPersistsManualCorePerVillageAndDeleteCascades() throws {
        let store = TestStore()
        let model = try makeModel(store: store)
        let firstID = model.villages[0].id
        let now = Date(timeIntervalSince1970: 100)

        try model.updateManualUpgradeCore(for: firstID, at: now) { core in
            core = try self.manualCompletedCore()
            _ = try core.startUpgrade(
                itemKey: self.key,
                fromLevel: 10,
                targetLevel: 11,
                quantity: 1,
                startedAt: now,
                durationState: .instant,
                frozenCosts: nil,
                catalogProvenance: self.provenance,
                baselineReference: self.baseline,
                recordID: UUID(),
                now: now
            )
        }
        let saved = try XCTUnwrap(store.load())
        XCTAssertNotNil(saved.state(for: firstID)?.core.completedHistory.first)

        model.addVillageForImport()
        XCTAssertEqual(model.villages.count, 2)
        let secondID = try XCTUnwrap(model.villages.last?.id)
        XCTAssertNotNil(try store.load()?.state(for: firstID))
        XCTAssertNotNil(try store.load()?.state(for: secondID))
        XCTAssertTrue(try XCTUnwrap(store.load()?.state(for: secondID)?.core.records).isEmpty)

        model.deleteVillage(id: firstID)
        XCTAssertEqual(model.villages.count, 1)
        XCTAssertNil(try store.load()?.state(for: firstID))
        XCTAssertNotNil(try store.load()?.state(for: secondID))
    }

    @MainActor
    func testReimportReconcilesOnlyTheTargetVillage() throws {
        let store = TestStore()
        let firstSnapshot = try importedSnapshot(tag: "#2QJQ8J88")
        let secondSnapshot = try importedSnapshot(tag: "#2QJQ8J89")
        let villages = [
            VillageProfile(name: "A", accountSnapshot: firstSnapshot),
            VillageProfile(name: "B", accountSnapshot: secondSnapshot)
        ]
        let model = try makeModel(
            store: store,
            villages: villages,
            injectedHistoryStore: TestSnapshotHistoryStore()
        )
        let firstID = model.villages[0].id
        let secondID = model.villages[1].id
        let secondBefore = try XCTUnwrap(store.load()?.state(for: secondID))

        model.importText = firstSnapshot.originalText
        model.parseAccountText()
        XCTAssertTrue(model.applyPendingAccountSnapshot())

        let persisted = try XCTUnwrap(store.load())
        XCTAssertEqual(persisted.state(for: secondID), secondBefore)
        XCTAssertEqual(persisted.state(for: firstID)?.reconciliationHistory.count, 1)
        XCTAssertTrue(
            persisted.state(for: firstID)?.reconciliationHistory.last?.duplicate == true
        )
    }

    @MainActor
    func testAppModelManualCoreSurvivesRestartWithSameStore() throws {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileManualTrackerStore(fileURL: url)
        let village = VillageProfile(name: "主村")
        defaults.set(
            try JSONEncoder().encode([village]),
            forKey: "coc-helper.villages.v1"
        )
        let first = AppModel(
            defaults: defaults,
            historyStore: historyStore(),
            manualTrackerStore: store
        )
        let villageID = first.villages[0].id
        try first.updateManualUpgradeCore(for: villageID, at: Date(timeIntervalSince1970: 100)) { core in
            core = try self.manualCompletedCore()
        }

        let reloaded = AppModel(
            defaults: defaults,
            historyStore: historyStore(),
            manualTrackerStore: FileManualTrackerStore(fileURL: url)
        )
        XCTAssertEqual(
            reloaded.manualUpgradeCore(for: villageID),
            first.manualUpgradeCore(for: villageID)
        )
        XCTAssertEqual(reloaded.manualTrackerStatus, .available)
    }

    @MainActor
    func testAppModelSettlesDueRecordsAtInjectedTimeAndStartup() throws {
        let store = TestStore()
        let model = try makeModel(store: store)
        let villageID = model.villages[0].id
        let start = Date(timeIntervalSince1970: 100)
        try model.updateManualUpgradeCore(for: villageID, at: start) { core in
            core = try self.manualCompletedCore()
            _ = try core.startUpgrade(
                itemKey: self.key,
                fromLevel: 10,
                targetLevel: 11,
                quantity: 1,
                startedAt: start,
                durationState: .timed(seconds: 60),
                frozenCosts: nil,
                catalogProvenance: self.provenance,
                baselineReference: self.baseline,
                recordID: UUID(),
                now: start
            )
        }
        XCTAssertEqual(model.settleManualUpgrades(at: start.addingTimeInterval(59)), 0)
        XCTAssertEqual(model.settleManualUpgrades(at: start.addingTimeInterval(60)), 1)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID)?.activeRecords.count, 0)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID)?.completedHistory.count, 1)

        var dueCore = try manualCompletedCore()
        _ = try dueCore.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: start,
            durationState: .instant,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            recordID: UUID(),
            now: start
        )
        var envelope = ManualTrackerEnvelope.empty(for: [villageID])
        try envelope.upsert(try ManualTrackerVillageState(
            villageID: villageID,
            core: dueCore,
            stateUpdatedAt: start
        ))
        try store.save(envelope)
        let reloaded = try makeModel(
            store: store,
            villages: [VillageProfile(id: villageID, name: "主村")]
        )
        XCTAssertEqual(reloaded.manualUpgradeCore(for: villageID)?.activeRecords.count, 0)
        XCTAssertEqual(reloaded.manualUpgradeCore(for: villageID)?.completedHistory.count, 1)
    }

    @MainActor
    func testManualWriteFailureDoesNotHalfCommitVillageCreation() throws {
        let store = TestStore()
        let model = try makeModel(store: store)
        let beforeCurrent = try XCTUnwrap(
            defaults.data(forKey: "coc-helper.villages.v1")
        )
        let beforeManual = try XCTUnwrap(store.rawData)
        store.failWrite = true
        store.writeBeforeFailure = true

        model.addVillageForImport()

        XCTAssertEqual(model.villages.count, 1)
        XCTAssertEqual(defaults.data(forKey: "coc-helper.villages.v1"), beforeCurrent)
        XCTAssertEqual(store.rawData, beforeManual)
        XCTAssertNotNil(model.manualTrackerError)
    }

    @MainActor
    func testCorruptOrFutureManualStoreDoesNotBlockVillageLoad() throws {
        let store = TestStore()
        store.rawData = Data("not-json".utf8)
        let model = try makeModel(store: store)
        XCTAssertEqual(model.villages.count, 1)
        XCTAssertEqual(model.manualTrackerStatus, .unavailable)
        XCTAssertTrue(model.manualUpgradeCores.isEmpty)
        XCTAssertEqual(store.rawData, Data("not-json".utf8))

        let futureStore = TestStore()
        futureStore.rawData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "storeVersion": 1,
            "villages": []
        ])
        let futureModel = try makeModel(store: futureStore)
        XCTAssertEqual(futureModel.villages.count, 1)
        XCTAssertEqual(futureModel.manualTrackerStatus, .migrationRequired)
        XCTAssertTrue(futureModel.manualUpgradeCores.isEmpty)
    }

    @MainActor
    func testClearAndRenameDoNotRewriteManualState() throws {
        let store = TestStore()
        let model = try makeModel(store: store)
        let villageID = model.villages[0].id
        let now = Date(timeIntervalSince1970: 100)
        try model.updateManualUpgradeCore(for: villageID, at: now) { core in
            core = try self.manualCompletedCore()
        }
        let before = try XCTUnwrap(store.rawData)

        model.clearAccountSnapshot()
        model.renameSelectedVillage("改名后")
        XCTAssertEqual(store.rawData, before)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID), try store.load()?.state(for: villageID)?.core)
    }

    @MainActor
    func testOfficialRefreshDoesNotRewriteManualState() async throws {
        let store = TestStore()
        let village = VillageProfile(name: "主村", officialAPIState: OfficialAPIState(
            status: .success,
            playerTag: "#P1",
            fetchedAt: Date(timeIntervalSince1970: 1),
            lastAttemptAt: Date(timeIntervalSince1970: 1),
            lastGood: nil
        ))
        defaults.set(
            try JSONEncoder().encode([village]),
            forKey: "coc-helper.villages.v1"
        )
        let response = Data(##"{"tag":"#P1","name":"updated","townHallLevel":18}"##.utf8)
        let refresher = OfficialPlayerRefresher(client: CoAPIClient(
            config: CoAPIConfig(maxRetryCount: 0),
            session: MockURLProtocol.makeSession()
        ) { "fake-token" })
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                response
            )
        }
        let model = AppModel(
            defaults: defaults,
            refresher: refresher,
            historyStore: historyStore(),
            manualTrackerStore: store
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        try model.updateManualUpgradeCore(for: villageID, at: Date(timeIntervalSince1970: 100)) { core in
            core = try self.manualCompletedCore()
        }
        let before = try XCTUnwrap(store.rawData)

        model.refreshOfficialPlayer(villageID: villageID)
        let deadline = Date().addingTimeInterval(5)
        while model.isRefreshingOfficialData && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isRefreshingOfficialData, "官方刷新测试超时")

        XCTAssertEqual(store.rawData, before)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID), try store.load()?.state(for: villageID)?.core)
    }
}
