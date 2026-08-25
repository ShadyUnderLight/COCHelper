import Foundation
import COCHelperApp
import COCHelperCore

// Issue #226：真实村庄连续导入验收记录器（脱敏输出，不打印 raw JSON / tag / token）。
// 用法：acceptance-runner <local-data-directory>
// 目录内需含 village-a-1.json … village-b-2.json（见 Tools/acceptance/local/README.md）。

@main
struct AcceptanceRunner {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        guard let directory = args.first else {
            fputs("用法: acceptance-runner <local-data-directory>\n", stderr)
            exit(2)
        }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        let required = [
            "village-a-1", "village-a-2",
            "village-b-1", "village-b-2",
        ]
        for name in required {
            let path = base.appendingPathComponent("\(name).json")
            guard FileManager.default.fileExists(atPath: path.path) else {
                fputs("缺少文件: \(path.path)\n", stderr)
                exit(2)
            }
        }

        do {
            let report = try await MainActor.run {
                try runAcceptance(base: base)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("验收失败: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    fileprivate static func runAcceptance(base: URL) throws -> AcceptanceReport {
        let suiteName = "acceptance-runner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-226-acceptance-\(UUID().uuidString).json")
        let manualURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-226-manual-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: historyURL)
            try? FileManager.default.removeItem(at: manualURL)
            if let journal = FileSnapshotHistoryStore(fileURL: historyURL).transactionJournalURL {
                try? FileManager.default.removeItem(at: journal)
            }
            if let mJournal = FileManualTrackerStore(fileURL: manualURL).transactionJournalURL {
                try? FileManager.default.removeItem(at: mJournal)
            }
        }
        let historyStore = FileSnapshotHistoryStore(fileURL: historyURL)
        let manualStore = FileManualTrackerStore(fileURL: manualURL)

        func makeModel() -> AppModel {
            AppModel(defaults: defaults, historyStore: historyStore, manualTrackerStore: manualStore)
        }

        func loadText(_ name: String) throws -> String {
            try String(
                contentsOf: base.appendingPathComponent("\(name).json"),
                encoding: .utf8
            )
        }

        var steps: [AcceptanceStepRecord] = []

        func currentEnvelope() throws -> SnapshotHistoryEnvelope? {
            try historyStore.load()
        }

        func recordStep(_ label: String, model: AppModel, villageID: UUID?) throws {
            let envelope = try historyStore.load()
            let villageHistory: SanitizedVillageHistory?
            if let villageID, let envelope {
                villageHistory = SanitizedVillageHistory(envelope: envelope, villageID: villageID)
            } else {
                villageHistory = nil
            }
            steps.append(
                AcceptanceStepRecord(
                    step: label,
                    villageCount: model.villages.count,
                    historyEntryCount: envelope?.entries.count,
                    duplicateMetadataCount: envelope?.duplicateMetadata.count,
                    lineageCount: envelope?.lineages.count,
                    villageHistory: villageHistory
                )
            )
        }

        func sanitized(_ history: SanitizedVillageHistory) -> SanitizedVillageHistory {
            history
        }

        func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
            guard lhs == rhs else {
                throw AcceptanceError.validationFailed("\(message) — 期望 \(rhs)，实际 \(lhs)")
            }
        }

        func assertTrue(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw AcceptanceError.validationFailed(message)
            }
        }

        func assertSanitizedEqual(_ lhs: SanitizedVillageHistory, _ rhs: SanitizedVillageHistory, _ context: String) throws {
            try assertEqual(lhs.entryCount, rhs.entryCount, "\(context) entryCount 应一致")
            try assertEqual(lhs.baselineCount, rhs.baselineCount, "\(context) baselineCount 应一致")
            try assertEqual(lhs.latestIsBaseline, rhs.latestIsBaseline, "\(context) latestIsBaseline 应一致")
            try assertEqual(lhs.duplicateImportCount, rhs.duplicateImportCount, "\(context) duplicateImportCount 应一致")
            try assertEqual(lhs.latestAppliedAt, rhs.latestAppliedAt, "\(context) latestAppliedAt 应一致")
            try assertEqual(lhs.latestCheckedAt, rhs.latestCheckedAt, "\(context) latestCheckedAt 应一致（duplicate 最近检查）")
            try assertEqual(lhs.statisticsSignature, rhs.statisticsSignature, "\(context) statisticsSignature 应一致（所有指标 state/value/reason）")
        }

        func accountImport(_ name: String, model: AppModel) throws {
            model.importText = try loadText(name)
            model.parseAccountText()
            guard model.pendingAccountSnapshot != nil else {
                throw AcceptanceError.importFailed("账号导入解析失败: \(name)")
            }
            guard model.applyPendingAccountSnapshot() else {
                let message = model.accountImportError ?? "未知错误"
                throw AcceptanceError.importFailed("账号导入提交失败: \(name) — \(message)")
            }
        }

        func quickImport(_ name: String, villageID: UUID, model: inout AppModel) throws {
            let text = try loadText(name)
            model = AppModel(
                defaults: defaults,
                clipboardReader: { text },
                historyStore: historyStore,
                manualTrackerStore: manualStore
            )
            guard case .success(let preview) = model.prepareQuickImport(for: villageID) else {
                throw AcceptanceError.importFailed("快捷导入预览失败: \(name)")
            }
            guard model.applyQuickImport(preview) else {
                throw AcceptanceError.importFailed("快捷导入提交失败: \(name)")
            }
        }

        func restart() -> AppModel {
            AppModel(defaults: defaults, historyStore: historyStore, manualTrackerStore: manualStore)
        }

        // 初始：单村庄（默认占位），导入 A1 后再创建 B，保证 A1 在单村庄环境下准确路由
        var model = makeModel()
        try accountImport("village-a-1", model: model)
        let villageAID = try requireVillageID(model: model, index: 0, label: "A")
        try assertTrue(model.villages.count == 1, "A1 后村庄数量应为 1")
        try recordStep("A1-account-import", model: model, villageID: villageAID)
        let envelopeAfterA1 = try XCTUnwrapWrapper(try currentEnvelope())
        let historyAfterA1 = SanitizedVillageHistory(envelope: envelopeAfterA1, villageID: villageAID)
        let lineageAfterA1 = envelopeAfterA1.activeLineage(for: villageAID)
        try assertTrue(lineageAfterA1 != nil, "A1 后应存在 active lineage")
        let lineageIDAfterA1 = try XCTUnwrapWrapper(lineageAfterA1).lineageID
        let entryCountAfterA1 = envelopeAfterA1.entries.count
        let duplicateCountAfterA1 = envelopeAfterA1.duplicateMetadata.count
        let lineageCountAfterA1 = envelopeAfterA1.lineages.count
        let sanitizedAfterA1 = historyAfterA1
        try assertTrue(entryCountAfterA1 == 1, "A1 后 history entries 应为 1")
        try assertTrue(historyAfterA1.entryCount == 1, "A1 后 village history entryCount 应为 1")

        // 创建村庄 B（走正常 AppModel 路径），此时 A 已有历史，B 为空
        model.addVillageForImport()
        let createdBID = model.selectedVillageID
        try assertTrue(model.villages.count == 2, "创建村庄 B 后村庄数应为 2")
        model.renameSelectedVillage("村庄 B")
        let renamedB = model.villages.first(where: { $0.id == createdBID })
        try assertTrue(renamedB?.name == "村庄 B", "村庄 B 重命名应成功")
        let villageBID = createdBID
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "创建 B 后 A 仍应存在")
        let envelopeAfterCreateB = try XCTUnwrapWrapper(try currentEnvelope())
        try assertEqual(envelopeAfterCreateB.entries.count, entryCountAfterA1, "创建 B 后 entries 应不变")
        try assertEqual(envelopeAfterCreateB.lineages.count, lineageCountAfterA1, "创建 B 后 lineage 应不变")
        try assertEqual(envelopeAfterCreateB.duplicateMetadata.count, duplicateCountAfterA1, "创建 B 后 duplicate 应不变")

        // B1 快捷导入（与 A1 同处于首次 restart 前，构成 A1→B1 交错）
        let entryCountBeforeB1 = envelopeAfterCreateB.entries.count
        let lineageCountBeforeB1 = envelopeAfterCreateB.lineages.count
        try quickImport("village-b-1", villageID: villageBID, model: &model)
        try assertTrue(model.villages.contains(where: { $0.id == villageBID }), "B1 后村庄 B ID 应不变")
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "B1 后村庄 A ID 仍应存在")
        try assertEqual(model.villages.count, 2, "B1 后村庄数量应仍为 2")
        try recordStep("B1-quick-import", model: model, villageID: villageBID)
        let envelopeAfterB1 = try XCTUnwrapWrapper(try currentEnvelope())
        let historyAfterB1 = SanitizedVillageHistory(envelope: envelopeAfterB1, villageID: villageBID)
        let lineageAfterB1 = envelopeAfterB1.activeLineage(for: villageBID)
        try assertTrue(lineageAfterB1 != nil, "B1 后应存在 active lineage")
        try assertEqual(envelopeAfterB1.entries.count, entryCountBeforeB1 + 1, "B1 后 history entries 应 +1")
        try assertEqual(envelopeAfterB1.lineages.count, lineageCountBeforeB1 + 1, "B1 后 lineage 数量应 +1（新增 B）")
        try assertEqual(lineageAfterB1?.villageID, villageBID, "B1 后 lineage villageID 应为 B")
        try assertTrue(historyAfterB1.entryCount == 1, "B1 后 B 的 village history entryCount 应为 1")
        let lineageIDAfterB1 = try XCTUnwrapWrapper(lineageAfterB1).lineageID
        // B1 后 A 的 history 应保持不变（交错不应影响对方）
        let historyAAfterB1 = SanitizedVillageHistory(envelope: envelopeAfterB1, villageID: villageAID)
        try assertSanitizedEqual(historyAAfterB1, sanitizedAfterA1, "B1 后 A")
        // 为 restart 前保存两边完整快照
        let envelopeBeforeRestart = try XCTUnwrapWrapper(try currentEnvelope())
        let sanABeforeRestart = SanitizedVillageHistory(envelope: envelopeBeforeRestart, villageID: villageAID)
        let sanBBeforeRestart = SanitizedVillageHistory(envelope: envelopeBeforeRestart, villageID: villageBID)
        let lineageIDA_BeforeRestart = envelopeBeforeRestart.activeLineage(for: villageAID)?.lineageID
        let lineageIDB_BeforeRestart = envelopeBeforeRestart.activeLineage(for: villageBID)?.lineageID
        try assertTrue(lineageIDA_BeforeRestart == lineageIDAfterA1, "restart 前 A lineageID 应仍为 A1 的 lineage")
        try assertTrue(lineageIDB_BeforeRestart == lineageIDAfterB1, "restart 前 B lineageID 应仍为 B1 的 lineage")

        // 共同 restart：A1/B1 都存在后重启，验证两边同时一致（交错边界）
        model = restart()
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "重启后村庄 A ID 应不变")
        try assertTrue(model.villages.contains(where: { $0.id == villageBID }), "重启后村庄 B ID 应不变")
        try assertTrue(model.villages.count == 2, "重启后村庄数应仍为 2")
        let envelopeAfterRestart = try XCTUnwrapWrapper(try currentEnvelope())
        let sanAAfterRestart = SanitizedVillageHistory(envelope: envelopeAfterRestart, villageID: villageAID)
        let sanBAfterRestart = SanitizedVillageHistory(envelope: envelopeAfterRestart, villageID: villageBID)
        try assertEqual(envelopeAfterRestart.entries.count, envelopeBeforeRestart.entries.count, "交错 restart 前后 entries 应一致")
        try assertEqual(envelopeAfterRestart.lineages.count, envelopeBeforeRestart.lineages.count, "交错 restart 前后 lineage 应一致")
        try assertEqual(envelopeAfterRestart.duplicateMetadata.count, envelopeBeforeRestart.duplicateMetadata.count, "交错 restart 前后 duplicate 应一致")
        try assertSanitizedEqual(sanAAfterRestart, sanABeforeRestart, "A 交错 restart")
        try assertSanitizedEqual(sanBAfterRestart, sanBBeforeRestart, "B 交错 restart")
        try assertTrue(envelopeAfterRestart.activeLineage(for: villageAID)?.lineageID == lineageIDA_BeforeRestart, "A 交错 restart 后 lineageID 应不变")
        try assertTrue(envelopeAfterRestart.activeLineage(for: villageBID)?.lineageID == lineageIDB_BeforeRestart, "B 交错 restart 后 lineageID 应不变")
        try recordStep("after-restart-before-A2B2", model: model, villageID: villageAID)
        // 额外记录 B 的 after-restart 证据（脱敏 JSON 中保留两边）
        try recordStep("after-restart-before-A2B2-B", model: model, villageID: villageBID)

        // A2 正常导入（交错后先 A2）
        let entryCountBeforeA2 = envelopeAfterRestart.entries.count
        let dupCountBeforeA2 = envelopeAfterRestart.duplicateMetadata.count
        let lineageCountBeforeA2 = envelopeAfterRestart.lineages.count
        let villagesBeforeA2 = model.villages
        try accountImport("village-a-2", model: model)
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "A2 后村庄 A 的 villageID 应保持不变")
        try assertTrue(model.villages.count == villagesBeforeA2.count, "A2 后村庄数量不应变化")
        let currentVillageAfterA2 = try XCTUnwrapWrapper(model.villages.first(where: { $0.id == villageAID }))
        _ = currentVillageAfterA2
        try recordStep("A2-account-import", model: model, villageID: villageAID)
        let envelopeAfterA2 = try XCTUnwrapWrapper(try currentEnvelope())
        let historyAfterA2 = SanitizedVillageHistory(envelope: envelopeAfterA2, villageID: villageAID)
        let lineageAfterA2 = envelopeAfterA2.activeLineage(for: villageAID)
        let sanAfterA2 = historyAfterA2
        try assertTrue(lineageAfterA2 != nil, "A2 后应存在 active lineage")
        try assertEqual(envelopeAfterA2.entries.count, entryCountBeforeA2 + 1, "A2 正常导入后 history entries 应 +1")
        try assertEqual(envelopeAfterA2.duplicateMetadata.count, dupCountBeforeA2, "A2 正常导入不应增加 duplicate")
        try assertEqual(envelopeAfterA2.lineages.count, lineageCountBeforeA2, "A2 同村连续导入 lineage 数量应不变")
        try assertTrue(lineageAfterA2?.lineageID == lineageIDAfterA1, "A2 同账号导入应保持 continued lineageID")
        try assertEqual(lineageAfterA2?.villageID, villageAID, "A2 后 lineage villageID 应仍为 A")
        try assertEqual(sanAfterA2.entryCount, sanAAfterRestart.entryCount + 1, "A2 后 A entryCount 应 +1")
        // B 在 A2 后应保持不变
        let historyBAfterA2 = SanitizedVillageHistory(envelope: envelopeAfterA2, villageID: villageBID)
        try assertSanitizedEqual(historyBAfterA2, sanBAfterRestart, "A2 后 B 应保持不变")
        try assertTrue(envelopeAfterA2.activeLineage(for: villageBID)?.lineageID == lineageIDAfterB1, "A2 后 B lineageID 应不变")

        // B2 正常导入（交错后紧跟 B2）
        let entryCountBeforeB2 = envelopeAfterA2.entries.count
        let dupCountBeforeB2 = envelopeAfterA2.duplicateMetadata.count
        let lineageCountBeforeB2 = envelopeAfterA2.lineages.count
        let sanBBeforeB2 = SanitizedVillageHistory(envelope: envelopeAfterA2, villageID: villageBID)
        try quickImport("village-b-2", villageID: villageBID, model: &model)
        try assertTrue(model.villages.contains(where: { $0.id == villageBID }), "B2 后村庄 B ID 应不变")
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "B2 后 A 仍应存在")
        try assertEqual(model.villages.count, 2, "B2 后村庄数量应仍为 2")
        try recordStep("B2-quick-import", model: model, villageID: villageBID)
        let envelopeAfterB2 = try XCTUnwrapWrapper(try currentEnvelope())
        let historyAfterB2 = SanitizedVillageHistory(envelope: envelopeAfterB2, villageID: villageBID)
        let lineageAfterB2 = envelopeAfterB2.activeLineage(for: villageBID)
        let sanAfterB2 = historyAfterB2
        try assertTrue(lineageAfterB2 != nil, "B2 后应存在 active lineage")
        try assertEqual(envelopeAfterB2.entries.count, entryCountBeforeB2 + 1, "B2 正常导入后 entries 应 +1")
        try assertEqual(envelopeAfterB2.duplicateMetadata.count, dupCountBeforeB2, "B2 正常导入不应增加 duplicate")
        try assertEqual(envelopeAfterB2.lineages.count, lineageCountBeforeB2, "B2 同村连续导入 lineage 数应不变")
        try assertTrue(lineageAfterB2?.lineageID == lineageIDAfterB1, "B2 同账号导入应保持 continued lineage")
        try assertEqual(sanAfterB2.entryCount, sanBBeforeB2.entryCount + 1, "B2 后 B entryCount 应 +1")
        // A 在 B2 后应保持不变
        let historyAAfterB2 = SanitizedVillageHistory(envelope: envelopeAfterB2, villageID: villageAID)
        try assertSanitizedEqual(historyAAfterB2, sanAfterA2, "B2 后 A 应保持不变")
        try assertTrue(envelopeAfterB2.activeLineage(for: villageAID)?.lineageID == lineageIDAfterA1, "B2 后 A lineageID 应不变")

        // 重复前快照
        let dupCountBeforeA2Dup = envelopeAfterB2.duplicateMetadata.count
        let entryCountBeforeA2Dup = envelopeAfterB2.entries.count
        let dupImportBeforeA2Dup = SanitizedVillageHistory(envelope: envelopeAfterB2, villageID: villageAID).duplicateImportCount ?? 0
        let sanABeforeDup = SanitizedVillageHistory(envelope: envelopeAfterB2, villageID: villageAID)
        let sanBBeforeDup = SanitizedVillageHistory(envelope: envelopeAfterB2, villageID: villageBID)

        // A2 duplicate：不新增 entry，duplicate +1，严格 +1
        try accountImport("village-a-2", model: model)
        let envelopeAfterA2Dup = try XCTUnwrapWrapper(try currentEnvelope())
        let historyAfterA2Dup = SanitizedVillageHistory(envelope: envelopeAfterA2Dup, villageID: villageAID)
        let sanAfterA2Dup = historyAfterA2Dup
        try recordStep("A2-duplicate-account-import", model: model, villageID: villageAID)
        try assertEqual(envelopeAfterA2Dup.entries.count, entryCountBeforeA2Dup, "A2 duplicate 后 history entries 应不变")
        try assertEqual(envelopeAfterA2Dup.duplicateMetadata.count, dupCountBeforeA2Dup + 1, "A2 duplicate 后 duplicateMetadata 应 +1")
        if let expectedDupKey = envelopeAfterB2.activeLineage(for: villageAID)?.lastEntryID.uuidString {
            let dupMeta = envelopeAfterA2Dup.duplicateMetadata[expectedDupKey]
            try assertTrue(dupMeta != nil && dupMeta!.duplicateImportCount >= 1, "A2 duplicate 应记录对应 snapshot 的 duplicate metadata")
        } else {
            throw AcceptanceError.validationFailed("无法确定 A2 duplicate 的 expected key")
        }
        try assertEqual(envelopeAfterA2Dup.lineages.count, lineageCountBeforeB2, "A2 duplicate 后 lineage 数量应不变")
        try assertTrue(envelopeAfterA2Dup.activeLineage(for: villageAID)?.lineageID == lineageIDAfterA1, "A2 duplicate 后 lineageID 应不变")
        try assertEqual(sanAfterA2Dup.entryCount, sanABeforeDup.entryCount, "A2 duplicate 后 entryCount 应不变")
        let dupCountAfterA2Dup = historyAfterA2Dup.duplicateImportCount ?? 0
        try assertEqual(dupCountAfterA2Dup, dupImportBeforeA2Dup + 1, "A2 duplicate 后 duplicateImportCount 应严格 +1")
        try assertSanitizedEqual(SanitizedVillageHistory(envelope: envelopeAfterA2Dup, villageID: villageBID), sanBBeforeDup, "A2 duplicate 后 B 应保持不变")
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "A2 duplicate 后 A ID 仍应存在")
        try assertTrue(model.villages.contains(where: { $0.id == villageBID }), "A2 duplicate 后 B ID 仍应存在")

        // B2 duplicate
        let dupCountBeforeB2Dup = envelopeAfterA2Dup.duplicateMetadata.count
        let entryCountBeforeB2Dup = envelopeAfterA2Dup.entries.count
        let dupImportBeforeB2Dup = SanitizedVillageHistory(envelope: envelopeAfterA2Dup, villageID: villageBID).duplicateImportCount ?? 0
        let sanABeforeB2Dup = SanitizedVillageHistory(envelope: envelopeAfterA2Dup, villageID: villageAID)
        try quickImport("village-b-2", villageID: villageBID, model: &model)
        let envelopeAfterB2Dup = try XCTUnwrapWrapper(try currentEnvelope())
        let historyAfterB2Dup = SanitizedVillageHistory(envelope: envelopeAfterB2Dup, villageID: villageBID)
        let sanAfterB2Dup = historyAfterB2Dup
        try recordStep("B2-duplicate-quick-import", model: model, villageID: villageBID)
        try assertEqual(envelopeAfterB2Dup.entries.count, entryCountBeforeB2Dup, "B2 duplicate 后 entries 应不变")
        try assertEqual(envelopeAfterB2Dup.duplicateMetadata.count, dupCountBeforeB2Dup + 1, "B2 duplicate 后 duplicate 应 +1")
        if let expectedDupKeyB = envelopeAfterA2Dup.activeLineage(for: villageBID)?.lastEntryID.uuidString {
            let dupMetaB = envelopeAfterB2Dup.duplicateMetadata[expectedDupKeyB]
            try assertTrue(dupMetaB != nil && dupMetaB!.duplicateImportCount >= 1, "B2 duplicate 应记录对应 snapshot 的 duplicate metadata")
        }
        try assertEqual(envelopeAfterB2Dup.lineages.count, lineageCountBeforeB2, "B2 duplicate 后 lineage 数应不变")
        try assertTrue(envelopeAfterB2Dup.activeLineage(for: villageBID)?.lineageID == lineageIDAfterB1, "B2 duplicate 后 lineageID 应不变")
        let sanBBeforeB2Dup = sanBBeforeDup // B 在 A2 duplicate 后未变，复用
        try assertEqual(sanAfterB2Dup.entryCount, sanBBeforeB2Dup.entryCount, "B2 duplicate 后 entryCount 应不变")
        let dupImportAfterB2Dup = historyAfterB2Dup.duplicateImportCount ?? 0
        try assertEqual(dupImportAfterB2Dup, dupImportBeforeB2Dup + 1, "B2 duplicate 后 duplicateImportCount 应严格 +1")
        try assertSanitizedEqual(SanitizedVillageHistory(envelope: envelopeAfterB2Dup, villageID: villageAID), sanABeforeB2Dup, "B2 duplicate 后 A 应保持不变")

        // 串档检查 + 最终 restart duplicate 持久化（覆盖 P1 duplicate 跨 restart）
        let envelopeBeforeFinalRestart = try XCTUnwrapWrapper(try currentEnvelope())
        let sanABeforeFinalRestart = SanitizedVillageHistory(envelope: envelopeBeforeFinalRestart, villageID: villageAID)
        let sanBBeforeFinalRestart = SanitizedVillageHistory(envelope: envelopeBeforeFinalRestart, villageID: villageBID)
        let dupCountBeforeFinalRestart = envelopeBeforeFinalRestart.duplicateMetadata.count
        let lineageIDA_BeforeFinalRestart = envelopeBeforeFinalRestart.activeLineage(for: villageAID)?.lineageID
        let lineageIDB_BeforeFinalRestart = envelopeBeforeFinalRestart.activeLineage(for: villageBID)?.lineageID
        model = restart()
        let envelope = try XCTUnwrapWrapper(try currentEnvelope())
        let historyA = SanitizedVillageHistory(envelope: envelope, villageID: villageAID)
        let historyB = SanitizedVillageHistory(envelope: envelope, villageID: villageBID)
        // final restart persistence：duplicate / trust / statistics / baseline / diagnostics 均应一致
        try assertEqual(envelope.entries.count, envelopeBeforeFinalRestart.entries.count, "final restart 前后 entries 应一致")
        try assertEqual(envelope.lineages.count, envelopeBeforeFinalRestart.lineages.count, "final restart 前后 lineages 应一致")
        try assertEqual(envelope.duplicateMetadata.count, dupCountBeforeFinalRestart, "final restart 前后 duplicateMetadata 应一致")
        try assertSanitizedEqual(historyA, sanABeforeFinalRestart, "A final restart")
        try assertSanitizedEqual(historyB, sanBBeforeFinalRestart, "B final restart")
        try assertTrue(envelope.activeLineage(for: villageAID)?.lineageID == lineageIDA_BeforeFinalRestart, "A final restart 后 lineageID 应不变")
        try assertTrue(envelope.activeLineage(for: villageBID)?.lineageID == lineageIDB_BeforeFinalRestart, "B final restart 后 lineageID 应不变")
        try assertEqual(historyA.duplicateImportCount, 1, "A final restart 后 duplicateImportCount 仍为 1")
        try assertEqual(historyB.duplicateImportCount, 1, "B final restart 后 duplicateImportCount 仍为 1")
        let lineageA = envelope.activeLineage(for: villageAID)
        let lineageB = envelope.activeLineage(for: villageBID)
        guard let lineageA, let lineageB else {
            throw AcceptanceError.validationFailed("缺少 active lineage")
        }
        guard lineageA.villageID == villageAID, lineageB.villageID == villageBID else {
            throw AcceptanceError.validationFailed("lineage villageID 串档")
        }
        guard lineageA.lineageID != lineageB.lineageID else {
            throw AcceptanceError.validationFailed("A/B lineageID 不应相同")
        }
        let entriesA = envelope.entries.filter { $0.villageID == villageAID }
        let entriesB = envelope.entries.filter { $0.villageID == villageBID }
        guard !entriesA.isEmpty, !entriesB.isEmpty else {
            throw AcceptanceError.validationFailed("A/B history entry 为空")
        }
        guard Set(entriesA.map(\.snapshotID)).isDisjoint(with: Set(entriesB.map(\.snapshotID))) else {
            throw AcceptanceError.validationFailed("A/B history entry 交叉")
        }
        let villageIDs = Set([villageAID, villageBID])
        try assertTrue(villageIDs.count == 2, "A/B villageID 应不同")
        for entry in entriesA {
            try assertTrue(entry.lineageID == lineageA.lineageID, "A 的 history entry lineageID 应与 active lineage 一致")
        }
        for entry in entriesB {
            try assertTrue(entry.lineageID == lineageB.lineageID, "B 的 history entry lineageID 应与 active lineage 一致")
        }
        // 额外：交错后两边 entry 均应为 2（A1/A2 与 B1/B2，各含 baseline+一变化）
        try assertEqual(historyA.entryCount, 2, "最终 A entryCount 应为 2")
        try assertEqual(historyB.entryCount, 2, "最终 B entryCount 应为 2")

        return AcceptanceReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            commitSHA: ProcessInfo.processInfo.environment["ACCEPTANCE_COMMIT_SHA"],
            steps: steps,
            finalState: AcceptanceFinalState(
                villageA: historyA,
                villageB: historyB,
                lineageIsolated: true,
                villageACount: historyA.entryCount,
                villageBCount: historyB.entryCount
            )
        )
    }

    @MainActor
    private static func requireVillageID(model: AppModel, index: Int, label: String) throws -> UUID {
        guard model.villages.indices.contains(index) else {
            throw AcceptanceError.importFailed("村庄 \(label) 未创建")
        }
        return model.villages[index].id
    }
}

private enum AcceptanceError: LocalizedError {
    case importFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .importFailed(let message), .validationFailed(let message):
            return message
        }
    }
}

private func XCTUnwrapWrapper<T>(_ value: T?) throws -> T {
    guard let value else {
        throw AcceptanceError.validationFailed("必需值为 nil")
    }
    return value
}

private struct AcceptanceReport: Encodable {
    let generatedAt: String
    let commitSHA: String?
    let steps: [AcceptanceStepRecord]
    let finalState: AcceptanceFinalState
}

private struct AcceptanceStepRecord: Encodable {
    let step: String
    let villageCount: Int
    let historyEntryCount: Int?
    let duplicateMetadataCount: Int?
    let lineageCount: Int?
    let villageHistory: SanitizedVillageHistory?
}

private struct AcceptanceFinalState: Encodable {
    let villageA: SanitizedVillageHistory
    let villageB: SanitizedVillageHistory
    let lineageIsolated: Bool
    let villageACount: Int
    let villageBCount: Int
}

private struct SanitizedStatValue: Encodable, Equatable {
    let state: String
    let value: Int?
    let reason: String?
    init(_ v: SnapshotStatisticValue) {
        state = v.state.rawValue
        value = v.value
        reason = v.reason
    }
}

private struct SanitizedWindowSignature: Encodable, Equatable {
    let buildingUpgradeCompletions: SanitizedStatValue
    let aggregateInferredBuildingUpgradeCompletions: SanitizedStatValue
    let buildingLevelGrowth: SanitizedStatValue
    let aggregateInferredBuildingLevelGrowth: SanitizedStatValue
    let wallLevelGrowth: SanitizedStatValue
    let aggregateInferredWallLevelGrowth: SanitizedStatValue
    let heroLevelGrowth: SanitizedStatValue
    let troopLevelGrowth: SanitizedStatValue
    let spellLevelGrowth: SanitizedStatValue
    let petLevelGrowth: SanitizedStatValue
    let heroEquipmentLevelGrowth: SanitizedStatValue
    let aggregateInferredEventCount: SanitizedStatValue
    init(_ w: SnapshotHistoryStatisticsWindow) {
        buildingUpgradeCompletions = SanitizedStatValue(w.buildingUpgradeCompletions)
        aggregateInferredBuildingUpgradeCompletions = SanitizedStatValue(w.aggregateInferredBuildingUpgradeCompletions)
        buildingLevelGrowth = SanitizedStatValue(w.buildingLevelGrowth)
        aggregateInferredBuildingLevelGrowth = SanitizedStatValue(w.aggregateInferredBuildingLevelGrowth)
        wallLevelGrowth = SanitizedStatValue(w.wallLevelGrowth)
        aggregateInferredWallLevelGrowth = SanitizedStatValue(w.aggregateInferredWallLevelGrowth)
        heroLevelGrowth = SanitizedStatValue(w.heroLevelGrowth)
        troopLevelGrowth = SanitizedStatValue(w.troopLevelGrowth)
        spellLevelGrowth = SanitizedStatValue(w.spellLevelGrowth)
        petLevelGrowth = SanitizedStatValue(w.petLevelGrowth)
        heroEquipmentLevelGrowth = SanitizedStatValue(w.heroEquipmentLevelGrowth)
        aggregateInferredEventCount = SanitizedStatValue(w.aggregateInferredEventCount)
    }
}

private struct SanitizedStatisticsSignature: Encodable, Equatable {
    let today: SanitizedWindowSignature
    let last7Days: SanitizedWindowSignature
    let last30Days: SanitizedWindowSignature
    let diagnostics: [String]
    init(_ s: SnapshotHistoryStatistics) {
        today = SanitizedWindowSignature(s.today)
        last7Days = SanitizedWindowSignature(s.last7Days)
        last30Days = SanitizedWindowSignature(s.last30Days)
        diagnostics = s.diagnostics
    }
}

/// 基于历史 envelope 的村庄级脱敏摘要（替代已移除的 UI projection）。
private struct SanitizedVillageHistory: Encodable, Equatable {
    let entryCount: Int
    let baselineCount: Int
    let latestIsBaseline: Bool
    let duplicateImportCount: Int?
    let latestAppliedAt: Date?
    let latestCheckedAt: Date?
    let statisticsSignature: SanitizedStatisticsSignature?

    init(envelope: SnapshotHistoryEnvelope, villageID: UUID, referenceDate: Date = Date()) {
        // P1(#260 review)：必须先定位 active lineage，再过滤 villageID + lineageID；
        // 不同 lineage 的 entries 不得混入 adjacent diff（Diff Engine 会 suppress + lineageMismatch）。
        guard let activeLineageID = envelope.activeLineage(for: villageID)?.lineageID else {
            entryCount = 0
            baselineCount = 0
            latestIsBaseline = false
            duplicateImportCount = nil
            latestAppliedAt = nil
            latestCheckedAt = nil
            statisticsSignature = nil
            return
        }
        // 不排序：adjacentDiffs 必须吃 envelope append order，appliedAt 排序只用于展示。
        let entries = envelope.entries.filter {
            $0.villageID == villageID && $0.lineageID == activeLineageID
        }
        entryCount = entries.count
        baselineCount = entries.filter(\.isBaseline).count
        // latest 单独用 max 找（appliedAt 优先，snapshotID 做 tiebreaker）。
        let latestEntry = entries.max {
            if $0.appliedAt != $1.appliedAt {
                return $0.appliedAt < $1.appliedAt
            }
            return $0.snapshotID.uuidString > $1.snapshotID.uuidString
        }
        latestIsBaseline = latestEntry?.isBaseline ?? false
        latestAppliedAt = latestEntry?.appliedAt
        // duplicateImportCount 绑定 latest entry。
        if let latestSnapshotID = latestEntry?.snapshotID,
           let meta = envelope.duplicateMetadata[latestSnapshotID.uuidString] {
            duplicateImportCount = meta.duplicateImportCount
        } else {
            duplicateImportCount = nil
        }
        // P2(#260 review)：latestCheckedAt 取 active-lineage 全部 entries 的 duplicate metadata
        // 中最大 lastSeenAt，而非只看 latest entry——重新导入旧快照会刷新旧 entry 的 lastSeenAt。
        latestCheckedAt = entries.compactMap { entry in
            envelope.duplicateMetadata[entry.snapshotID.uuidString]?.lastSeenAt
        }.max()
        // adjacent diff 吃 envelope append order（不排序）。
        if entries.count >= 2 {
            let diffs = SnapshotDiffEngine.adjacentDiffs(in: entries)
            let statistics = SnapshotHistoryStatistics.calculate(
                diffs: diffs,
                referenceDate: referenceDate,
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
            statisticsSignature = SanitizedStatisticsSignature(statistics)
        } else {
            statisticsSignature = nil
        }
    }
}
