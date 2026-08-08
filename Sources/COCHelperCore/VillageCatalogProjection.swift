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
    /// Issue #67 fail-closed：目录有 prerequisite requirement（TH/BH/Lab/StarLab/
    /// HeroHall）但快照缺少对应解锁建筑记录，无法验证当前阶段上限。
    /// 不判 maxed/complete、不推断下一级、不计入完成度 known——「无法验证」
    /// 不得伪装成「未满级」或「满级」（#70 契约）。
    case unverified
}

/// 单个物品的「下一等级」投影语义（Issue #68）。
/// UI 三处（列表行/详情 sheet/组卡）必须消费本字段，禁止各自 currentLevel + 1 推导。
public enum VillageNextUpgrade: Hashable, Sendable {
    /// 可操作升级：未达阶段上限，下一等级（目录真实等级）gate 全部满足。
    case available(level: Int, durationSeconds: Int64?)
    /// 阶段满级且目录存在更高等级：nextLevel 是第一个超过 currentStageMax 的真实
    /// 等级，requirements 为其解锁条件；referenceDurationSeconds 是「解锁后参考」
    /// 时长，UI 不得与 available 混用（不得显示为当前可操作升级时长）。
    /// 异常快照（currentLevel ≥ currentStageMax 且真实下一级 ≤ currentLevel）由
    /// 投影层守卫降级为 .unknown（评审 F1），本 case 恒不产生倒挂的下一级。
    case requires(nextLevel: Int, requirements: [UpgradeRequirement], referenceDurationSeconds: Int64?)
    /// 全局已满级：currentLevel >= 目录 maxLevel。
    case globalMaxed
    /// 升级中：目标等级是快照事实（非可达性判断）；durationSeconds 是目录目标等级
    /// 时长（版本不匹配/目录不可用时为 nil，不得泄漏旧目录时长）。
    case inProgressFact(level: Int, durationSeconds: Int64?)
    /// 缺 prerequisite 无法验证阶段上限（fail-closed，不推断可升级）。
    case unverified
    /// 目录不可用/版本不匹配（非升级）/未收录（fail-closed，不推断可升级）。
    case unknown
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
    ///（未满级）均推断（升级中 = 当前 + 1（#14 契约）；非升级 = 目录真实下一等级，
    /// 值匹配、非连续目录安全（Issue #68）），目录未命中、已满级或时长缺失时 nil。
    /// 注意 nextLevel 字段仍只在升级中推断（#14 契约），duration 与其解耦。
    public let nextLevelDurationSeconds: Int64?
    /// Issue #74b：`nextLevelDurationSeconds` 的伴随语义（与时长来自同一
    /// CatalogLevel 单一查表，见 `GameCatalog.catalogLevel(toUpgrade:for:)`）。
    /// nil = 无目录/未命中/超范围/满级/版本不匹配，以及目录记录
    /// durationSeconds 与 reason 双 nil 的防御场景（UI 兜底「暂无目录数据」）；
    /// 非 nil 时 UI 按状态分支展示——缺失类（initialLevel/notApplicable/
    /// sourceMissing/parseFailed）不再统一显示「暂无目录数据」。
    public let nextLevelDurationState: CatalogDurationState?
    public let maxLevel: Int?
    /// 当前玩家解锁等级下的阶段上限（Issue #67）：目录允许的最高等级受解锁建筑
    ///（大本营/实验室/英雄殿堂/建筑大师大本营/星空实验室）门槛约束。
    /// 可计算时 ≤ maxLevel（无 requirement 的 item 恒等于 maxLevel）；
    /// nil = 不可计算（快照缺 prerequisite 建筑记录）→ 满级判定回退全局 maxLevel。
    public let currentStageMaxLevel: Int?
    /// Issue #68：下一等级可达性投影（UI 三处必须消费本字段，禁止各自
    /// currentLevel + 1 推导）。nil = 嵌套项/不支持类别/目录未命中
    ///（与 nextLevelDurationSeconds 的 nil 场景一致，不参与升级追踪）。
    public let nextUpgrade: VillageNextUpgrade?
    public let status: VillageItemStatus
    /// join 语义缺失原因（目录未收录/不可用/基地不匹配等）。
    public let missingReason: String?
    /// Issue #74a：来源级标记（`CatalogItem.missingReason` 原样透传，如
    /// `deprecated_in_source`；仅 base 匹配且目录命中时非 nil）。与
    /// `missingReason`（join 语义）分离——前者表示该条目在源目录中被标记
    /// （历史数据/已废弃），后者表示投影 join 失败。
    public let catalogItemMissingReason: String?

    /// 源目录标记「已废弃」（`deprecated_in_source`）。UI 判断统一走本属性，
    /// 禁止散落魔数（Python 侧 ITEM_MISSING_REASONS 为单一值域契约）。
    public var isCatalogDeprecated: Bool {
        catalogItemMissingReason == "deprecated_in_source"
    }
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

    /// 该行的 count 是否为聚合层饱和结果（原始多条记录权重和 > Int.max，issue #66）。
    /// 统计层求和时该位并入溢出标志——饱和信息不得在链路前端丢失。
    internal var countOverflowed: Bool = false

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
        nextLevelDurationState: CatalogDurationState?,
        maxLevel: Int?,
        currentStageMaxLevel: Int? = nil,
        nextUpgrade: VillageNextUpgrade? = nil,
        status: VillageItemStatus,
        missingReason: String?,
        catalogItemMissingReason: String?,
        icon: CatalogAssetRef?,
        levelVisual: CatalogAssetRef?,
        currentLevelIcon: CatalogAssetRef?,
        currentLevelVisual: CatalogAssetRef?,
        isNested: Bool,
        displayCategory: TrackerDisplayCategory? = nil,
        countOverflowed: Bool = false
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
        self.nextLevelDurationState = nextLevelDurationState
        self.maxLevel = maxLevel
        self.currentStageMaxLevel = currentStageMaxLevel
        self.nextUpgrade = nextUpgrade
        self.status = status
        self.missingReason = missingReason
        self.catalogItemMissingReason = catalogItemMissingReason
        self.icon = icon
        self.levelVisual = levelVisual
        self.currentLevelIcon = currentLevelIcon
        self.currentLevelVisual = currentLevelVisual
        self.isNested = isNested
        self.displayCategory = displayCategory
        self.countOverflowed = countOverflowed
    }
}

// MARK: - 解锁建筑（Issue #67 阶段上限）

/// 解锁建筑的快照 dataID（真实目录契约，Task 1 落库锚定）：
/// 主村大本营 buildings:1000001、实验室 buildings:1000007、英雄殿堂 buildings:1000071；
/// 建筑大师大本营 buildings2:1000034、星空实验室 buildings2:1000046。
enum UnlockBuildingDataID {
    static let townHall: Int64 = 1_000_001
    static let laboratory: Int64 = 1_000_007
    static let heroHall: Int64 = 1_000_071
    static let builderHall: Int64 = 1_000_034
    static let starLaboratory: Int64 = 1_000_046
}

/// 玩家当前解锁建筑等级（Issue #67）。
///
/// 从快照 buildings/buildings2 按 dataID 找第一个匹配记录取其 level；
/// 快照无该建筑记录 → nil（阶段上限不可计算，满级判定回退全局）。
public struct PlayerUnlockLevels: Sendable {
    public let townHall: Int?
    public let laboratory: Int?
    public let heroHall: Int?
    public let builderHall: Int?
    public let starLaboratory: Int?

    /// 测试/合成构造入口（默认全 nil）；生产路径统一走 `init(snapshot:)`。
    public init(
        townHall: Int? = nil,
        builderHall: Int? = nil,
        laboratory: Int? = nil,
        starLaboratory: Int? = nil,
        heroHall: Int? = nil
    ) {
        self.townHall = townHall
        self.builderHall = builderHall
        self.laboratory = laboratory
        self.starLaboratory = starLaboratory
        self.heroHall = heroHall
    }

    public init(snapshot: AccountSnapshot?) {
        func firstLevel(in section: String, dataID: Int64) -> Int? {
            snapshot?.objectSections[section]?.first { $0.dataID == dataID }?.level
        }
        townHall = firstLevel(in: "buildings", dataID: UnlockBuildingDataID.townHall)
        laboratory = firstLevel(in: "buildings", dataID: UnlockBuildingDataID.laboratory)
        heroHall = firstLevel(in: "buildings", dataID: UnlockBuildingDataID.heroHall)
        builderHall = firstLevel(in: "buildings2", dataID: UnlockBuildingDataID.builderHall)
        starLaboratory = firstLevel(in: "buildings2", dataID: UnlockBuildingDataID.starLaboratory)
    }

    /// requirement 类型对应的解锁等级；nil = 快照无该建筑记录。
    func level(for requirement: UpgradeRequirement) -> Int? {
        switch requirement {
        case .townHall: return townHall
        case .builderHall: return builderHall
        case .laboratory: return laboratory
        case .starLaboratory: return starLaboratory
        case .heroHall: return heroHall
        }
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
    /// Issue #74a：目录与玩家 build 兼容性状态（展示语义，与 catalogIsUsable
    /// 分离——后者阻断完成度、前者供 UI 展示「未验证/已匹配/不匹配」）。
    public let compatibility: CatalogCompatibility
    public let items: [VillageItemState]
    public let diagnostics: [AccountDataDiagnostic]

    /// 核心入口。投影规则见本类型 doc comment。
    ///
    /// Issue #74a：`expectedGameVersion` 默认 nil——**不再自我比较**
    ///（评审定稿：不能把目录与自身比较的结果伪装成「已验证」）。默认路径产出
    /// `.unverified`（info 诊断明确「与玩家版本未验证」）；显式传入玩家 build
    /// 才可能 `.verified`/`.mismatch`。`catalogIsUsable` 语义不变：unverified
    /// 不阻断完成度（玩家 build 数据源不存在），mismatch 才 fail-closed。
    public static func project(
        village: VillageProfile,
        catalog: GameCatalog?,
        expectedGameVersion: String? = nil,
        base: TrackerBase,
        now: Date = Date()
    ) -> VillageCatalogProjection {
        var diagnostics: [AccountDataDiagnostic] = []
        let compatibility = CatalogCompatibility.resolve(
            catalog: catalog, expectedGameVersion: expectedGameVersion)
        // Issue #74a：完成度可用性由兼容性状态派生（单一判定点防漂移）。
        let catalogIsUsable = compatibility.isUsable
        switch compatibility {
        case .unavailable:
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: "GameCatalog/" + base.rawValue,
                message: "静态升级目录不可用，等级上限与完整时长信息将缺失。"
            ))
        case .unverified(let gameVersion):
            // Issue #74a：无玩家 build 时明确「未验证」，不得伪装「已匹配」。
            diagnostics.append(AccountDataDiagnostic(
                severity: .info,
                path: "GameCatalog/" + base.rawValue,
                message: "静态目录版本 \(gameVersion)；与玩家版本未验证。"
            ))
        case .mismatch(let catalogVersion, let expectedVersion):
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning,
                path: "GameCatalog/" + base.rawValue,
                message: "静态目录版本 \(catalogVersion) 与期望版本 \(expectedVersion) 不匹配，完整时长与上限信息可能过时。"
            ))
        case .verified:
            break
        }

        // 解锁建筑等级（阶段上限驱动）只推导一次，经 records 传给 map。
        let unlocks = PlayerUnlockLevels(snapshot: village.accountSnapshot)
        let states = village.accountSnapshot.map { snapshot in
            aggregate(records(
                from: snapshot, catalog: catalog, base: base, now: now,
                unlocks: unlocks, catalogIsUsable: catalogIsUsable
            ))
        } ?? []

        return VillageCatalogProjection(
            villageID: village.id,
            villageName: village.name,
            base: base,
            catalogVersion: catalog?.gameVersion,
            catalogIsUsable: catalogIsUsable,
            compatibility: compatibility,
            items: states,
            diagnostics: diagnostics
        )
    }

    // MARK: - Record derivation

    static func records(
        from snapshot: AccountSnapshot,
        catalog: GameCatalog?,
        base: TrackerBase,
        now: Date,
        unlocks: PlayerUnlockLevels,
        catalogIsUsable: Bool
    ) -> [VillageItemState] {
        // Issue #37：第一遍扫描构建「根父 id → dataID」映射。快照 id 是数组索引路径
        //（如 buildings:6.types.0），嵌套项归属精制台必须回查根父的 dataID。
        var rootParentDataIDs: [String: Int64] = [:]
        for item in snapshot.allObjectItems where !isNestedItem(item) {
            rootParentDataIDs[BuildingDisplayCategoryRules.rootID(of: item.id)] = item.dataID
        }
        return snapshot.allObjectItems.compactMap { item in
            map(item, in: snapshot, catalog: catalog, base: base, now: now,
                rootParentDataIDs: rootParentDataIDs, unlocks: unlocks,
                catalogIsUsable: catalogIsUsable)
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
        rootParentDataIDs: [String: Int64],
        unlocks: PlayerUnlockLevels,
        catalogIsUsable: Bool
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
                nextLevelDurationState: nil,
                maxLevel: nil,
                status: .unavailable,
                missingReason: "该类别不参与升级追踪（\(item.section)）。",
                catalogItemMissingReason: nil,
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

        // Issue #67：阶段上限。仅 baseMatches 且目录命中时计算。
        // - 无 requirement（equipment/capital 等）→ 返回 maxLevel（可计算）；
        // - 有 requirement 但快照缺对应解锁建筑 → nil（不可计算，见 status 分支）。
        // 必须在 nextLevelDuration 之前计算：unverified（nil）时禁止推断下一级时长。
        let stageMax: Int?
        if baseMatches, let catalogItem, catalogIsUsable {
            stageMax = currentStageMaxLevel(for: catalogItem, unlocks: unlocks)
        } else {
            stageMax = nil
        }

        // Issue #68：目录「真实下一等级」——值匹配而非 currentLevel + 1（非连续目录
        // 安全，如战斗直升机 15..35）。阶段满级（level >= stageMax 且 < maxLevel）时
        // 目标是第一个超过 stageMax 的真实等级（被门槛阻塞的目标）；否则为第一个
        // 超过当前等级的真实等级。防御性 sort：契约保证升序，防合成目录乱序。
        let realNext: CatalogLevel?
        if baseMatches, let catalogItem, let level = item.level, level < catalogItem.maxLevel {
            let threshold: Int
            if let stageMax, level >= stageMax {
                threshold = stageMax
            } else {
                threshold = level
            }
            realNext = catalogItem.levels
                .sorted(by: { $0.level < $1.level })
                .first { $0.level > threshold }
        } else {
            realNext = nil
        }

        // Issue #67 fail-closed：目录有 requirement 但快照缺 prerequisite（stageMax == nil）
        // → 非升级记录不推断下一级时长（无法验证，不得伪装成「未满级可升级」）。
        // 升级中记录（isUpgrading）不受限：目标等级已显式推断（#14 契约），时长是
        // 进行中升级的事实，与阶段上限无关。目录版本不匹配（catalogIsUsable == false）
        // → 一律不推断（旧目录时长不可信）。
        let nextLevelDuration: Int64?
        let nextLevelDurationState: CatalogDurationState?
        if baseMatches, let catalogItem, catalogIsUsable, (stageMax != nil || isUpgrading) {
            if let nextLevel {
                // 升级中：目标等级 = 当前 + 1（显式推断，#14 契约）。
                // Issue #74b：单一查表——同一 CatalogLevel 同时取秒数与状态，
                // 避免 durationToUpgradeLevel 二次查表漂移。
                let target = catalog?.catalogLevel(toUpgrade: nextLevel, for: catalogItem)
                nextLevelDuration = target?.durationSeconds
                nextLevelDurationState = target?.durationState
            } else if let level = item.level, level < (stageMax ?? catalogItem.maxLevel) {
                // 非升级且未满级（issue #16 列表规则：普通建筑显示下一等级时间）：
                // 下一级 = 目录真实下一级（Issue #68：修复非连续目录下 level + 1 推
                // 时长恒 nil）；nextLevel 字段保持 nil（#14：目标等级只允许升级中
                // 显式推断）。已满级（level >= effectiveMax）不推。
                let target = realNext.flatMap {
                    catalog?.catalogLevel(toUpgrade: $0.level, for: catalogItem)
                }
                nextLevelDuration = target?.durationSeconds
                nextLevelDurationState = target?.durationState
            } else {
                nextLevelDuration = nil
                nextLevelDurationState = nil
            }
        } else {
            nextLevelDuration = nil
            nextLevelDurationState = nil
        }

        // Issue #68：下一等级可达性投影（fail-closed，与 status 同口径）。
        // - 升级中：目标等级是快照事实（inProgressFact），与目录/阶段上限无关；
        // - 非升级：目录不可用/版本不匹配 → .unknown；缺 prereq → .unverified；
        //   全局满级 → .globalMaxed；阶段满级 → .requires（含被门槛阻塞的真实下一级）；
        //   其余 → .available（真实下一级）。
        let nextUpgrade: VillageNextUpgrade?
        if baseMatches, let catalogItem {
            if isUpgrading {
                if let level = item.level {
                    // #14 契约：仅升级中显式推断目标等级；时长在版本不匹配时不得
                    // 泄漏旧目录值（nil）。
                    let factLevel = level + 1
                    let duration = catalogIsUsable
                        ? catalog?.durationToUpgradeLevel(nextLevel: factLevel, for: catalogItem)
                        : nil
                    nextUpgrade = .inProgressFact(level: factLevel, durationSeconds: duration)
                } else {
                    // 升级中但快照当前等级未知：目标等级事实无法确定（fail-closed）。
                    nextUpgrade = .unknown
                }
            } else if !catalogIsUsable {
                // 目录版本不匹配/不可用：旧目录等级/时长不可信（与 status .unknown 同口径）。
                nextUpgrade = .unknown
            } else if let stageMax {
                if (item.level ?? -1) >= catalogItem.maxLevel {
                    // 全局满级（含 currentLevel > maxLevel 的目录过时场景）。
                    nextUpgrade = .globalMaxed
                } else if (item.level ?? -1) >= stageMax {
                    // 阶段满级且目录存在更高等级：真实下一级被门槛阻塞。
                    if let realNext {
                        // 语义守卫（评审 F1）：异常快照下当前等级可能达到或超过阶段上限
                        //（如快照 10 级、阶段上限 8——版本不匹配已被 .unknown 拦截，
                        // 此处仅损坏/过时数据可达）。此时真实下一级（9）不大于当前等级
                        //（10），会输出倒挂/重复的「下一级 9级」；fail-closed 为
                        // .unknown，不产生可操作/倒挂的下一级。正常阶段满级
                        //（currentLevel == stageMax）时 realNext 恒 > currentLevel，
                        // 不受本守卫影响。
                        if let currentLevel = item.level, realNext.level <= currentLevel {
                            nextUpgrade = .unknown
                        } else {
                            let requirements = realNext.requirements(base: catalogItem.base)
                            if requirements.isEmpty {
                                // 数据异常兜底：阶段上限之上存在无门槛等级（门槛断裂）→ 该
                                // 等级实际可达，与 stageMax 语义矛盾。按全局满级处理，不产生
                                //「需要解锁 []」的空列表误导（Issue #68 决策）。
                                nextUpgrade = .globalMaxed
                            } else {
                                nextUpgrade = .requires(
                                    nextLevel: realNext.level,
                                    requirements: requirements,
                                    referenceDurationSeconds: catalog?.durationToUpgradeLevel(
                                        nextLevel: realNext.level, for: catalogItem
                                    )
                                )
                            }
                        }
                    } else {
                        // 防御：目录无更高等级（数据异常）→ 按满级处理。
                        nextUpgrade = .globalMaxed
                    }
                } else if let realNext {
                    // 可操作升级：真实下一级 gate 全部满足（未达阶段上限）。
                    nextUpgrade = .available(
                        level: realNext.level,
                        durationSeconds: catalog?.durationToUpgradeLevel(nextLevel: realNext.level, for: catalogItem)
                    )
                } else {
                    // 防御：数据异常（未满级但无更高等级）→ 不推断可升级。
                    nextUpgrade = .unknown
                }
            } else {
                // 缺 prerequisite 解锁建筑记录：阶段上限不可计算
                //（fail-closed，不推断可升级）。
                nextUpgrade = .unverified
            }
        } else {
            // 目录未命中 / base 不匹配 / 嵌套项：不参与升级追踪。
            nextUpgrade = nil
        }

        let status: VillageItemStatus
        let missingReason: String?
        if isUpgrading {
            // 升级状态独立于目录：记录在升级就是 upgrading，
            // 目录未命中时通过 missingReason 说明原因。
            status = .upgrading
            if isNested {
                missingReason = "嵌套模块/类型不参与静态目录 join（\(item.section):\(item.dataID)）。"
            } else if baseMatches, catalogItem != nil, !catalogIsUsable {
                // Issue #68：升级中 + 目录版本不匹配——升级时长来自旧目录目标等级
                // 记录，不可信必须显式标注（旧实现 missingReasonForStatus 对
                // baseMatches 恒返回 nil，版本不匹配原因泄漏）。
                missingReason = "目录版本不匹配（\(catalog?.gameVersion ?? "?") vs 期望版本），旧目录等级/时长不可信。"
            } else {
                missingReason = missingReasonForStatus(
                    baseMatches: baseMatches, catalogItem: catalogItem,
                    catalogAvailable: catalog != nil, item: item
                )
            }
        } else if isNested {
            status = .unknown
            missingReason = "嵌套模块/类型不参与静态目录 join（\(item.section):\(item.dataID)）。"
        } else if baseMatches, catalogItem != nil, !catalogIsUsable {
            // Issue #67 fail-closed：目录版本不匹配（或不可用）时，行状态不得消费
            // 旧目录判 maxed/complete——「看似权威的满级状态」禁止（#70 契约）。
            // maxLevel 字段仍保留供 UI 展示，但 status 不产生满级判定。
            status = .unknown
            missingReason = catalog == nil
                ? "静态目录不可用。"
                : "目录版本不匹配（\(catalog?.gameVersion ?? "?") vs 期望版本），满级状态不可信。"
        } else if let catalogItem, baseMatches {
            if stageMax == nil {
                // Issue #67 fail-closed：有 prerequisite requirement 但快照缺对应
                // 解锁建筑记录（如英雄殿堂/实验室）→ 无法验证当前阶段上限。
                // 不判 maxed/complete、不计入完成度 known、不推断下一级。
                status = .unverified
                missingReason = "快照缺少 prerequisite 解锁建筑记录（大本营/实验室/英雄殿堂等），无法验证当前阶段上限。"
            } else {
                // 阶段上限优先（可计算时恒非 nil：无 requirement 时 = maxLevel）。
                // 阶段满级（stage < maxLevel）与全局满级同报 .maxed——完成度口径：
                // 阶段满级即完成，UI 用 currentStageMaxLevel 区分文案（Issue #67）。
                let effectiveMax = stageMax ?? catalogItem.maxLevel
                if item.level ?? -1 >= effectiveMax {
                    status = .maxed
                } else {
                    status = .complete
                }
                missingReason = nil
            }
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
            nextLevelDurationState: nextLevelDurationState,
            maxLevel: baseMatches ? catalogItem?.maxLevel : nil,
            currentStageMaxLevel: stageMax,
            nextUpgrade: nextUpgrade,
            status: status,
            missingReason: missingReason,
            catalogItemMissingReason: baseMatches ? catalogItem?.missingReason : nil,
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

    /// 计算单个目录 item 的当前阶段上限（Issue #67）。
    ///
    /// - 无 requirement（equipment/guardians/capital 等）→ `item.maxLevel`
    ///   （无门槛，阶段上限 == 全局上限，始终可计算）；
    /// - 任一 requirement 类型对应解锁等级为 nil（快照缺该建筑记录）→ nil
    ///   （不可计算，调用方回退全局 maxLevel，保守不误报满级）；
    /// - 否则逐级检查（目录契约 levels 升序，此处防御性 sort 保证不变量）：
    ///   该级 requirement 全部满足则作为候选；遇到第一个不满足的级即停止
    ///   （门槛随等级单调不减，目录 validate 保证），返回最高候选。
    static func currentStageMaxLevel(
        for item: CatalogItem,
        unlocks: PlayerUnlockLevels
    ) -> Int? {
        let itemRequirements = item.requirements
        guard !itemRequirements.isEmpty else { return item.maxLevel }
        // 可计算性检查：item 级存在任一 requirement 类型，其解锁等级必须已知。
        for requirement in itemRequirements where unlocks.level(for: requirement) == nil {
            return nil
        }
        var highest: Int?
        // 防御性排序：契约保证升序，此处防测试/合成目录乱序输入破坏 break 语义。
        for level in item.levels.sorted(by: { $0.level < $1.level }) {
            let satisfied = level.requirements(base: item.base).allSatisfy { requirement in
                guard let unlock = unlocks.level(for: requirement) else { return false }
                return unlock >= requirement.requiredLevel
            }
            guard satisfied else { break }
            highest = level.level
        }
        return highest
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
            // 第 7 轮：饱和求和同时记录 didOverflow——聚合行 count==Int.max 时
            // 统计层单行求和恰好 Int.max 无算术溢出，若无此标志，saturated 会在
            // 链路前端被静默丢弃（契约绕过）。饱和后各 instanceWeight ≥ 1，
            // 后续加法恒溢出，didOverflow 保持 true。
            let (aggregatedCount, countOverflowed) = group.reduce((0, false)) { acc, record in
                let (sum, overflow) = acc.0.addingReportingOverflow(record.instanceWeight)
                return overflow ? (Int.max, true) : (sum, acc.1)
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
                nextLevelDurationState: first.nextLevelDurationState,
                maxLevel: first.maxLevel,
                currentStageMaxLevel: first.currentStageMaxLevel,
                nextUpgrade: first.nextUpgrade,
                status: first.status,
                missingReason: first.missingReason,
                catalogItemMissingReason: first.catalogItemMissingReason,
                icon: first.icon,
                levelVisual: first.levelVisual,
                currentLevelIcon: first.currentLevelIcon,
                currentLevelVisual: first.currentLevelVisual,
                isNested: first.isNested,
                displayCategory: first.displayCategory,
                countOverflowed: countOverflowed
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

    static func liveRemainingSeconds(
        for item: AccountItem,
        snapshot: AccountSnapshot,
        at now: Date
    ) -> Int64? {
        guard let remaining = item.remainingSeconds else { return nil }
        let elapsed = max(0, Int64(now.timeIntervalSince(snapshot.importedAt).rounded(.down)))
        return max(0, remaining - elapsed)
    }
}
