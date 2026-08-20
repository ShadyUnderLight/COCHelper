import AppKit
import Combine
import Foundation
import COCHelperCore

/// Existing AppModel tests inject a history store but do not need to touch the
/// user's Application Support directory.  Production uses the file-backed
/// store; this adapter keeps the same persistence contract for injected runs.
private final class InMemoryManualTrackerStore: ManualTrackerStore, @unchecked Sendable {
    private var envelope: ManualTrackerEnvelope?

    var transactionJournalURL: URL? { nil }

    func load() throws -> ManualTrackerEnvelope? {
        envelope
    }

    func save(_ envelope: ManualTrackerEnvelope) throws {
        self.envelope = try envelope.validated()
    }

    func readRawData() throws -> Data? {
        try envelope?.encodedData()
    }

    func writeRawData(_ data: Data) throws {
        do {
            envelope = try JSONDecoder()
                .decode(ManualTrackerEnvelope.self, from: data)
                .validated()
        } catch let error as ManualTrackerStoreError {
            throw error
        } catch {
            throw ManualTrackerStoreError.corrupt(error.localizedDescription)
        }
    }

    func restoreRawData(_ data: Data?) throws {
        guard let data else {
            envelope = nil
            return
        }
        try writeRawData(data)
    }
}

// MARK: - 快捷快照导入（Issue #61）

/// 「按当前详情页」快捷导入的预览：目标村庄固定为 `targetVillageID`，
/// 与剪贴板 JSON 的账号 tag 无关（路由到显式 ID，而非按 tag 匹配）。
public struct QuickImportPreview: Identifiable, Equatable, Sendable {
    public let snapshot: AccountSnapshot
    public let targetVillageID: UUID
    public let targetVillageName: String
    /// 目标村庄当前快照 tag（原样，未规范化）。
    public let targetVillageTag: String?
    /// 目标村庄是否已有导入快照（与 tag 是否缺失无关：有快照但无 tag 时
    /// targetVillageTag 为 nil 但本字段为 true，P2 修正 isFirstImport 误判）。
    public let targetVillageHasSnapshot: Bool
    /// normalized(JSON tag) == normalized(targetVillageTag)。
    public let replacesSameTag: Bool
    /// 目标村庄从未导入过快照（targetVillageHasSnapshot == false）。
    public var isFirstImport: Bool { !targetVillageHasSnapshot }
    public var id: UUID { targetVillageID }
    public var confirmationTitle: String { "更新「\(targetVillageName)」" }
    public let destinationDescription: String
    public let reconciliationPreview: ManualReconciliationPreview?

    public init(
        snapshot: AccountSnapshot,
        targetVillageID: UUID,
        targetVillageName: String,
        targetVillageTag: String?,
        targetVillageHasSnapshot: Bool,
        replacesSameTag: Bool,
        destinationDescription: String,
        reconciliationPreview: ManualReconciliationPreview? = nil
    ) {
        self.snapshot = snapshot
        self.targetVillageID = targetVillageID
        self.targetVillageName = targetVillageName
        self.targetVillageTag = targetVillageTag
        self.targetVillageHasSnapshot = targetVillageHasSnapshot
        self.replacesSameTag = replacesSameTag
        self.destinationDescription = destinationDescription
        self.reconciliationPreview = reconciliationPreview
    }
}

/// 快捷导入错误（展示导向：UI 直接展示 `errorDescription`）。
public enum QuickImportError: Error, LocalizedError, Equatable, Sendable {
    case emptyClipboard
    case parseFailed(AccountSnapshotImportError)
    case targetVillageMissing
    case tagBelongsToAnotherVillage(tag: String, villageName: String)
    case historyUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyClipboard:
            "系统剪贴板中没有可用的文本。"
        case .parseFailed(let error):
            error.errorDescription ?? "解析失败。"
        case .targetVillageMissing:
            "目标村庄已不存在，请刷新后重试。"
        case .tagBelongsToAnotherVillage(let tag, let villageName):
            "剪贴板 JSON 的账号 Tag（\(tag)）属于另一档案「\(villageName)」。为避免误覆盖，请到「账号数据」页手动导入。"
        case .historyUnavailable(let message):
            message
        }
    }
}

private struct SnapshotHistoryProjectionCacheKey: Hashable {
    let villageID: UUID
    let startOfDay: Date
    let timeZoneIdentifier: String
    let hasCurrentSnapshot: Bool
}

/// 手动升级命令错误（UI 展示导向；Core 内部错误统一归类）。
public enum ManualUpgradeCommandError: Error, LocalizedError, Equatable, Sendable {
    case villageMissing
    case storeUnavailable(String)
    case staleAction
    case recordNotFound(UUID)
    case recordNotActive(UUID)
    case invalidTime
    case unreconciledSnapshot
    case coreRejected(String)
    case queueCapacityInvalid
    case queueCapacityFull(
        queueKind: LocalQueueKind,
        activeCount: Int,
        confirmedImportedCount: Int,
        capacity: Int
    )
    case itemNotImportedObservation
    case importedObservationWithoutTimer
    case importedObservationIncompleteCoverage

    public var errorDescription: String? {
        switch self {
        case .villageMissing:
            "目标村庄不存在。"
        case .storeUnavailable(let message):
            "手动升级存储不可用：" + message
        case .staleAction:
            "升级操作已过期，请刷新后重试。"
        case .recordNotFound:
            "未找到该升级记录。"
        case .recordNotActive:
            "该升级记录已不在进行中。"
        case .invalidTime:
            "开始时间无效（不允许未来时间）。"
        case .unreconciledSnapshot:
            "当前快照与手动升级记录尚未对账。请先完成快照对账后再操作。"
        case .coreRejected(let message):
            "升级命令被拒绝：" + message
        case .queueCapacityInvalid:
            "队列容量配置无效（必须为 0 到 10000 的整数）。"
        case .queueCapacityFull(
            let queueKind, let activeCount, let confirmedImportedCount, let capacity
        ):
            "本地容量已满：\(queueKind.displayName) 队列本地占用 \(activeCount) 个、已确认导入 \(confirmedImportedCount) 个，容量 \(capacity)。"
        case .itemNotImportedObservation:
            "该条目不是导入观察，不能确认本地队列映射。"
        case .importedObservationWithoutTimer:
            "该导入观察没有进行中计时证据，不能确认本地队列映射。"
        case .importedObservationIncompleteCoverage:
            "该导入观察的等级/数量覆盖不完整，不能确认本地队列映射。"
        }
    }
}

/// Issue #183：UI 展示用的导入观察分配候选。
public struct ImportedObservationCandidate: Identifiable, Hashable, Sendable {
    public let itemKey: TrackerItemKey
    public let displayName: String
    public let hasTimer: Bool
    public let assignment: QueueAssignmentDecision?
    /// review P2：非当前 lineage 的历史映射（保留为审计证据，不占容量）。
    public let historicalAssignments: [QueueAssignmentDecision]
    /// Issue #189：是否具备"确认/重新确认本地队列映射"资格。直接投影 Core
    /// 谓词 `ManualItemState.isQueueAssignmentConfirmable`（timer + 覆盖完整），
    /// 不在 UI 中自行推断 observedTimer/levelDistribution/coverage 组合。
    public let isConfirmable: Bool
    /// Issue #189：不可确认时的原因文案（nil = 可确认）。由 AppModel 依据
    /// 证据状态生成，UI 只消费展示。
    public let unconfirmableReason: String?

    public init(
        itemKey: TrackerItemKey,
        displayName: String,
        hasTimer: Bool,
        assignment: QueueAssignmentDecision?,
        historicalAssignments: [QueueAssignmentDecision] = [],
        isConfirmable: Bool,
        unconfirmableReason: String?
    ) {
        self.itemKey = itemKey
        self.displayName = displayName
        self.hasTimer = hasTimer
        self.assignment = assignment
        self.historicalAssignments = historicalAssignments
        self.isConfirmable = isConfirmable
        self.unconfirmableReason = unconfirmableReason
    }

    public var id: String { itemKey.stableID }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var villages: [VillageProfile]
    @Published public private(set) var selectedVillageID: UUID
    @Published public var importText = ""
    @Published public var importIntoCurrentVillage = false
    @Published public private(set) var accountSnapshot: AccountSnapshot?
    @Published public private(set) var pendingAccountSnapshot: AccountSnapshot?
    @Published public private(set) var pendingReconciliationPreview: ManualReconciliationPreview?
    @Published public private(set) var accountImportError: String?
    @Published public private(set) var snapshotHistoryError: String?
    /// Health of the base village store.  A corrupt or future store is kept in
    /// memory only as a recovery placeholder and never treated as an empty
    /// successful load.
    @Published public private(set) var villageStoreStatus: VillageStoreStatus = .missing
    @Published public private(set) var villageStoreError: String?
    @Published public private(set) var villageStoreRecoveryNotice: String?
    /// Projection-safe per-village manual state. Imported snapshots remain
    /// observations; a core whose baseline is not the current active history
    /// tail is exposed here as unknown without rewriting its persisted bytes.
    @Published public private(set) var manualUpgradeCores: [UUID: ManualUpgradeCore] = [:]
    @Published public private(set) var manualTrackerStatus: ManualTrackerStoreStatus = .empty
    @Published public private(set) var manualTrackerError: String?
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
    /// 部落都城突袭周末共享数据层（分页）。
    @Published public private(set) var clanCapitalStates: [String: ClanCapitalAPIState] = [:]
    /// 正在刷新突袭周末的部落 tag 集合（防重入守卫 + 卡片按部落隔离，Issue #35）。
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
    /// 官方公告人工维护的限时内容阶段表。版本与实际加载目录绑定；目录加载失败时
    /// 回退默认 bundled 版本，仍可为旧快照提供历史阶段标记。
    public private(set) lazy var seasonalPhases: SeasonalPhaseTable = {
        let version = gameCatalog?.gameVersion ?? GameCatalog.defaultBundledVersion
        return SeasonalPhaseTable.loadBundled(version: version)
    }()
    /// 精制台 Defense/Module 目录独立于普通升级目录；缺失时只降级为未知状态。
    public private(set) lazy var craftTableCatalog: CraftTableCatalog? = CraftTableCatalog.loadBundled()

    // MARK: - Issue #200 渲染缓存

    /// 目录/阶段表内容纪元：游戏目录、精制台目录或阶段表热更新时递增，
    /// 作为投影缓存 key 的一部分。当前 bundled 目录为 lazy 只读（恒 0）；
    /// 保留递增点供未来热更新路径使用（缓存 key 变化 → 自动重建）。
    public private(set) var catalogEpoch = 0

    /// 村庄静态投影缓存（key = 内容身份，命中后动态刷新）。
    /// @MainActor 持有；同步访问，无后台计算。
    private let projectionCache = VillageProjectionCache()

    /// Issue #212：详情页扁平 row 元数据缓存（与投影 render 身份对齐）。
    private let detailFlatRowCache = VillageDetailFlatRowCache()

    /// Issue #200：投影缓存统计（测试钩子，@testable 可见；生产不消费）。
    var projectionCacheStats: (buildCount: Int, hitCount: Int) {
        (projectionCache.buildCount, projectionCache.hitCount)
    }

    /// Issue #212：扁平 row 缓存统计（测试钩子）。
    var detailFlatRowCacheStats: (buildCount: Int, hitCount: Int) {
        (detailFlatRowCache.buildCount, detailFlatRowCache.hitCount)
    }

    /// Issue #200：村庄详情渲染入口（缓存命中 + 动态刷新）。
    /// 输出与直接 `VillageCatalogProjection.project` 一致。
    public func villageRender(
        villageID: UUID, base: TrackerBase, now: Date
    ) -> VillageProjectionCache.RenderResult? {
        guard let village = villages.first(where: { $0.id == villageID }) else {
            return nil
        }
        return projectionCache.render(
            village: village,
            catalog: gameCatalog,
            craftTableCatalog: craftTableCatalog,
            seasonalPhases: seasonalPhases,
            base: base,
            now: now,
            manualUpgradeCore: manualUpgradeCores[villageID],
            catalogEpoch: catalogEpoch
        )
    }

    /// Issue #212：村庄详情扁平 row 元数据（缓存 + 动态 group 回查）。
    ///
    /// row 元数据在 render/筛选身份不变时复用；`sortDependsOnNow` 为 true
    /// （如 `.remaining`）时每次重建。View body 仍由 LazyVStack 按需构建。
    public func villageDetailFlatRows(
        village: VillageProfile,
        render: VillageProjectionCache.RenderResult,
        base: TrackerBase,
        now: Date,
        displayGroups: [VillageDetailGroup],
        statsByKey: [String: VillageCategoryCompletion],
        filterKey: VillageDetailFlatRowCache.FilterKey,
        sortDependsOnNow: Bool
    ) -> (rows: [VillageDetailFlatRow], groupByInstanceID: [String: BuildingGroup]) {
        let buildingGroups = render.buildingGroups
        guard let renderKey = VillageDetailFlatRowCache.RenderIdentityKey(
            village: village,
            base: base,
            now: now,
            manualUpgradeCore: manualUpgradeCores[village.id],
            catalogEpoch: catalogEpoch,
            catalog: gameCatalog,
            seasonalPhases: seasonalPhases
        ) else {
            let groupByInstanceID = VillageDetailFlatRowProjection.groupByInstanceID(
                from: buildingGroups
            )
            let rows = VillageDetailFlatRowProjection.build(
                displayGroups: displayGroups,
                statsByKey: statsByKey,
                groupByInstanceID: groupByInstanceID
            )
            return (rows, groupByInstanceID)
        }
        return detailFlatRowCache.rows(
            renderKey: renderKey,
            filterKey: filterKey,
            sortDependsOnNow: sortDependsOnNow,
            displayGroups: displayGroups,
            statsByKey: statsByKey,
            buildingGroups: buildingGroups
        )
    }

    /// Issue #200：升级总览单趟渲染入口（缓存 provider 注入）。
    /// 输出与 `overviewRecords` + `overviewState` 一致；村庄投影走缓存
    /// （每 village×base 一次投影，tick 间动态刷新）。`villages` 限定
    /// 渲染范围（「全部村庄」传 `self.villages`，「当前村庄」传单元素数组）。
    public func overviewRender(
        for villages: [VillageProfile], now: Date
    ) -> UpgradeOverviewRender {
        // 局部快照避免闭包捕获 MainActor 隔离属性（Swift 6 并发检查）。
        let catalog = gameCatalog
        let craftTableCatalog = craftTableCatalog
        let seasonalPhases = seasonalPhases
        let cores = manualUpgradeCores
        let epoch = catalogEpoch
        let cache = projectionCache
        let provider: VillageProjectionProvider = { village, base, now in
            cache.render(
                village: village,
                catalog: catalog,
                craftTableCatalog: craftTableCatalog,
                seasonalPhases: seasonalPhases,
                base: base,
                now: now,
                manualUpgradeCore: cores[village.id],
                catalogEpoch: epoch
            ).projection
        }
        return UpgradeOverviewProjection.overviewRender(
            from: villages,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog,
            seasonalPhases: seasonalPhases,
            manualUpgradeCores: cores,
            at: now,
            projectionProvider: provider
        )
    }

    private let defaults: UserDefaults
    private let legacyAccountSnapshotStorageKey = "coc-helper.account-snapshot.v1"
    private let villagesStorageKey = "coc-helper.villages.v1"
    private let villageStoreRecoveryKey = "coc-helper.villages.v1.recovery"
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
    /// 快捷导入的剪贴板读取器（测试注入；生产默认读系统剪贴板）。
    private let clipboardReader: () -> String?
    private let historyService: SnapshotHistoryService
    private let currentVillagePersistence: any CurrentVillagePersistence
    private let importTransaction: SnapshotImportTransactionCoordinator
    private var historyEnvelope: SnapshotHistoryEnvelope?
    private let manualTrackerStore: any ManualTrackerStore
    private let manualTrackerTransaction: ManualTrackerTransactionCoordinator
    private var manualTrackerEnvelope: ManualTrackerEnvelope?
    private var historyLoadFailure: SnapshotHistoryAvailability?
    private var historyProjectionCache: [SnapshotHistoryProjectionCacheKey: SnapshotHistoryProjection] = [:]
    private var villageStoreRecoveryData: Data?

    private enum VillageTransactionJournalKind: String, Codable {
        case snapshotImport
        case manualTracker
    }

    public convenience init(
        defaults: UserDefaults = .standard,
        refresher: OfficialPlayerRefresher? = nil,
        clanRefresher: ClanRefresher? = nil,
        clanWarRefresher: ClanWarRefresher? = nil,
        clanLogClient: CoAPIClient? = nil,
        clipboardReader: (() -> String?)? = nil,
        historyStore: (any SnapshotHistoryStore)? = nil,
        manualTrackerStore: (any ManualTrackerStore)? = nil
    ) {
        self.init(
            defaults: defaults,
            refresher: refresher,
            clanRefresher: clanRefresher,
            clanWarRefresher: clanWarRefresher,
            clanLogClient: clanLogClient,
            clipboardReader: clipboardReader,
            historyStore: historyStore,
            manualTrackerStore: manualTrackerStore,
            currentVillagePersistence: nil,
            transactionJournalURL: nil
        )
    }

    init(
        defaults: UserDefaults = .standard,
        refresher: OfficialPlayerRefresher? = nil,
        clanRefresher: ClanRefresher? = nil,
        clanWarRefresher: ClanWarRefresher? = nil,
        clanLogClient: CoAPIClient? = nil,
        clipboardReader: (() -> String?)? = nil,
        historyStore: (any SnapshotHistoryStore)? = nil,
        manualTrackerStore: (any ManualTrackerStore)? = nil,
        currentVillagePersistence: (any CurrentVillagePersistence)? = nil,
        transactionJournalURL: URL? = nil
    ) {
        self.defaults = defaults
        self.clipboardReader = clipboardReader ?? { NSPasteboard.general.string(forType: .string) }

        let resolvedHistoryStore = historyStore ?? FileSnapshotHistoryStore(
            fileURL: FileSnapshotHistoryStore.defaultURL()
        )
        let resolvedCurrentPersistence = currentVillagePersistence
            ?? UserDefaultsCurrentVillagePersistence(defaults: defaults, key: villagesStorageKey)
        self.historyService = SnapshotHistoryService(store: resolvedHistoryStore)
        self.currentVillagePersistence = resolvedCurrentPersistence
        let resolvedManualTrackerStore: any ManualTrackerStore
        if let manualTrackerStore {
            resolvedManualTrackerStore = manualTrackerStore
        } else if historyStore != nil {
            // A caller-supplied history store is the existing test/injection
            // seam.  Keep that path fully isolated from real user data.
            resolvedManualTrackerStore = InMemoryManualTrackerStore()
        } else {
            resolvedManualTrackerStore = FileManualTrackerStore(
                fileURL: FileManualTrackerStore.defaultURL()
            )
        }
        self.manualTrackerStore = resolvedManualTrackerStore
        self.importTransaction = SnapshotImportTransactionCoordinator(
            current: resolvedCurrentPersistence,
            history: resolvedHistoryStore,
            journalURL: transactionJournalURL ?? resolvedHistoryStore.transactionJournalURL,
            manual: resolvedManualTrackerStore
        )
        self.manualTrackerTransaction = ManualTrackerTransactionCoordinator(
            current: resolvedCurrentPersistence,
            manual: resolvedManualTrackerStore,
            journalURL: resolvedManualTrackerStore.transactionJournalURL
        )
        self.historyEnvelope = nil
        self.manualTrackerEnvelope = nil
        self.historyLoadFailure = nil
        self.villageStoreRecoveryData = nil
        snapshotHistoryError = nil
        manualTrackerStatus = .empty
        manualTrackerError = nil

        var persistedVillageData = resolvedCurrentPersistence.readData()
        var villageLoadResult = VillageStoreCodec.load(persistedVillageData)
        let skipTransactionRecovery: Bool = {
            switch villageLoadResult {
            case .corrupt, .unsupportedSchema:
                return true
            case .missing, .loaded:
                return false
            }
        }()
        var startupError: String?
        var manualStartupError: String?

        // A transaction journal can restore a missing/valid current blob.  It
        // must run before startup decides whether to synthesize and persist a
        // default village; otherwise a recovered payload could be overwritten.
        // Corrupt/future bytes deliberately skip all recovery writes so the
        // original payload remains untouched until the user chooses recovery.
        if !skipTransactionRecovery {
            do {
                try importTransaction.recoverIfNeeded()
                persistedVillageData = resolvedCurrentPersistence.readData()
                villageLoadResult = VillageStoreCodec.load(persistedVillageData)
            } catch {
                startupError = Self.localizedPersistenceError(error)
                historyLoadFailure = Self.snapshotHistoryAvailability(for: error)
            }

            // Manual transactions can also carry a current-village payload;
            // recover them before deciding whether a missing store needs a
            // synthesized default.  A corrupt/future current blob never
            // reaches this path, so no derived-store side effect is started.
            if startupError == nil {
                let skipManualRecovery: Bool = {
                    switch villageLoadResult {
                    case .corrupt, .unsupportedSchema:
                        return true
                    case .missing, .loaded:
                        return false
                    }
                }()
                if !skipManualRecovery {
                    do {
                        try manualTrackerTransaction.recoverIfNeeded()
                    } catch {
                        manualStartupError = Self.localizedPersistenceError(error)
                    }
                }
            }

            persistedVillageData = resolvedCurrentPersistence.readData()
            villageLoadResult = VillageStoreCodec.load(persistedVillageData)
        }

        var resolvedVillageStatus: VillageStoreStatus
        var resolvedVillageError: String?
        var resolvedVillageRecoveryData: Data?
        var initialVillages: [VillageProfile]
        var shouldPersistInitialVillages = false
        var canInitializeDerivedStores = false

        switch villageLoadResult {
        case .missing:
            let legacySnapshot = defaults.data(forKey: legacyAccountSnapshotStorageKey)
                .flatMap { try? JSONDecoder().decode(AccountSnapshot.self, from: $0) }
            initialVillages = [VillageProfile(
                name: legacySnapshot?.tag ?? "我的村庄",
                accountSnapshot: legacySnapshot
            )]
            resolvedVillageStatus = .missing
            resolvedVillageError = nil
            resolvedVillageRecoveryData = nil
            shouldPersistInitialVillages = true
            canInitializeDerivedStores = true
        case .loaded(let villages) where villages.isEmpty:
            // An explicit empty array is valid data, but the UI/model invariant
            // still needs one in-memory target.  Canonicalize it to a first
            // village through the normal explicit write path below; it is not a
            // decode failure and never consults the legacy snapshot.
            initialVillages = [VillageProfile(name: "我的村庄")]
            resolvedVillageStatus = .empty
            resolvedVillageError = nil
            resolvedVillageRecoveryData = nil
            shouldPersistInitialVillages = true
            canInitializeDerivedStores = true
        case .loaded(let villages):
            initialVillages = villages
            resolvedVillageStatus = .available
            resolvedVillageError = nil
            resolvedVillageRecoveryData = nil
            canInitializeDerivedStores = true
        case .corrupt(let rawData, let message):
            initialVillages = [VillageProfile(name: "需要恢复的村庄")]
            resolvedVillageStatus = .corrupt
            resolvedVillageError = "村庄数据无法解码，原始 bytes 已保留。\n" + message
            resolvedVillageRecoveryData = rawData
        case .unsupportedSchema(let rawData, let schemaVersion):
            initialVillages = [VillageProfile(name: "需要升级的村庄数据")]
            resolvedVillageStatus = .unsupported
            resolvedVillageError = "检测到未来村庄存储版本 \(schemaVersion)，当前版本不会覆盖它。"
            resolvedVillageRecoveryData = rawData
        }

        if let startupError {
            resolvedVillageStatus = .readOnly
            resolvedVillageError = startupError
            resolvedVillageRecoveryData = persistedVillageData
            initialVillages = [VillageProfile(name: "需要完成存储恢复")]
            shouldPersistInitialVillages = false
            canInitializeDerivedStores = false
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
        pendingReconciliationPreview = nil
        accountImportError = nil
        snapshotHistoryError = startupError
        manualTrackerError = manualStartupError
        importText = initialVillages[0].accountSnapshot?.originalText ?? ""
        officialRefreshSummary = nil
        villageStoreStatus = resolvedVillageStatus
        villageStoreError = resolvedVillageError
        villageStoreRecoveryNotice = nil
        villageStoreRecoveryData = resolvedVillageRecoveryData
        if villageStoreStatus.isRecoveryRequired,
           let journalNotice = pendingTransactionJournalNotice() {
            villageStoreError = [villageStoreError, journalNotice]
                .compactMap { $0 }
                .joined(separator: "\n")
        }

        if shouldPersistInitialVillages, startupError == nil {
            do {
                try persistVillages(initialVillages)
            } catch {
                startupError = Self.localizedPersistenceError(error)
                snapshotHistoryError = startupError
                villageStoreStatus = .writeFailed
                villageStoreError = startupError
                canInitializeDerivedStores = false
            }
        }

        if !canInitializeDerivedStores {
            manualTrackerStatus = .unavailable
            manualTrackerError = manualStartupError
                ?? villageStoreError
                ?? "村庄基础存储尚未恢复，手动升级状态不会被初始化。"
        } else if let manualStartupError {
            manualTrackerStatus = .unavailable
            manualTrackerError = manualStartupError
        } else {
            loadManualTracker(for: initialVillages.map(\.id), now: Date())
        }

        if canInitializeDerivedStores, startupError == nil {
            do {
                historyEnvelope = try historyService.loadOrMigrate(
                    villages: initialVillages,
                    now: Date(),
                    catalog: gameCatalog,
                    craftTableCatalog: craftTableCatalog,
                    sectionProofs: Self.coverageProofs(for: initialVillages)
                )
                snapshotHistoryError = nil
                historyLoadFailure = nil
            } catch {
                snapshotHistoryError = Self.localizedPersistenceError(error)
                historyLoadFailure = Self.snapshotHistoryAvailability(for: error)
            }
        } else if snapshotHistoryError == nil {
            snapshotHistoryError = villageStoreError
        }
        // The manual store is loaded before the history store so startup can
        // recover both independently.  Rebuild the UI-facing projection now
        // that the current snapshot's active lineage is known.
        refreshManualTrackerProjection()
        // 自动结算需要当前快照基线（Issue #170 gate）：history 已加载，
        // 只结算基线一致的村庄，未对账村庄保持原状。
        _ = settleManualUpgrades(at: Date())
    }

    /// Returns the persisted local tracker core for an explicit village.
    /// Snapshot data remains separate and is never used as a fallback here.
    /// UI consumers use `manualUpgradeCores`, which is a projection-safe view
    /// and may intentionally expose an unreconciled state as `unknown`.
    public func manualUpgradeCore(for villageID: UUID) -> ManualUpgradeCore? {
        manualTrackerEnvelope?.state(for: villageID)?.core
    }

    /// Applies one manual-tracker command to a single village and persists the
    /// candidate envelope only after the core accepts it.  The closure is the
    /// narrow command seam for the tracker UI; it cannot accidentally route by
    /// the currently selected village.
    public func updateManualUpgradeCore(
        for villageID: UUID,
        at now: Date = Date(),
        _ update: (inout ManualUpgradeCore) throws -> Void
    ) throws {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualTrackerStoreError.unavailable("目标村庄不存在。")
        }
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualTrackerStoreError.unavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualTrackerStoreError.invalidEnvelope("更新时间无效。")
        }

        var core: ManualUpgradeCore
        if let storedCore = currentEnvelope.state(for: villageID)?.core {
            core = storedCore
        } else {
            core = try ManualUpgradeCore()
        }
        let previousCore = core
        try update(&core)
        guard core != previousCore else { return }

        let previousState = currentEnvelope.state(for: villageID)
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: now,
            lastSettleAt: previousState?.lastSettleAt,
            lastImportAt: previousState?.lastImportAt,
            diagnostics: previousState?.diagnostics ?? [],
            reconciliationHistory: previousState?.reconciliationHistory ?? [],
            queueCapacityConfigs: previousState?.queueCapacityConfigs ?? [],
            queueAssignments: previousState?.queueAssignments ?? []
        )
        var candidate = currentEnvelope
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            markManualTrackerUnavailable(error)
            throw error
        }
        installManualTrackerEnvelope(candidate)
    }

    /// Settles due records using the same absolute-time Core path used by
    /// manual commands.  `remainingSeconds` is intentionally not persisted.
    @discardableResult
    public func settleManualUpgrades(at now: Date = Date()) -> Int {
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired,
              now.timeIntervalSinceReferenceDate.isFinite else {
            return 0
        }

        var candidate = currentEnvelope
        var settledCount = 0
        do {
            for village in villages {
                guard let previousState = currentEnvelope.state(for: village.id) else {
                    continue
                }
                var core = previousState.core
                // Issue #170：未对账村庄跳过自动结算，不修改其 Core、
                // stateUpdatedAt、lastSettleAt 或 record status；其他基线
                // 一致的村庄不受影响。
                guard isBaselineReconciled(for: village.id, core: core) else {
                    continue
                }
                let settled = try core.settleDue(at: now)
                guard core != previousState.core else { continue }

                let state = try ManualTrackerVillageState(
                    villageID: village.id,
                    core: core,
                    stateUpdatedAt: now,
                    lastSettleAt: now,
                    lastImportAt: previousState.lastImportAt,
                    diagnostics: previousState.diagnostics,
                    reconciliationHistory: previousState.reconciliationHistory,
                    queueCapacityConfigs: previousState.queueCapacityConfigs,
                    queueAssignments: previousState.queueAssignments
                )
                try candidate.upsert(state)
                settledCount += settled.count
            }
            guard candidate != currentEnvelope else { return 0 }
            try manualTrackerStore.save(candidate)
        } catch {
            markManualTrackerUnavailable(error)
            return 0
        }

        installManualTrackerEnvelope(candidate)
        return settledCount
    }

    // MARK: - Issue #145 队列容量配置

    /// 设置/更新某个队列类别的本地容量（userConfigured）。
    /// 只影响未来 local manual start 的容量校验，不修改历史 record。
    @discardableResult
    public func setQueueCapacity(
        for villageID: UUID,
        queueKind: LocalQueueKind,
        capacity: Int,
        now: Date = Date()
    ) throws -> LocalQueueCapacityConfig {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualTrackerStoreError.unavailable("目标村庄不存在。")
        }
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualTrackerStoreError.unavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualTrackerStoreError.invalidEnvelope("更新时间无效。")
        }
        let config: LocalQueueCapacityConfig
        do {
            config = try LocalQueueCapacityConfig(
                villageID: villageID,
                queueKind: queueKind,
                capacity: capacity,
                updatedAt: now
            )
        } catch LocalQueueCapacityConfigError.invalidCapacity {
            throw ManualUpgradeCommandError.queueCapacityInvalid
        } catch LocalQueueCapacityConfigError.invalidTimestamp {
            throw ManualUpgradeCommandError.invalidTime
        }

        var candidate = currentEnvelope
        let previousState = candidate.state(for: villageID)
        let core: ManualUpgradeCore
        if let storedCore = previousState?.core {
            core = storedCore
        } else {
            core = try ManualUpgradeCore()
        }
        var configs = previousState?.queueCapacityConfigs
            .filter { $0.queueKind != queueKind } ?? []
        configs.append(config)
        configs.sort { $0.queueKind.rawValue < $1.queueKind.rawValue }
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: now,
            lastSettleAt: previousState?.lastSettleAt,
            lastImportAt: previousState?.lastImportAt,
            diagnostics: previousState?.diagnostics ?? [],
            reconciliationHistory: previousState?.reconciliationHistory ?? [],
            queueCapacityConfigs: configs,
            queueAssignments: previousState?.queueAssignments ?? []
        )
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            markManualTrackerUnavailable(error)
            throw error
        }
        installManualTrackerEnvelope(candidate)
        return config
    }

    /// 清除某个队列类别的本地容量配置（回到未配置状态）。
    public func clearQueueCapacity(
        for villageID: UUID,
        queueKind: LocalQueueKind,
        now: Date = Date()
    ) throws {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualTrackerStoreError.unavailable("目标村庄不存在。")
        }
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualTrackerStoreError.unavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualTrackerStoreError.invalidEnvelope("更新时间无效。")
        }
        guard let previousState = currentEnvelope.state(for: villageID),
              previousState.queueCapacityConfigs.contains(where: {
                  $0.queueKind == queueKind
              }) else { return }

        var candidate = currentEnvelope
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: previousState.core,
            stateUpdatedAt: now,
            lastSettleAt: previousState.lastSettleAt,
            lastImportAt: previousState.lastImportAt,
            diagnostics: previousState.diagnostics,
            reconciliationHistory: previousState.reconciliationHistory,
            queueCapacityConfigs: previousState.queueCapacityConfigs.filter {
                $0.queueKind != queueKind
            },
            queueAssignments: previousState.queueAssignments
        )
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            markManualTrackerUnavailable(error)
            throw error
        }
        installManualTrackerEnvelope(candidate)
    }

    /// Issue #182：以一次事务替换本村庄的容量配置。
    ///
    /// `updates` 中 `.clear` 表示清除该类别配置（回到未配置），`.set` 的
    /// `0` 是合法容量（不允许任何本地 active）。字典未出现的类别保持原
    /// 配置不变——包括未知/未来 `queueKind`，不会被已知类别表单保存静默删除。
    ///
    /// 原子性：先构造并校验全部候选 config，全部合法后才走一次受保护的
    /// 保存路径；任何校验失败都不会改变原有配置、内存状态、`stateUpdatedAt`
    /// 或已持久化字节。保存失败时尚未 install 候选，内存与磁盘保持一致的
    /// 旧状态，因此不标记 unavailable，用户可直接重试。成功时只产生一次
    /// 有效 state 保存。
    @discardableResult
    public func replaceQueueCapacities(
        for villageID: UUID,
        updates: [LocalQueueKind: LocalQueueCapacityUpdate],
        now: Date = Date()
    ) throws -> [LocalQueueCapacityConfig] {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualTrackerStoreError.unavailable("目标村庄不存在。")
        }
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualTrackerStoreError.unavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualTrackerStoreError.invalidEnvelope("更新时间无效。")
        }

        // 先完整构造候选 config：任何非法输入在此抛错，不碰任何状态。
        var replacements: [LocalQueueCapacityConfig] = []
        replacements.reserveCapacity(updates.count)
        for (kind, update) in updates.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard case .set(let capacity) = update else { continue }
            do {
                replacements.append(try LocalQueueCapacityConfig(
                    villageID: villageID,
                    queueKind: kind,
                    capacity: capacity,
                    updatedAt: now
                ))
            } catch LocalQueueCapacityConfigError.invalidCapacity {
                throw ManualUpgradeCommandError.queueCapacityInvalid
            } catch LocalQueueCapacityConfigError.invalidTimestamp {
                throw ManualUpgradeCommandError.invalidTime
            }
        }

        let previousState = currentEnvelope.state(for: villageID)
        let previousConfigs = previousState?.queueCapacityConfigs ?? []
        // 未出现在 updates 的类别（含未知/未来 queueKind）原样保留。
        var configs = previousConfigs.filter { updates[$0.queueKind] == nil }
        configs.append(contentsOf: replacements)
        configs.sort { $0.queueKind.rawValue < $1.queueKind.rawValue }
        guard configs != previousConfigs else { return configs }

        let core: ManualUpgradeCore
        if let storedCore = previousState?.core {
            core = storedCore
        } else {
            core = try ManualUpgradeCore()
        }
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: now,
            lastSettleAt: previousState?.lastSettleAt,
            lastImportAt: previousState?.lastImportAt,
            diagnostics: previousState?.diagnostics ?? [],
            reconciliationHistory: previousState?.reconciliationHistory ?? [],
            queueCapacityConfigs: configs,
            queueAssignments: previousState?.queueAssignments ?? []
        )
        var candidate = currentEnvelope
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            // 与单条命令不同：失败时未 install 候选，内存与磁盘一致（旧状态），
            // 不标记 unavailable，允许用户直接重试本次编辑。
            throw error
        }
        installManualTrackerEnvelope(candidate)
        return configs
    }

    /// 某个村庄×队列类别的本地占用投影（未配置容量时 capacity == nil）。
    /// `at now` 用于排除已到期未 settle 的 active 记录（与 Start 校验同口径）。
    /// Issue #183：占用计入当前 lineage 的 userAssigned overlay。
    /// Issue #192：未对账（`isBaselineReconciled == false`）时不得把旧
    /// baseline 的 overlay/active 当作当前占用——投影返回不可比较状态，
    /// 数字不提供（由 status 区分「已知 0」与「当前未知」）。其中：
    /// - `.unreconciled`：当前 baseline 存在但 stored baseline 未对账（尚未对账）；
    /// - `.unavailable`：当前 baseline 不可确定（history 加载失败/无 active
    ///   lineage/tag 不一致/冲突）或存储不可用，无法投影。
    /// Start 仍使用命令级 `unreconciledSnapshot` gate。
    public func queueOccupancy(
        for villageID: UUID,
        queueKind: LocalQueueKind,
        at now: Date = Date()
    ) -> LocalQueueOccupancy {
        guard let state = manualTrackerEnvelope?.state(for: villageID) else {
            return LocalQueueOccupancy(
                queueKind: queueKind,
                activeManualCount: 0,
                capacity: nil,
                status: .unavailable
            )
        }
        let config = state.queueCapacityConfigs.first { $0.queueKind == queueKind }
        guard isBaselineReconciled(for: villageID, core: state.core) else {
            // review P2：区分「当前 baseline 不可确定」（history 缺失/加载失败、
            // 无 active lineage、tag 不一致、冲突 → .unavailable）与
            // 「stored != current，尚未对账」（.unreconciled）。
            let currentBaseline = currentManualBaselineReference(for: villageID)
            let status: LocalQueueOccupancyStatus = currentBaseline == nil
                ? .unavailable
                : .unreconciled
            return LocalQueueOccupancy(
                queueKind: queueKind,
                activeManualCount: 0,
                confirmedImportedCount: 0,
                capacity: config?.capacity,
                status: status
            )
        }
        let confirmed = capacityConfirmingAssignments(in: state, queueKind: queueKind)
        return LocalQueueOccupancyResolver.occupancy(
            queueKind: queueKind,
            activeRecords: state.core.activeRecords,
            confirmedAssignments: confirmed,
            capacityConfig: config,
            at: now
        )
    }

    /// Issue #188：占用本地容量的已确认映射唯一口径——`userAssigned`、当前
    /// lineage、且对应 itemState 仍具备确认资格（Core 谓词
    /// `isQueueAssignmentConfirmable`）。即使持久化状态被异常写入（如空
    /// distribution 的 userAssigned overlay），也不得占容量；`queueOccupancy`
    /// 与 Start 校验共用此谓词，不在 UI/投影中各自推断 coverage。
    private func capacityConfirmingAssignments(
        in state: ManualTrackerVillageState,
        queueKind: LocalQueueKind
    ) -> [QueueAssignmentDecision] {
        let currentLineage = state.core.baselineReference?.lineageID
        return state.queueAssignments.filter { assignment in
            guard assignment.status == .userAssigned,
                  assignment.queueKind == queueKind,
                  assignment.baselineReference.lineageID == currentLineage else {
                return false
            }
            return state.core.itemStates
                .first { $0.itemKey == assignment.itemKey }?
                .isQueueAssignmentConfirmable == true
        }
    }

    // MARK: - Issue #183 导入观察队列映射

    /// 当前村庄的 queueAssignments 只读查询（按决策时间排序）。
    public func queueAssignments(for villageID: UUID) throws -> [QueueAssignmentDecision] {
        guard let state = manualTrackerEnvelope?.state(for: villageID) else {
            throw ManualTrackerStoreError.unavailable("目标村庄的手动升级状态尚未可用。")
        }
        return state.queueAssignments.sorted { $0.decidedAt < $1.decidedAt }
    }

    /// 用户确认某条导入观察属于本地队列（userConfigured overlay）。
    ///
    /// - 只允许对已导入观察（`ManualItemState.importedObservation != nil`）的
    ///   item 分配；
    /// - 同 itemKey 同 lineage 重复分配 = 更新 queueKind（幂等，不重复创建）；
    /// - 旧 lineage 的历史映射保留，不被覆盖。
    @discardableResult
    public func assignQueueToImportedObservation(
        for villageID: UUID,
        itemKey: TrackerItemKey,
        queueKind: LocalQueueKind,
        now: Date = Date()
    ) throws -> QueueAssignmentDecision {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualTrackerStoreError.unavailable("目标村庄不存在。")
        }
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualTrackerStoreError.unavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualTrackerStoreError.invalidEnvelope("更新时间无效。")
        }
        guard let previousState = currentEnvelope.state(for: villageID) else {
            throw ManualTrackerStoreError.unavailable("目标村庄的手动升级状态尚未可用。")
        }
        guard previousState.core.itemStates.contains(where: {
            $0.itemKey == itemKey && $0.importedObservation != nil
        }) else {
            throw ManualUpgradeCommandError.itemNotImportedObservation
        }
        guard let observed = previousState.core.itemStates.first(where: {
            $0.itemKey == itemKey
        })?.importedObservation, observed.observedTimer else {
            // review P1：没有进行中计时证据的导入观察不得确认映射，
            // 否则已结束或证据不足的条目会错误占用容量、阻塞 Start。
            throw ManualUpgradeCommandError.importedObservationWithoutTimer
        }
        guard observed.hasCompleteCoverage else {
            // Issue #188 review P1：只有 timer 但等级/数量覆盖不完整的导入
            // 观察不得确认映射。`hasCompleteCoverage` 是 Core 统一资格谓词：
            // 对账只在 coverage 完整时产出非空 distribution，nil 或空
            // distribution 都视为覆盖不足（空 distribution 是合法模型值，
            // 持久化状态可能被异常写入）。确认后会错误占用本地容量、阻塞
            // Start。fail-closed，旧数据缺省 `observedTimer == false` 同样
            // 不可确认。
            throw ManualUpgradeCommandError.importedObservationIncompleteCoverage
        }
        // Issue #189 review P1：与 start/cancel/adjust 同口径，必须当前
        // baseline 已对账才能写入映射——否则会把 userAssigned 绑定到过期
        // lineage 的 baselineReference，投影时被当作旧 lineage 处理。
        guard isBaselineReconciled(for: villageID, core: previousState.core),
              let coreBaseline = previousState.core.baselineReference else {
            throw ManualUpgradeCommandError.unreconciledSnapshot
        }
        var assignments = previousState.queueAssignments.filter {
            !($0.itemKey == itemKey
                && $0.baselineReference.lineageID == coreBaseline.lineageID)
        }
        let decision = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: itemKey,
            baselineReference: coreBaseline,
            queueKind: queueKind,
            decidedAt: now
        )
        assignments.append(decision)
        assignments.sort { $0.decidedAt < $1.decidedAt }

        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: previousState.core,
            stateUpdatedAt: now,
            lastSettleAt: previousState.lastSettleAt,
            lastImportAt: previousState.lastImportAt,
            diagnostics: previousState.diagnostics,
            reconciliationHistory: previousState.reconciliationHistory,
            queueCapacityConfigs: previousState.queueCapacityConfigs,
            queueAssignments: assignments
        )
        var candidate = currentEnvelope
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            // review P2：保存失败不标记 unavailable，保留内存旧状态可重试
            // （与 replaceQueueCapacities 同语义）。
            throw error
        }
        installManualTrackerEnvelope(candidate)
        return decision
    }

    /// 用户解除某条导入观察的本地队列映射（只删除当前 lineage 的 overlay，
    /// 旧 lineage 的历史证据保留为 `unknown`）。timer 消失本身不会触发本
    /// 命令；本命令只由用户显式发起。
    public func unassignQueueFromImportedObservation(
        for villageID: UUID,
        itemKey: TrackerItemKey,
        now: Date = Date()
    ) throws {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualTrackerStoreError.unavailable("目标村庄不存在。")
        }
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualTrackerStoreError.unavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard let previousState = currentEnvelope.state(for: villageID) else { return }
        let currentLineage = previousState.core.baselineReference?.lineageID
        let remaining = previousState.queueAssignments.filter {
            !($0.itemKey == itemKey
                && $0.baselineReference.lineageID == currentLineage)
        }
        guard remaining.count != previousState.queueAssignments.count else { return }

        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: previousState.core,
            stateUpdatedAt: now,
            lastSettleAt: previousState.lastSettleAt,
            lastImportAt: previousState.lastImportAt,
            diagnostics: previousState.diagnostics,
            reconciliationHistory: previousState.reconciliationHistory,
            queueCapacityConfigs: previousState.queueCapacityConfigs,
            queueAssignments: remaining
        )
        var candidate = currentEnvelope
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            // review P2：保存失败不标记 unavailable，保留内存旧状态可重试
            // （与 replaceQueueCapacities 同语义）。
            throw error
        }
        installManualTrackerEnvelope(candidate)
    }

    /// Issue #183：村庄全部导入观察的分配候选（含显示名与当前状态）。
    /// 供 UI 分配面板使用；未找到目录显示名时回退稳定 ID。
    /// review P1：`hasTimer` 使用导入观察的 `observedTimer` 证据，
    /// 不是 sourceTimestamp（快照来源时间 ≠ 计时证据）。
    /// Issue #189：`isConfirmable`/`unconfirmableReason` 是 UI 显示资格的
    /// 唯一投影——直接基于 Core 谓词，UI 不得自行推断 coverage。
    /// Issue #189 review P1/P3：未对账（core baseline ≠ 当前快照 lineage）
    /// 时不提供任何确认资格（fail-closed，与 assign 命令 gate 同口径），
    /// 但候选项与历史 overlay 证据仍然可见并给出原因，满足验收
    /// 「baseline 未对账显示原因、unknown/旧 lineage 历史仍可见」。
    public func queueAssignmentCandidates(
        for villageID: UUID
    ) -> [ImportedObservationCandidate] {
        guard let state = manualTrackerEnvelope?.state(for: villageID) else { return [] }
        let isReconciled = isBaselineReconciled(for: villageID, core: state.core)
        let catalog = gameCatalog
        let currentLineage = state.core.baselineReference?.lineageID
        return state.core.itemStates
            .filter { $0.importedObservation != nil }
            .map { itemState in
                let name = catalog?.item(
                    section: itemState.itemKey.rawSection,
                    dataID: itemState.itemKey.dataID
                )?.name ?? itemState.itemKey.stableID
                let assignment = state.queueAssignments.first {
                    $0.itemKey == itemState.itemKey
                        && $0.baselineReference.lineageID == currentLineage
                }
                // review P2：旧 lineage 的历史映射也一并返回，UI 可见，
                // 不作为当前占用，但保留审计证据。
                let historicalAssignments = state.queueAssignments.filter {
                    $0.itemKey == itemState.itemKey
                        && $0.baselineReference.lineageID != currentLineage
                }
                // Issue #189：资格唯一来源是 Core 谓词（timer + 覆盖完整），
                // 未对账时强制不可确认（与命令 gate 同口径）；原因细分供
                // UI 展示，与命令拒绝路径的语义保持一致
                // （unreconciledSnapshot / importedObservationWithoutTimer /
                // incompleteCoverage）。
                let evidenceConfirmable = itemState.isQueueAssignmentConfirmable
                let isConfirmable = isReconciled && evidenceConfirmable
                let unconfirmableReason: String?
                if !isReconciled {
                    unconfirmableReason = "快照尚未对账，暂不能确认"
                } else if evidenceConfirmable {
                    unconfirmableReason = nil
                } else if itemState.importedObservation?.observedTimer != true {
                    unconfirmableReason = "没有进行中计时证据"
                } else {
                    unconfirmableReason = "观察证据不完整，暂不能确认"
                }
                return ImportedObservationCandidate(
                    itemKey: itemState.itemKey,
                    displayName: name,
                    hasTimer: itemState.importedObservation?.observedTimer ?? false,
                    assignment: assignment,
                    historicalAssignments: historicalAssignments,
                    isConfirmable: isConfirmable,
                    unconfirmableReason: unconfirmableReason
                )
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    // MARK: - Issue #144 类型化手动升级命令

    /// 启动一次本地手动升级（Issue #144）。
    ///
    /// 执行前必须重新验证（不信任 UI 旧 action）：
    /// 显式 villageID 存在、存储可用、基于当前快照/目录/存储 core 重建投影后
    /// action 仍可启动，且 itemKey/from/target/quantity/baseline/duration 与
    /// 传入 action 一致。unknown cost 不阻塞（成本只是本地记录事实）。
    @discardableResult
    public func startManualUpgrade(
        for villageID: UUID,
        action: UpgradeAction,
        startedAt: Date,
        queueKind: LocalQueueKind? = nil,
        now: Date = Date()
    ) throws -> ManualUpgradeRecord {
        guard let village = villages.first(where: { $0.id == villageID }) else {
            throw ManualUpgradeCommandError.villageMissing
        }
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualUpgradeCommandError.storeUnavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              startedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualUpgradeCommandError.invalidTime
        }

        let core = try (currentEnvelope.state(for: villageID)?.core ?? ManualUpgradeCore())
        // Issue #170：未对账（当前快照/lineage 基线 ≠ 存储 core 基线）时拒绝
        // 旧 baseline action，不落盘任何新 record。
        guard isBaselineReconciled(for: villageID, core: core) else {
            throw ManualUpgradeCommandError.unreconciledSnapshot
        }
        // Issue #145：容量校验只约束 future local manual start。
        // 未配置容量或 queueKind == nil（不归类）时不校验；
        // 未确认的 imported timer 从不计入本地占用；
        // Issue #183：用户确认（userAssigned 且当前 lineage）的 overlay 计入。
        if let queueKind {
            let state = currentEnvelope.state(for: villageID)
            let capacityConfigs = state?.queueCapacityConfigs ?? []
            if let config = capacityConfigs.first(where: { $0.queueKind == queueKind }) {
                let confirmed = state.map {
                    capacityConfirmingAssignments(in: $0, queueKind: queueKind)
                } ?? []
                let occupancy = LocalQueueOccupancyResolver.occupancy(
                    queueKind: queueKind,
                    activeRecords: core.activeRecords,
                    confirmedAssignments: confirmed,
                    capacityConfig: config,
                    at: now
                )
                guard !occupancy.isFull else {
                    throw ManualUpgradeCommandError.queueCapacityFull(
                        queueKind: queueKind,
                        activeCount: occupancy.activeManualCount,
                        confirmedImportedCount: occupancy.confirmedImportedCount,
                        capacity: config.capacity
                    )
                }
            }
        }
        let freshAction = try revalidatedAction(
            for: action,
            village: village,
            core: core,
            now: now
        )
        guard let fromLevel = freshAction.fromLevel,
              let targetLevel = freshAction.targetLevel,
              let baseline = freshAction.baselineReference,
              let provenance = freshAction.catalogProvenance else {
            throw ManualUpgradeCommandError.staleAction
        }

        var created: ManualUpgradeRecord?
        do {
            try updateManualUpgradeCore(for: villageID, at: now) { core in
                created = try core.startUpgrade(
                    itemKey: freshAction.itemKey,
                    fromLevel: fromLevel,
                    targetLevel: targetLevel,
                    quantity: freshAction.quantity,
                    startedAt: startedAt,
                    durationState: freshAction.durationState,
                    frozenCosts: freshAction.frozenCosts,
                    catalogProvenance: provenance,
                    baselineReference: baseline,
                    queueKind: queueKind?.rawValue,
                    now: now
                )
            }
        } catch let error as ManualUpgradeError {
            if case .futureStart = error {
                throw ManualUpgradeCommandError.invalidTime
            }
            throw ManualUpgradeCommandError.coreRejected(Self.manualUpgradeErrorMessage(error))
        }
        guard let created else {
            throw ManualUpgradeCommandError.coreRejected("启动命令未产生记录。")
        }
        return created
    }

    /// 取消一条进行中的手动升级记录（Issue #144）。
    @discardableResult
    public func cancelManualUpgrade(
        for villageID: UUID,
        recordID: UUID
    ) throws -> ManualUpgradeRecord {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualUpgradeCommandError.villageMissing
        }
        guard manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualUpgradeCommandError.storeUnavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        // Issue #170：未对账村庄的旧 record 不得被取消或改写。
        if let storedCore = manualTrackerEnvelope?.state(for: villageID)?.core,
           !isBaselineReconciled(for: villageID, core: storedCore) {
            throw ManualUpgradeCommandError.unreconciledSnapshot
        }
        var cancelled: ManualUpgradeRecord?
        do {
            try updateManualUpgradeCore(for: villageID) { core in
                cancelled = try core.cancelUpgrade(recordID: recordID)
            }
        } catch let error as ManualUpgradeError {
            switch error {
            case .recordNotFound:
                throw ManualUpgradeCommandError.recordNotFound(recordID)
            case .recordNotActive, .cannotCancelCompleted:
                throw ManualUpgradeCommandError.recordNotActive(recordID)
            default:
                throw ManualUpgradeCommandError.coreRejected(Self.manualUpgradeErrorMessage(error))
            }
        }
        guard let cancelled else {
            throw ManualUpgradeCommandError.coreRejected("取消命令未产生记录。")
        }
        return cancelled
    }

    /// 调整进行中的手动升级开始时间（Issue #144）。
    ///
    /// 调整后由 Core 重算 expectedEndAt；已到期立即经同一 settle 路径完成。
    @discardableResult
    public func adjustManualUpgradeStart(
        for villageID: UUID,
        recordID: UUID,
        startedAt: Date,
        now: Date = Date()
    ) throws -> ManualUpgradeRecord {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualUpgradeCommandError.villageMissing
        }
        guard manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualUpgradeCommandError.storeUnavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              startedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualUpgradeCommandError.invalidTime
        }
        // Issue #170：未对账村庄的旧 record 不得通过调整时间绕过基线校验。
        if let storedCore = manualTrackerEnvelope?.state(for: villageID)?.core,
           !isBaselineReconciled(for: villageID, core: storedCore) {
            throw ManualUpgradeCommandError.unreconciledSnapshot
        }
        var adjusted: ManualUpgradeRecord?
        do {
            try updateManualUpgradeCore(for: villageID, at: now) { core in
                adjusted = try core.adjustStartTime(
                    recordID: recordID,
                    startedAt: startedAt,
                    now: now
                )
            }
        } catch let error as ManualUpgradeError {
            switch error {
            case .futureStart:
                throw ManualUpgradeCommandError.invalidTime
            case .recordNotFound:
                throw ManualUpgradeCommandError.recordNotFound(recordID)
            case .recordNotActive:
                throw ManualUpgradeCommandError.recordNotActive(recordID)
            default:
                throw ManualUpgradeCommandError.coreRejected(Self.manualUpgradeErrorMessage(error))
            }
        }
        guard let adjusted else {
            throw ManualUpgradeCommandError.coreRejected("调整命令未产生记录。")
        }
        return adjusted
    }

    /// 基于当前快照/目录/存储 core 重建 action 并与传入 action 比对。
    /// 任一不一致或不可启动 → staleAction。
    ///
    /// 按 `action.sourceKind` 选择投影路径（review P1-2）：
    /// - `.row`：普通行投影——`.manualActive` 行不产生 Start（由 Cancel/Adjust
    ///   承接），剩余数量不可再启动。
    /// - `.group`：组聚合投影——`.manualActive` 下仍可为剩余数量生成 action
    ///   （v1 每次启动一个实例），且保留混合等级的 fromLevel。
    private func revalidatedAction(
        for action: UpgradeAction,
        village: VillageProfile,
        core: ManualUpgradeCore,
        now: Date
    ) throws -> UpgradeAction {
        switch action.sourceKind {
        case .row:
            return try revalidatedRowAction(
                for: action, village: village, core: core, now: now
            )
        case .group:
            return try revalidatedGroupAction(
                for: action, village: village, core: core, now: now
            )
        }
    }

    private func revalidatedRowAction(
        for action: UpgradeAction,
        village: VillageProfile,
        core: ManualUpgradeCore,
        now: Date
    ) throws -> UpgradeAction {
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: gameCatalog,
            seasonalPhases: seasonalPhases,
            craftTableCatalog: craftTableCatalog,
            base: action.base,
            now: now,
            manualUpgradeCore: core
        )
        guard let item = trackerItem(for: action.itemKey, in: projection) else {
            throw ManualUpgradeCommandError.staleAction
        }
        guard let fresh = UpgradeActionProjection.action(
            for: item,
            catalog: gameCatalog,
            catalogIsUsable: projection.catalogIsUsable,
            manualUpgradeCore: core,
            coverage: UpgradeActionProjection.coverage(
                for: item,
                progressCoverage: projection.progressCoverage
            ),
            now: now
        ), fresh.isStartable else {
            throw ManualUpgradeCommandError.staleAction
        }
        guard fresh.itemKey == action.itemKey,
              fresh.fromLevel == action.fromLevel,
              fresh.targetLevel == action.targetLevel,
              fresh.quantity == action.quantity,
              fresh.baselineReference == action.baselineReference,
              fresh.durationState == action.durationState else {
            throw ManualUpgradeCommandError.staleAction
        }
        return fresh
    }

    /// 组聚合 action 复核：重建组投影，按 fromLevel/targetLevel 定位同名 action。
    /// 组在 `.manualActive` 下仍可为剩余数量生成 action（不 stale），混合等级
    /// 组的 fromLevel 不被普通行投影抹平。
    private func revalidatedGroupAction(
        for action: UpgradeAction,
        village: VillageProfile,
        core: ManualUpgradeCore,
        now: Date
    ) throws -> UpgradeAction {
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: gameCatalog,
            seasonalPhases: seasonalPhases,
            craftTableCatalog: craftTableCatalog,
            base: action.base,
            now: now,
            manualUpgradeCore: core
        )
        let groups = BuildingGroupProjection.project(
            projection: projection,
            catalog: gameCatalog,
            base: action.base,
            manualUpgradeCore: core
        )
        guard let group = groups.first(where: { $0.trackerState.itemKey == action.itemKey }) else {
            throw ManualUpgradeCommandError.staleAction
        }
        let freshActions = UpgradeActionProjection.actions(for: group, catalog: gameCatalog)
        guard let fresh = freshActions.first(where: {
            $0.fromLevel == action.fromLevel && $0.targetLevel == action.targetLevel
        }), fresh.isStartable else {
            throw ManualUpgradeCommandError.staleAction
        }
        guard fresh.itemKey == action.itemKey,
              fresh.fromLevel == action.fromLevel,
              fresh.targetLevel == action.targetLevel,
              fresh.quantity == action.quantity,
              fresh.baselineReference == action.baselineReference,
              fresh.durationState == action.durationState else {
            throw ManualUpgradeCommandError.staleAction
        }
        return fresh
    }

    private func trackerItem(
        for itemKey: TrackerItemKey,
        in projection: VillageCatalogProjection
    ) -> VillageItemState? {
        projection.items.first { $0.effectiveState?.itemKey == itemKey }
            ?? projection.items.first {
                TrackerItemKey.root(base: $0.base, rawSection: $0.section, dataID: $0.dataID)
                    == itemKey
            }
    }

    private static func manualUpgradeErrorMessage(_ error: ManualUpgradeError) -> String {
        switch error {
        case .invalidItemKey:
            "项目身份无效。"
        case .invalidBaselineReference:
            "基线引用无效。"
        case .invalidCatalogProvenance:
            "目录来源无效。"
        case .invalidLevel:
            "等级无效。"
        case .invalidQuantity:
            "数量无效。"
        case .arithmeticOverflow:
            "数值溢出。"
        case .missingItemState:
            "缺少项目状态。"
        case .unavailableItemState:
            "项目状态不可用。"
        case .conflictingItemState:
            "项目状态冲突。"
        case .baselineMismatch:
            "基线不匹配。"
        case .insufficientQuantity:
            "可用数量不足。"
        case .futureStart:
            "不允许未来开始时间。"
        case .invalidDuration:
            "升级时长无效。"
        case .durationUnavailable:
            "升级时长不可用。"
        case .duplicateRecordID:
            "记录 ID 重复。"
        case .recordNotFound:
            "记录不存在。"
        case .recordNotActive:
            "记录不在进行中。"
        case .cannotCancelCompleted:
            "已完成记录不可取消。"
        case .invalidRecord:
            "记录内容无效。"
        }
    }

    public var currentVillageName: String {
        villages.first(where: { $0.id == selectedVillageID })?.name ?? VillageProfile.placeholderName
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

    /// Read-only history projection for Village Detail.  Diff construction is
    /// cached per village and local calendar day, while category changes only
    /// filter the immutable rows.  This prevents the surrounding 60-second
    /// `TimelineView` from rebuilding every historical diff on each tick.
    public func snapshotHistoryProjection(
        for villageID: UUID,
        category: SnapshotHistoryCategory = .all,
        at referenceDate: Date = Date(),
        calendar inputCalendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> SnapshotHistoryProjection {
        let hasCurrentSnapshot = villages.first(where: { $0.id == villageID })?.accountSnapshot != nil
        if let historyLoadFailure {
            return SnapshotHistoryProjection.unavailable(
                villageID: villageID,
                hasCurrentSnapshot: hasCurrentSnapshot,
                availability: historyLoadFailure,
                selectedCategory: category,
                referenceDate: referenceDate,
                calendar: inputCalendar,
                timeZone: timeZone
            )
        }
        guard let historyEnvelope else {
            return SnapshotHistoryProjection.unavailable(
                villageID: villageID,
                hasCurrentSnapshot: hasCurrentSnapshot,
                availability: .unavailable(snapshotHistoryError ?? "历史尚未完成加载。"),
                selectedCategory: category,
                referenceDate: referenceDate,
                calendar: inputCalendar,
                timeZone: timeZone
            )
        }

        var calendar = inputCalendar
        calendar.timeZone = timeZone
        let cacheKey = SnapshotHistoryProjectionCacheKey(
            villageID: villageID,
            startOfDay: calendar.startOfDay(for: referenceDate),
            timeZoneIdentifier: timeZone.identifier,
            hasCurrentSnapshot: hasCurrentSnapshot
        )
        let baseProjection: SnapshotHistoryProjection
        if let cached = historyProjectionCache[cacheKey] {
            baseProjection = cached
        } else {
            let projection = SnapshotHistoryProjection.project(
                envelope: historyEnvelope,
                villageID: villageID,
                hasCurrentSnapshot: hasCurrentSnapshot,
                selectedCategory: .all,
                referenceDate: referenceDate,
                calendar: calendar,
                timeZone: timeZone
            )
            historyProjectionCache = historyProjectionCache.filter { $0.key.villageID != villageID }
            historyProjectionCache[cacheKey] = projection
            baseProjection = projection
        }
        return baseProjection.applying(category: category)
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

    /// 指定部落 tag 的突袭周末状态（分页）。
    public func capitalState(for clanTag: String) -> ClanCapitalAPIState? {
        clanCapitalStates[clanTag]
    }

    /// 部落档案已知战争日志不公开（无档案/未知 → false）。
    public func isWarLogKnownNotPublic(for clanTag: String) -> Bool {
        clanState(for: clanTag)?.lastGood?.isWarLogPublic == false
    }

    /// 指定部落的战争日志是否还有更多页（分页按钮可用性）。
    /// 成功或失败（保留 last-good 的加载更多失败）且有游标 → 可继续翻页/重试
    /// （Issue #124：加载更多失败时按钮仍可用于重试，不得误显"没有更多"）。
    public func warLogHasMore(for clanTag: String) -> Bool {
        guard let state = warLogState(for: clanTag),
              state.status == .success || state.status == .failed,
              let cursor = state.lastGood?.after else { return false }
        return PaginationLogic.hasMore(requestedCursor: nil, responseAfter: cursor)
    }

    /// 指定部落的突袭周末是否还有更多页。
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

    /// 指定部落的突袭周末刷新/翻页是否在途（clanTag 为 nil 时返回 false）。
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

    public var isVillageStoreRecoveryRequired: Bool {
        villageStoreStatus.isRecoveryRequired
    }

    /// A pending transaction journal is intentionally surfaced separately
    /// from the villages blob.  When the blob is corrupt, startup must not
    /// replay a journal implicitly because that would write derived state
    /// before the user chooses which source to trust.
    public var hasPendingVillageTransactionJournal: Bool {
        activeTransactionJournalURLs().contains { entry in
            FileManager.default.fileExists(atPath: entry.url.path)
                || FileManager.default.fileExists(
                    atPath: quarantinedTransactionJournalURL(for: entry.url).path
                )
        }
    }

    /// A read-only copy for recovery/export UI.  Callers cannot mutate the
    /// in-memory bytes held by AppModel.
    public var villageStoreRecoveryDataForExport: Data? {
        villageStoreRecoveryData
    }

    /// Replays valid pending transaction journals only after the user has
    /// explicitly chosen this action in the recovery UI.  Prepared journals
    /// roll back and committed journals roll forward using the same
    /// coordinator rules as normal startup recovery.
    @discardableResult
    public func recoverVillageStoreFromTransactionJournal() -> Bool {
        guard villageStoreStatus.isRecoveryRequired else {
            villageStoreRecoveryNotice = "当前村庄数据无需从事务记录恢复。"
            return false
        }
        guard hasPendingVillageTransactionJournal else {
            villageStoreRecoveryNotice = "没有找到待处理的事务 journal。"
            return false
        }

        if let villageStoreRecoveryData {
            defaults.set(villageStoreRecoveryData, forKey: villageStoreRecoveryKey)
        }

        do {
            try recoverTransactionJournal(.snapshotImport)
            try recoverTransactionJournal(.manualTracker)

            let recoveredData = currentVillagePersistence.readData()
            let recoveredVillages: [VillageProfile]
            switch VillageStoreCodec.load(recoveredData) {
            case .missing:
                recoveredVillages = [VillageProfile(name: "我的村庄")]
                try persistVillages(recoveredVillages, bypassRecoveryGate: true)
            case .loaded(let villages) where villages.isEmpty:
                recoveredVillages = [VillageProfile(name: "我的村庄")]
                try persistVillages(recoveredVillages, bypassRecoveryGate: true)
            case .loaded(let villages):
                recoveredVillages = villages
            case .corrupt(let rawData, let message):
                villageStoreRecoveryData = rawData
                villageStoreStatus = .corrupt
                villageStoreError = "事务记录恢复后当前村庄数据仍无法解码：\n" + message
                return false
            case .unsupportedSchema(let rawData, let schemaVersion):
                villageStoreRecoveryData = rawData
                villageStoreStatus = .unsupported
                villageStoreError = "事务记录恢复后检测到未来村庄存储版本 \(schemaVersion)。"
                return false
            }

            installRestoredVillageState(recoveredVillages)
            villageStoreRecoveryNotice = "事务 journal 已恢复；prepared 已回滚，committed 已重放。"
            return true
        } catch {
            villageStoreStatus = .readOnly
            villageStoreError = Self.localizedPersistenceError(error)
            snapshotHistoryError = villageStoreError
            villageStoreRecoveryData = currentVillagePersistence.readData()
            villageStoreRecoveryNotice = "事务 journal 恢复失败；原始数据和未处理 journal 仍保留。"
            return false
        }
    }

    /// Opens a save panel and exports the exact bytes that caused recovery.
    /// The operation is deliberately user-triggered and never rewrites the
    /// villages key.
    public func exportVillageStoreData() {
        guard let data = villageStoreRecoveryData else {
            villageStoreRecoveryNotice = "当前没有可导出的村庄原始数据。"
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "coc-helper.villages.v1.recovery.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            villageStoreRecoveryNotice = "原始村庄数据已导出。"
        } catch {
            villageStoreRecoveryNotice = "导出失败：" + error.localizedDescription
        }
    }

    /// Opens a user-selected recovery copy and restores it only when the
    /// complete villages blob validates.  Invalid input never replaces the
    /// existing corrupt bytes.
    @discardableResult
    public func restoreVillageStoreFromFile() -> Bool {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            return restoreVillageStore(from: try Data(contentsOf: url))
        } catch {
            villageStoreRecoveryNotice = "读取恢复文件失败：" + error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func restoreVillageStoreFromSavedRecoveryCopy() -> Bool {
        guard let data = defaults.data(forKey: villageStoreRecoveryKey) else {
            villageStoreRecoveryNotice = "没有找到保存的村庄恢复副本。"
            return false
        }
        return restoreVillageStore(from: data)
    }

    /// Testable/core recovery seam.  The UI calls this through the file-panel
    /// wrapper; malformed or future data is rejected before any write.
    @discardableResult
    public func restoreVillageStore(from rawData: Data) -> Bool {
        let loaded: [VillageProfile]
        let preservesRawData: Bool
        switch VillageStoreCodec.load(rawData) {
        case .loaded(let villages):
            preservesRawData = !villages.isEmpty
            loaded = villages.isEmpty ? [VillageProfile(name: "我的村庄")] : villages
        case .corrupt(_, let message):
            villageStoreRecoveryNotice = "恢复文件损坏，未写入当前数据：" + message
            return false
        case .unsupportedSchema(_, let version):
            villageStoreRecoveryNotice = "恢复文件版本不受支持（\(version)），未写入当前数据。"
            return false
        case .missing:
            villageStoreRecoveryNotice = "恢复文件为空，未写入当前数据。"
            return false
        }

        do {
            if let villageStoreRecoveryData {
                defaults.set(villageStoreRecoveryData, forKey: villageStoreRecoveryKey)
            }
            try quarantinePendingTransactionJournals()
            if preservesRawData {
                try writeVillageStoreData(
                    rawData,
                    candidateVillages: loaded,
                    bypassRecoveryGate: true
                )
            } else {
                try persistVillages(loaded, bypassRecoveryGate: true)
            }
            installRestoredVillageState(loaded)
            villageStoreRecoveryNotice = "村庄数据已恢复，原始恢复副本仍保留。"
            return true
        } catch {
            villageStoreRecoveryNotice = "恢复写入失败：" + Self.localizedPersistenceError(error)
            return false
        }
    }

    /// Explicit reset entry point.  The caller must provide a confirmation in
    /// the UI before invoking this method; the previous bytes are retained in
    /// a separate recovery key before the new default village is written.
    @discardableResult
    public func resetVillageStore() -> Bool {
        guard villageStoreStatus.isRecoveryRequired else {
            villageStoreRecoveryNotice = "当前村庄数据无需重置。"
            return false
        }
        if let villageStoreRecoveryData {
            defaults.set(villageStoreRecoveryData, forKey: villageStoreRecoveryKey)
        }

        let resetVillages = [VillageProfile(name: "我的村庄")]
        do {
            try quarantinePendingTransactionJournals()
            try persistVillages(resetVillages, bypassRecoveryGate: true)
            installRestoredVillageState(resetVillages)
            villageStoreRecoveryNotice = "村庄数据已重置；旧 bytes 已保存为恢复副本。"
            return true
        } catch {
            villageStoreRecoveryNotice = "重置写入失败：" + Self.localizedPersistenceError(error)
            return false
        }
    }

    public var canDeleteCurrentVillage: Bool {
        villages.count > 1
    }

    public func activeUpgradeCount(
        for village: VillageProfile,
        manualUpgradeCore: ManualUpgradeCore? = nil,
        at now: Date = Date()
    ) -> Int {
        guard village.accountSnapshot != nil else { return 0 }
        let manualUpgradeCores = manualUpgradeCore.map { [village.id: $0] } ?? [:]
        return UpgradeOverviewProjection.activeRecords(
            from: [village],
            catalog: gameCatalog,
            seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores,
            at: now
        ).count
    }

    public func selectVillage(id: UUID) {
        guard id != selectedVillageID,
              let village = villages.first(where: { $0.id == id }) else { return }

        do {
            try persistVillages(villagesForImportPersistence())
        } catch {
            accountImportError = Self.localizedPersistenceError(error)
            return
        }
        load(village)
    }

    public func addVillageForImport() {
        let name = "村庄 " + String(villages.count + 1)
        let village = VillageProfile(name: name)
        var candidateVillages = villagesForImportPersistence()
        candidateVillages.append(village)
        guard var candidateEnvelope = manualTrackerEnvelope else {
            let error = ManualTrackerStoreError.unavailable("手动升级存储不可用，无法创建村庄。")
            markManualTrackerUnavailable(error)
            accountImportError = Self.localizedPersistenceError(error)
            return
        }
        do {
            try candidateEnvelope.upsert(ManualTrackerVillageState.empty(villageID: village.id))
            try commitVillageMutation(
                candidateVillages: candidateVillages,
                envelope: candidateEnvelope
            )
        } catch {
            accountImportError = Self.localizedPersistenceError(error)
            manualTrackerError = Self.localizedPersistenceError(error)
            return
        }

        villages = candidateVillages
        installManualTrackerEnvelope(candidateEnvelope)
        load(village, importText: "")
        importIntoCurrentVillage = true
        accountImportError = nil
    }

    public func renameSelectedVillage(_ name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = villages.firstIndex(where: { $0.id == selectedVillageID }) else { return }

        var candidateVillages = villagesForImportPersistence()
        candidateVillages[index].name = trimmedName
        candidateVillages[index].updatedAt = Date()
        do {
            try persistVillages(candidateVillages)
        } catch {
            accountImportError = Self.localizedPersistenceError(error)
            return
        }
        villages = candidateVillages
        accountImportError = nil
    }

    public func deleteVillage(id: UUID) {
        guard villages.count > 1,
              let index = villages.firstIndex(where: { $0.id == id }) else { return }

        guard var candidateEnvelope = manualTrackerEnvelope else {
            let error = ManualTrackerStoreError.unavailable("手动升级存储不可用，无法删除村庄。")
            markManualTrackerUnavailable(error)
            accountImportError = Self.localizedPersistenceError(error)
            return
        }

        var candidateVillages = villagesForImportPersistence()
        candidateVillages.remove(at: index)
        candidateEnvelope.remove(villageID: id)
        do {
            try commitVillageMutation(
                candidateVillages: candidateVillages,
                envelope: candidateEnvelope
            )
        } catch {
            accountImportError = Self.localizedPersistenceError(error)
            manualTrackerError = Self.localizedPersistenceError(error)
            return
        }

        let isSelected = id == selectedVillageID
        villages = candidateVillages
        installManualTrackerEnvelope(candidateEnvelope)

        if isSelected {
            let nextIndex = min(index, villages.count - 1)
            load(villages[nextIndex])
        }
        accountImportError = nil
    }

    public func pasteFromClipboard() {
        guard let text = clipboardReader(), !text.isEmpty else {
            accountImportError = "系统剪贴板中没有可用的文本。"
            return
        }
        importText = text
        accountImportError = nil
    }

    // MARK: - 快捷快照导入（按显式 villageID，Issue #61）

    /// 跨档案拦截用比较键：trim 后去掉可选 `#` 前缀并统一大写。
    /// 仅用于 prepareQuickImport 的拦截（防御门）；replacesSameTag / apply
    /// 契约仍用 OfficialPlayerTagValidator.normalized 的大小写敏感比较。
    private static func interceptKey(_ tag: String?) -> String? {
        guard let normalized = OfficialPlayerTagValidator.normalized(tag) else { return nil }
        let body = normalized.hasPrefix("#") ? String(normalized.dropFirst()) : normalized
        return body.uppercased()
    }

    /// 为指定村庄准备快捷导入预览：解析剪贴板 JSON 并做路由校验。
    /// **纯函数**：不写任何持久化状态、不改 villages、不改
    /// accountSnapshot / importText / pending 状态（失败与成功路径均无副作用）。
    ///
    /// 路由语义：目标固定为传入 `villageID`（与 JSON 的账号 tag 无关）；
    /// 仅当 JSON tag 规范化后命中**其他**村庄时才拦截（防误覆盖）。
    public func prepareQuickImport(for villageID: UUID) -> Result<QuickImportPreview, QuickImportError> {
        guard let text = clipboardReader(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyClipboard)
        }

        let snapshot: AccountSnapshot
        do {
            snapshot = try AccountSnapshotImporter.parse(text)
        } catch let error as AccountSnapshotImportError {
            return .failure(.parseFailed(error))
        } catch {
            // 防御分支：解析器只抛 AccountSnapshotImportError，此路径不可达。
            return .failure(.parseFailed(.invalidJSON(error.localizedDescription)))
        }

        guard let target = villages.first(where: { $0.id == villageID }) else {
            return .failure(.targetVillageMissing)
        }

        // 规范化后的 JSON tag 命中其他村庄 → 阻止（避免误覆盖另一档案）。
        // 拦截是防御门：比较键忽略大小写与可选 `#` 前缀（normalized 只 trim，
        // `#abc`/`ABC` 这类非 canonical 变体同样必须命中），防止快捷路径把 A
        // 的账号数据写进 B。
        // 注意与下方 replacesSameTag 的判定基准刻意不同：replacesSameTag 保持
        // 大小写敏感，与 VillageProfile.applyImportedSnapshot 的 tagChanged 判定
        // 同基准——否则会出现「预览说同 Tag 更新、实际官方状态被清」的语义矛盾。
        if let snapshotKey = Self.interceptKey(snapshot.tag),
           let other = villages.first(where: {
               $0.id != villageID && Self.interceptKey($0.tag) == snapshotKey
           }) {
            return .failure(.tagBelongsToAnotherVillage(tag: snapshot.tag ?? "", villageName: other.name))
        }

        let normalizedSnapshotTag = OfficialPlayerTagValidator.normalized(snapshot.tag)
        let replacesSameTag = normalizedSnapshotTag != nil
            && normalizedSnapshotTag == OfficialPlayerTagValidator.normalized(target.tag)
        let targetVillageHasSnapshot = target.accountSnapshot != nil

        let description: String
        if !targetVillageHasSnapshot {
            // P2：仅「从未导入快照」才进入建立分支；有快照但无 tag 时
            // targetVillageTag 为 nil，不得误判为首次导入。
            description = "将建立「\(target.name)」的账号快照并导入"
        } else if normalizedSnapshotTag == nil {
            // 无 tag 是独立分支：目标已有快照但 JSON 未带 tag，官方数据因 Tag
            // 缺失被重置（缺失 ≠ 变化，文案必须区分，不得误称「Tag 变化」）。
            description = "导入目标：按当前详情页应用到「\(target.name)」。JSON 未提供账号 Tag，将按当前目标处理，原官方数据将因 Tag 缺失被重置"
        } else if replacesSameTag {
            description = "导入目标：按当前详情页更新「\(target.name)」"
        } else {
            description = "导入目标：按当前详情页应用到「\(target.name)」，原官方数据将因 Tag 变化被重置"
        }

        do {
            let reconciliationPreview = try prepareReconciliationPreview(
                snapshot,
                targetVillage: target,
                appliedAt: Date()
            )
            return .success(QuickImportPreview(
                snapshot: snapshot,
                targetVillageID: target.id,
                targetVillageName: target.name,
                targetVillageTag: target.tag,
                targetVillageHasSnapshot: targetVillageHasSnapshot,
                replacesSameTag: replacesSameTag,
                destinationDescription: description,
                reconciliationPreview: reconciliationPreview
            ))
        } catch {
            // A quick-import confirmation without a reconciliation preview
            // cannot safely reach the fallback pending-snapshot action. Fail
            // closed and keep the model unchanged so the caller can explain
            // that history storage must be repaired first.
            return .failure(.historyUnavailable(Self.localizedPersistenceError(error)))
        }
    }

    /// 应用快捷导入：按 preview 固定的目标村庄写入快照。
    /// 顺序契约：先 `applyImportedSnapshot`（tag 变化清官方数据）→ 构造
    /// 包含当前属性的 candidate → 事务持久化 → 再 `load` 刷新选中状态。
    /// 目标村庄已不存在时 no-op（不崩溃）。
    ///
    /// 隐性不变式：`accountSnapshot` 属性与 selectedVillageID 指向的村庄 entry
    /// 会在 candidate 构造阶段物化，因此任何属性写入点都必须通过对应的
    /// candidate/事务路径持久化，新代码不得绕过该顺序。
    ///
    /// 副作用（load 语义的既有复用，账号数据页全局状态会被重置）：
    /// `pendingAccountSnapshot` / `accountImportError` / `importIntoCurrentVillage`
    /// 被 load 清空，`importText` 替换为导入快照的原文，selectedVillageID 切回
    /// 目标村庄。详情页快捷入口不经过 pending 流程，UI 路径上这些重置不可达；
    /// 但本方法是 public API，调用方（尤其测试与未来调用点）需知晓。
    @discardableResult
    public func applyQuickImport(
        _ preview: QuickImportPreview,
        decision reconciliationDecision: ManualReconciliationDecision = .applyNonConflicting
    ) -> Bool {
        snapshotHistoryError = nil
        guard let index = villages.firstIndex(where: { $0.id == preview.targetVillageID }) else {
            snapshotHistoryError = QuickImportError.targetVillageMissing.errorDescription
            return false
        }

        let appliedAt = Date()
        var candidateVillages = villagesForImportPersistence()
        candidateVillages[index].applyImportedSnapshot(preview.snapshot)
        if candidateVillages[index].name.hasPrefix("村庄 ")
            || candidateVillages[index].name == VillageProfile.placeholderName {
            candidateVillages[index].name = OfficialPlayerTagValidator.normalized(preview.snapshot.tag)
                ?? candidateVillages[index].name
        }
        candidateVillages[index].updatedAt = appliedAt

        do {
            try commitImportedSnapshot(
                preview.snapshot,
                targetVillage: villages[index],
                candidateVillages: candidateVillages,
                appliedAt: appliedAt,
                expectedPreview: preview.reconciliationPreview,
                reconciliationDecision: reconciliationDecision
            )
        } catch {
            snapshotHistoryError = Self.localizedPersistenceError(error)
            return false
        }

        let targetVillage = candidateVillages[index]
        load(targetVillage, importText: preview.snapshot.originalText)
        refreshManualTrackerProjection()
        snapshotHistoryError = nil
        return true
    }

    public func parseAccountText() {
        accountImportError = nil
        pendingAccountSnapshot = nil
        pendingReconciliationPreview = nil

        do {
            let snapshot = try AccountSnapshotImporter.parse(importText)
            pendingAccountSnapshot = snapshot
            switch pendingSnapshotTarget(for: snapshot) {
            case .ambiguous(let tag, let villageNames):
                accountImportError = Self.ambiguousImportTargetMessage(
                    tag: tag,
                    villageNames: villageNames
                )
            case .existing(let index):
                pendingReconciliationPreview = try prepareReconciliationPreview(
                    snapshot,
                    targetVillage: villages[index],
                    appliedAt: Date()
                )
            case .create:
                pendingReconciliationPreview = nil
            }
        } catch {
            accountImportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public var pendingAccountSnapshotActionTitle: String? {
        guard let snapshot = pendingAccountSnapshot else { return nil }

        switch pendingSnapshotTarget(for: snapshot) {
        case .ambiguous:
            return "无法确定导入目标"
        case .existing(let targetIndex):
            let targetName = villages[targetIndex].name
            let action = isReimportingExistingVillage(snapshot, at: targetIndex) ? "更新" : "应用到"
            return action + "「" + targetName + "」"
        case .create:
            break
        }

        let newName = OfficialPlayerTagValidator.normalized(snapshot.tag) ?? "村庄 " + String(villages.count + 1)
        return "创建「" + newName + "」"
    }

    public var pendingAccountSnapshotDestinationDescription: String? {
        guard let snapshot = pendingAccountSnapshot else { return nil }

        switch pendingSnapshotTarget(for: snapshot) {
        case .ambiguous(let tag, let villageNames):
            return Self.ambiguousImportTargetMessage(tag: tag, villageNames: villageNames)
        case .existing(let targetIndex):
            let targetName = villages[targetIndex].name
            if isReimportingExistingVillage(snapshot, at: targetIndex) {
                return "导入目标：按账号 tag 更新「" + targetName + "」"
            }
            return "导入目标：应用到「" + targetName + "」"
        case .create:
            break
        }

        let newName = OfficialPlayerTagValidator.normalized(snapshot.tag) ?? "村庄 " + String(villages.count + 1)
        return "导入目标：没有同 tag 档案，将创建「" + newName + "」"
    }

    @discardableResult
    public func applyPendingAccountSnapshot(
        decision reconciliationDecision: ManualReconciliationDecision = .applyNonConflicting
    ) -> Bool {
        guard let snapshot = pendingAccountSnapshot else { return false }

        let targetIndex: Int
        switch pendingSnapshotTarget(for: snapshot) {
        case .existing(let existingIndex):
            // Re-importing the same account refreshes only its raw snapshot.
            targetIndex = existingIndex
        case .create:
            targetIndex = villages.count
        case .ambiguous(let tag, let villageNames):
            accountImportError = Self.ambiguousImportTargetMessage(
                tag: tag,
                villageNames: villageNames
            )
            return false
        }

        let appliedAt = Date()
        var candidateVillages = villagesForImportPersistence()
        var manualEnvelopeForCreate: ManualTrackerEnvelope?
        if targetIndex == candidateVillages.count {
            let name = OfficialPlayerTagValidator.normalized(snapshot.tag) ?? "村庄 " + String(candidateVillages.count + 1)
            let newVillage = VillageProfile(name: name)
            candidateVillages.append(newVillage)
            guard var candidateEnvelope = manualTrackerEnvelope else {
                accountImportError = ManualTrackerStoreError.unavailable(
                    "手动升级存储不可用，无法创建村庄。"
                ).errorDescription
                return false
            }
            do {
                try candidateEnvelope.upsert(
                    ManualTrackerVillageState.empty(villageID: newVillage.id, now: appliedAt)
                )
            } catch {
                accountImportError = Self.localizedPersistenceError(error)
                return false
            }
            manualEnvelopeForCreate = candidateEnvelope
        }

        // tag 变化时自动重置官方数据（applyImportedSnapshot 内部处理）。
        candidateVillages[targetIndex].applyImportedSnapshot(snapshot)
        if candidateVillages[targetIndex].name.hasPrefix("村庄 ")
            || candidateVillages[targetIndex].name == VillageProfile.placeholderName {
            candidateVillages[targetIndex].name = OfficialPlayerTagValidator.normalized(snapshot.tag)
                ?? candidateVillages[targetIndex].name
        }
        candidateVillages[targetIndex].updatedAt = appliedAt

        let existingTarget = targetIndex < villages.count ? villages[targetIndex] : VillageProfile(
            id: candidateVillages[targetIndex].id,
            name: candidateVillages[targetIndex].name
        )
        do {
            try commitImportedSnapshot(
                snapshot,
                targetVillage: existingTarget,
                candidateVillages: candidateVillages,
                appliedAt: appliedAt,
                manualEnvelope: manualEnvelopeForCreate,
                expectedPreview: pendingReconciliationPreview,
                reconciliationDecision: reconciliationDecision
            )
        } catch {
            accountImportError = Self.localizedPersistenceError(error)
            return false
        }

        let targetVillage = candidateVillages[targetIndex]
        load(targetVillage, importText: snapshot.originalText)
        refreshManualTrackerProjection()
        importIntoCurrentVillage = false
        snapshotHistoryError = nil
        return true
    }

    public func discardPendingAccountSnapshot() {
        pendingAccountSnapshot = nil
        pendingReconciliationPreview = nil
        accountImportError = nil
    }

    public func clearAccountSnapshot() {
        guard let index = villages.firstIndex(where: { $0.id == selectedVillageID }) else { return }
        var candidateVillages = villagesForImportPersistence()
        candidateVillages[index].accountSnapshot = nil
        candidateVillages[index].officialAPIState = nil
        candidateVillages[index].updatedAt = Date()

        do {
            try persistVillages(candidateVillages)
        } catch {
            accountImportError = Self.localizedPersistenceError(error)
            return
        }

        villages = candidateVillages
        accountSnapshot = nil
        pendingAccountSnapshot = nil
        pendingReconciliationPreview = nil
        accountImportError = nil
        importText = ""
        refreshManualTrackerProjection()
    }

    // MARK: - Issue #197 性能样本加载（隐藏 debug seed，确定性重放）

    /// 性能样本 fixture 名（与 Tests/COCHelperCoreTests/Fixtures 同名；
    /// 运行时从 COCHelperApp bundle 的 PerfFixtures/ 读取）。
    public enum PerfSampleFixture {
        public static let home = "perf_account_snapshot_home"
        public static let builder = "perf_account_snapshot_builder"
        public static let mixed = "perf_account_snapshot_mixed"
        public static let variant = "perf_account_snapshot_variant"
        public static let warLogPage1 = "perf_war_log_page_01"
        public static let warLogPage2 = "perf_war_log_page_02"
        public static let warLogPage3 = "perf_war_log_page_03"
        public static let raidPage1 = "perf_capital_raid_page_01"
        public static let raidPage2 = "perf_capital_raid_page_02"
        public static let raidPage3 = "perf_capital_raid_page_03"
        /// 性能样本跟踪部落 tag（匿名，非真实账号；格式须合法：`#` + 大写字母/数字）。
        public static let perfClanTag = "#PERFCLAN"
    }

    /// 加载性能样本（隐藏 debug seed）：
    /// - 仅当当前无任何村庄数据时执行（避免覆盖用户真实数据）。
    /// - 隔离检查：已有 #PERFCLAN 的部落缓存/跟踪时拒绝（合法 tag 可能真实存在）。
    /// - 预检全部 fixtures（读取 + account parse + war/raid Codable 解码，
    ///   纯函数、发生在任何状态变更之前）→ 任何 fixture 失败不会留下半成品。
    /// - 导入 home/builder/mixed → 3 村庄（A/B/C）。
    /// - A 启动 manual active（含 1000002 lvl15→16）+ 2 项过去启动 → settle → completed。
    /// - 导入 variant（#ANONYMIZED → 更新 A）→ 1000002 分布互不支配 → 对账 .conflict。
    /// - 清除 B 快照 → unreconciled。
    /// - 注册跟踪部落 #PERFCLAN + 加载 war log/raid 多页缓存。
    ///   任一执行步骤失败 → 返回 false（不再忽略 variant/war-raid 结果）。
    ///
    /// 残余边界：执行阶段的 manual/persistence 失败（非 fixture 失败）仍可能在
    /// 已有写入后返回 false——真正的全量回滚不可行（fresh app 初始 history 为 nil，
    /// seed 写入后 FileSnapshotHistoryStore 无删除 API）；预检已消除 fixture 失败
    /// 的半成品，执行阶段失败概率≈0（fixtures 预检通过 + 预设 tag 不拦截）。
    ///
    /// `fixtureDirectory` 为 nil 时读取 COCHelperApp bundle 的 PerfFixtures/；
    /// 测试可注入测试 bundle 的 Fixtures 目录。
    @discardableResult
    public func loadPerformanceSample(fixtureDirectory: URL? = nil) -> Bool {
        // 仅当没有真实导入数据时执行（默认占位村庄允许被 seed 覆盖，不碰用户数据）。
        guard villages.allSatisfy({ !$0.hasImportedData }) else { return false }
        guard let directory = fixtureDirectory ?? Self.perfFixtureBundleDirectory() else { return false }

        // 隔离检查：seed 会写 #PERFCLAN 的 war/raid 缓存并添加跟踪部落。
        // 若用户无村庄快照但已有该 tag 的任何部落缓存/跟踪，拒绝执行，
        // 避免覆盖已有部落数据（#PERFCLAN 是合法 tag，可能真实存在）。
        guard !clanWarLogStates.keys.contains(PerfSampleFixture.perfClanTag),
              !clanCapitalStates.keys.contains(PerfSampleFixture.perfClanTag),
              !clanWarStates.keys.contains(PerfSampleFixture.perfClanTag),
              !clanStates.keys.contains(PerfSampleFixture.perfClanTag),
              !trackedClans.contains(where: { $0.clanTag == PerfSampleFixture.perfClanTag }) else {
            accountImportError = "已存在部落 #PERFCLAN 的数据，性能样本为避免覆盖而不加载。"
            return false
        }

        // 0. 预检：任何 fixture 读取/解析/解码失败都发生在状态变更之前。
        do {
            try perfFixturePreflight(in: directory)
        } catch {
            accountImportError = Self.localizedPersistenceError(error)
            return false
        }

        // 1. 导入 3 个村庄（home 更新默认占位村庄 → A；builder/mixed 新建）。
        guard perfImport(PerfSampleFixture.home, in: directory),
              perfImport(PerfSampleFixture.builder, in: directory),
              perfImport(PerfSampleFixture.mixed, in: directory) else { return false }
        guard let villageA = villages.first(where: { $0.tag == "#ANONYMIZED" }),
              let villageB = villages.first(where: { $0.tag == "#PERF-BUILDER" }) else { return false }

        // 2. A 上启动 manual active + 过去启动项 → settle → completed。
        let now = Date()
        guard startPerfManualUpgrades(on: villageA.id, now: now) else { return false }
        settleManualUpgrades(at: now)

        // 3. 导入 variant（#ANONYMIZED → 更新 A）→ 1000002 冲突（必须成功）。
        guard perfImport(PerfSampleFixture.variant, in: directory) else { return false }

        // 4. B 清除快照 → unreconciled。
        selectVillage(id: villageB.id)
        clearAccountSnapshot()

        // 5. war log / raid 多页缓存 + 跟踪部落（失败 → 返回 false）。
        guard seedPerfWarLogAndRaid(in: directory) else { return false }

        // 6. 回到村庄 A 便于测量。
        selectVillage(id: villageA.id)
        return true
    }

    /// 预检全部 fixtures（纯函数，不改变任何 AppModel 状态）：
    /// 读取文本 + `AccountSnapshotImporter.parse` + war/raid `JSONDecoder` 解码。
    private func perfFixturePreflight(in directory: URL) throws {
        let accountNames = [
            PerfSampleFixture.home,
            PerfSampleFixture.builder,
            PerfSampleFixture.mixed,
            PerfSampleFixture.variant,
        ]
        for name in accountNames {
            _ = try AccountSnapshotImporter.parse(try perfFixtureText(name, in: directory))
        }
        let warNames = [
            PerfSampleFixture.warLogPage1,
            PerfSampleFixture.warLogPage2,
            PerfSampleFixture.warLogPage3,
        ]
        for name in warNames {
            _ = try decodePerfWarLogPage(try perfFixtureText(name, in: directory))
        }
        let raidNames = [
            PerfSampleFixture.raidPage1,
            PerfSampleFixture.raidPage2,
            PerfSampleFixture.raidPage3,
        ]
        for name in raidNames {
            _ = try decodePerfRaidPage(try perfFixtureText(name, in: directory))
        }
    }

    private func decodePerfWarLogPage(_ text: String) throws -> OfficialWarLogPage {
        try JSONDecoder().decode(OfficialWarLogPage.self, from: Data(text.utf8))
    }

    private func decodePerfRaidPage(_ text: String) throws -> OfficialCapitalRaidPage {
        try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: Data(text.utf8))
    }

    /// COCHelperApp bundle 的 PerfFixtures 目录（运行时 fixture 源）。
    private static func perfFixtureBundleDirectory() -> URL? {
        Bundle.module.url(forResource: "PerfFixtures", withExtension: nil)
            ?? Bundle.module.resourceURL?.appendingPathComponent("PerfFixtures")
    }

    /// 读取 fixture 文本（bundle 或测试注入目录）。
    private func perfFixtureText(_ name: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(name + ".json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 用 pending 导入路径导入单个 fixture（同 UI 粘贴路径，确定性）。
    private func perfImport(_ name: String, in directory: URL) -> Bool {
        do {
            importText = try perfFixtureText(name, in: directory)
        } catch {
            accountImportError = Self.localizedPersistenceError(error)
            return false
        }
        parseAccountText()
        guard pendingAccountSnapshot != nil else {
            return false
        }
        return applyPendingAccountSnapshot()
    }

    /// 在村庄上启动 manual 记录：1000002 lvl15→16（冲突样本）+ 2 项 active
    /// + 2 项过去启动（settle 后 completed）。
    private func startPerfManualUpgrades(on villageID: UUID, now: Date) -> Bool {
        guard let village = villages.first(where: { $0.id == villageID }),
              let catalog = gameCatalog,
              let core = manualUpgradeCore(for: villageID) else { return false }
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            base: .home,
            now: now,
            manualUpgradeCore: core
        )
        let startable = projection.items.compactMap { item -> UpgradeAction? in
            UpgradeActionProjection.action(
                for: item,
                catalog: catalog,
                catalogIsUsable: projection.catalogIsUsable,
                manualUpgradeCore: core,
                coverage: UpgradeActionProjection.coverage(
                    for: item,
                    progressCoverage: projection.progressCoverage
                ),
                now: now
            )
        }.filter { $0.isStartable }

        // 冲突样本：1000002 lvl15→16。
        let conflictAction = startable.first {
            $0.itemKey.dataID == 1_000_002 && $0.fromLevel == 15
        }
        let others = startable.filter { $0.itemKey.dataID != 1_000_002 }
        var started = 0
        if let conflictAction {
            do {
                try startManualUpgrade(
                    for: villageID,
                    action: conflictAction,
                    startedAt: now
                )
                started += 1
            } catch {
                return false
            }
        }
        for action in others where started < 5 {
            let startedAt: Date
            if started >= 3 {
                // 第 4/5 项过去启动（90 天前）→ settle 立即到期 → completed。
                // 不能用 1 天：多数建筑升级时长 > 24h，settle 不会完成。
                startedAt = now.addingTimeInterval(-7_776_000)
            } else {
                startedAt = now
            }
            do {
                try startManualUpgrade(
                    for: villageID,
                    action: action,
                    startedAt: startedAt
                )
                started += 1
            } catch {
                // 个别项目可能因重验证 stale 跳过；seed 只要达到 5 项即可。
                continue
            }
        }
        return started >= 3
    }

    /// war log / raid 多页缓存：解码 3 页 → 合并 → 写 API state store + 内存。
    /// 任何解码/持久化失败 → 返回 false（不再忽略结果继续加部落）。
    private func seedPerfWarLogAndRaid(in directory: URL) -> Bool {
        let now = Date()
        do {
            let warP1 = try decodePerfWarLogPage(try perfFixtureText(PerfSampleFixture.warLogPage1, in: directory))
            let warP2 = try decodePerfWarLogPage(try perfFixtureText(PerfSampleFixture.warLogPage2, in: directory))
            let warP3 = try decodePerfWarLogPage(try perfFixtureText(PerfSampleFixture.warLogPage3, in: directory))
            let warMerged = PaginationMerge.mergedPage(
                existing: PaginationMerge.mergedPage(existing: warP1.page, fetched: warP2.page),
                fetched: warP3.page
            )
            let warState = ClanWarLogAPIState(
                status: .success,
                clanTag: PerfSampleFixture.perfClanTag,
                fetchedAt: now,
                parserVersion: OfficialWarLogPage.currentParserVersion,
                lastGood: OfficialWarLogPage(page: warMerged)
            )
            clanWarLogStates[PerfSampleFixture.perfClanTag] = warState
            persistClanWarLogStates()

            let raidP1 = try decodePerfRaidPage(try perfFixtureText(PerfSampleFixture.raidPage1, in: directory))
            let raidP2 = try decodePerfRaidPage(try perfFixtureText(PerfSampleFixture.raidPage2, in: directory))
            let raidP3 = try decodePerfRaidPage(try perfFixtureText(PerfSampleFixture.raidPage3, in: directory))
            let raidMerged = PaginationMerge.mergedPage(
                existing: PaginationMerge.mergedPage(existing: raidP1.page, fetched: raidP2.page),
                fetched: raidP3.page
            )
            let raidState = ClanCapitalAPIState(
                status: .success,
                clanTag: PerfSampleFixture.perfClanTag,
                fetchedAt: now,
                parserVersion: OfficialCapitalRaidPage.currentParserVersion,
                lastGood: OfficialCapitalRaidPage(page: raidMerged)
            )
            clanCapitalStates[PerfSampleFixture.perfClanTag] = raidState
            persistClanCapitalStates()
        } catch {
            // war/raid seed 失败：记录诊断并返回失败（不继续加部落）。
            accountImportError = Self.localizedPersistenceError(error)
            return false
        }

        // 跟踪部落（war log / raid 卡片入口，无需 token）。
        if !trackedClans.contains(where: { $0.clanTag == PerfSampleFixture.perfClanTag }) {
            guard case .success = addTrackedClan(
                rawTag: PerfSampleFixture.perfClanTag,
                displayName: "anonymized-perf-clan"
            ) else {
                return false
            }
        }
        return true
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
            var candidateVillages = self.villages
            let applied = self.applyOfficialState(
                state,
                to: village.id,
                expectedTag: expectedTag,
                in: &candidateVillages
            )
            guard applied else { return }
            do {
                try self.persistVillages(candidateVillages)
                self.villages = candidateVillages
                if self.selectedVillageID == village.id {
                    self.officialRefreshSummary = nil
                }
            } catch {
                self.accountImportError = Self.localizedPersistenceError(error)
                return
            }
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
            var candidateVillages = self.villages
            var appliedVillageIDs = Set<UUID>()
            for (id, state) in states {
                if self.applyOfficialState(
                    state,
                    to: id,
                    expectedTag: tagByID[id],
                    in: &candidateVillages
                ) {
                    appliedVillageIDs.insert(id)
                }
            }
            let successCount = states.values.filter { $0.status == .success }.count
            let skippedCount = states.values.filter { $0.status == .skipped }.count
            let failedCount = states.values.filter { $0.status == .failed }.count
            do {
                // 批量刷新只写一次 UserDefaults，避免 N+1 次全量 JSON 编码。
                try self.persistVillages(candidateVillages)
                self.villages = candidateVillages
            } catch {
                self.accountImportError = Self.localizedPersistenceError(error)
                return
            }
            self.officialRefreshSummary = "刷新完成：成功 \(successCount)，失败 \(failedCount)，跳过 \(skippedCount)"
            // 玩家快照更新后部落归属可能变化，联动刷新部落共享数据
            // （refreshAllClans 内部按 clan tag 去重，被占用时排队补跑）。
            // 仅在本次存在成功时联动：玩家请求全挂（如断网/429）时不追加
            // 部落请求，避免在限流边界上放大请求面。
            if successCount > 0, !appliedVillageIDs.isEmpty {
                self.refreshAllClans()
            }
        }
    }

    /// 纯内存状态更新；调用方负责在合适的时机持久化。
    /// 若村庄当前 tag 与发起请求时不一致（账号已变化），丢弃过期结果并返回 false。
    @discardableResult
    private func applyOfficialState(
        _ state: OfficialAPIState,
        to villageID: UUID,
        expectedTag: String?,
        in candidateVillages: inout [VillageProfile]
    ) -> Bool {
        guard let index = candidateVillages.firstIndex(where: { $0.id == villageID }) else { return false }
        guard candidateVillages[index].officialStateMatchesTag(at: expectedTag) else { return false }
        candidateVillages[index].officialAPIState = state
        candidateVillages[index].updatedAt = Date()
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
            // 注：即使 tag 已在当前批次中仍入队——手动刷新语义是"补跑确保
            // 最新数据"（B1 测试锁定），重复请求是故意的，不属于 single-flight
            // 范围（single-flight 仅约束 resolveClan 解析路径）。
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
    /// 允许 `.success` 与保留 last-good 的 `.failed`（失败重试，Issue #124）。
    public func loadMoreWarLog(tag: String) {
        guard let tag = ClanTagNormalizer.normalize(tag) else { return }
        guard !isRefreshingWarLogData else { return }
        guard let current = clanWarLogStates[tag],
              current.status == .success || current.status == .failed,
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

    /// 按显式 Tag 刷新部落都城突袭周末（手动部落入口）。
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

    /// 按显式 Tag 突袭周末加载更多（手动部落入口；入参规范化，非法输入 no-op）。
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
        // 防御：入集合前规范化（与 EndpointRefresher.uniqueTags 同源），
        // 保证 single-flight 的 contains 判定与请求 tag 一致。
        refreshingClanTags = Set(villageClanTags.compactMap {
            OfficialPlayerTagValidator.normalized($0).flatMap { tag in
                OfficialPlayerTagValidator.isValid(tag) ? tag : nil
            }
        })
        let previous = clanStates
        // 批次开始时间：合并时用于防回退（C1）——批次期间若有更新的成功
        // 数据写入（如解析预览成功），批次失败不得覆盖它。
        let batchStart = Date()

        Task { [weak self] in
            guard let self else { return }
            // 清空 + 排队补跑都不能用 defer 的"闭包末尾执行"：refreshAllClans
            // 以集合为空判断可进入（会重新设置集合），必须先清空再触发。
            let refreshed = await self.clanRefresher.refreshClans(
                villageClanTags: villageClanTags,
                previous: previous
            )
            self.mergeClanStates(refreshed, batchStart: batchStart)
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

    /// C1 防回退谓词（纯函数，独立可测）：
    /// 刷新批次失败时，若批次开始后已有更新的成功数据（如解析预览写入），
    /// 跳过覆盖——否则用户刚看到的成功预览会被陈旧的失败状态抹掉。
    /// `existing.fetchedAt > batchStart` 严格大于：previous 与 batchStart 在
    /// 同一主 actor 同步块捕获，批次期间写入的成功数据 fetchedAt 必然严格
    /// 晚于 batchStart（== 不可达，防御上不跳过）。
    static func shouldSkipFailedOverwrite(
        refreshedState: ClanAPIState,
        existing: ClanAPIState?,
        batchStart: Date
    ) -> Bool {
        guard refreshedState.status == .failed,
              let existing, existing.status == .success,
              let fetchedAt = existing.fetchedAt else { return false }
        return fetchedAt > batchStart
    }

    /// 合并刷新结果到共享存储：只覆盖本次请求过的 tag，其余保留
    /// （旧部落快照不因换部落而丢失）。
    ///
    /// `batchStart` 防回退（C1）：刷新批次开始时捕获 `previous` 快照，
    /// 批次进行中若该 tag 出现了更新的成功数据（如解析预览写入成功），
    /// 批次以失败收尾时**不得用陈旧的失败状态覆盖它**——否则用户刚看到的
    /// 成功预览会在保存后变成"获取失败"。批次成功时正常覆盖（更新的抓取
    /// 数据优先）。其他调用（resolveClan）不传 batchStart，行为不变。
    private func mergeClanStates(
        _ refreshed: [String: ClanAPIState],
        batchStart: Date? = nil
    ) {
        let current = clanStates
        let protected = refreshed.filter { tag, state in
            guard let batchStart else { return true }
            return !Self.shouldSkipFailedOverwrite(
                refreshedState: state,
                existing: current[tag],
                batchStart: batchStart
            )
        }
        clanStates = ClanStateStore(states: current).merging(protected).states
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

    // MARK: - 部落都城突袭周末（分页，按需）

    /// 当前村庄所属部落的突袭周末状态。
    public var currentCapitalState: ClanCapitalAPIState? {
        guard let tag = currentVillageClanTag else { return nil }
        return capitalState(for: tag)
    }

    /// 当前突袭周末是否还有更多页。
    public var currentCapitalHasMore: Bool {
        guard let tag = currentVillageClanTag else { return false }
        return capitalHasMore(for: tag)
    }

    /// 指定村庄所属部落的突袭周末首屏/刷新（替换累计列表；失败保留既有 last-good）。
    public func refreshCapitalRaid(villageID: UUID) {
        guard let tag = officialClanTag(for: villageID) else { return }
        refreshCapitalRaid(tag: tag)
    }

    /// 当前村庄所属部落的突袭周末首屏/刷新（兼容转发，语义不变）。
    public func refreshCurrentCapitalRaid() {
        refreshCapitalRaid(villageID: selectedVillageID)
    }

    /// 指定村庄所属部落的突袭周末加载更多（合并去重）。
    public func loadMoreCapitalRaid(villageID: UUID) {
        guard let tag = officialClanTag(for: villageID) else { return }
        loadMoreCapitalRaid(tag: tag)
    }

    /// 当前村庄所属部落的突袭周末加载更多（兼容转发，语义不变）。
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
        case cancelled

        /// 展示文案（脱敏，可安全用于 UI）。
        public var userFacingMessage: String {
            switch self {
            case .invalidTag:
                return "标签无效：需要以 # 开头，仅含大写字母和数字，长度不超过 15 字符。"
            case .missingToken:
                return "未配置 API token，请先在账号数据页配置。"
            case .notFound:
                return "未找到该部落（404），请检查标签是否正确。"
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
            case .cancelled:
                return "解析已取消。"
            }
        }
    }

    /// 解析部落（Issue #48 Step A）：本地规范化 → `fetchClan` → 成功后写入
    /// 共享缓存并返回快照。**不保存跟踪关系**（保存由 `addTrackedClan` 负责），
    /// **不查重**（查重由 `isClanTracked` 提供，sheet 在发起请求前拦截）。
    ///
    /// 成功写入 `clanStates` 的理由：#48「详情页首屏只读取已保存的基础信息/
    /// API 状态」——确认保存后打开详情页首屏直接有数据，无需再次请求。
    ///
    /// single-flight（#48 验收"同一部落标签并发刷新只产生一次实际请求"）：
    /// 同 tag 刷新批次在途时（`refreshingClanTags` 含该 tag），解析**等待**
    /// 批次结束并复用其结果（成功返回快照、失败映射分类），不发第二个请求；
    /// 仅"确实等待过批次"才复用，避免误复用解析前的旧缓存。等待可取消。
    /// `performClanRefresh` 保证合并先于集合清空，等待恢复后读到的是批次
    /// 合并后的状态（成功/失败；C1 防回退下可能保留批次期间更新的成功）。
    /// 批次成功但数据未合并到状态的情况不可达。
    ///
    /// 错误映射：`CoAPIError.missingCredentials`（token provider 返回 nil 时
    /// 由 client 抛出，与刷新链路一致，不重复检查 Keychain）→ `.missingToken`；
    /// 401/403 → `.accessDenied`；404 → `.notFound`；429 → `.rateLimited`；
    /// 5xx → `.server`；超时/网络 → `.network`；解析 → `.malformed`。
    public func resolveClan(rawTag: String?) async -> Result<OfficialClanSnapshot, ClanResolveError> {
        guard let tag = ClanTagNormalizer.normalize(rawTag) else { return .failure(.invalidTag) }
        // 等待前记录该 tag 的 lastAttemptAt：用于区分"批次确实处理了该 tag"
        // 与"批次未包含该 tag"（pendingClanRefreshAll 的补跑集合动态读村庄
        // tags，该 tag 可能被丢弃）——只有前者才复用，后者 fallthrough 请求。
        let previousLastAttempt = clanStates[tag]?.lastAttemptAt
        var waitedForBatch = false
        while isClanRefreshPending(involving: tag) {
            waitedForBatch = true
            if Task.isCancelled { return .failure(.cancelled) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if waitedForBatch, let existing = clanStates[tag], existing.lastAttemptAt != previousLastAttempt {
            if existing.status == .success, let snapshot = existing.lastGood {
                return .success(snapshot)
            }
            if existing.status == .failed {
                return .failure(Self.mapFailedState(existing))
            }
        }
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
        } catch is CancellationError {
            // CoAPIClient 显式透传取消（含 URLSession 的 URLError(.cancelled)），
            // 不得误报为网络错误。
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch let error as CoAPIError {
            return .failure(Self.mapResolveError(error))
        } catch {
            return .failure(.network)
        }
    }

    /// single-flight 判定（外部终审 P1）：tag 是否在**当前批次**或**已排队批次**
    /// 中——等待条件必须覆盖 `pendingClanRefreshTags`（显式 tag 排队）与
    /// `pendingClanRefreshAll`（村庄全量联动排队，补跑集合动态读当前村庄 tags）。
    private func isClanRefreshPending(involving tag: String) -> Bool {
        Self.isClanRefreshPending(
            inFlightTags: refreshingClanTags,
            queuedTags: pendingClanRefreshTags,
            queuedAll: pendingClanRefreshAll,
            villageClanTags: villages.compactMap { $0.officialAPIState?.currentClanTag },
            tag: tag
        )
    }

    /// single-flight 判定谓词（纯函数，独立可测；模式同 `shouldSkipFailedOverwrite`）。
    static func isClanRefreshPending(
        inFlightTags: Set<String>,
        queuedTags: Set<String>,
        queuedAll: Bool,
        villageClanTags: [String],
        tag: String
    ) -> Bool {
        if inFlightTags.contains(tag) { return true }
        if queuedTags.contains(tag) { return true }
        if queuedAll { return villageClanTags.contains(tag) }
        return false
    }

    /// 批次失败状态 → 解析错误分类（single-flight 复用路径）。
    /// `ClanAPIState` 只保留脱敏 HTTP 状态码与原因字符串，按码映射；
    /// 传输层失败/解析失败/缺 token 的 `lastHTTPStatus` 均为 nil，统一
    /// 归为 .network（与直接路径的精确分类有差距：malformed/missingToken
    /// 无法从状态区分——完整修复需在 `OfficialEndpointState` 增加结构化
    /// 错误类别字段，记 follow-up）。"已取消"是 `EndpointRefresher` 写死的
    /// 稳定文案，可精确识别。
    private static func mapFailedState(_ state: ClanAPIState) -> ClanResolveError {
        if state.lastErrorReason == "已取消" {
            return .cancelled
        }
        switch state.lastHTTPStatus {
        case 404: return .notFound
        case 401, 403: return .accessDenied
        case 429: return .rateLimited
        case let code? where (500..<600).contains(code): return .server
        default: return .network
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
        pendingReconciliationPreview = nil
        accountImportError = nil
    }

    private func villagesForImportPersistence() -> [VillageProfile] {
        var candidate = villages
        guard let index = candidate.firstIndex(where: { $0.id == selectedVillageID }) else {
            return candidate
        }
        candidate[index].accountSnapshot = accountSnapshot
        candidate[index].updatedAt = Date()
        return candidate
    }

    private func loadManualTracker(for villageIDs: [UUID], now: Date) {
        do {
            let uniqueVillageIDs = Array(Set(villageIDs)).sorted {
                $0.uuidString < $1.uuidString
            }
            var envelope = try manualTrackerStore.load()
            var shouldSave = false

            if envelope == nil {
                // Missing storage is an uninitialized store, not an error and
                // never a reason to synthesize completed manual records.
                envelope = ManualTrackerEnvelope.empty(for: uniqueVillageIDs, now: now)
                shouldSave = true
            } else if var existing = envelope {
                if existing.migrationMarker == nil {
                    existing.migrationMarker = ManualTrackerMigrationMarker(completedAt: now)
                    shouldSave = true
                }
                for villageID in uniqueVillageIDs where existing.state(for: villageID) == nil {
                    try existing.upsert(
                        ManualTrackerVillageState.empty(villageID: villageID, now: now)
                    )
                    shouldSave = true
                }
                envelope = existing
            }

            guard let envelope else {
                throw ManualTrackerStoreError.unavailable("无法建立手动升级初始状态。")
            }
            if shouldSave {
                try manualTrackerStore.save(envelope)
            }
            installManualTrackerEnvelope(envelope)
            // 自动结算依赖当前快照基线（Issue #170 gate），必须在 history
            // 加载完成后由调用方触发；此处不再提前 settle。
        } catch let error as ManualTrackerStoreError {
            if case .unsupportedSchema = error {
                manualTrackerStatus = .migrationRequired
            } else {
                manualTrackerStatus = .unavailable
            }
            manualTrackerEnvelope = nil
            manualUpgradeCores = [:]
            manualTrackerError = Self.localizedPersistenceError(error)
        } catch {
            manualTrackerStatus = .unavailable
            manualTrackerEnvelope = nil
            manualUpgradeCores = [:]
            manualTrackerError = Self.localizedPersistenceError(error)
        }
    }

    private func installManualTrackerEnvelope(_ envelope: ManualTrackerEnvelope) {
        manualTrackerEnvelope = envelope
        var cores: [UUID: ManualUpgradeCore] = [:]
        for village in villages where cores[village.id] == nil {
            if let state = envelope.state(for: village.id) {
                cores[village.id] = projectedManualUpgradeCore(
                    state.core,
                    for: village.id
                )
            }
        }
        manualUpgradeCores = cores
        manualTrackerStatus = envelope.isEmpty ? .empty : .available
        manualTrackerError = nil
    }

    /// Rebuilds only the projection exposed to UI/overview consumers.  The
    /// persisted envelope remains the source for mutations and is never
    /// rewritten merely because a snapshot is cleared or re-imported.
    private func refreshManualTrackerProjection() {
        guard let manualTrackerEnvelope else {
            manualUpgradeCores = [:]
            return
        }
        installManualTrackerEnvelope(manualTrackerEnvelope)
    }

    private func projectedManualUpgradeCore(
        _ core: ManualUpgradeCore,
        for villageID: UUID
    ) -> ManualUpgradeCore {
        guard !core.itemStates.isEmpty || !core.records.isEmpty else {
            return core
        }
        guard isBaselineReconciled(for: villageID, core: core) else {
            return core.gatedForUnreconciledSnapshot()
        }
        return core
    }

    /// 统一基线 gate（Issue #170）：当前快照/active lineage 的基线是否与
    /// 持久化 Core 的基线是同一个可比较事实。
    ///
    /// - 空白新村庄（无 item state / record）可继续作为空状态使用；
    /// - 有任何本地 item state 或 record，但缺少当前可比较 baseline
    ///   （无快照、无 active lineage、lineage 有冲突、或 tag 不一致），
    ///   或 stored baseline 与 current baseline 不相等 → 未对账；
    /// - 未对账状态不得被命令改写或自动结算，旧 bytes 留给 #143 显式对账。
    private func isBaselineReconciled(
        for villageID: UUID,
        core: ManualUpgradeCore
    ) -> Bool {
        guard !core.itemStates.isEmpty || !core.records.isEmpty else {
            return true
        }
        guard let storedBaseline = core.baselineReference,
              let currentBaseline = currentManualBaselineReference(for: villageID),
              storedBaseline == currentBaseline else {
            return false
        }
        return true
    }

    /// Converts the active history tail into the baseline identity used by
    /// manual tracker records.  Missing/invalid/conflicted identity is not a
    /// joinable baseline, so the caller must keep local manual state unknown.
    private func currentManualBaselineReference(for villageID: UUID) -> ManualBaselineReference? {
        guard let village = villages.first(where: { $0.id == villageID }),
              village.accountSnapshot != nil,
              let historyEnvelope,
              let lineage = historyEnvelope.activeLineage(for: villageID),
              !lineage.hasConflict,
              let entry = historyEnvelope.entry(id: lineage.lastEntryID),
              entry.villageID == villageID,
              entry.lineageID == lineage.lineageID,
              OfficialPlayerTagValidator.normalized(village.tag)
                  == lineage.normalizedPlayerTag,
              let normalizedTag = lineage.normalizedPlayerTag,
              !normalizedTag.isEmpty else {
            return nil
        }
        let duplicateImportCount = historyEnvelope.duplicateMetadata[
            entry.snapshotID.uuidString
        ]?.duplicateImportCount ?? 0
        let observationRevision = duplicateImportCount == 0
            ? entry.snapshotID.uuidString
            : entry.snapshotID.uuidString + ":observation:" + String(duplicateImportCount)
        return ManualBaselineReference(
            revision: observationRevision,
            fingerprint: entry.canonicalFingerprint,
            lineageID: entry.lineageID.uuidString
        )
    }

    private func markManualTrackerUnavailable(_ error: Error) {
        manualTrackerEnvelope = nil
        manualUpgradeCores = [:]
        manualTrackerStatus = .unavailable
        manualTrackerError = Self.localizedPersistenceError(error)
    }

    private func commitVillageMutation(
        candidateVillages: [VillageProfile],
        envelope: ManualTrackerEnvelope
    ) throws {
        try ensureVillageStoreWritable()
        let currentData = try VillageStoreCodec.encode(candidateVillages)
        do {
            try manualTrackerTransaction.commit(
                currentData: currentData,
                envelope: envelope
            )
            markVillageStoreAvailable(for: candidateVillages)
        } catch {
            markVillageStoreWriteFailure(error)
            throw error
        }
    }

    private func commitImportedSnapshot(
        _ snapshot: AccountSnapshot,
        targetVillage: VillageProfile,
        candidateVillages: [VillageProfile],
        appliedAt: Date,
        manualEnvelope: ManualTrackerEnvelope? = nil,
        expectedPreview: ManualReconciliationPreview? = nil,
        reconciliationDecision: ManualReconciliationDecision = .applyNonConflicting
    ) throws {
        try ensureVillageStoreWritable()
        guard let historyEnvelope else {
            throw SnapshotHistoryServiceError.historyUnavailable(
                snapshotHistoryError ?? "历史存储尚未可用。"
            )
        }

        let previousEntry = activeHistoryEntry(
            for: targetVillage.id,
            in: historyEnvelope
        )
        let historyDecision = try historyService.planImport(
            snapshot: snapshot,
            villageID: targetVillage.id,
            currentTag: targetVillage.tag,
            hasCurrentSnapshot: targetVillage.accountSnapshot != nil,
            envelope: historyEnvelope,
            appliedAt: appliedAt,
            catalog: gameCatalog,
            craftTableCatalog: craftTableCatalog,
            sectionProofs: JSONSnapshotCoverageAdapter.proofs(for: snapshot)
        )
        guard var candidateManualEnvelope = manualEnvelope ?? manualTrackerEnvelope else {
            throw ManualTrackerStoreError.unavailable("导入前未找到可用的手动升级状态。")
        }
        let currentManualState = candidateManualEnvelope.state(for: targetVillage.id)
            ?? ManualTrackerVillageState.empty(villageID: targetVillage.id, now: appliedAt)
        let reconciliationPlan = try ManualTrackerReconciliationService.reconcile(
            villageID: targetVillage.id,
            previousEntry: previousEntry,
            historyDecision: historyDecision,
            currentState: currentManualState,
            expectedPreview: expectedPreview,
            decision: reconciliationDecision,
            appliedAt: appliedAt
        )
        try candidateManualEnvelope.upsert(reconciliationPlan.state)
        let currentData = try VillageStoreCodec.encode(candidateVillages)
        do {
            try importTransaction.commit(
                currentData: currentData,
                envelope: historyDecision.envelope,
                manualEnvelope: candidateManualEnvelope
            )
            markVillageStoreAvailable(for: candidateVillages)
        } catch {
            markVillageStoreWriteFailure(error)
            throw error
        }
        villages = candidateVillages
        self.historyEnvelope = historyDecision.envelope
        historyProjectionCache.removeAll()
        installManualTrackerEnvelope(candidateManualEnvelope)
    }

    private func prepareReconciliationPreview(
        _ snapshot: AccountSnapshot,
        targetVillage: VillageProfile,
        appliedAt: Date
    ) throws -> ManualReconciliationPreview {
        guard let historyEnvelope else {
            throw SnapshotHistoryServiceError.historyUnavailable(
                snapshotHistoryError ?? "历史存储尚未可用。"
            )
        }
        guard let manualTrackerEnvelope,
              let currentState = manualTrackerEnvelope.state(for: targetVillage.id) else {
            throw ManualTrackerStoreError.unavailable("目标村庄的手动升级状态尚未可用。")
        }
        let previousEntry = activeHistoryEntry(for: targetVillage.id, in: historyEnvelope)
        let historyDecision = try historyService.planImport(
            snapshot: snapshot,
            villageID: targetVillage.id,
            currentTag: targetVillage.tag,
            hasCurrentSnapshot: targetVillage.accountSnapshot != nil,
            envelope: historyEnvelope,
            appliedAt: appliedAt,
            catalog: gameCatalog,
            craftTableCatalog: craftTableCatalog,
            sectionProofs: JSONSnapshotCoverageAdapter.proofs(for: snapshot)
        )
        return try ManualTrackerReconciliationService.preview(
            villageID: targetVillage.id,
            previousEntry: previousEntry,
            decision: historyDecision,
            currentState: currentState,
            appliedAt: appliedAt
        )
    }

    private func activeHistoryEntry(
        for villageID: UUID,
        in envelope: SnapshotHistoryEnvelope
    ) -> SnapshotHistoryEntry? {
        guard let lineage = envelope.activeLineage(for: villageID) else { return nil }
        return envelope.entry(id: lineage.lastEntryID)
    }

    private func activeTransactionJournalURLs() -> [(kind: VillageTransactionJournalKind, url: URL)] {
        [
            (.snapshotImport, importTransaction.journalURL),
            (.manualTracker, manualTrackerTransaction.journalURL),
        ].compactMap { kind, url in
            guard let url else { return nil }
            return (kind, url)
        }
    }

    private func quarantinedTransactionJournalURL(for journalURL: URL) -> URL {
        journalURL.appendingPathExtension("quarantined")
    }

    private func pendingTransactionJournalNotice() -> String? {
        let pending = activeTransactionJournalURLs().filter {
            FileManager.default.fileExists(atPath: $0.url.path)
                || FileManager.default.fileExists(
                    atPath: quarantinedTransactionJournalURL(for: $0.url).path
                )
        }
        let total = pending.count
        guard total > 0 else { return nil }
        return "检测到 \(total) 条待处理事务 journal；可显式从 journal 恢复，或选择文件恢复/重置（会先隔离 journal）。"
    }

    /// Copies active journal bytes to a sibling quarantine file before
    /// removing the source file.  This prevents a stale committed journal
    /// from replaying over a user-selected restore while retaining evidence.
    private func quarantinePendingTransactionJournals() throws {
        let active = activeTransactionJournalURLs().filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
        guard !active.isEmpty else { return }

        var bytesByKind: [(kind: VillageTransactionJournalKind, url: URL, quarantineURL: URL, data: Data)] = []
        for (kind, url) in active {
            bytesByKind.append((
                kind,
                url,
                quarantinedTransactionJournalURL(for: url),
                try Data(contentsOf: url)
            ))
        }

        do {
            for item in bytesByKind {
                try item.data.write(to: item.quarantineURL, options: .atomic)
            }
            for item in bytesByKind {
                try FileManager.default.removeItem(at: item.url)
            }
        } catch {
            throw VillageStoreError.writeFailed(
                "事务 journal 隔离后清理源文件失败：" + error.localizedDescription
            )
        }
    }

    private func recoverTransactionJournal(
        _ kind: VillageTransactionJournalKind
    ) throws {
        guard let journalURL = activeTransactionJournalURLs().first(where: { $0.kind == kind })?.url else {
            return
        }

        let quarantineURL = quarantinedTransactionJournalURL(for: journalURL)
        let hasActiveJournal = FileManager.default.fileExists(atPath: journalURL.path)
        if !hasActiveJournal, FileManager.default.fileExists(atPath: quarantineURL.path) {
            try FileManager.default.createDirectory(
                at: journalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let quarantinedData = try Data(contentsOf: quarantineURL)
            try quarantinedData.write(to: journalURL, options: .atomic)
        }

        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        switch kind {
        case .snapshotImport:
            try importTransaction.recoverIfNeeded()
        case .manualTracker:
            try manualTrackerTransaction.recoverIfNeeded()
        }

        if FileManager.default.fileExists(atPath: quarantineURL.path) {
            try FileManager.default.removeItem(at: quarantineURL)
        }
    }

    private func persistVillages(
        _ candidateVillages: [VillageProfile],
        bypassRecoveryGate: Bool = false
    ) throws {
        let data = try VillageStoreCodec.encode(candidateVillages)
        try writeVillageStoreData(
            data,
            candidateVillages: candidateVillages,
            bypassRecoveryGate: bypassRecoveryGate
        )
    }

    private func writeVillageStoreData(
        _ data: Data,
        candidateVillages: [VillageProfile],
        bypassRecoveryGate: Bool = false
    ) throws {
        if !bypassRecoveryGate {
            try ensureVillageStoreWritable()
        }

        let previousData = currentVillagePersistence.readData()
        var writeAttempted = false
        do {
            try CurrentVillageDataValidator.validate(data, label: "候选村庄数据")
            writeAttempted = true
            try currentVillagePersistence.writeData(data)
            villageStoreStatus = candidateVillages.isEmpty ? .empty : .available
            villageStoreError = nil
            villageStoreRecoveryData = nil
        } catch {
            var failure = error
            if writeAttempted {
                do {
                    try currentVillagePersistence.restoreData(previousData)
                } catch {
                    failure = VillageStoreError.writeFailed(
                        Self.localizedPersistenceError(error)
                            + "；原始村庄 bytes 回滚失败。"
                    )
                }
            }
            markVillageStoreWriteFailure(failure)
            throw failure
        }
    }

    private func markVillageStoreWriteFailure(_ error: Error) {
        villageStoreStatus = .writeFailed
        villageStoreError = Self.localizedPersistenceError(error)
        villageStoreRecoveryData = currentVillagePersistence.readData()
    }

    private func ensureVillageStoreWritable() throws {
        guard !villageStoreStatus.isRecoveryRequired else {
            throw VillageStoreError.unavailable(
                villageStoreError ?? "村庄数据处于恢复状态，普通写入已停止。"
            )
        }
    }

    private func markVillageStoreAvailable(for candidateVillages: [VillageProfile]? = nil) {
        let villages = candidateVillages ?? villages
        villageStoreStatus = villages.isEmpty ? .empty : .available
        villageStoreError = nil
        villageStoreRecoveryData = nil
    }

    private func installRestoredVillageState(_ restoredVillages: [VillageProfile]) {
        let normalizedVillages = restoredVillages.isEmpty
            ? [VillageProfile(name: "我的村庄")]
            : restoredVillages
        villages = normalizedVillages
        selectedVillageID = normalizedVillages[0].id
        accountSnapshot = normalizedVillages[0].accountSnapshot
        pendingAccountSnapshot = nil
        accountImportError = nil
        importText = normalizedVillages[0].accountSnapshot?.originalText ?? ""
        historyEnvelope = nil
        historyLoadFailure = nil
        historyProjectionCache.removeAll()
        snapshotHistoryError = nil
        manualTrackerEnvelope = nil
        manualTrackerStatus = .empty
        manualTrackerError = nil
        villageStoreStatus = .available
        villageStoreError = nil
        villageStoreRecoveryData = nil

        loadManualTracker(for: normalizedVillages.map(\.id), now: Date())
        do {
            historyEnvelope = try historyService.loadOrMigrate(
                villages: normalizedVillages,
                now: Date(),
                catalog: gameCatalog,
                craftTableCatalog: craftTableCatalog,
                sectionProofs: Self.coverageProofs(for: normalizedVillages)
            )
        } catch {
            snapshotHistoryError = Self.localizedPersistenceError(error)
            historyLoadFailure = Self.snapshotHistoryAvailability(for: error)
        }
        refreshManualTrackerProjection()
        // 自动结算需要当前快照基线（Issue #170 gate）：history 已加载，
        // 只结算基线一致的村庄。
        _ = settleManualUpgrades(at: Date())
    }

    private enum PendingSnapshotTarget {
        case existing(Int)
        case create
        case ambiguous(tag: String, villageNames: [String])
    }

    /// Issue #173: 为启动迁移等批量入口按村庄提取来源 coverage proof。
    ///
    /// 每个村庄的快照独立经过 `JSONSnapshotCoverageAdapter`,来源没有
    /// 完整性协议的村庄保持 unavailable(fail-closed),不会借用其他村庄
    /// 或默认参数的证明。
    private static func coverageProofs(
        for villages: [VillageProfile]
    ) -> [UUID: [String: SnapshotCoverageProof]] {
        var proofs: [UUID: [String: SnapshotCoverageProof]] = [:]
        for village in villages {
            guard let snapshot = village.accountSnapshot else { continue }
            proofs[village.id] = JSONSnapshotCoverageAdapter.proofs(for: snapshot)
        }
        return proofs
    }

    private func pendingSnapshotTarget(for snapshot: AccountSnapshot) -> PendingSnapshotTarget {
        if let tag = OfficialPlayerTagValidator.normalized(snapshot.tag) {
            let matchingIndices = villages.indices.filter {
                OfficialPlayerTagValidator.normalized(villages[$0].tag) == tag
            }
            if matchingIndices.count > 1 {
                return .ambiguous(
                    tag: tag,
                    villageNames: matchingIndices.map { villages[$0].name }
                )
            }
            if let existingIndex = matchingIndices.first {
                return .existing(existingIndex)
            }
        }

        guard let currentIndex = villages.firstIndex(where: { $0.id == selectedVillageID }),
              importIntoCurrentVillage || (villages.count == 1 && !villages[currentIndex].hasImportedData)
        else { return .create }
        return .existing(currentIndex)
    }

    private static func ambiguousImportTargetMessage(
        tag: String,
        villageNames: [String]
    ) -> String {
        "账号 Tag（" + tag + "）对应多个村庄档案：" + villageNames.joined(separator: "、")
            + "。为避免绑定错误，导入已拒绝，请先保留唯一匹配档案后重试。"
    }

    private func isReimportingExistingVillage(_ snapshot: AccountSnapshot, at index: Int) -> Bool {
        guard let tag = OfficialPlayerTagValidator.normalized(snapshot.tag) else { return false }
        return OfficialPlayerTagValidator.normalized(villages[index].tag) == tag
    }

    private static func localizedPersistenceError(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func snapshotHistoryAvailability(for error: Error) -> SnapshotHistoryAvailability {
        let message = localizedPersistenceError(error)
        if let storeError = error as? SnapshotHistoryStoreError {
            switch storeError {
            case .corrupt, .invalidEntry:
                return .corrupt(message)
            case .unsupportedSchema:
                return .unsupported(message)
            case .unavailable, .writeFailed:
                return .unavailable(message)
            }
        }
        if let transactionError = error as? SnapshotImportTransactionError {
            switch transactionError {
            case .journalCorrupt:
                return .corrupt(message)
            case .rollbackFailed:
                return .unavailable(message)
            }
        }
        return .unavailable(message)
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
