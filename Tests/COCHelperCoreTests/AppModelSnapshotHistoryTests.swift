import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

final class AppModelSnapshotHistoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelSnapshotHistoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func snapshot(tag: String, text: String) -> AccountSnapshot {
        AccountSnapshot(
            tag: tag,
            capturedAt: nil,
            importedAt: Date(timeIntervalSince1970: 1),
            ageSeconds: nil,
            originalText: text,
            objectSections: [:],
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
    }

    private func assertCoverageIsKnownMetadata(
        _ snapshot: AccountSnapshot,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            snapshot.unknownTopLevelKeys.contains("coverage"),
            "coverage 不得进入 unknownTopLevelKeys",
            file: file,
            line: line
        )
        XCTAssertFalse(
            snapshot.diagnostics.contains {
                $0.path == "顶层"
                    && $0.severity == .warning
                    && $0.message.contains("未识别字段")
                    && $0.message.contains("coverage")
            },
            "合法 coverage 不得触发未识别字段警告",
            file: file,
            line: line
        )
    }

    @MainActor
    private func makeModel(
        villages: [VillageProfile],
        historyStore: TestSnapshotHistoryStore,
        clipboardReader: @escaping () -> String? = { nil }
    ) throws -> AppModel {
        defaults.set(try JSONEncoder().encode(villages), forKey: "coc-helper.villages.v1")
        return AppModel(
            defaults: defaults,
            clipboardReader: clipboardReader,
            historyStore: historyStore
        )
    }

    @MainActor
    func testQuickImportCommitsCurrentStateAndHistoryAndDeduplicatesRepeat() throws {
        let raw = "{\"tag\":\"#2QJQ8J88\",\"buildings\":[]}"
        let village = VillageProfile(id: UUID(), name: "主村")
        let historyStore = TestSnapshotHistoryStore()
        let model = try makeModel(
            villages: [village],
            historyStore: historyStore,
            clipboardReader: { raw }
        )
        let targetID = model.villages[0].id

        guard case .success(let preview) = model.prepareQuickImport(for: targetID) else {
            return XCTFail("有效快照应能生成快捷导入预览")
        }
        XCTAssertTrue(model.applyQuickImport(preview))
        XCTAssertNil(model.snapshotHistoryError)

        let persistedData = try XCTUnwrap(defaults.data(forKey: "coc-helper.villages.v1"))
        let persistedVillages = try JSONDecoder().decode([VillageProfile].self, from: persistedData)
        XCTAssertEqual(persistedVillages[0].accountSnapshot?.originalText, raw)
        XCTAssertEqual(persistedVillages[0].accountSnapshot?.tag, "#2QJQ8J88")

        let firstEnvelope = try XCTUnwrap(historyStore.load())
        XCTAssertEqual(firstEnvelope.entries.count, 1)
        XCTAssertEqual(firstEnvelope.entries[0].rawJSON, raw)
        let baselineProjection = model.snapshotHistoryProjection(for: targetID)
        XCTAssertEqual(baselineProjection.availability, .baselineOnly)
        XCTAssertEqual(baselineProjection.timeline.count, 1)
        XCTAssertTrue(baselineProjection.timeline[0].isBaseline)

        guard case .success(let secondPreview) = model.prepareQuickImport(for: targetID) else {
            return XCTFail("重复导入仍应能生成快捷导入预览")
        }
        XCTAssertTrue(model.applyQuickImport(secondPreview))
        let secondEnvelope = try XCTUnwrap(historyStore.load())
        XCTAssertEqual(secondEnvelope.entries.count, 1)
        XCTAssertEqual(secondEnvelope.duplicateMetadata.count, 1)
        XCTAssertEqual(secondEnvelope.duplicateMetadata.values.first?.duplicateImportCount, 1)
        let duplicateProjection = model.snapshotHistoryProjection(for: targetID)
        XCTAssertEqual(duplicateProjection.totalSnapshotCount, 1)
        XCTAssertEqual(duplicateProjection.timeline.count, 1)
        XCTAssertEqual(duplicateProjection.timeline[0].duplicateImportCount, 1)
        XCTAssertNotNil(duplicateProjection.latestCheckedAt)
    }

    @MainActor
    func testAccountImportUsesSameHistoryAndCurrentStateTransaction() throws {
        let raw = "{\"tag\":\"#2QJQ8J89\",\"buildings\":[]}"
        let historyStore = TestSnapshotHistoryStore()
        let model = try makeModel(villages: [], historyStore: historyStore)
        model.importText = raw
        model.parseAccountText()

        XCTAssertNotNil(model.pendingAccountSnapshot)
        XCTAssertTrue(model.applyPendingAccountSnapshot())
        XCTAssertEqual(model.villages.count, 1)
        XCTAssertEqual(model.villages[0].accountSnapshot?.tag, "#2QJQ8J89")

        let envelope = try XCTUnwrap(historyStore.load())
        XCTAssertEqual(envelope.entries.count, 1)
        XCTAssertEqual(envelope.entries[0].villageID, model.villages[0].id)
        let persistedData = try XCTUnwrap(defaults.data(forKey: "coc-helper.villages.v1"))
        let persisted = try JSONDecoder().decode([VillageProfile].self, from: persistedData)
        XCTAssertEqual(persisted, model.villages)
    }

    @MainActor
    func testAccountImportRejectsDuplicateTagWithoutChoosingFirstVillage() throws {
        let tag = "#2QJQ8J88"
        let raw = "{\"tag\":\"\(tag)\",\"buildings\":[]}"
        let villages = [
            VillageProfile(
                id: UUID(),
                name: "村庄 A",
                accountSnapshot: snapshot(tag: tag, text: raw)
            ),
            VillageProfile(
                id: UUID(),
                name: "村庄 B",
                accountSnapshot: snapshot(tag: tag, text: raw)
            )
        ]
        let historyStore = TestSnapshotHistoryStore()
        let model = try makeModel(villages: villages, historyStore: historyStore)
        model.importText = raw
        model.parseAccountText()

        let beforeVillages = model.villages
        let beforeCurrent = defaults.data(forKey: "coc-helper.villages.v1")
        let beforeHistory = historyStore.rawData

        XCTAssertNotNil(model.pendingAccountSnapshot)
        XCTAssertEqual(model.pendingAccountSnapshotActionTitle, "无法确定导入目标")
        XCTAssertTrue(model.pendingAccountSnapshotDestinationDescription?.contains("多个") == true)
        XCTAssertTrue(model.accountImportError?.contains("多个") == true)
        XCTAssertFalse(model.applyPendingAccountSnapshot())
        XCTAssertEqual(model.villages, beforeVillages)
        XCTAssertEqual(defaults.data(forKey: "coc-helper.villages.v1"), beforeCurrent)
        XCTAssertEqual(historyStore.rawData, beforeHistory)
        XCTAssertNotNil(model.pendingAccountSnapshot)
    }

    @MainActor
    func testLegacySingleSnapshotLoadsIntoCurrentVillageAndCreatesOneBaseline() throws {
        let raw = "{\"tag\":\"#2QJQ8J88\",\"buildings\":[]}"
        let legacySnapshot = snapshot(tag: "#2QJQ8J88", text: raw)
        defaults.set(
            try JSONEncoder().encode(legacySnapshot),
            forKey: "coc-helper.account-snapshot.v1"
        )
        let historyStore = TestSnapshotHistoryStore()

        let model = AppModel(defaults: defaults, historyStore: historyStore)

        XCTAssertEqual(model.villages.count, 1)
        XCTAssertEqual(model.villages[0].accountSnapshot?.originalText, raw)
        let persistedData = try XCTUnwrap(defaults.data(forKey: "coc-helper.villages.v1"))
        let persisted = try JSONDecoder().decode([VillageProfile].self, from: persistedData)
        XCTAssertEqual(persisted[0].accountSnapshot?.originalText, raw)
        let envelope = try XCTUnwrap(historyStore.load())
        XCTAssertEqual(envelope.entries.count, 1)
        XCTAssertTrue(envelope.entries[0].isBaseline)
    }

    @MainActor
    func testHistoryWriteFailureLeavesCurrentStateUnchangedAndRejectsImport() throws {
        let village = VillageProfile(id: UUID(), name: "主村")
        let historyStore = TestSnapshotHistoryStore()
        let model = try makeModel(
            villages: [village],
            historyStore: historyStore,
            clipboardReader: { "{\"tag\":\"#2QJQ8J88\",\"buildings\":[]}" }
        )
        let beforeCurrent = defaults.data(forKey: "coc-helper.villages.v1")
        let beforeHistory = historyStore.rawData
        historyStore.failWrite = true
        historyStore.writeBeforeFailure = true

        guard case .success(let preview) = model.prepareQuickImport(for: model.villages[0].id) else {
            return XCTFail("有效快照应能生成快捷导入预览")
        }
        XCTAssertFalse(model.applyQuickImport(preview))
        XCTAssertNotNil(model.snapshotHistoryError)
        XCTAssertNil(model.villages[0].accountSnapshot)
        XCTAssertEqual(defaults.data(forKey: "coc-helper.villages.v1"), beforeCurrent)
        XCTAssertEqual(historyStore.rawData, beforeHistory)
    }

    @MainActor
    func testUnavailableHistoryFailsClosedWithoutWritingCurrentState() throws {
        let village = VillageProfile(id: UUID(), name: "主村")
        let historyStore = TestSnapshotHistoryStore()
        historyStore.failLoad = true
        let model = try makeModel(
            villages: [village],
            historyStore: historyStore,
            clipboardReader: { "{\"tag\":\"#2QJQ8J88\",\"buildings\":[]}" }
        )
        let beforeCurrent = defaults.data(forKey: "coc-helper.villages.v1")

        guard case .failure(.historyUnavailable) = model.prepareQuickImport(for: model.villages[0].id) else {
            return XCTFail("历史读取失败时快捷导入不得生成没有对账预览的确认页")
        }
        guard case .unavailable = model.snapshotHistoryProjection(for: model.villages[0].id).availability else {
            return XCTFail("历史读取失败必须映射为不可用，而不是空历史。")
        }
        XCTAssertNil(model.villages[0].accountSnapshot)
        XCTAssertEqual(defaults.data(forKey: "coc-helper.villages.v1"), beforeCurrent)
    }

    @MainActor
    func testCorruptImportJournalKeepsHistoryUnavailableAndPreservesEvidence() throws {
        let village = VillageProfile(id: UUID(), name: "主村")
        let historyStore = TestSnapshotHistoryStore()
        let journalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-AppModelJournalTests-\(UUID().uuidString)", isDirectory: true)
        let journalURL = journalDirectory.appendingPathComponent("transaction.json")
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: journalURL, options: .atomic)
        historyStore.transactionJournalURL = journalURL

        let model = try makeModel(
            villages: [village],
            historyStore: historyStore,
            clipboardReader: { "{\"tag\":\"#2QJQ8J88\",\"buildings\":[]}" }
        )
        let beforeCurrent = defaults.data(forKey: "coc-helper.villages.v1")

        XCTAssertNotNil(model.snapshotHistoryError)
        guard case .corrupt = model.snapshotHistoryProjection(for: model.villages[0].id).availability else {
            return XCTFail("损坏事务记录必须映射为 corrupt 历史状态。")
        }
        guard case .failure(.historyUnavailable) = model.prepareQuickImport(for: model.villages[0].id) else {
            return XCTFail("事务日志损坏时快捷导入不得生成没有对账预览的确认页")
        }
        XCTAssertEqual(defaults.data(forKey: "coc-helper.villages.v1"), beforeCurrent)
        XCTAssertEqual(try Data(contentsOf: journalURL), corrupt)
    }

    @MainActor
    func testClearAndOrdinaryVillagePersistenceDoNotAppendHistory() throws {
        let raw = "{\"tag\":\"#2QJQ8J88\",\"buildings\":[]}"
        let initialSnapshot = snapshot(tag: "#2QJQ8J88", text: raw)
        let village = VillageProfile(id: UUID(), name: "旧名称", accountSnapshot: initialSnapshot)
        let historyStore = TestSnapshotHistoryStore()
        let model = try makeModel(villages: [village], historyStore: historyStore)
        let before = try XCTUnwrap(historyStore.load())

        model.renameSelectedVillage("新名称")
        model.clearAccountSnapshot()

        let after = try XCTUnwrap(historyStore.load())
        XCTAssertEqual(after.entries, before.entries)
        XCTAssertEqual(after.duplicateMetadata, before.duplicateMetadata)
        XCTAssertNil(model.villages[0].accountSnapshot)
        XCTAssertEqual(model.villages[0].name, "新名称")
    }

    // MARK: - Issue #173: 真实导入经统一 source coverage contract 接线

    /// 真实账号 JSON 没有完整性协议 → 导入后 buildings 不得声称 complete
    /// （fail-closed，任何入口都不能隐式用空 proof 声称 complete）。
    @MainActor
    func testRealAccountImportWithoutCoverageProtocolKeepsSectionsUnavailable() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(forResource: "anonymized_account_snapshot", withExtension: "json")
        )
        let raw = try String(contentsOf: fixtureURL, encoding: .utf8)
        let historyStore = TestSnapshotHistoryStore()
        let model = try makeModel(villages: [], historyStore: historyStore)
        model.importText = raw
        model.parseAccountText()

        let pending = try XCTUnwrap(model.pendingAccountSnapshot)
        XCTAssertEqual(pending.unknownTopLevelKeys, [])
        XCTAssertFalse(pending.diagnostics.contains {
            $0.path == "顶层" && $0.severity == .warning && $0.message.contains("未识别字段")
        })
        XCTAssertTrue(model.applyPendingAccountSnapshot())
        let envelope = try XCTUnwrap(historyStore.load())
        let entry = try XCTUnwrap(envelope.entries.first)
        let buildings = try XCTUnwrap(
            entry.coverage.section(base: .home, rawSection: "buildings")
        )
        XCTAssertFalse(buildings.isComplete, "无来源协议时不得声称 complete")
        XCTAssertFalse(buildings.proof.isVerified)
    }

    /// 账号导入路径：带 coverage 声明的 JSON 冻结 declared proof，但不 complete。
    @MainActor
    func testAccountImportWithCoverageDeclarationFreezesDeclaredProofWithoutComplete() throws {
        let raw = """
        {"tag":"#2QJQ8J88","buildings":[{"data":1,"lvl":1}],
         "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
        """
        let historyStore = TestSnapshotHistoryStore()
        let model = try makeModel(villages: [], historyStore: historyStore)
        model.importText = raw
        model.parseAccountText()

        let pending = try XCTUnwrap(model.pendingAccountSnapshot)
        assertCoverageIsKnownMetadata(pending)
        XCTAssertTrue(model.applyPendingAccountSnapshot())
        let envelope = try XCTUnwrap(historyStore.load())
        let entry = try XCTUnwrap(envelope.entries.first)
        let buildings = try XCTUnwrap(
            entry.coverage.section(base: .home, rawSection: "buildings")
        )
        XCTAssertEqual(buildings.completeness, .unavailable)
        XCTAssertFalse(buildings.isComplete)
        XCTAssertEqual(
            buildings.proof,
            .declared(source: "u.coc", version: "1", expectedCount: 1)
        )
    }

    /// 快捷导入路径（预览 + 提交）同样经过 source coverage adapter。
    @MainActor
    func testQuickImportWithCoverageDeclarationFreezesDeclaredProofWithoutComplete() throws {
        let raw = """
        {"tag":"#2QJQ8J88","buildings":[{"data":1,"lvl":1}],
         "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
        """
        let village = VillageProfile(id: UUID(), name: "主村")
        let historyStore = TestSnapshotHistoryStore()
        let model = try makeModel(
            villages: [village],
            historyStore: historyStore,
            clipboardReader: { raw }
        )

        guard case .success(let preview) = model.prepareQuickImport(for: model.villages[0].id) else {
            return XCTFail("有效快照应能生成快捷导入预览")
        }
        assertCoverageIsKnownMetadata(preview.snapshot)
        XCTAssertTrue(model.applyQuickImport(preview))
        let envelope = try XCTUnwrap(historyStore.load())
        let entry = try XCTUnwrap(envelope.entries.last)
        let buildings = try XCTUnwrap(
            entry.coverage.section(base: .home, rawSection: "buildings")
        )
        XCTAssertEqual(buildings.completeness, .unavailable)
        XCTAssertFalse(buildings.isComplete)
    }

    /// 启动迁移路径（loadOrMigrate）也按村庄传入 source coverage proof。
    @MainActor
    func testStartupMigrationWithCoverageDeclarationFreezesDeclaredProofWithoutComplete() throws {
        let raw = """
        {"tag":"#2QJQ8J88","buildings":[{"data":1,"lvl":1}],
         "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
        """
        let parsed = try AccountSnapshotImporter.parse(raw, now: Date(timeIntervalSince1970: 1))
        assertCoverageIsKnownMetadata(parsed)
        let village = VillageProfile(
            id: UUID(),
            name: "主村",
            accountSnapshot: parsed
        )
        let historyStore = TestSnapshotHistoryStore()
        _ = try makeModel(villages: [village], historyStore: historyStore)

        let envelope = try XCTUnwrap(historyStore.load())
        let entry = try XCTUnwrap(envelope.entries.first)
        let buildings = try XCTUnwrap(
            entry.coverage.section(base: .home, rawSection: "buildings")
        )
        XCTAssertEqual(buildings.completeness, .unavailable)
        XCTAssertFalse(buildings.isComplete)
    }

    /// Issue #173 / #205 手工验证等价项:两个真实村庄连续导入。
    /// 无协议的真实 fixture → 双村 buildings proof 均 unavailable;
    /// 对村 A 导入带 coverage 声明的 JSON → 村 A complete、村 B 保持
    /// unavailable(per-village 隔离,证明不会跨村庄借用)。
    @MainActor
    func testTwoRealVillageImportsKeepUnknownAndIsolatePerVillageProof() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(forResource: "anonymized_account_snapshot", withExtension: "json")
        )
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        let villageAJSON = fixture.replacingOccurrences(
            of: "\"#ANONYMIZED\"", with: "\"#2QJQ8J88\""
        )
        let villageBJSON = fixture.replacingOccurrences(
            of: "\"#ANONYMIZED\"", with: "\"#2QJQ8J89\""
        )
        let villageA = VillageProfile(
            id: UUID(),
            name: "村庄 A",
            accountSnapshot: snapshot(tag: "#2QJQ8J88", text: villageAJSON)
        )
        let villageB = VillageProfile(
            id: UUID(),
            name: "村庄 B",
            accountSnapshot: snapshot(tag: "#2QJQ8J89", text: villageBJSON)
        )
        let historyStore = TestSnapshotHistoryStore()
        let model = try makeModel(
            villages: [villageA, villageB],
            historyStore: historyStore,
            clipboardReader: {
                """
                {"tag":"#2QJQ8J88","buildings":[{"data":1,"lvl":1}],
                 "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
                """
            }
        )
        let idA = model.villages[0].id
        let idB = model.villages[1].id

        // 启动迁移后:双村真实 fixture 均无协议 → 均 unavailable。
        var envelope = try XCTUnwrap(historyStore.load())
        var entryA = try XCTUnwrap(
            envelope.entry(id: XCTUnwrap(envelope.activeLineage(for: idA)?.lastEntryID))
        )
        var entryB = try XCTUnwrap(
            envelope.entry(id: XCTUnwrap(envelope.activeLineage(for: idB)?.lastEntryID))
        )
        XCTAssertFalse(
            try XCTUnwrap(entryA.coverage.section(base: .home, rawSection: "buildings")).isComplete,
            "村庄 A 无协议不得 complete"
        )
        XCTAssertFalse(
            try XCTUnwrap(entryB.coverage.section(base: .home, rawSection: "buildings")).isComplete,
            "村庄 B 无协议不得 complete"
        )

        // 村 A 快捷导入带 coverage 声明的 JSON → 村 A 冻结 declared 但不 complete,村 B 不变。
        guard case .success(let preview) = model.prepareQuickImport(for: idA) else {
            return XCTFail("有效快照应能生成快捷导入预览")
        }
        assertCoverageIsKnownMetadata(preview.snapshot)
        XCTAssertTrue(model.applyQuickImport(preview))
        envelope = try XCTUnwrap(historyStore.load())
        entryA = try XCTUnwrap(
            envelope.entry(id: XCTUnwrap(envelope.activeLineage(for: idA)?.lastEntryID))
        )
        entryB = try XCTUnwrap(
            envelope.entry(id: XCTUnwrap(envelope.activeLineage(for: idB)?.lastEntryID))
        )
        let villageABuildings = try XCTUnwrap(
            entryA.coverage.section(base: .home, rawSection: "buildings")
        )
        XCTAssertEqual(
            villageABuildings.proof,
            .declared(source: "u.coc", version: "1", expectedCount: 1)
        )
        XCTAssertEqual(villageABuildings.completeness, .unavailable)
        XCTAssertFalse(villageABuildings.isComplete)
        XCTAssertFalse(
            try XCTUnwrap(entryB.coverage.section(base: .home, rawSection: "buildings")).isComplete,
            "村庄 B 不得借用村庄 A 的证明"
        )
    }
}
