import Combine
import Foundation
import AppKit
import COCHelperCore

@MainActor
final class AppModel: ObservableObject {
    @Published var input: PlannerInput
    @Published private(set) var plan: RoadmapPlan
    @Published var importText = ""
    @Published private(set) var accountSnapshot: AccountSnapshot?
    @Published private(set) var pendingAccountSnapshot: AccountSnapshot?
    @Published private(set) var accountImportError: String?

    private let planner = RoadmapPlanner()
    private let defaults = UserDefaults.standard
    private let storageKey = "coc-helper.planner-input.v1"
    private let accountSnapshotStorageKey = "coc-helper.account-snapshot.v1"

    init() {
        let initialInput: PlannerInput
        if let saved = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(PlannerInput.self, from: saved) {
            initialInput = decoded
        } else {
            initialInput = .demo
        }
        let savedSnapshot = defaults.data(forKey: accountSnapshotStorageKey)
            .flatMap { try? JSONDecoder().decode(AccountSnapshot.self, from: $0) }
        input = initialInput
        plan = RoadmapPlanner().makePlan(for: initialInput)
        accountSnapshot = savedSnapshot
        pendingAccountSnapshot = nil
        accountImportError = nil
    }

    func rebuild() {
        plan = planner.makePlan(for: input)
        persist()
    }

    func resetToDemo() {
        input = .demo
        rebuild()
    }

    func addTask(_ task: UpgradeTask) {
        input.tasks.append(task)
        rebuild()
    }

    func removeTask(id: UUID) {
        input.tasks.removeAll { $0.id == id }
        rebuild()
    }

    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            accountImportError = "系统剪贴板中没有可用的文本。"
            return
        }
        importText = text
        accountImportError = nil
    }

    func parseAccountText() {
        accountImportError = nil
        pendingAccountSnapshot = nil

        do {
            pendingAccountSnapshot = try AccountSnapshotImporter.parse(importText)
        } catch {
            accountImportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func applyPendingAccountSnapshot() {
        guard let pendingAccountSnapshot else { return }
        accountSnapshot = pendingAccountSnapshot
        self.pendingAccountSnapshot = nil
        accountImportError = nil
        persistAccountSnapshot()
    }

    func discardPendingAccountSnapshot() {
        pendingAccountSnapshot = nil
        accountImportError = nil
    }

    func clearAccountSnapshot() {
        accountSnapshot = nil
        pendingAccountSnapshot = nil
        accountImportError = nil
        persistAccountSnapshot()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(input) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func persistAccountSnapshot() {
        guard let accountSnapshot,
              let data = try? JSONEncoder().encode(accountSnapshot) else {
            defaults.removeObject(forKey: accountSnapshotStorageKey)
            return
        }
        defaults.set(data, forKey: accountSnapshotStorageKey)
    }
}
