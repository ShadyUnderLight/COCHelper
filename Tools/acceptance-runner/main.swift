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
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let historyStore = FileSnapshotHistoryStore(fileURL: historyURL)

        func loadText(_ name: String) throws -> String {
            try String(
                contentsOf: base.appendingPathComponent("\(name).json"),
                encoding: .utf8
            )
        }

        var steps: [AcceptanceStepRecord] = []

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
                historyStore: historyStore
            )
            guard case .success(let preview) = model.prepareQuickImport(for: villageID) else {
                throw AcceptanceError.importFailed("快捷导入预览失败: \(name)")
            }
            guard model.applyQuickImport(preview) else {
                throw AcceptanceError.importFailed("快捷导入提交失败: \(name)")
            }
        }

        func restart() -> AppModel {
            AppModel(defaults: defaults, historyStore: FileSnapshotHistoryStore(fileURL: historyURL))
        }

        // 村庄 A：账号数据页完整导入 A1
        var model = AppModel(defaults: defaults, historyStore: historyStore)
        try accountImport("village-a-1", model: model)
        let villageAID = try requireVillageID(model: model, index: 0, label: "A")
        try recordStep("A1-account-import", model: model, villageID: villageAID)

        // 重启后导入 A2
        model = restart()
        try recordStep("after-restart-before-A2", model: model, villageID: villageAID)
        try accountImport("village-a-2", model: model)
        try recordStep("A2-account-import", model: model, villageID: villageAID)

        // 重复 A2 → duplicate
        try accountImport("village-a-2", model: model)
        try recordStep("A2-duplicate-account-import", model: model, villageID: villageAID)

        // 预置村庄 B（空档案，走快捷导入路径）
        var villages = model.villages
        let villageB = VillageProfile(name: "村庄 B")
        villages.append(villageB)
        defaults.set(try JSONEncoder().encode(villages), forKey: "coc-helper.villages.v1")
        model = restart()
        guard let villageBID = model.villages.first(where: { $0.name == "村庄 B" })?.id else {
            throw AcceptanceError.importFailed("村庄 B 未创建")
        }
        try quickImport("village-b-1", villageID: villageBID, model: &model)
        try recordStep("B1-quick-import", model: model, villageID: villageBID)

        // 重启后 B2
        model = restart()
        try recordStep("after-restart-before-B2", model: model, villageID: villageBID)
        try quickImport("village-b-2", villageID: villageBID, model: &model)
        try recordStep("B2-quick-import", model: model, villageID: villageBID)

        // 重复 B2 → duplicate
        try quickImport("village-b-2", villageID: villageBID, model: &model)
        try recordStep("B2-duplicate-quick-import", model: model, villageID: villageBID)

        // 串档检查：A/B lineage 隔离
        model = restart()
        let projectionA = model.snapshotHistoryProjection(for: villageAID)
        let projectionB = model.snapshotHistoryProjection(for: villageBID)
        let envelope = try XCTUnwrapWrapper(historyStore.load())
        let lineageA = envelope.activeLineage(for: villageAID)
        let lineageB = envelope.activeLineage(for: villageBID)
        guard let lineageA, let lineageB else {
            throw AcceptanceError.validationFailed("缺少 active lineage")
        }
        guard lineageA.villageID == villageAID, lineageB.villageID == villageBID else {
            throw AcceptanceError.validationFailed("lineage villageID 串档")
        }
        let entriesA = envelope.entries.filter { $0.villageID == villageAID }
        let entriesB = envelope.entries.filter { $0.villageID == villageBID }
        guard !entriesA.isEmpty, !entriesB.isEmpty else {
            throw AcceptanceError.validationFailed("A/B history entry 为空")
        }
        guard Set(entriesA.map(\.snapshotID)).isDisjoint(with: Set(entriesB.map(\.snapshotID))) else {
            throw AcceptanceError.validationFailed("A/B history entry 交叉")
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
