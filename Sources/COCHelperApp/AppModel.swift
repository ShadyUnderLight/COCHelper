import AppKit
import Combine
import Foundation
import COCHelperCore

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var villages: [VillageProfile]
    @Published public private(set) var selectedVillageID: UUID
    @Published public var importText = ""
    @Published public var importIntoCurrentVillage = false
    @Published public private(set) var accountSnapshot: AccountSnapshot?
    @Published public private(set) var pendingAccountSnapshot: AccountSnapshot?
    @Published public private(set) var accountImportError: String?
    /// 官方数据刷新进行中（防重入 + UI 禁用）。
    @Published public private(set) var isRefreshingOfficialData = false
    /// 最近一次批量刷新结果摘要（用于 UI 提示）。
    @Published public private(set) var officialRefreshSummary: String?
    /// 部落共享数据层：clan tag → 状态。部落数据不写入村庄档案，
    /// 同部落多个村庄共享同一份（Issue #7 验收：不产生重复存储矛盾）。
    @Published public private(set) var clanStates: [String: ClanAPIState] = [:]
    /// 部落刷新进行中（防重入 + UI 禁用）。
    @Published public private(set) var isRefreshingClanData = false
    /// 部落当前战争共享数据层：clan tag → 状态（与 clan profile 独立端点、
    /// 独立新鲜度、独立存储）。按需刷新：由用户显式触发，不做批量联动。
    @Published public private(set) var clanWarStates: [String: ClanWarAPIState] = [:]
    /// 战争刷新进行中（防重入 + UI 禁用）。
    @Published public private(set) var isRefreshingClanWarData = false

    private let defaults: UserDefaults
    private let legacyAccountSnapshotStorageKey = "coc-helper.account-snapshot.v1"
    private let villagesStorageKey = "coc-helper.villages.v1"
    private static let clanStatesStorageKey = "coc-helper.clans.v1"
    private static let clanWarStatesStorageKey = "coc-helper.clan-wars.v1"
    private let refresher: OfficialPlayerRefresher
    private let clanRefresher: ClanRefresher
    private let clanWarRefresher: ClanWarRefresher

    public init(
        defaults: UserDefaults = .standard,
        refresher: OfficialPlayerRefresher? = nil,
        clanRefresher: ClanRefresher? = nil,
        clanWarRefresher: ClanWarRefresher? = nil
    ) {
        self.defaults = defaults
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

        if let refresher {
            self.refresher = refresher
            self.tokenStore = KeychainTokenStore()
        } else {
            // 生产路径：token 只经 Keychain 进出，绝不进入 UserDefaults / JSON。
            let store = KeychainTokenStore()
            self.tokenStore = store
            self.refresher = OfficialPlayerRefresher(client: CoAPIClient { try? store.readToken() })
        }

        if let clanRefresher {
            self.clanRefresher = clanRefresher
        } else {
            // 生产路径：与玩家 refresher 共用同一 Keychain token 来源。
            // 初始化未完成时不能引用 self.tokenStore，KeychainTokenStore 是
            // 同一 keychain 记录的薄封装，多实例读取结果一致。
            let store = KeychainTokenStore()
            self.clanRefresher = ClanRefresher(client: CoAPIClient { try? store.readToken() })
        }

        if let clanWarRefresher {
            self.clanWarRefresher = clanWarRefresher
        } else {
            let store = KeychainTokenStore()
            self.clanWarRefresher = ClanWarRefresher(client: CoAPIClient { try? store.readToken() })
        }

        clanStates = Self.loadClanStates(from: defaults)
        clanWarStates = Self.loadClanWarStates(from: defaults)
        villages = initialVillages
        selectedVillageID = initialVillages[0].id
        accountSnapshot = initialVillages[0].accountSnapshot
        pendingAccountSnapshot = nil
        accountImportError = nil
        importText = initialVillages[0].accountSnapshot?.originalText ?? ""
        isRefreshingOfficialData = false
        officialRefreshSummary = nil

        // This upgrades the previous single-account storage and also drops
        // the old planner-only fields on the next write.
        persistVillages()
    }

    public var currentVillageName: String {
        villages.first(where: { $0.id == selectedVillageID })?.name ?? "未命名村庄"
    }

    public var currentVillageTag: String? {
        villages.first(where: { $0.id == selectedVillageID })?.tag
    }

    public var currentVillageOfficialTag: String? {
        villages.first(where: { $0.id == selectedVillageID })?.officialTag
    }

    public var currentVillageOfficialState: OfficialAPIState? {
        villages.first(where: { $0.id == selectedVillageID })?.officialAPIState
    }

    /// 当前村庄的部落归属：派生自最近成功玩家快照的 `clan.tag`。
    /// 玩家换部落/离开部落后，新快照刷新即更新此值；旧部落数据保留在
    /// `clanStates` 中但不会显示为当前归属。
    public var currentVillageClanTag: String? {
        currentVillageOfficialState?.currentClanTag
    }

    /// 玩家官方数据是否从未成功抓取过（用于区分"未知归属"与"确认无部落"）。
    public var currentVillageClanStatusUnknown: Bool {
        currentVillageOfficialState?.lastGood == nil
    }

    /// 当前村庄所属部落的共享状态（nil = 无部落 / 从未请求）。
    public var currentClanState: ClanAPIState? {
        guard let tag = currentVillageClanTag else { return nil }
        return clanStates[tag]
    }

    /// 当前村庄所属部落的当前战争共享状态（nil = 无部落 / 从未请求）。
    public var currentClanWarState: ClanWarAPIState? {
        guard let tag = currentVillageClanTag else { return nil }
        return clanWarStates[tag]
    }

    // MARK: - API Token（仅 Keychain）

    private let tokenStore: KeychainTokenStore

    public var hasAPIToken: Bool {
        (try? tokenStore.readToken()) != nil
    }

    public func saveAPIToken(_ token: String) throws {
        try tokenStore.saveToken(token)
    }

    public func deleteAPIToken() throws {
        try tokenStore.deleteToken()
    }

    public var canDeleteCurrentVillage: Bool {
        villages.count > 1
    }

    public func activeUpgradeCount(for village: VillageProfile, at now: Date = Date()) -> Int {
        guard let snapshot = village.accountSnapshot else { return 0 }
        return TrackerBase.allCases.reduce(0) { total, base in
            total + UpgradeTracker.activeRecords(from: snapshot, base: base, at: now).count
        }
    }

    public func selectVillage(id: UUID) {
        guard id != selectedVillageID,
              let village = villages.first(where: { $0.id == id }) else { return }

        persistVillages()
        load(village)
    }

    public func addVillageForImport() {
        persistVillages()

        let name = "村庄 " + String(villages.count + 1)
        let village = VillageProfile(name: name)
        villages.append(village)
        load(village, importText: "")
        importIntoCurrentVillage = true
        persistVillages()
    }

    public func renameSelectedVillage(_ name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = villages.firstIndex(where: { $0.id == selectedVillageID }) else { return }

        villages[index].name = trimmedName
        villages[index].updatedAt = Date()
        persistVillages()
    }

    public func deleteVillage(id: UUID) {
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

    public func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            accountImportError = "系统剪贴板中没有可用的文本。"
            return
        }
        importText = text
        accountImportError = nil
    }

    public func parseAccountText() {
        accountImportError = nil
        pendingAccountSnapshot = nil

        do {
            pendingAccountSnapshot = try AccountSnapshotImporter.parse(importText)
        } catch {
            accountImportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public var pendingAccountSnapshotActionTitle: String? {
        guard let snapshot = pendingAccountSnapshot else { return nil }

        if let targetIndex = targetVillageIndex(for: snapshot) {
            let targetName = villages[targetIndex].name
            let action = isReimportingExistingVillage(snapshot, at: targetIndex) ? "更新" : "应用到"
            return action + "「" + targetName + "」"
        }

        let newName = normalizedTag(snapshot.tag) ?? "村庄 " + String(villages.count + 1)
        return "创建「" + newName + "」"
    }

    public var pendingAccountSnapshotDestinationDescription: String? {
        guard let snapshot = pendingAccountSnapshot else { return nil }

        if let targetIndex = targetVillageIndex(for: snapshot) {
            let targetName = villages[targetIndex].name
            if isReimportingExistingVillage(snapshot, at: targetIndex) {
                return "导入目标：按账号 tag 更新「" + targetName + "」"
            }
            return "导入目标：应用到「" + targetName + "」"
        }

        let newName = normalizedTag(snapshot.tag) ?? "村庄 " + String(villages.count + 1)
        return "导入目标：没有同 tag 档案，将创建「" + newName + "」"
    }

    public func applyPendingAccountSnapshot() {
        guard let snapshot = pendingAccountSnapshot else { return }
        persistVillages()

        let targetIndex: Int
        if let existingIndex = targetVillageIndex(for: snapshot) {
            // Re-importing the same account refreshes only its raw snapshot.
            targetIndex = existingIndex
        } else {
            let name = normalizedTag(snapshot.tag) ?? "村庄 " + String(villages.count + 1)
            villages.append(VillageProfile(name: name))
            targetIndex = villages.count - 1
        }

        // tag 变化时自动重置官方数据（applyImportedSnapshot 内部处理）。
        villages[targetIndex].applyImportedSnapshot(snapshot)
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

    public func discardPendingAccountSnapshot() {
        pendingAccountSnapshot = nil
        accountImportError = nil
    }

    public func clearAccountSnapshot() {
        accountSnapshot = nil
        pendingAccountSnapshot = nil
        accountImportError = nil
        importText = ""
        // 清除本地快照后官方数据（原账号）不再适用于本村庄，一并重置。
        if let index = villages.firstIndex(where: { $0.id == selectedVillageID }) {
            villages[index].officialAPIState = nil
        }
        persistVillages()
    }

    // MARK: - 官方数据刷新

    /// 刷新当前村庄的官方玩家信息。
    public func refreshOfficialPlayer() {
        guard !isRefreshingOfficialData else { return }
        guard let index = villages.firstIndex(where: { $0.id == selectedVillageID }) else { return }
        isRefreshingOfficialData = true
        officialRefreshSummary = nil

        let village = villages[index]
        let expectedTag = village.officialTag
        Task { [weak self] in
            guard let self else { return }
            let state = await self.refresher.refresh(village: village)
            // 竞态防护：刷新期间账号若已变化（重导入/清除），丢弃过期结果。
            let applied = self.applyOfficialState(state, to: village.id, expectedTag: expectedTag)
            self.persistVillages()
            self.isRefreshingOfficialData = false
            // 玩家快照更新后部落归属可能变化，联动刷新**发起村庄**的部落
            // （传 village.id 而非读取当前选中村庄：刷新期间用户可能已切换
            // 村庄，读 selectedVillageID 会误刷当前村庄、漏刷发起村庄）。
            if applied, state.status == .success {
                self.refreshClan(villageID: village.id)
            }
        }
    }

    /// 刷新所有已导入村庄的官方玩家信息（同 tag 只请求一次，顺序执行）。
    public func refreshAllOfficialPlayers() {
        guard !isRefreshingOfficialData else { return }
        isRefreshingOfficialData = true
        officialRefreshSummary = nil

        let villages = self.villages
        // 记录发起请求时各村庄的 tag，用于写回竞态校验。
        var tagByID: [UUID: String] = [:]
        for village in villages {
            tagByID[village.id] = village.officialTag
        }
        Task { [weak self] in
            guard let self else { return }
            let states = await self.refresher.refreshAll(villages: villages)
            for (id, state) in states {
                self.applyOfficialState(state, to: id, expectedTag: tagByID[id])
            }
            let successCount = states.values.filter { $0.status == .success }.count
            let skippedCount = states.values.filter { $0.status == .skipped }.count
            let failedCount = states.values.filter { $0.status == .failed }.count
            self.officialRefreshSummary = "刷新完成：成功 \(successCount)，失败 \(failedCount)，跳过 \(skippedCount)"
            // 批量刷新只写一次 UserDefaults，避免 N+1 次全量 JSON 编码。
            self.persistVillages()
            self.isRefreshingOfficialData = false
            // 玩家快照更新后部落归属可能变化，联动刷新部落共享数据
            // （refreshAllClans 内部按 clan tag 去重，被占用时排队补跑）。
            // 仅在本次存在成功时联动：玩家请求全挂（如断网/429）时不追加
            // 部落请求，避免在限流边界上放大请求面。
            if successCount > 0 {
                self.refreshAllClans()
            }
        }
    }

    /// 纯内存状态更新；调用方负责在合适的时机持久化。
    /// 若村庄当前 tag 与发起请求时不一致（账号已变化），丢弃过期结果并返回 false。
    @discardableResult
    private func applyOfficialState(_ state: OfficialAPIState, to villageID: UUID, expectedTag: String?) -> Bool {
        guard let index = villages.firstIndex(where: { $0.id == villageID }) else { return false }
        guard villages[index].officialStateMatchesTag(at: expectedTag) else { return false }
        villages[index].officialAPIState = state
        villages[index].updatedAt = Date()
        if selectedVillageID == villageID {
            officialRefreshSummary = nil
        }
        return true
    }

    // MARK: - 部落数据刷新（共享数据层）

    /// 部落刷新进行中被再次触发时排队补跑，避免联动刷新被静默丢弃。
    private var pendingClanRefreshAll = false

    /// 刷新当前选中村庄所属部落的档案（UI 按钮入口）。
    public func refreshCurrentClan() {
        refreshClan(villageID: selectedVillageID)
    }

    /// 刷新**指定村庄**所属部落的档案（按 clan tag 去重，单 tag 单请求）。
    /// 联动场景必须传发起村庄 id：刷新期间用户可能已切换村庄，
    /// 读取当前选中村庄会导致误刷新（P1 竞态）。
    func refreshClan(villageID: UUID) {
        guard let tag = villages.first(where: { $0.id == villageID })?
            .officialAPIState?.currentClanTag else { return }
        if isRefreshingClanData {
            // 被占用时排队为一次全量补跑（覆盖所有村庄，语义更广且确定性）。
            pendingClanRefreshAll = true
            return
        }
        performClanRefresh(villageClanTags: [tag])
    }

    /// 批量刷新所有已导入村庄所属部落（同 clan tag 只请求一次，顺序执行）。
    /// 玩家批量刷新完成后由 `refreshAllOfficialPlayers` 联动调用。
    public func refreshAllClans() {
        if isRefreshingClanData {
            // 排队补跑：联动/手动请求不会因当前批次占用而被静默丢弃。
            pendingClanRefreshAll = true
            return
        }
        performClanRefresh(villageClanTags: villages.compactMap { $0.officialAPIState?.currentClanTag })
    }

    private func performClanRefresh(villageClanTags: [String?]) {
        isRefreshingClanData = true
        let previous = clanStates

        Task { [weak self] in
            guard let self else { return }
            let refreshed = await self.clanRefresher.refreshClans(
                villageClanTags: villageClanTags,
                previous: previous
            )
            self.mergeClanStates(refreshed)
            self.isRefreshingClanData = false
            if self.pendingClanRefreshAll {
                self.pendingClanRefreshAll = false
                self.refreshAllClans()
            }
        }
    }

    /// 合并刷新结果到共享存储：只覆盖本次请求过的 tag，其余保留
    /// （旧部落快照不因换部落而丢失）。
    private func mergeClanStates(_ refreshed: [String: ClanAPIState]) {
        clanStates = ClanStateStore(states: clanStates).merging(refreshed).states
        persistClanStates()
    }

    private func persistClanStates() {
        guard let data = try? JSONEncoder().encode(ClanStateStore(states: clanStates)) else { return }
        defaults.set(data, forKey: Self.clanStatesStorageKey)
    }

    // MARK: - 当前战争刷新（按需）

    /// 刷新当前村庄所属部落的当前战争（按需：用户打开战争面板时显式触发；
    /// 不做批量联动，避免启动/批量刷新时全量拉取战争请求）。
    /// `notInWar` 是成功响应（无战争空状态），失败保留 last-good。
    public func refreshCurrentClanWar() {
        guard !isRefreshingClanWarData else { return }
        guard let tag = currentVillageClanTag else { return }
        isRefreshingClanWarData = true
        let previous = clanWarStates

        Task { [weak self] in
            guard let self else { return }
            let refreshed = await self.clanWarRefresher.refreshClanWars(
                villageClanTags: [tag],
                previous: previous
            )
            self.clanWarStates = ClanWarStateStore(states: self.clanWarStates)
                .merging(refreshed).states
            self.persistClanWarStates()
            self.isRefreshingClanWarData = false
        }
    }

    private func persistClanWarStates() {
        guard let data = try? JSONEncoder().encode(ClanWarStateStore(states: clanWarStates)) else { return }
        defaults.set(data, forKey: Self.clanWarStatesStorageKey)
    }

    private static func loadClanWarStates(from defaults: UserDefaults) -> [String: ClanWarAPIState] {
        guard let data = defaults.data(forKey: Self.clanWarStatesStorageKey),
              let store = try? JSONDecoder().decode(ClanWarStateStore.self, from: data) else {
            return [:]
        }
        return store.states
    }

    private static func loadClanStates(from defaults: UserDefaults) -> [String: ClanAPIState] {
        guard let data = defaults.data(forKey: Self.clanStatesStorageKey),
              let store = try? JSONDecoder().decode(ClanStateStore.self, from: data) else {
            return [:]
        }
        return store.states
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

    private func targetVillageIndex(for snapshot: AccountSnapshot) -> Int? {
        if let tag = normalizedTag(snapshot.tag),
           let existingIndex = villages.firstIndex(where: { normalizedTag($0.tag) == tag }) {
            return existingIndex
        }

        guard let currentIndex = villages.firstIndex(where: { $0.id == selectedVillageID }),
              importIntoCurrentVillage || (villages.count == 1 && !villages[currentIndex].hasImportedData)
        else { return nil }
        return currentIndex
    }

    private func isReimportingExistingVillage(_ snapshot: AccountSnapshot, at index: Int) -> Bool {
        guard let tag = normalizedTag(snapshot.tag) else { return false }
        return normalizedTag(villages[index].tag) == tag
    }

    private static func loadVillages(from defaults: UserDefaults) -> [VillageProfile] {
        guard let data = defaults.data(forKey: "coc-helper.villages.v1"),
              let decoded = try? JSONDecoder().decode([VillageProfile].self, from: data) else {
            return []
        }
        return decoded
    }
}
