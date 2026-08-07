import Foundation

public enum VillageItemStatus: String, Codable, Hashable, Sendable {
    /// 进行中（remainingSeconds > 0）。
    case upgrading
    /// 有记录、未在升级、未达上限。
    case complete
    /// 已达目录上限（currentLevel >= maxLevel）。
    case maxed
    /// 目录未命中（或目录不可用）：保留 dataID 与 missingReason，不丢弃记录。
    case unknown
    /// 类别不支持（helpers/decos/obstacles 等不参与升级追踪）。
    case unavailable
    /// 目录存在但快照无记录。投影不产出该项；枚举留给 UI 层（#12）遍历目录时使用。
    case available
}

/// 单个物品的投影状态。
public struct VillageItemState: Identifiable, Hashable, Sendable {
    /// 快照原始 id（含 `.types.`/`.modules.` 路径 → 可追溯）。
    public let id: String
    public let section: String
    public let dataID: Int64
    public let base: TrackerBase
    public let name: String
    public let category: TrackerCategory?
    public let currentLevel: Int?
    public let count: Int?
    public let timerSeconds: Int64?
    public let remainingSeconds: Int64?
    /// 仅当 isUpgrading 且 currentLevel 存在时为 currentLevel + 1；否则 nil。
    public let nextLevel: Int?
    /// 目录给出的「升级到下一级」完整时长（表语义感知）；升级中与非升级已命中项
    /// （未满级）均推断（下一级 = 当前 + 1），目录未命中、已满级或时长缺失时 nil。
    /// 注意 nextLevel 字段仍只在升级中推断（#14 契约），duration 与其解耦。
    public let nextLevelDurationSeconds: Int64?
    public let maxLevel: Int?
    public let status: VillageItemStatus
    public let missingReason: String?
    public let icon: CatalogAssetRef?
    public let levelVisual: CatalogAssetRef?
    /// 当前等级（currentLevel）匹配的 CatalogLevel 资产（level-level，Issue #39）：
    /// 列表行/详情头部按 currentLevel 显示对应等级外观；无匹配等级时为 nil。
    /// 注意与 item-level 的 icon/levelVisual 区分：这两个新字段来自 currentLevel
    /// 匹配的 CatalogLevel 记录，选择优先级高于 item-level 资产（见 preferredAssetURLs）。
    public let currentLevelIcon: CatalogAssetRef?
    public let currentLevelVisual: CatalogAssetRef?
    public let isNested: Bool
    /// Issue #37：展示分类（防御/军事/精制台）；nil 表示无细分（走原分类兜底）。
    public let displayCategory: TrackerDisplayCategory?

    public var isUpgrading: Bool { (remainingSeconds ?? 0) > 0 }

    /// 计时已结束、需要重新导入确认实际等级。
    ///
    /// 条件：timer 存在且 remaining 归零（`timerSeconds != nil && remainingSeconds == 0`）。
    /// remainingSeconds 是 Int64?，`== 0` 已覆盖 nil ≠ 0 的情况（无计时直接 false）。
    /// 投影聚合层（UpgradeOverviewProjection）与 UI 行（UpgradeDisplayRow）共用此谓词，
    /// 避免两处手写条件漂移。
    public var needsReimport: Bool { timerSeconds != nil && remainingSeconds == 0 }

    /// 实例权重（issue #66 契约，聚合层与统计层共用同一来源）：
    /// count == nil → 1；count <= 0（malformed）→ 1（与 `TrackerModels.countLabel`
    /// 展示口径一致：count <= 1 不显示 ×N，按单条处理）；count > 0 → count。
    /// 非法 count 不得产生 0/负权重（issue #66 边界 3）。
    internal var instanceWeight: Int {
        guard let count, count > 0 else { return 1 }
        return count
    }

    /// 视觉资产缺失原因（用于 UI 降级提示角标）。
    ///
    /// 优先级：level-level 资产优先于 item-level（显示链首选缺失最值得提示，
    /// Issue #39 P2：currentLevel 对应等级资产 render_failed 时必须可见提示，
    /// 不能静默回退 item-level 外观）；同层级内 icon 优先（保持 #34 语义：
    /// 报告"缺失的图标类资产"）。两者均可用时返回 nil。
    /// 注意：这是缺失原因优先级，与 `preferredAssetURLs` 的显示候选顺序
    /// （currentLevelVisual → currentLevelIcon → levelVisual → icon）不同维
    /// 度，勿混用。当前 bundled 目录（18.400.13）：部分等级资产带缺失原因
    /// （export_not_found / render_failed）；UI 依据该值给出可见缺失状态。
    public var assetMissingReason: String? {
        currentLevelIcon?.missingReason
            ?? currentLevelVisual?.missingReason
            ?? icon?.missingReason
            ?? levelVisual?.missingReason
    }

    /// 视觉资产候选 URL（运行时文件存在性过滤）：
    /// 精制台模组/父级类型图标 → currentLevelVisual → currentLevelIcon → levelVisual → icon。
    /// 精制台嵌套项的图标来自 APK 资源，不属于静态目录的 item/level join；其余项
    /// 继续使用原有 4 级目录资产回退链。
    /// `bundledURL` 仅在 isRenderable 且 Bundle 文件真实存在时返回 URL，因此
    /// 「元数据可渲染但文件缺失」的候选自动过滤——UI 对返回数组依次做 NSImage
    /// 加载探测，实现逐级回退链。前两级为 level-level 资产（Issue #39 按
    /// currentLevel 显示对应等级外观，来自 CatalogLevel），优先级高于
    /// item-level 的 levelVisual/icon；后两级为 item-level 资产（Issue #34）。
    /// 列表行与详情 sheet 必须共用本解析防漂移。
    public func preferredAssetURLs(version: String) -> [URL] {
        let craftTableAsset: CatalogAssetRef?
        if isNested {
            craftTableAsset = ModuleUpgradeIconCatalog.asset(for: dataID)
                ?? CraftTableTypeIconCatalog.asset(for: dataID)
        } else {
            craftTableAsset = nil
        }
        return CatalogAssetRef.availableURLs(
            [craftTableAsset, currentLevelVisual, currentLevelIcon, levelVisual, icon],
            version: version
        )
    }

    init(
        id: String,
        section: String,
        dataID: Int64,
        base: TrackerBase,
        name: String,
        category: TrackerCategory?,
        currentLevel: Int?,
        count: Int?,
        timerSeconds: Int64?,
        remainingSeconds: Int64?,
        nextLevel: Int?,
        nextLevelDurationSeconds: Int64?,
        maxLevel: Int?,
        status: VillageItemStatus,
        missingReason: String?,
        icon: CatalogAssetRef?,
        levelVisual: CatalogAssetRef?,
        currentLevelIcon: CatalogAssetRef?,
        currentLevelVisual: CatalogAssetRef?,
        isNested: Bool,
        displayCategory: TrackerDisplayCategory? = nil
    ) {
        self.id = id
        self.section = section
        self.dataID = dataID
        self.base = base
        self.name = name
        self.category = category
        self.currentLevel = currentLevel
        self.count = count
        self.timerSeconds = timerSeconds
        self.remainingSeconds = remainingSeconds
        self.nextLevel = nextLevel
        self.nextLevelDurationSeconds = nextLevelDurationSeconds
        self.maxLevel = maxLevel
        self.status = status
        self.missingReason = missingReason
        self.icon = icon
        self.levelVisual = levelVisual
        self.currentLevelIcon = currentLevelIcon
        self.currentLevelVisual = currentLevelVisual
        self.isNested = isNested
        self.displayCategory = displayCategory
    }
}

/// 一个村庄、一个基地的完整投影。
public struct VillageCatalogProjection: Sendable {
    public let villageID: UUID
    public let villageName: String
    public let base: TrackerBase
    /// 目录版本；目录不可用时 nil。
    public let catalogVersion: String?
    /// 目录是否可用于可确认统计（issue #16 完成度规则）：目录存在且版本与
    /// 期望匹配（`expectedGameVersion == nil` 时不做版本校验）。目录不可用
    /// 或版本不匹配时，完成度不得产生可确认分母——旧目录的 maxLevel 仍用于
    /// 展示（行状态/徽标），但不得支撑看似权威的百分比。
    public let catalogIsUsable: Bool
    public let items: [VillageItemState]
    public let diagnostics: [AccountDataDiagnostic]

    /// 核心入口。投影规则见本类型 doc comment。
    public static func project(
        village: VillageProfile,
        catalog: GameCatalog?,
        expectedGameVersion: String? = GameCatalog.defaultBundledVersion,
        base: TrackerBase,
        now: Date = Date()
    ) -> VillageCatalogProjection {
        var diagnostics: [AccountDataDiagnostic] = []
        let catalogIsUsable: Bool
        if let catalog {
            catalogIsUsable = expectedGameVersion.map { $0 == catalog.gameVersion } ?? true
        } else {
            catalogIsUsable = false
        }
        if catalog == nil {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: "GameCatalog/" + base.rawValue,
                message: "静态升级目录不可用，等级上限与完整时长信息将缺失。"
            ))
        } else if let expectedGameVersion, catalog?.gameVersion != expectedGameVersion {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: "GameCatalog/" + base.rawValue,
                message: "静态目录版本 \(catalog?.gameVersion ?? "?") 与期望版本 \(expectedGameVersion) 不匹配，完整时长与上限信息可能过时。"
            ))
        }

        let states = village.accountSnapshot.map { snapshot in
            aggregate(records(from: snapshot, catalog: catalog, base: base, now: now))
        } ?? []

        return VillageCatalogProjection(
            villageID: village.id,
            villageName: village.name,
            base: base,
            catalogVersion: catalog?.gameVersion,
            catalogIsUsable: catalogIsUsable,
            items: states,
            diagnostics: diagnostics
        )
    }

    // MARK: - Record derivation

    static func records(
        from snapshot: AccountSnapshot,
        catalog: GameCatalog?,
        base: TrackerBase,
        now: Date
    ) -> [VillageItemState] {
        // Issue #37：第一遍扫描构建「根父 id → dataID」映射。快照 id 是数组索引路径
        //（如 buildings:6.types.0），嵌套项归属精制台必须回查根父的 dataID。
        var rootParentDataIDs: [String: Int64] = [:]
        for item in snapshot.allObjectItems where !isNestedItem(item) {
            rootParentDataIDs[BuildingDisplayCategoryRules.rootID(of: item.id)] = item.dataID
        }
        return snapshot.allObjectItems.compactMap { item in
            map(item, in: snapshot, catalog: catalog, base: base, now: now,
                rootParentDataIDs: rootParentDataIDs)
        }
    }

    private static func isNestedItem(_ item: AccountItem) -> Bool {
        item.id.contains(".types.") || item.id.contains(".modules.")
    }

    private static func map(
        _ item: AccountItem,
        in snapshot: AccountSnapshot,
        catalog: GameCatalog?,
        base: TrackerBase,
        now: Date,
        rootParentDataIDs: [String: Int64]
    ) -> VillageItemState? {
        let isBuilderSection = item.section.hasSuffix("2")
        guard isBuilderSection == (base == .builder) else { return nil }

        let remainingSeconds = liveRemainingSeconds(
            for: item,
            snapshot: snapshot,
            at: now
        )
        let isUpgrading = (remainingSeconds ?? 0) > 0
        let category = TrackerCategory.from(section: item.section)
        let isNested = item.id.contains(".types.") || item.id.contains(".modules.")

        // Issue #37：展示分类。嵌套项按根父归属（回查第一遍扫描的根父 dataID），
        // 平铺项按自身 dataID 白名单；非 buildings/非 home 一律 nil（走原分类兜底）。
        let displayCategory = BuildingDisplayCategoryRules.displayCategory(
            section: item.section,
            dataID: item.dataID,
            base: base,
            rootParentDataID: isNested
                ? rootParentDataIDs[BuildingDisplayCategoryRules.rootID(of: item.id)]
                : nil
        )

        // 1. 类别不支持（helpers/decos/obstacles/…）。
        guard let category else {
            return VillageItemState(
                id: item.id,
                section: item.section,
                dataID: item.dataID,
                base: base,
                name: item.nameLabel,
                category: nil,
                currentLevel: item.level,
                count: item.count,
                timerSeconds: item.timerSeconds,
                remainingSeconds: remainingSeconds,
                nextLevel: nil,
                nextLevelDurationSeconds: nil,
                maxLevel: nil,
                status: .unavailable,
                missingReason: "该类别不参与升级追踪（\(item.section)）。",
                icon: nil,
                levelVisual: nil,
                currentLevelIcon: nil,
                currentLevelVisual: nil,
                isNested: isNested,
                displayCategory: displayCategory
            )
        }

        // 2. join 目录：(section, dataID) + base 防御校验。
        // 嵌套 types/modules 复用父 section（解析器行为），其 dataID 段（102M/103M）不属于
        // 任何目录 section；为避免未来 dataID 碰撞误命中父类目录物品，嵌套项一律不参与 join。
        let catalogItem = isNested ? nil : catalog?.item(section: item.section, dataID: item.dataID)
        let baseMatches = catalogItem.map { item in
            switch item.base {
            case "home": return base == .home
            case "builder": return base == .builder
            case .none: return false // capital：快照 section 不会命中，防御性视为不匹配
            default: return false
            }
        } ?? false

        // 目标等级只允许显式推断「当前等级 + 1」；当前等级未知时不推断（issue 语义）。
        let nextLevel: Int?
        if isUpgrading, let level = item.level {
            nextLevel = level + 1
        } else {
            nextLevel = nil
        }
        let nextLevelDuration: Int64?
        if baseMatches, let catalogItem {
            if let nextLevel {
                // 升级中：目标等级 = 当前 + 1（显式推断）。
                nextLevelDuration = catalog?.durationToUpgradeLevel(nextLevel: nextLevel, for: catalogItem)
            } else if let level = item.level, level < catalogItem.maxLevel {
                // 非升级且未满级（issue #16 列表规则：普通建筑显示下一等级时间）：
                // 下一级 = 当前 + 1 的目录时长；nextLevel 字段保持 nil（#14：目标等级
                // 只允许升级中显式推断）。已满级（level >= maxLevel）不推。
                nextLevelDuration = catalog?.durationToUpgradeLevel(nextLevel: level + 1, for: catalogItem)
            } else {
                nextLevelDuration = nil
            }
        } else {
            nextLevelDuration = nil
        }

        let status: VillageItemStatus
        let missingReason: String?
        if isUpgrading {
            // 升级状态独立于目录：记录在升级就是 upgrading，
            // 目录未命中时通过 missingReason 说明原因。
            status = .upgrading
            missingReason = isNested
                ? "嵌套模块/类型不参与静态目录 join（\(item.section):\(item.dataID)）。"
                : missingReasonForStatus(baseMatches: baseMatches, catalogItem: catalogItem, catalogAvailable: catalog != nil, item: item)
        } else if isNested {
            status = .unknown
            missingReason = "嵌套模块/类型不参与静态目录 join（\(item.section):\(item.dataID)）。"
        } else if let catalogItem, baseMatches {
            if item.level ?? -1 >= catalogItem.maxLevel {
                status = .maxed
            } else {
                status = .complete
            }
            missingReason = nil
        } else if catalogItem != nil {
            status = .unknown
            missingReason = "目录物品与投影基地不匹配（\(item.section):\(item.dataID)）。"
        } else if catalog == nil {
            status = .unknown
            missingReason = "静态目录不可用。"
        } else {
            status = .unknown
            missingReason = "目录未收录（\(item.section):\(item.dataID)）。"
        }

        // Issue #39：当前等级资产。按值匹配 level（目录等级号可能不连续），
        // 仅 baseMatches 且目录命中时解析；currentLevel 为 nil / 超范围 / 未收录
        // 时两字段均为 nil，UI 回退 item-level 资产（不按名称/位置猜测）。
        let currentLevelAssets: (visual: CatalogAssetRef?, icon: CatalogAssetRef?)
        if baseMatches, let catalogItem, let level = item.level {
            let matched = catalogItem.levels.first { $0.level == level }
            currentLevelAssets = (matched?.levelVisual, matched?.icon)
        } else {
            currentLevelAssets = (nil, nil)
        }

        return VillageItemState(
            id: item.id,
            section: item.section,
            dataID: item.dataID,
            base: base,
            name: catalogItem?.name ?? item.nameLabel,
            category: category,
            currentLevel: item.level,
            count: item.count,
            timerSeconds: item.timerSeconds,
            remainingSeconds: remainingSeconds,
            nextLevel: nextLevel,
            nextLevelDurationSeconds: nextLevelDuration,
            maxLevel: baseMatches ? catalogItem?.maxLevel : nil,
            status: status,
            missingReason: missingReason,
            icon: baseMatches ? catalogItem?.icon : nil,
            levelVisual: baseMatches ? catalogItem?.levelVisual : nil,
            currentLevelIcon: currentLevelAssets.icon,
            currentLevelVisual: currentLevelAssets.visual,
            isNested: isNested,
            displayCategory: displayCategory
        )
    }

    private static func missingReasonForStatus(
        baseMatches: Bool,
        catalogItem: CatalogItem?,
        catalogAvailable: Bool,
        item: AccountItem
    ) -> String? {
        if !baseMatches {
            if catalogItem != nil {
                return "目录物品与投影基地不匹配（\(item.section):\(item.dataID)）。"
            }
            if catalogAvailable {
                return "目录未收录（\(item.section):\(item.dataID)）。"
            }
            return "静态目录不可用。"
        }
        return nil
    }

    // MARK: - Aggregation

    /// 同 `(section, dataID, currentLevel, isNested)` 的非升级记录合并为一条并聚合 count；
    /// 升级记录各自保留（每个计时实例独立）。count 聚合规则：nil 计 1
    /// （一条快照记录 = 至少一个实例）。isNested 参与分组，父项与嵌套项不合并。
    /// count 归一化与饱和求和先于统计层执行：非法 count（nil/≤0）按
    /// `instanceWeight` 契约计 1（不得累加 0/负值）；和溢出时饱和到 Int.max，
    /// 聚合层不崩溃（恶意/损坏快照可含多条 count == Int.max，issue #66 边界 3）。
    private static func aggregate(_ records: [VillageItemState]) -> [VillageItemState] {
        var result: [VillageItemState] = []
        var upgradingKeys = Set<String>()
        var grouped: [String: [VillageItemState]] = [:]

        for record in records where record.isUpgrading {
            result.append(record)
            upgradingKeys.insert(aggregateKey(record))
        }
        for record in records where !record.isUpgrading {
            let key = aggregateKey(record)
            if !upgradingKeys.contains(key) {
                grouped[key, default: []].append(record)
            } else {
                // 同键已有升级记录：非升级部分单独成组（键加后缀避免冲突）。
                grouped[key + "|idle", default: []].append(record)
            }
        }

        for (_, group) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let first = group.first else { continue }
            let aggregatedCount = group.reduce(0) { acc, record in
                let (sum, overflow) = acc.addingReportingOverflow(record.instanceWeight)
                return overflow ? Int.max : sum
            }
            // 计时已结束的记录（timer 存在且 remaining 显式归零）进入聚合，但「需重新导入」
            // 信号必须保留：组内任一记录带已结束计时时，聚合项保留 timerSeconds 并将
            // remainingSeconds 置 0，UI 可据此推导「计时已结束」而不会与普通完成状态混淆。
            // remaining == nil（有 timer 无 remaining 的 malformed 记录）不算计时结束：
            // 不得强制写入 remainingSeconds = 0 而误报「待重新导入」。
            let groupHasFinishedTimer = group.contains { $0.timerSeconds != nil && $0.remainingSeconds == 0 }
            // 计时代表必须与数组顺序无关（issue #17 验收 #6）：组内多条已结束
            // 计时记录重排后聚合值不得改变。只从「已结束」记录（timer 存在且
            // remaining 显式归零）中取最早归零的计时值；malformed 记录（有 timer
            // 无 remaining）不参与代表选择，避免聚合值携带错误语义。该值仅作
            // needsReimport 信号载体（UI 对已结束行不展示具体时长）。
            let representativeTimer = group
                .filter { $0.timerSeconds != nil && $0.remainingSeconds == 0 }
                .compactMap(\.timerSeconds)
                .min()
            result.append(VillageItemState(
                id: "agg:" + first.id,
                section: first.section,
                dataID: first.dataID,
                base: first.base,
                name: first.name,
                category: first.category,
                currentLevel: first.currentLevel,
                count: aggregatedCount,
                timerSeconds: groupHasFinishedTimer ? representativeTimer : nil,
                remainingSeconds: groupHasFinishedTimer ? 0 : nil,
                nextLevel: nil,
                nextLevelDurationSeconds: first.nextLevelDurationSeconds,
                maxLevel: first.maxLevel,
                status: first.status,
                missingReason: first.missingReason,
                icon: first.icon,
                levelVisual: first.levelVisual,
                currentLevelIcon: first.currentLevelIcon,
                currentLevelVisual: first.currentLevelVisual,
                isNested: first.isNested,
                displayCategory: first.displayCategory
            ))
        }

        return result
    }

    /// 聚合键 = (section, dataID, currentLevel, isNested, 嵌套根父)。
    /// isNested 必须参与分组：父项与嵌套项可能同 section/dataID/level，
    /// 不区分会导致嵌套项被并入父项组而消失（且状态/图标按父项保留）。
    /// 根父身份必须参与：不同根父下的同 dataID/level 嵌套项合并会错标展示分类
    ///（issue #37 展示分类评审）。
    private static func aggregateKey(_ record: VillageItemState) -> String {
        let root = record.isNested ? BuildingDisplayCategoryRules.rootID(of: record.id) : ""
        return "\(record.section):\(record.dataID):\(record.currentLevel.map(String.init) ?? "nil"):\(record.isNested ? "nested" : "flat"):\(root)"
    }

    // MARK: - Live timers

    private static func liveRemainingSeconds(
        for item: AccountItem,
        snapshot: AccountSnapshot,
        at now: Date
    ) -> Int64? {
        guard let remaining = item.remainingSeconds else { return nil }
        let elapsed = max(0, Int64(now.timeIntervalSince(snapshot.importedAt).rounded(.down)))
        return max(0, remaining - elapsed)
    }
}
