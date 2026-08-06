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
    /// 正在刷新官方玩家数据的村庄 ID 集合（防重入守卫 + 卡片按村庄隔离，Issue #35）。
    /// 空集合 = 无请求在途；非空 = 对应村庄的请求在途。
    @Published public private(set) var refreshingOfficialPlayerVillageIDs: Set<UUID> = []
    /// 最近一次批量刷新结果摘要（用于 UI 提示）。
    @Published public private(set) var officialRefreshSummary: String?
    /// 部落共享数据层：clan tag → 状态。部落数据不写入村庄档案，
    /// 同部落多个村庄共享同一份（Issue #7 验收：不产生重复存储矛盾）。
    @Published public private(set) var clanStates: [String: ClanAPIState] = [:]
    /// 正在刷新档案的部落 tag 集合（防重入守卫 + 卡片按部落隔离，Issue #35）。
    @Published public private(set) var refreshingClanTags: Set<String> = []
    /// 部落当前战争共享数据层：clan tag → 状态（与 clan profile 独立端点、
    /// 独立新鲜度、独立存储）。按需刷新：由用户显式触发，不做批量联动。
    @Published public private(set) var clanWarStates: [String: ClanWarAPIState] = [:]
    /// 正在刷新当前战争的部落 tag 集合（防重入守卫 + 卡片按部落隔离，Issue #35）。
    @Published public private(set) var refreshingClanWarTags: Set<String> = []
    /// 战争日志共享数据层（分页：lastGood = 累计页 + 最新游标）。
    @Published public private(set) var clanWarLogStates: [String: ClanWarLogAPIState] = [:]
    /// 正在刷新战争日志的部落 tag 集合（防重入守卫 + 卡片按部落隔离，Issue #35）。
    @Published public private(set) var refreshingWarLogTags: Set<String> = []
    /// 部落资本赛季共享数据层（分页）。
    @Published public private(set) var clanCapitalStates: [String: ClanCapitalAPIState] = [:]
    /// 正在刷新资本赛季的部落 tag 集合（防重入守卫 + 卡片按部落隔离，Issue #35）。
    @Published public private(set) var refreshingCapitalTags: Set<String> = []
    /// 手动跟踪的部落档案（Issue #41）：独立于村庄档案与玩家快照。
    /// 只存档案元数据（tag/备注/创建时间），部落 API 数据仍在
    /// clanStates 等按 Tag 共享状态层。
    @Published public private(set) var trackedClans: [TrackedClanProfile] = []
    /// 静态升级目录（Issue #15 升级总览展示用：完整时长 / 等级上限 / 版本）。
    /// lazy：避免 AppModel.init 同步解码目录 JSON（当前 2.9MB / ~16ms 无感，
    /// 防御未来目录体积增长），首次访问（升级总览渲染）时才加载，启动路径保持纯净。
    /// `loadBundled` 失败返回 nil 是合法路径——UI 显示「目录不可用」，不允许崩溃。
    public private(set) lazy var gameCatalog: GameCatalog? = GameCatalog.loadBundled()

    private let defaults: UserDefaults
    private let legacyAccountSnapshotStorageKey = "coc-helper.account-snapshot.v1"
    private let villagesStorageKey = "coc-helper.villages.v1"
    private static let clanStatesStorageKey = "coc-helper.clans.v1"
    private static let clanWarStatesStorageKey = "coc-helper.clan-wars.v1"
    private static let clanWarLogStatesStorageKey = "coc-helper.clan-war-logs.v1"
    private static let clanCapitalStatesStorageKey = "coc-helper.clan-capitals.v1"
    private static let trackedClansStorageKey = "coc-helper.tracked-clans.v1"
    private let refresher: OfficialPlayerRefresher
    private let clanRefresher: ClanRefresher
    private let clanWarRefresher: ClanWarRefresher
    /// 分页端点（warlog / capitalraidseasons）共用的客户端。
    private let clanLogClient: CoAPIClient

    public init(
        defaults: UserDefaults = .standard,
        refresher: OfficialPlayerRefresher? = nil,
        clanRefresher: ClanRefresher? = nil,
        clanWarRefresher: ClanWarRefresher? = nil,
        clanLogClient: CoAPIClient? = nil
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

        if let clanLogClient {
            self.clanLogClient = clanLogClient
        } else {
            let store = KeychainTokenStore()
            self.clanLogClient = CoAPIClient { try? store.readToken() }
        }

        clanStates = Self.loadClanStates(from: defaults)
        clanWarStates = Self.loadClanWarStates(from: defaults)
        clanWarLogStates = Self.loadClanWarLogStates(from: defaults)
        clanCapitalStates = Self.loadClanCapitalStates(from: defaults)
        trackedClans = Self.loadTrackedClans(from: defaults)
        villages = initialVillages
        selectedVillageID = initialVillages[0].id
        accountSnapshot = initialVillages[0].accountSnapshot
        pendingAccountSnapshot = nil
        accountImportError = nil
        importText = initialVillages[0].accountSnapshot?.originalText ?? ""
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

    /// 按村庄 ID 的官方 tag（村庄导入 tag 的规范化；无有效 tag 返回 nil）。
    /// 语义与 currentVillageOfficialTag 一致，仅来源改为显式 ID。
    public func officialTag(for villageID: UUID) -> String? {
        villages.first(where: { $0.id == villageID })?.officialTag
    }

    public var currentVillageOfficialState: OfficialAPIState? {
        officialState(for: selectedVillageID)
    }

    /// 当前村庄的部落归属：派生自最近成功玩家快照的 `clan.tag`。
    /// 玩家换部落/离开部落后，新快照刷新即更新此值；旧部落数据保留在
    /// `clanStates` 中但不会显示为当前归属。
    public var currentVillageClanTag: String? {
        officialClanTag(for: selectedVillageID)
    }

    /// 玩家官方数据是否从未成功抓取过（用于区分"未知归属"与"确认无部落"）。
    public var currentVillageClanStatusUnknown: Bool {
        clanStatusUnknown(for: selectedVillageID)
    }

    /// 当前村庄所属部落的共享状态（nil = 无部落 / 从未请求）。
    public var currentClanState: ClanAPIState? {
        guard let tag = currentVillageClanTag else { return nil }
        return clanState(for: tag)
    }

    /// 当前村庄所属部落的当前战争共享状态（nil = 无部落 / 从未请求）。
    public var currentClanWarState: ClanWarAPIState? {
        guard let tag = currentVillageClanTag else { return nil }
        return clanWarState(for: tag)
    }

    // MARK: - 官方数据读取（显式 ID 路由，Issue #35）

    /// 指定村庄的官方玩家状态（nil = 不存在该 ID / 从未刷新，不崩溃）。
    /// 页面必须始终以当前 villageID 为数据来源，不得读 `selectedVillageID`。
    public func officialState(for villageID: UUID) -> OfficialAPIState? {
        villages.first(where: { $0.id == villageID })?.officialAPIState
    }

    /// 指定村庄的部落归属：派生自最近成功玩家快照的 `clan.tag`
    ///（复用 `OfficialAPIState.currentClanTag` 的规范化与格式校验）。
    /// 同步纯查询（无副作用）：部落类刷新入口也在同步段调用它捕获 tag。
    public func officialClanTag(for villageID: UUID) -> String? {
        officialState(for: villageID)?.currentClanTag
    }

    /// 指定村庄的玩家官方数据是否从未成功抓取过（`lastGood == nil`）。
    public func clanStatusUnknown(for villageID: UUID) -> Bool {
        officialState(for: villageID)?.lastGood == nil
    }

    /// 指定部落 tag 的共享档案状态（nil = 无部落 / 从未请求）。
    public func clanState(for clanTag: String) -> ClanAPIState? {
        clanStates[clanTag]
    }

    /// 指定部落 tag 的当前战争共享状态。
    public func clanWarState(for clanTag: String) -> ClanWarAPIState? {
        clanWarStates[clanTag]
    }

    /// 指定部落 tag 的战争日志状态（分页）。
    public func warLogState(for clanTag: String) -> ClanWarLogAPIState? {
        clanWarLogStates[clanTag]
    }

    /// 指定部落 tag 的资本赛季状态（分页）。
    public func capitalState(for clanTag: String) -> ClanCapitalAPIState? {
        clanCapitalStates[clanTag]
    }

    /// 部落档案已知战争日志不公开（无档案/未知 → false）。
    public func isWarLogKnownNotPublic(for clanTag: String) -> Bool {
        clanState(for: clanTag)?.lastGood?.isWarLogPublic == false
    }

    /// 指定部落的战争日志是否还有更多页（分页按钮可用性）。
    public func warLogHasMore(for clanTag: String) -> Bool {
        guard let state = warLogState(for: clanTag), state.status == .success,
              let cursor = state.lastGood?.after else { return false }
        return PaginationLogic.hasMore(requestedCursor: nil, responseAfter: cursor)
    }

    /// 指定部落的资本赛季是否还有更多页。
    public func capitalHasMore(for clanTag: String) -> Bool {
        guard let state = capitalState(for: clanTag), state.status == .success,
              let cursor = state.lastGood?.after else { return false }
        return PaginationLogic.hasMore(requestedCursor: nil, responseAfter: cursor)
    }

    // MARK: - 刷新进行中状态（按村庄 / 部落 ID 隔离，Issue #35）

    /// 指定村庄的官方玩家刷新是否在途（卡片按村庄显示 ProgressView/禁用）。
    public func isRefreshingOfficialPlayer(villageID: UUID) -> Bool {
        refreshingOfficialPlayerVillageIDs.contains(villageID)
    }

    /// 指定部落的档案刷新是否在途（clanTag 为 nil 时返回 false）。
    public func isRefreshingClan(clanTag: String?) -> Bool {
        guard let clanTag else { return false }
        return refreshingClanTags.contains(clanTag)
    }

    /// 指定部落的当前战争刷新是否在途（clanTag 为 nil 时返回 false）。
    public func isRefreshingClanWar(clanTag: String?) -> Bool {
        guard let clanTag else { return false }
        return refreshingClanWarTags.contains(clanTag)
    }

    /// 指定部落的战争日志刷新/翻页是否在途（clanTag 为 nil 时返回 false）。
    public func isRefreshingWarLog(clanTag: String?) -> Bool {
        guard let clanTag else { return false }
        return refreshingWarLogTags.contains(clanTag)
    }

    /// 指定部落的资本赛季刷新/翻页是否在途（clanTag 为 nil 时返回 false）。
    public func isRefreshingCapital(clanTag: String?) -> Bool {
        guard let clanTag else { return false }
        return refreshingCapitalTags.contains(clanTag)
    }

    /// 兼容计算属性（全局语义：任意村庄/部落刷新在途即 true）。
    /// 侧边栏禁用与既有测试 waitUntil 继续使用；基于集合的 @Published
    /// 变化会触发 objectWillChange → SwiftUI 重算。
    public var isRefreshingOfficialData: Bool { !refreshingOfficialPlayerVillageIDs.isEmpty }
    public var isRefreshingClanData: Bool { !refreshingClanTags.isEmpty }
    public var isRefreshingClanWarData: Bool { !refreshingClanWarTags.isEmpty }
    public var isRefreshingWarLogData: Bool { !refreshingWarLogTags.isEmpty }
    public var isRefreshingCapitalData: Bool { !refreshingCapitalTags.isEmpty }

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

        let newName = OfficialPlayerTagValidator.normalized(snapshot.tag) ?? "村庄 " + String(villages.count + 1)
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

        let newName = OfficialPlayerTagValidator.normalized(snapshot.tag) ?? "村庄 " + String(villages.count + 1)
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
            let name = OfficialPlayerTagValidator.normalized(snapshot.tag) ?? "村庄 " + String(villages.count + 1)
            villages.append(VillageProfile(name: name))
            targetIndex = villages.count - 1
        }

        // tag 变化时自动重置官方数据（applyImportedSnapshot 内部处理）。
        villages[targetIndex].applyImportedSnapshot(snapshot)
        if villages[targetIndex].name.hasPrefix("村庄 ") || villages[targetIndex].name == "未命名村庄" {
            villages[targetIndex].name = OfficialPlayerTagValidator.normalized(snapshot.tag) ?? villages[targetIndex].name
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

    /// 刷新**指定村庄**的官方玩家信息（页面入口必须传显式 villageID）。
    /// 同步段捕获 village.id 与 expectedTag：刷新期间切换村庄不影响写回目标
    ///（applyOfficialState 按 villageID 定位、按 expectedTag 丢弃过期结果）。
    public func refreshOfficialPlayer(villageID: UUID) {
        guard !isRefreshingOfficialData else { return }
        guard let index = villages.firstIndex(where: { $0.id == villageID }) else { return }
        refreshingOfficialPlayerVillageIDs = [villageID]
        officialRefreshSummary = nil

        let village = villages[index]
        let expectedTag = village.officialTag
        Task { [weak self] in
            guard let self else { return }
            // defer 清空：无论后续分支如何都保证在途状态复位（防御未来提前 return）。
            defer { self.refreshingOfficialPlayerVillageIDs.removeAll() }
            let state = await self.refresher.refresh(village: village)
            // 竞态防护：刷新期间账号若已变化（重导入/清除），丢弃过期结果。
            let applied = self.applyOfficialState(state, to: village.id, expectedTag: expectedTag)
            self.persistVillages()
            // 玩家快照更新后部落归属可能变化，联动刷新**发起村庄**的部落
            // （传 village.id 而非读取当前选中村庄：刷新期间用户可能已切换
            // 村庄，读 selectedVillageID 会误刷当前村庄、漏刷发起村庄）。
            if applied, state.status == .success {
                self.refreshClan(villageID: village.id)
            }
        }
    }

    /// 刷新当前选中村庄的官方玩家信息（兼容转发，语义不变）。
    public func refreshOfficialPlayer() {
        refreshOfficialPlayer(villageID: selectedVillageID)
    }

    /// 刷新所有已导入村庄的官方玩家信息（同 tag 只请求一次，顺序执行）。
    public func refreshAllOfficialPlayers() {
        guard !isRefreshingOfficialData else { return }
        let villages = self.villages
        // 发起时快照：批量在途集合 = 发起请求时存在的全部村庄 ID。
        refreshingOfficialPlayerVillageIDs = Set(villages.map(\.id))
        officialRefreshSummary = nil

        // 记录发起请求时各村庄的 tag，用于写回竞态校验。
        var tagByID: [UUID: String] = [:]
        for village in villages {
            tagByID[village.id] = village.officialTag
        }
        Task { [weak self] in
            guard let self else { return }
            // defer 清空：无论后续分支如何都保证在途状态复位（防御未来提前 return）。
            defer { self.refreshingOfficialPlayerVillageIDs.removeAll() }
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

    // MARK: - 按 Tag 刷新入口（Issue #41 手动部落）

    /// 按显式 Tag 刷新部落档案（手动部落入口；村庄入口转发）。
    /// 同一 Tag 与村庄入口共享状态与防重入守卫，不产生重复请求。
    /// 忙时排队记录该 tag 本身（`pendingClanRefreshTags`），补跑覆盖手动 tag；
    /// 不会退化为村庄全量联动（村庄入口忙时同样走这里，其 tag 也被排队记录）。
    /// 入参先经 `ClanTagNormalizer.normalize` 规范化（trim + 大写），
    /// 请求/状态/在途 key 统一使用规范化值；非法输入静默 no-op。
    public func refreshClan(tag: String) {
        guard let tag = ClanTagNormalizer.normalize(tag) else { return }
        if isRefreshingClanData {
            // 被占用时排队记录 tag：补跑必须覆盖手动 tag（B1 修复——
            // 旧实现置 pendingClanRefreshAll 补跑村庄全量，手动 tag 被静默吞掉）。
            pendingClanRefreshTags.insert(tag)
            return
        }
        performClanRefresh(villageClanTags: [tag])
    }

    /// 按显式 Tag 刷新当前战争（手动部落入口；入参规范化，非法输入 no-op）。
    public func refreshClanWar(tag: String) {
        guard let tag = ClanTagNormalizer.normalize(tag) else { return }
        guard !isRefreshingClanWarData else { return }
        refreshingClanWarTags = [tag]
        let previous = clanWarStates

        Task { [weak self] in
            guard let self else { return }
            // defer 清空：无论后续分支如何都保证在途状态复位（防御未来提前 return）。
            defer { self.refreshingClanWarTags.removeAll() }
            let refreshed = await self.clanWarRefresher.refreshClanWars(
                villageClanTags: [tag],
                previous: previous
            )
            self.clanWarStates = ClanWarStateStore(states: self.clanWarStates)
                .merging(refreshed).states
            self.persistClanWarStates()
        }
    }

    /// 按显式 Tag 刷新战争日志（手动部落入口；force 语义与村庄版一致；
    /// 入参规范化，非法输入 no-op）。
    public func refreshWarLog(tag: String, force: Bool = false) {
        guard let tag = ClanTagNormalizer.normalize(tag) else { return }
        guard !isRefreshingWarLogData else { return }
        if !force, isWarLogKnownNotPublic(for: tag) { return }
        refreshingWarLogTags = [tag]
        let client = clanLogClient
        let parserVersion = ClanWarLogAPIState.currentParserVersion
        let previous = clanWarLogStates[tag]

        Task { [weak self] in
            guard let self else { return }
            // defer 清空：无论后续分支如何都保证在途状态复位（防御未来提前 return）。
            defer { self.refreshingWarLogTags.removeAll() }
            let state = await EndpointRefresher.fetchSingle(
                tag: tag,
                previous: previous,
                parserVersion: parserVersion
            ) { tag in
                OfficialWarLogPage(page: try await client.fetchWarLog(tag: tag))
            }
            self.clanWarLogStates[tag] = state
            self.persistClanWarLogStates()
        }
    }

    /// 按显式 Tag 战争日志加载更多（手动部落入口；入参规范化，非法输入 no-op）。
    public func loadMoreWarLog(tag: String) {
        guard let tag = ClanTagNormalizer.normalize(tag) else { return }
        guard !isRefreshingWarLogData else { return }
        guard let current = clanWarLogStates[tag],
              current.status == .success,
              let cursor = current.lastGood?.after else { return }
        refreshingWarLogTags = [tag]
        let client = clanLogClient
        let parserVersion = ClanWarLogAPIState.currentParserVersion
        // 跨解析器版本：旧累计页（成员明细未解析等）与新页条目 Equatable 不等，
        // 合并会残留重复；且旧页形态过时。重建语义：丢弃累计页，重新拉第一页
        //（refresh 语义），保持列表完整与游标停滞保护（重建请求无游标）。
        let needsRebuild = current.parserVersion != parserVersion

        Task { [weak self] in
            guard let self else { return }
            // defer 清空：无论后续分支如何都保证在途状态复位（防御未来提前 return）。
            defer { self.refreshingWarLogTags.removeAll() }
            let state = await EndpointRefresher.fetchSingle(
                tag: tag,
                previous: current,
                parserVersion: parserVersion
            ) { tag in
                if needsRebuild {
                    OfficialWarLogPage(page: try await client.fetchWarLog(tag: tag))
                } else {
                    OfficialWarLogPage(page: try await client.fetchWarLog(tag: tag, after: cursor))
                }
            }
            if state.status == .success,
               let fetched = state.lastGood,
               let existing = current.lastGood,
               !needsRebuild {
                var merged = state
                merged.lastGood = OfficialWarLogPage(
                    page: PaginationMerge.mergedPage(existing: existing.page, fetched: fetched.page)
                )
                self.clanWarLogStates[tag] = merged
            } else {
                // 失败保留 last-good（previous）；跨版本重建直接采用新页。
                self.clanWarLogStates[tag] = state
            }
            self.persistClanWarLogStates()
        }
    }

    /// 按显式 Tag 刷新部落资本赛季（手动部落入口）。
    public func refreshCapitalRaid(tag: String) {
        guard let tag = ClanTagNormalizer.normalize(tag) else { return }
        guard !isRefreshingCapitalData else { return }
        refreshingCapitalTags = [tag]
        let client = clanLogClient
        let parserVersion = ClanCapitalAPIState.currentParserVersion
        let previous = clanCapitalStates[tag]

        Task { [weak self] in
            guard let self else { return }
            // defer 清空：无论后续分支如何都保证在途状态复位（防御未来提前 return）。
            defer { self.refreshingCapitalTags.removeAll() }
            let state = await EndpointRefresher.fetchSingle(
                tag: tag,
                previous: previous,
                parserVersion: parserVersion
            ) { tag in
                OfficialCapitalRaidPage(page: try await client.fetchCapitalRaidSeasons(tag: tag))
            }
            self.clanCapitalStates[tag] = state
            self.persistClanCapitalStates()
        }
    }

    /// 按显式 Tag 资本赛季加载更多（手动部落入口；入参规范化，非法输入 no-op）。
    public func loadMoreCapitalRaid(tag: String) {
        guard let tag = ClanTagNormalizer.normalize(tag) else { return }
        guard !isRefreshingCapitalData else { return }
        guard let current = clanCapitalStates[tag],
              current.status == .success,
              let cursor = current.lastGood?.after else { return }
        refreshingCapitalTags = [tag]
        let client = clanLogClient
        let parserVersion = ClanCapitalAPIState.currentParserVersion
        // 跨解析器版本：与战争日志同理——丢弃累计页，重新拉第一页（无游标）。
        let needsRebuild = current.parserVersion != parserVersion

        Task { [weak self] in
            guard let self else { return }
            // defer 清空：无论后续分支如何都保证在途状态复位（防御未来提前 return）。
            defer { self.refreshingCapitalTags.removeAll() }
            let state = await EndpointRefresher.fetchSingle(
                tag: tag,
                previous: current,
                parserVersion: parserVersion
            ) { tag in
                if needsRebuild {
                    OfficialCapitalRaidPage(page: try await client.fetchCapitalRaidSeasons(tag: tag))
                } else {
                    OfficialCapitalRaidPage(page: try await client.fetchCapitalRaidSeasons(tag: tag, after: cursor))
                }
            }
            if state.status == .success,
               let fetched = state.lastGood,
               let existing = current.lastGood,
               !needsRebuild {
                var merged = state
                merged.lastGood = OfficialCapitalRaidPage(
                    page: PaginationMerge.mergedPage(existing: existing.page, fetched: fetched.page)
                )
                self.clanCapitalStates[tag] = merged
            } else {
                // 失败保留 last-good（previous）；跨版本重建直接采用新页。
                self.clanCapitalStates[tag] = state
            }
            self.persistClanCapitalStates()
        }
    }

    // MARK: - 部落数据刷新（共享数据层）

    /// 部落刷新进行中被再次触发时排队补跑，避免联动刷新被静默丢弃。
    /// - `pendingClanRefreshAll`：村庄全量联动语义（`refreshAllClans` 忙时置位，
    ///   补跑 = 当前村庄 tags 全量重拉）。
    /// - `pendingClanRefreshTags`：显式 tag 排队语义（`refreshClan(tag:)` 忙时记录，
    ///   补跑 = 村庄 tags ∪ 排队手动 tags；手动 tag 不再被静默丢弃）。
    private var pendingClanRefreshAll = false
    private var pendingClanRefreshTags: Set<String> = []

    /// 刷新当前选中村庄所属部落的档案（UI 按钮入口）。
    public func refreshCurrentClan() {
        refreshClan(villageID: selectedVillageID)
    }

    /// 刷新**指定村庄**所属部落的档案（按 clan tag 去重，单 tag 单请求）。
    /// 联动场景必须传发起村庄 id：刷新期间用户可能已切换村庄，
    /// 读取当前选中村庄会导致误刷新（P1 竞态）。
    /// COCHelper executable 无法访问本模块 internal，必须 public。
    public func refreshClan(villageID: UUID) {
        guard let tag = officialClanTag(for: villageID) else { return }
        refreshClan(tag: tag)
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
        refreshingClanTags = Set(villageClanTags.compactMap { $0 })
        let previous = clanStates

        Task { [weak self] in
            guard let self else { return }
            // 清空 + 排队补跑都不能用 defer 的"闭包末尾执行"：refreshAllClans
            // 以集合为空判断可进入（会重新设置集合），必须先清空再触发。
            let refreshed = await self.clanRefresher.refreshClans(
                villageClanTags: villageClanTags,
                previous: previous
            )
            self.mergeClanStates(refreshed)
            self.refreshingClanTags.removeAll()
            // 排队补跑：pendingClanRefreshAll（村庄全量联动）∪ pendingClanRefreshTags（含手动 tag）。
            // 补跑集合 = 村庄 tags ∪ 排队的手动 tags（去重；已清空的 refreshingClanTags
            // 保证补跑直接进入 performClanRefresh，不重复请求）。
            if self.pendingClanRefreshAll || !self.pendingClanRefreshTags.isEmpty {
                var tags: [String?] = []
                if self.pendingClanRefreshAll {
                    tags = self.villages.compactMap { $0.officialAPIState?.currentClanTag }
                }
                for tag in self.pendingClanRefreshTags where !tags.contains(tag) {
                    tags.append(tag)
                }
                self.pendingClanRefreshAll = false
                self.pendingClanRefreshTags.removeAll()
                self.performClanRefresh(villageClanTags: tags)
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

    /// 刷新**指定村庄**所属部落的当前战争（按需：用户打开战争面板时显式触发；
    /// 不做批量联动，避免启动/批量刷新时全量拉取战争请求）。
    /// `notInWar` 是成功响应（无战争空状态），失败保留 last-good。
    public func refreshClanWar(villageID: UUID) {
        guard let tag = officialClanTag(for: villageID) else { return }
        refreshClanWar(tag: tag)
    }

    /// 刷新当前村庄所属部落的当前战争（兼容转发，语义不变）。
    public func refreshCurrentClanWar() {
        refreshClanWar(villageID: selectedVillageID)
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

    // MARK: - 战争日志（分页，按需）

    /// 当前村庄所属部落的战争日志状态（nil = 无部落 / 从未请求）。
    public var currentWarLogState: ClanWarLogAPIState? {
        guard let tag = currentVillageClanTag else { return nil }
        return warLogState(for: tag)
    }

    /// 部落档案已知战争日志不公开（UI 预判：不发起请求，显示显式状态）。
    /// 403 兜底：即使档案过期，请求失败也会显示失败原因。
    public var isCurrentWarLogKnownNotPublic: Bool {
        guard let tag = currentVillageClanTag else { return false }
        return isWarLogKnownNotPublic(for: tag)
    }

    /// 当前战争日志是否还有更多页（分页按钮可用性）。
    public var currentWarLogHasMore: Bool {
        guard let tag = currentVillageClanTag else { return false }
        return warLogHasMore(for: tag)
    }

    /// 战争日志首屏/刷新：重新拉第一页（**替换**累计列表，避免陈旧混合）。
    /// 刷新失败时保留既有 last-good（传 previous 保持共享层契约）。
    /// `force` 为 true 时跳过"已知不公开"预判（用户主动要求检查，
    /// 应对部落档案过期导致的误判；真实 403 仍会显示失败原因）。
    public func refreshWarLog(villageID: UUID, force: Bool = false) {
        guard let tag = officialClanTag(for: villageID) else { return }
        refreshWarLog(tag: tag, force: force)
    }

    /// 当前村庄所属部落的战争日志首屏/刷新（兼容转发，语义不变）。
    public func refreshCurrentWarLog(force: Bool = false) {
        refreshWarLog(villageID: selectedVillageID, force: force)
    }

    /// 指定村庄所属部落的战争日志加载更多：用现有游标向后翻页，**合并**（去重）到累计列表。
    public func loadMoreWarLog(villageID: UUID) {
        guard let tag = officialClanTag(for: villageID) else { return }
        loadMoreWarLog(tag: tag)
    }

    /// 当前村庄所属部落的战争日志加载更多（兼容转发，语义不变）。
    public func loadMoreCurrentWarLog() {
        loadMoreWarLog(villageID: selectedVillageID)
    }

    private func persistClanWarLogStates() {
        guard let data = try? JSONEncoder().encode(ClanWarLogStateStore(states: clanWarLogStates)) else { return }
        defaults.set(data, forKey: Self.clanWarLogStatesStorageKey)
    }

    private static func loadClanWarLogStates(from defaults: UserDefaults) -> [String: ClanWarLogAPIState] {
        guard let data = defaults.data(forKey: Self.clanWarLogStatesStorageKey),
              let store = try? JSONDecoder().decode(ClanWarLogStateStore.self, from: data) else {
            return [:]
        }
        return store.states
    }

    // MARK: - 部落资本赛季（分页，按需）

    /// 当前村庄所属部落的资本赛季状态。
    public var currentCapitalState: ClanCapitalAPIState? {
        guard let tag = currentVillageClanTag else { return nil }
        return capitalState(for: tag)
    }

    /// 当前资本赛季是否还有更多页。
    public var currentCapitalHasMore: Bool {
        guard let tag = currentVillageClanTag else { return false }
        return capitalHasMore(for: tag)
    }

    /// 指定村庄所属部落的资本赛季首屏/刷新（替换累计列表；失败保留既有 last-good）。
    public func refreshCapitalRaid(villageID: UUID) {
        guard let tag = officialClanTag(for: villageID) else { return }
        refreshCapitalRaid(tag: tag)
    }

    /// 当前村庄所属部落的资本赛季首屏/刷新（兼容转发，语义不变）。
    public func refreshCurrentCapitalRaid() {
        refreshCapitalRaid(villageID: selectedVillageID)
    }

    /// 指定村庄所属部落的资本赛季加载更多（合并去重）。
    public func loadMoreCapitalRaid(villageID: UUID) {
        guard let tag = officialClanTag(for: villageID) else { return }
        loadMoreCapitalRaid(tag: tag)
    }

    /// 当前村庄所属部落的资本赛季加载更多（兼容转发，语义不变）。
    public func loadMoreCurrentCapitalRaid() {
        loadMoreCapitalRaid(villageID: selectedVillageID)
    }

    // MARK: - 手动跟踪部落（Issue #41）

    public enum TrackedClanAddError: Equatable, Error {
        case invalidTag
        case duplicate
    }

    /// 部落解析错误（Issue #48 Step A：添加流程的解析预览阶段）。
    ///
    /// 展示导向的独立枚举：与 `CoAPIError`（传输语义）解耦，UI 直接按 case
    /// 展示 `userFacingMessage`，无需感知 HTTP 细节。映射规则见 `map(_:)`。
    public enum ClanResolveError: Equatable, Sendable, Error {
        case invalidTag
        case missingToken
        case notFound
        case accessDenied
        case rateLimited
        case server
        case network
        case malformed

        /// 展示文案（脱敏，可安全用于 UI）。
        public var userFacingMessage: String {
            switch self {
            case .invalidTag:
                return "Tag 无效：需要以 # 开头，仅含大写字母和数字，长度不超过 15 字符。"
            case .missingToken:
                return "未配置 API token，请先在账号数据页配置。"
            case .notFound:
                return "未找到该部落（404），请检查 Tag 是否正确。"
            case .accessDenied:
                return "访问被拒绝（401/403）：请检查 API token 是否有效。"
            case .rateLimited:
                return "请求被限流（429），请稍后再试。"
            case .server:
                return "服务器错误（5xx），请稍后再试。"
            case .network:
                return "网络错误，请检查连接后重试。"
            case .malformed:
                return "响应解析失败，请稍后再试。"
            }
        }
    }

    /// 解析部落（Issue #48 Step A）：本地规范化 → `fetchClan` → 成功后写入
    /// 共享缓存并返回快照。**不保存跟踪关系**（保存由 `addTrackedClan` 负责），
    /// **不查重**（查重由 `isClanTracked` 提供，sheet 在发起请求前拦截）。
    ///
    /// 成功写入 `clanStates` 的理由：#48「详情页首屏只读取已保存的基础信息/
    /// API 状态」——确认保存后打开详情页首屏直接有数据，无需再次请求。
    /// 解析不经过 `refreshingClanTags` 防重入守卫（部落未收藏前详情页不可达，
    /// 与刷新并发实际不会发生；文档注明以防未来接线时误用）。
    ///
    /// 错误映射：`CoAPIError.missingCredentials`（token provider 返回 nil 时
    /// 由 client 抛出，与刷新链路一致，不重复检查 Keychain）→ `.missingToken`；
    /// 401/403 → `.accessDenied`；404 → `.notFound`；429 → `.rateLimited`；
    /// 5xx → `.server`；超时/网络 → `.network`；解析 → `.malformed`。
    public func resolveClan(rawTag: String?) async -> Result<OfficialClanSnapshot, ClanResolveError> {
        guard let tag = ClanTagNormalizer.normalize(rawTag) else { return .failure(.invalidTag) }
        do {
            let snapshot = try await clanRefresher.client.fetchClan(tag: tag)
            let state = ClanAPIState(
                status: .success,
                clanTag: tag,
                fetchedAt: Date(),
                lastAttemptAt: Date(),
                lastErrorReason: nil,
                lastHTTPStatus: nil,
                parserVersion: ClanAPIState.currentParserVersion,
                lastGood: snapshot,
                unrecognizedKeys: snapshot.unrecognizedKeys
            )
            mergeClanStates([tag: state])
            return .success(snapshot)
        } catch let error as CoAPIError {
            return .failure(Self.mapResolveError(error))
        } catch {
            return .failure(.network)
        }
    }

    /// 该 Tag 是否已在跟踪列表（解析前查重，避免无谓请求）。非法输入返回 false。
    public func isClanTracked(rawTag: String?) -> Bool {
        guard let tag = ClanTagNormalizer.normalize(rawTag) else { return false }
        return trackedClans.contains { $0.clanTag == tag }
    }

    private static func mapResolveError(_ error: CoAPIError) -> ClanResolveError {
        switch error {
        case .missingCredentials:
            return .missingToken
        case .unauthorized, .accessDenied:
            return .accessDenied
        case .notFound:
            return .notFound
        case .rateLimited:
            return .rateLimited
        case .serverError:
            return .server
        case .timeout, .network:
            return .network
        case .malformedResponse:
            return .malformed
        }
    }

    /// 添加手动跟踪部落：只做本地校验与保存，**不触发任何网络请求**。
    /// Tag 规范化失败 → .invalidTag；规范化后已存在 → .duplicate（不覆盖原档案）。
    @discardableResult
    public func addTrackedClan(rawTag: String?, displayName: String?) -> Result<TrackedClanProfile, TrackedClanAddError> {
        guard let tag = ClanTagNormalizer.normalize(rawTag) else { return .failure(TrackedClanAddError.invalidTag) }
        guard !trackedClans.contains(where: { $0.clanTag == tag }) else { return .failure(TrackedClanAddError.duplicate) }
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = TrackedClanProfile(
            clanTag: tag,
            displayName: trimmedName?.isEmpty == false ? trimmedName : nil,
            createdAt: Date()
        )
        trackedClans.append(profile)
        persistTrackedClans()
        return .success(profile)
    }

    /// 删除跟踪关系：**保留**按 Tag 的共享 API 缓存（clanStates 等），
    /// 误删后重新添加不丢失历史数据。入参规范化（幂等），非法输入 no-op。
    public func removeTrackedClan(tag: String) {
        guard let tag = ClanTagNormalizer.normalize(tag) else { return }
        guard trackedClans.contains(where: { $0.clanTag == tag }) else { return }
        trackedClans.removeAll { $0.clanTag == tag }
        persistTrackedClans()
    }

    /// 该 Tag 是否为**当前选中村庄**所属部落（列表"当前村庄所属"标识）。
    /// 只做标识展示，不改变手动档案身份。入参规范化（幂等）。
    public func isCurrentVillageClan(_ tag: String) -> Bool {
        guard let tag = ClanTagNormalizer.normalize(tag) else { return false }
        return currentVillageClanTag == tag
    }

    private func persistTrackedClans() {
        guard let data = try? JSONEncoder().encode(TrackedClanStore(profiles: trackedClans)) else { return }
        defaults.set(data, forKey: Self.trackedClansStorageKey)
    }

    private static func loadTrackedClans(from defaults: UserDefaults) -> [TrackedClanProfile] {
        guard let data = defaults.data(forKey: Self.trackedClansStorageKey),
              let store = try? JSONDecoder().decode(TrackedClanStore.self, from: data) else {
            return []
        }
        return store.profiles
    }

    private func persistClanCapitalStates() {
        guard let data = try? JSONEncoder().encode(ClanCapitalStateStore(states: clanCapitalStates)) else { return }
        defaults.set(data, forKey: Self.clanCapitalStatesStorageKey)
    }

    private static func loadClanCapitalStates(from defaults: UserDefaults) -> [String: ClanCapitalAPIState] {
        guard let data = defaults.data(forKey: Self.clanCapitalStatesStorageKey),
              let store = try? JSONDecoder().decode(ClanCapitalStateStore.self, from: data) else {
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

    private func targetVillageIndex(for snapshot: AccountSnapshot) -> Int? {
        if let tag = OfficialPlayerTagValidator.normalized(snapshot.tag),
           let existingIndex = villages.firstIndex(where: { OfficialPlayerTagValidator.normalized($0.tag) == tag }) {
            return existingIndex
        }

        guard let currentIndex = villages.firstIndex(where: { $0.id == selectedVillageID }),
              importIntoCurrentVillage || (villages.count == 1 && !villages[currentIndex].hasImportedData)
        else { return nil }
        return currentIndex
    }

    private func isReimportingExistingVillage(_ snapshot: AccountSnapshot, at index: Int) -> Bool {
        guard let tag = OfficialPlayerTagValidator.normalized(snapshot.tag) else { return false }
        return OfficialPlayerTagValidator.normalized(villages[index].tag) == tag
    }

    private static func loadVillages(from defaults: UserDefaults) -> [VillageProfile] {
        guard let data = defaults.data(forKey: "coc-helper.villages.v1"),
              let decoded = try? JSONDecoder().decode([VillageProfile].self, from: data) else {
            return []
        }
        return decoded
    }

    /// 测试辅助：为指定 Tag 注入共享部落缓存（验证删除跟踪关系保留缓存）。
    /// 仅测试模块通过 @testable 可见，生产路径不调用。
    func seedClanStateForTesting(tag: String) {
        clanStates[tag] = ClanAPIState(
            status: .success,
            fetchedAt: Date(),
            lastErrorReason: nil,
            parserVersion: ClanAPIState.currentParserVersion,
            lastGood: OfficialClanSnapshot(
                tag: tag, name: "测试部落", type: nil, description: nil,
                clanLevel: 1, badgeUrls: nil,
                members: 1, requiredTrophies: nil, requiredTownHallLevel: nil,
                warWins: nil, warLosses: nil, warTies: nil, warWinStreak: nil,
                isWarLogPublic: nil,
                labels: nil, clanCapital: nil, unrecognizedKeys: []
            )
        )
    }
}
