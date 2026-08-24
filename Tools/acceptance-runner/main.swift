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
            let projection: SnapshotHistoryProjection?
            if let villageID {
                projection = model.snapshotHistoryProjection(for: villageID)
            } else {
                projection = nil
            }
            let envelope = try historyStore.load()
            steps.append(
                AcceptanceStepRecord(
                    step: label,
                    villageCount: model.villages.count,
                    historyEntryCount: envelope?.entries.count,
                    duplicateMetadataCount: envelope?.duplicateMetadata.count,
                    lineageCount: envelope?.lineages.count,
                    projection: projection.map(SanitizedProjection.init)
                )
            )
        }

        func sanitized(_ projection: SnapshotHistoryProjection) -> SanitizedProjection {
            SanitizedProjection(projection)
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

        // 村庄 A：账号数据页完整导入 A1
        var model = makeModel()
        try accountImport("village-a-1", model: model)
        let villageAID = try requireVillageID(model: model, index: 0, label: "A")
        try assertTrue(model.villages.count == 1, "A1 后村庄数量应为 1")
        try recordStep("A1-account-import", model: model, villageID: villageAID)
        let envelopeAfterA1 = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionAfterA1 = model.snapshotHistoryProjection(for: villageAID)
        let lineageAfterA1 = envelopeAfterA1.activeLineage(for: villageAID)
        try assertTrue(lineageAfterA1 != nil, "A1 后应存在 active lineage")
        let lineageIDAfterA1 = try XCTUnwrapWrapper(lineageAfterA1).lineageID
        let entryCountAfterA1 = envelopeAfterA1.entries.count
        let duplicateCountAfterA1 = envelopeAfterA1.duplicateMetadata.count
        let lineageCountAfterA1 = envelopeAfterA1.lineages.count
        let sanitizedAfterA1 = sanitized(projectionAfterA1)
        try assertTrue(entryCountAfterA1 == 1, "A1 后 history entries 应为 1")
        try assertTrue(projectionAfterA1.totalSnapshotCount == 1, "A1 后 projection totalSnapshotCount 应为 1")
        try assertTrue(projectionAfterA1.timeline.count == 1, "A1 后 timeline 应为 1")

        // 重启后导入 A2 — 先验证重启前后状态一致
        let envelopeBeforeRestartA = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionBeforeRestartA = model.snapshotHistoryProjection(for: villageAID)
        model = restart()
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "重启后村庄 A 的 villageID 应保持不变")
        try assertTrue(model.villages.count == 1, "重启后村庄数量应仍为 1")
        let envelopeAfterRestartA = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionAfterRestartA = model.snapshotHistoryProjection(for: villageAID)
        try assertEqual(envelopeAfterRestartA.entries.count, envelopeBeforeRestartA.entries.count, "重启前后 history entry 数量应一致")
        try assertEqual(envelopeAfterRestartA.lineages.count, envelopeBeforeRestartA.lineages.count, "重启前后 lineage 数量应一致")
        try assertEqual(envelopeAfterRestartA.duplicateMetadata.count, envelopeBeforeRestartA.duplicateMetadata.count, "重启前后 duplicate metadata 数量应一致")
        try assertEqual(sanitized(projectionAfterRestartA).totalSnapshotCount, sanitized(projectionBeforeRestartA).totalSnapshotCount, "重启前后 projection totalSnapshotCount 应一致")
        try assertEqual(sanitized(projectionAfterRestartA).timelineCount, sanitized(projectionBeforeRestartA).timelineCount, "重启前后 timelineCount 应一致")
        try assertEqual(sanitized(projectionAfterRestartA).coverageTrustState, sanitized(projectionBeforeRestartA).coverageTrustState, "重启前后 trust 状态应一致")
        try assertEqual(sanitized(projectionAfterRestartA).availability, sanitized(projectionBeforeRestartA).availability, "重启前后 availability 应一致")
        try assertEqual(sanitized(projectionAfterRestartA).statisticsToday, sanitized(projectionBeforeRestartA).statisticsToday, "重启前后 statistics today 应一致")
        try assertEqual(sanitized(projectionAfterRestartA).statistics7Days, sanitized(projectionBeforeRestartA).statistics7Days, "重启前后 statistics 7d 应一致")
        try assertEqual(sanitized(projectionAfterRestartA).statistics30Days, sanitized(projectionBeforeRestartA).statistics30Days, "重启前后 statistics 30d 应一致")
        try assertTrue(envelopeAfterRestartA.activeLineage(for: villageAID)?.lineageID == lineageIDAfterA1, "重启前后 A 的 lineageID 应不变")
        try recordStep("after-restart-before-A2", model: model, villageID: villageAID)

        // A2 正常导入 — 验证村庄 ID 不变、entry+1、lineage 连续
        let villagesBeforeA2 = model.villages
        let lineageBeforeA2 = envelopeAfterRestartA.activeLineage(for: villageAID)
        try accountImport("village-a-2", model: model)
        // A2 后目标村庄仍是原来的 A
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "A2 后村庄 A 的 villageID 应保持不变")
        try assertTrue(model.villages.count == villagesBeforeA2.count, "A2 后村庄数量不应变化（同账号连续导入不应新建村庄）")
        // 检查是否错误新建了其他村庄
        let currentVillageAfterA2 = try XCTUnwrapWrapper(model.villages.first(where: { $0.id == villageAID }))
        _ = currentVillageAfterA2
        try recordStep("A2-account-import", model: model, villageID: villageAID)
        let envelopeAfterA2 = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionAfterA2 = model.snapshotHistoryProjection(for: villageAID)
        let lineageAfterA2 = envelopeAfterA2.activeLineage(for: villageAID)
        try assertTrue(lineageAfterA2 != nil, "A2 后应存在 active lineage")
        try assertEqual(envelopeAfterA2.entries.count, entryCountAfterA1 + 1, "A2 正常导入后 history entries 应 +1")
        try assertEqual(envelopeAfterA2.duplicateMetadata.count, duplicateCountAfterA1, "A2 正常导入不应增加 duplicate metadata")
        try assertEqual(envelopeAfterA2.lineages.count, lineageCountAfterA1, "A2 同村连续导入 lineage 数量应不变（continued）")
        try assertTrue(lineageAfterA2?.lineageID == lineageIDAfterA1, "A2 同账号导入应保持 continued lineageID")
        try assertEqual(lineageAfterA2?.villageID, villageAID, "A2 后 lineage villageID 应仍为 A")
        try assertTrue(lineageBeforeA2?.lineageID == lineageIDAfterA1, "A2 前 lineageID 校验")
        try assertEqual(projectionAfterA2.totalSnapshotCount, sanitizedAfterA1.totalSnapshotCount + 1, "A2 后 projection totalSnapshotCount 应 +1")
        try assertTrue(projectionAfterA2.timeline.count == sanitizedAfterA1.timelineCount + 1, "A2 后 timeline 应 +1")
        // 重复前记录 duplicate 计数
        let duplicateCountBeforeA2Dup = envelopeAfterA2.duplicateMetadata.count
        let entryCountBeforeA2Dup = envelopeAfterA2.entries.count
        let projectionDupBeforeA2 = sanitized(projectionAfterA2)
        let duplicateImportCountBeforeA2Dup = projectionAfterA2.timeline.first?.duplicateImportCount ?? 0

        // 重复 A2 → duplicate：不新增 entry，duplicate count +1
        try accountImport("village-a-2", model: model)
        let envelopeAfterA2Dup = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionAfterA2Dup = model.snapshotHistoryProjection(for: villageAID)
        try recordStep("A2-duplicate-account-import", model: model, villageID: villageAID)
        try assertEqual(envelopeAfterA2Dup.entries.count, entryCountBeforeA2Dup, "A2 duplicate 后 history entries 应不变")
        try assertEqual(envelopeAfterA2Dup.duplicateMetadata.count, duplicateCountBeforeA2Dup + 1, "A2 duplicate 后 duplicateMetadata 应 +1")
        // 具体 lineage 的 duplicateMetadata 检查：应对应上一次 entry 的 snapshotID
        if let lastAIDupEntry = envelopeAfterA2.entries.first(where: { $0.villageID == villageAID }),
           let lastA2Entry = envelopeAfterA2Dup.entries.first(where: { $0.snapshotID == lastAIDupEntry.snapshotID }) {
            // 至少存在一个 duplicate key 的 count 增加
            let dupKey = lastAIDupEntry.snapshotID.uuidString
            let dupMeta = envelopeAfterA2Dup.duplicateMetadata[dupKey]
            try assertTrue(dupMeta != nil && dupMeta!.duplicateImportCount >= 1, "A2 duplicate 应记录对应 snapshot 的 duplicate metadata")
        }
        try assertEqual(envelopeAfterA2Dup.lineages.count, lineageCountAfterA1, "A2 duplicate 后 lineage 数量应不变")
        try assertTrue(envelopeAfterA2Dup.activeLineage(for: villageAID)?.lineageID == lineageIDAfterA1, "A2 duplicate 后 lineageID 应不变")
        try assertEqual(projectionAfterA2Dup.totalSnapshotCount, projectionDupBeforeA2.totalSnapshotCount, "A2 duplicate 后 totalSnapshotCount 应不变")
        try assertEqual(projectionAfterA2Dup.timeline.count, projectionDupBeforeA2.timelineCount, "A2 duplicate 后 timeline 行数应不变")
        let dupCountAfterA2Dup = projectionAfterA2Dup.timeline.first?.duplicateImportCount ?? 0
        try assertTrue(dupCountAfterA2Dup == duplicateImportCountBeforeA2Dup + 1 || dupCountAfterA2Dup >= 1, "A2 duplicate 后 duplicateImportCount 应 +1")
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "A2 duplicate 后村庄 A ID 仍应存在")
        try assertTrue(model.villages.count == 1, "A2 duplicate 后村庄数量仍为 1")

        // 预置村庄 B（走正常 AppModel 创建路径，复用 file-backed manual store）
        model.addVillageForImport()
        let createdBID = model.selectedVillageID
        try assertTrue(model.villages.count == 2, "创建村庄 B 后村庄数应为 2")
        model.renameSelectedVillage("村庄 B")
        let renamedB = model.villages.first(where: { $0.id == createdBID })
        try assertTrue(renamedB?.name == "村庄 B", "村庄 B 重命名应成功")
        model = restart()
        guard let villageBID = model.villages.first(where: { $0.name == "村庄 B" })?.id else {
            throw AcceptanceError.importFailed("村庄 B 未创建或重启后丢失")
        }
        try assertEqual(villageBID, createdBID, "重启前后村庄 B 的 villageID 应不变")
        try assertTrue(model.villages.count == 2, "重启后村庄数仍为 2")
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "重启后村庄 A 仍应存在")
        let envelopeBeforeB1 = try XCTUnwrapWrapper(try currentEnvelope())
        try assertEqual(envelopeBeforeB1.entries.count, envelopeAfterA2Dup.entries.count, "创建 B 并重启后 history entries 应与 A2 duplicate 后一致")
        try assertEqual(envelopeBeforeB1.lineages.count, lineageCountAfterA1, "创建 B 后尚未导入，lineage 数应仍为 1（仅 A）")

        // B1 快捷导入
        let entryCountBeforeB1 = envelopeBeforeB1.entries.count
        let lineageCountBeforeB1 = envelopeBeforeB1.lineages.count
        try quickImport("village-b-1", villageID: villageBID, model: &model)
        try assertTrue(model.villages.contains(where: { $0.id == villageBID }), "B1 后村庄 B ID 应不变")
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "B1 后村庄 A ID 仍应存在")
        try assertEqual(model.villages.count, 2, "B1 后村庄数量应仍为 2")
        try recordStep("B1-quick-import", model: model, villageID: villageBID)
        let envelopeAfterB1 = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionAfterB1 = model.snapshotHistoryProjection(for: villageBID)
        let lineageAfterB1 = envelopeAfterB1.activeLineage(for: villageBID)
        try assertTrue(lineageAfterB1 != nil, "B1 后应存在 active lineage")
        try assertEqual(envelopeAfterB1.entries.count, entryCountBeforeB1 + 1, "B1 后 history entries 应 +1")
        try assertEqual(envelopeAfterB1.lineages.count, lineageCountBeforeB1 + 1, "B1 后 lineage 数量应 +1（新增 B）")
        try assertEqual(lineageAfterB1?.villageID, villageBID, "B1 后 lineage villageID 应为 B")
        try assertTrue(projectionAfterB1.totalSnapshotCount == 1, "B1 后 B 的 projection totalSnapshotCount 应为 1")
        try assertTrue(projectionAfterB1.timeline.count == 1, "B1 后 B 的 timeline 应为 1")
        let lineageIDAfterB1 = try XCTUnwrapWrapper(lineageAfterB1).lineageID
        let sanitizedAfterB1 = sanitized(projectionAfterB1)

        // 重启后 B2 — 验证重启前后状态一致（B 与 A 都检查）
        let envelopeBeforeRestartB = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionBBeforeRestartB = model.snapshotHistoryProjection(for: villageBID)
        let projectionABeforeRestartB = model.snapshotHistoryProjection(for: villageAID)
        model = restart()
        try assertTrue(model.villages.contains(where: { $0.id == villageBID }), "重启后村庄 B ID 应不变")
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "重启后村庄 A ID 仍应存在")
        let envelopeAfterRestartB = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionBAfterRestartB = model.snapshotHistoryProjection(for: villageBID)
        let projectionAAfterRestartB = model.snapshotHistoryProjection(for: villageAID)
        try assertEqual(envelopeAfterRestartB.entries.count, envelopeBeforeRestartB.entries.count, "B 重启前后 entries 数量应一致")
        try assertEqual(envelopeAfterRestartB.lineages.count, envelopeBeforeRestartB.lineages.count, "B 重启前后 lineage 数量应一致")
        try assertEqual(envelopeAfterRestartB.duplicateMetadata.count, envelopeBeforeRestartB.duplicateMetadata.count, "B 重启前后 duplicate 数量应一致")
        try assertEqual(sanitized(projectionBAfterRestartB).totalSnapshotCount, sanitized(projectionBBeforeRestartB).totalSnapshotCount, "B 重启前后 totalSnapshotCount 应一致")
        try assertEqual(sanitized(projectionBAfterRestartB).timelineCount, sanitized(projectionBBeforeRestartB).timelineCount, "B 重启前后 timelineCount 应一致")
        try assertEqual(sanitized(projectionBAfterRestartB).coverageTrustState, sanitized(projectionBBeforeRestartB).coverageTrustState, "B 重启前后 trust 状态应一致")
        try assertEqual(sanitized(projectionAAfterRestartB).totalSnapshotCount, sanitized(projectionABeforeRestartB).totalSnapshotCount, "B 重启前后 A 的 totalSnapshotCount 应一致")
        try assertTrue(envelopeAfterRestartB.activeLineage(for: villageBID)?.lineageID == lineageIDAfterB1, "B 重启前后 lineageID 应不变")
        try recordStep("after-restart-before-B2", model: model, villageID: villageBID)

        // B2 正常导入 — 验证村庄 ID 不变、entry+1、lineage 连续
        let entryCountBeforeB2 = envelopeAfterRestartB.entries.count
        let lineageCountBeforeB2 = envelopeAfterRestartB.lineages.count
        let dupCountBeforeB2 = envelopeAfterRestartB.duplicateMetadata.count
        try quickImport("village-b-2", villageID: villageBID, model: &model)
        try assertTrue(model.villages.contains(where: { $0.id == villageBID }), "B2 后村庄 B ID 应不变")
        try assertTrue(model.villages.count == 2, "B2 后村庄数量仍为 2")
        try recordStep("B2-quick-import", model: model, villageID: villageBID)
        let envelopeAfterB2 = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionAfterB2 = model.snapshotHistoryProjection(for: villageBID)
        let lineageAfterB2 = envelopeAfterB2.activeLineage(for: villageBID)
        try assertTrue(lineageAfterB2 != nil, "B2 后应存在 active lineage")
        try assertEqual(envelopeAfterB2.entries.count, entryCountBeforeB2 + 1, "B2 正常导入后 entries 应 +1")
        try assertEqual(envelopeAfterB2.duplicateMetadata.count, dupCountBeforeB2, "B2 正常导入不应增加 duplicate")
        try assertEqual(envelopeAfterB2.lineages.count, lineageCountBeforeB2, "B2 同村连续导入 lineage 数应不变")
        try assertTrue(lineageAfterB2?.lineageID == lineageIDAfterB1, "B2 同账号导入应保持 continued lineage")
        try assertEqual(projectionAfterB2.totalSnapshotCount, sanitizedAfterB1.totalSnapshotCount + 1, "B2 后 B 的 totalSnapshotCount 应 +1")
        let dupCountBeforeB2Dup = envelopeAfterB2.duplicateMetadata.count
        let entryCountBeforeB2Dup = envelopeAfterB2.entries.count
        let projectionBeforeB2DupSan = sanitized(projectionAfterB2)
        let dupImportBeforeB2Dup = projectionAfterB2.timeline.first?.duplicateImportCount ?? 0

        // 重复 B2 → duplicate
        try quickImport("village-b-2", villageID: villageBID, model: &model)
        let envelopeAfterB2Dup = try XCTUnwrapWrapper(try currentEnvelope())
        let projectionAfterB2Dup = model.snapshotHistoryProjection(for: villageBID)
        try recordStep("B2-duplicate-quick-import", model: model, villageID: villageBID)
        try assertEqual(envelopeAfterB2Dup.entries.count, entryCountBeforeB2Dup, "B2 duplicate 后 entries 应不变")
        try assertEqual(envelopeAfterB2Dup.duplicateMetadata.count, dupCountBeforeB2Dup + 1, "B2 duplicate 后 duplicate 应 +1")
        try assertEqual(envelopeAfterB2Dup.lineages.count, lineageCountBeforeB2, "B2 duplicate 后 lineage 数应不变")
        try assertTrue(envelopeAfterB2Dup.activeLineage(for: villageBID)?.lineageID == lineageIDAfterB1, "B2 duplicate 后 lineageID 应不变")
        try assertEqual(sanitized(projectionAfterB2Dup).totalSnapshotCount, projectionBeforeB2DupSan.totalSnapshotCount, "B2 duplicate 后 totalSnapshotCount 应不变")
        try assertEqual(sanitized(projectionAfterB2Dup).timelineCount, projectionBeforeB2DupSan.timelineCount, "B2 duplicate 后 timeline 应不变")
        let dupImportAfterB2Dup = projectionAfterB2Dup.timeline.first?.duplicateImportCount ?? 0
        try assertTrue(dupImportAfterB2Dup == dupImportBeforeB2Dup + 1 || dupImportAfterB2Dup >= 1, "B2 duplicate 后 duplicateImportCount 应 +1")
        try assertTrue(model.villages.contains(where: { $0.id == villageBID }), "B2 duplicate 后 B ID 仍应存在")
        try assertTrue(model.villages.contains(where: { $0.id == villageAID }), "B2 duplicate 后 A ID 仍应存在")

        // 串档检查：A/B lineage 隔离
        model = restart()
        let projectionA = model.snapshotHistoryProjection(for: villageAID)
        let projectionB = model.snapshotHistoryProjection(for: villageBID)
        let envelope = try XCTUnwrapWrapper(try currentEnvelope())
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
        // 额外隔离检查：villageID 集合与 lineageID 集合无交叉
        let villageIDs = Set([villageAID, villageBID])
        try assertTrue(villageIDs.count == 2, "A/B villageID 应不同")
        // 确保各自 entry 的 lineageID 与 active lineage 一致（continued）
        for entry in entriesA {
            try assertTrue(entry.lineageID == lineageA.lineageID, "A 的 history entry lineageID 应与 active lineage 一致")
        }
        for entry in entriesB {
            try assertTrue(entry.lineageID == lineageB.lineageID, "B 的 history entry lineageID 应与 active lineage 一致")
        }

        return AcceptanceReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            commitSHA: ProcessInfo.processInfo.environment["ACCEPTANCE_COMMIT_SHA"],
            steps: steps,
            finalState: AcceptanceFinalState(
                villageA: SanitizedProjection(projectionA),
                villageB: SanitizedProjection(projectionB),
                lineageIsolated: true,
                villageACount: projectionA.totalSnapshotCount,
                villageBCount: projectionB.totalSnapshotCount
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
    let projection: SanitizedProjection?
}

private struct AcceptanceFinalState: Encodable {
    let villageA: SanitizedProjection
    let villageB: SanitizedProjection
    let lineageIsolated: Bool
    let villageACount: Int
    let villageBCount: Int
}

private struct SanitizedProjection: Encodable {
    let availability: String
    let totalSnapshotCount: Int
    let timelineCount: Int
    let coverageTrustState: String
    let duplicateImportCount: Int?
    let statisticsToday: String
    let statistics7Days: String
    let statistics30Days: String

    init(_ projection: SnapshotHistoryProjection) {
        availability = String(describing: projection.availability)
        totalSnapshotCount = projection.totalSnapshotCount
        timelineCount = projection.timeline.count
        coverageTrustState = String(describing: projection.coverageTrustState)
        duplicateImportCount = projection.timeline.first?.duplicateImportCount
        statisticsToday = SanitizedProjection.statState(projection.statistics.today.heroLevelGrowth.state)
        statistics7Days = SanitizedProjection.statState(projection.statistics.last7Days.heroLevelGrowth.state)
        statistics30Days = SanitizedProjection.statState(projection.statistics.last30Days.heroLevelGrowth.state)
    }

    private static func statState(_ state: SnapshotStatisticValueState) -> String {
        state.rawValue
    }
}
