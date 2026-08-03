import AppKit
import Combine
import Foundation
import COCHelperCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var villages: [VillageProfile]
    @Published private(set) var selectedVillageID: UUID
    @Published var importText = ""
    @Published var importIntoCurrentVillage = false
    @Published private(set) var accountSnapshot: AccountSnapshot?
    @Published private(set) var pendingAccountSnapshot: AccountSnapshot?
    @Published private(set) var accountImportError: String?

    private let defaults = UserDefaults.standard
    private let legacyAccountSnapshotStorageKey = "coc-helper.account-snapshot.v1"
    private let villagesStorageKey = "coc-helper.villages.v1"

    init() {
        let loadedVillages = Self.loadVillages(from: defaults)
        let initialVillages: [VillageProfile]
        if loadedVillages.isEmpty {
            let legacySnapshot = defaults.data(forKey: legacyAccountSnapshotStorageKey)
                .flatMap { try? JSONDecoder().decode(AccountSnapshot.self, from: $0) }
            initialVillages = [VillageProfile(
                name: legacySnapshot?.tag ?? "我的村庄",
                accountSnapshot: legacySnapshot
            )]
        } else {
            initialVillages = loadedVillages
        }

        villages = initialVillages
        selectedVillageID = initialVillages[0].id
        accountSnapshot = initialVillages[0].accountSnapshot
        pendingAccountSnapshot = nil
        accountImportError = nil
        importText = initialVillages[0].accountSnapshot?.originalText ?? ""

        // This upgrades the previous single-account storage and also drops
        // the old planner-only fields on the next write.
        persistVillages()
    }

    var currentVillageName: String {
        villages.first(where: { $0.id == selectedVillageID })?.name ?? "未命名村庄"
    }

    var currentVillageTag: String? {
        villages.first(where: { $0.id == selectedVillageID })?.tag
    }

    var canDeleteCurrentVillage: Bool {
        villages.count > 1
    }

    func activeUpgradeCount(for village: VillageProfile, at now: Date = Date()) -> Int {
        guard let snapshot = village.accountSnapshot else { return 0 }
        return TrackerBase.allCases.reduce(0) { total, base in
            total + UpgradeTracker.activeRecords(from: snapshot, base: base, at: now).count
        }
    }

    func selectVillage(id: UUID) {
        guard id != selectedVillageID,
              let village = villages.first(where: { $0.id == id }) else { return }

        persistVillages()
        load(village)
    }

    func addVillageForImport() {
        persistVillages()

        let name = "村庄 " + String(villages.count + 1)
        let village = VillageProfile(name: name)
        villages.append(village)
        load(village, importText: "")
        importIntoCurrentVillage = true
        persistVillages()
    }

    func renameSelectedVillage(_ name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = villages.firstIndex(where: { $0.id == selectedVillageID }) else { return }

        villages[index].name = trimmedName
        villages[index].updatedAt = Date()
        persistVillages()
    }

    func deleteVillage(id: UUID) {
        guard villages.count > 1,
              let index = villages.firstIndex(where: { $0.id == id }) else { return }

        let isSelected = id == selectedVillageID
        villages.remove(at: index)

        if isSelected {
            let nextIndex = min(index, villages.count - 1)
            load(villages[nextIndex])
        }
        persistVillages()
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
        guard let snapshot = pendingAccountSnapshot else { return }
        persistVillages()

        let targetIndex: Int
        if let tag = normalizedTag(snapshot.tag),
           let existingIndex = villages.firstIndex(where: { normalizedTag($0.tag) == tag }) {
            // Re-importing the same account refreshes only its raw snapshot.
            targetIndex = existingIndex
        } else if let currentIndex = villages.firstIndex(where: { $0.id == selectedVillageID }),
                  importIntoCurrentVillage || (villages.count == 1 && !villages[currentIndex].hasImportedData) {
            targetIndex = currentIndex
        } else {
            let name = normalizedTag(snapshot.tag) ?? "村庄 " + String(villages.count + 1)
            villages.append(VillageProfile(name: name))
            targetIndex = villages.count - 1
        }

        villages[targetIndex].accountSnapshot = snapshot
        if villages[targetIndex].name.hasPrefix("村庄 ") || villages[targetIndex].name == "未命名村庄" {
            villages[targetIndex].name = normalizedTag(snapshot.tag) ?? villages[targetIndex].name
        }
        villages[targetIndex].updatedAt = Date()

        let targetVillage = villages[targetIndex]
        load(targetVillage, importText: snapshot.originalText)
        pendingAccountSnapshot = nil
        accountImportError = nil
        importIntoCurrentVillage = false
        persistVillages()
    }

    func discardPendingAccountSnapshot() {
        pendingAccountSnapshot = nil
        accountImportError = nil
    }

    func clearAccountSnapshot() {
        accountSnapshot = nil
        pendingAccountSnapshot = nil
        accountImportError = nil
        importText = ""
        persistVillages()
    }

    private func load(_ village: VillageProfile, importText: String? = nil) {
        selectedVillageID = village.id
        accountSnapshot = village.accountSnapshot
        self.importText = importText ?? village.accountSnapshot?.originalText ?? ""
        importIntoCurrentVillage = false
        pendingAccountSnapshot = nil
        accountImportError = nil
    }

    private func syncCurrentVillage() {
        guard let index = villages.firstIndex(where: { $0.id == selectedVillageID }) else { return }
        villages[index].accountSnapshot = accountSnapshot
        villages[index].updatedAt = Date()
    }

    private func persistVillages() {
        syncCurrentVillage()
        guard let data = try? JSONEncoder().encode(villages) else { return }
        defaults.set(data, forKey: villagesStorageKey)
    }

    private func normalizedTag(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadVillages(from defaults: UserDefaults) -> [VillageProfile] {
        guard let data = defaults.data(forKey: "coc-helper.villages.v1"),
              let decoded = try? JSONDecoder().decode([VillageProfile].self, from: data) else {
            return []
        }
        return decoded
    }
}
