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
    /// 目录给出的完整时长（表语义感知）；目录未命中或缺失时 nil。
    public let nextLevelDurationSeconds: Int64?
    public let maxLevel: Int?
    public let status: VillageItemStatus
    public let missingReason: String?
    public let icon: CatalogAssetRef?
    public let levelVisual: CatalogAssetRef?
    public let isNested: Bool

    public var isUpgrading: Bool { (remainingSeconds ?? 0) > 0 }

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
        isNested: Bool
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
        self.isNested = isNested
    }
}

/// 一个村庄、一个基地的完整投影。
public struct VillageCatalogProjection: Sendable {
    public let villageID: UUID
    public let villageName: String
    public let base: TrackerBase
    /// 目录版本；目录不可用时 nil。
    public let catalogVersion: String?
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
            items: states,
            diagnostics: diagnostics
        )
    }

    // MARK: - Record derivation

    private static func records(
        from snapshot: AccountSnapshot,
        catalog: GameCatalog?,
        base: TrackerBase,
        now: Date
    ) -> [VillageItemState] {
        snapshot.allObjectItems.compactMap { item in
            map(item, in: snapshot, catalog: catalog, base: base, now: now)
        }
    }

    private static func map(
        _ item: AccountItem,
        in snapshot: AccountSnapshot,
        catalog: GameCatalog?,
        base: TrackerBase,
        now: Date
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
                isNested: isNested
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
        if baseMatches, let catalogItem, let nextLevel {
            nextLevelDuration = catalog?.durationToUpgradeLevel(nextLevel: nextLevel, for: catalogItem)
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
            isNested: isNested
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

    /// 同 `(section, dataID, currentLevel)` 的非升级记录合并为一条并聚合 count；
    /// 升级记录各自保留（每个计时实例独立）。count 聚合规则：nil 计 1
    /// （一条快照记录 = 至少一个实例）。
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
            let aggregatedCount = group.reduce(0) { $0 + ($1.count ?? 1) }
            // 计时已结束的记录（timer 存在且 remaining 归零）进入聚合，但「需重新导入」信号
            // 必须保留：组内任一记录带 timer 时，聚合项保留 timerSeconds 并将 remainingSeconds
            // 置 0，UI 可据此推导「计时已结束」而不会与普通完成状态混淆。
            let groupHasFinishedTimer = group.contains { $0.timerSeconds != nil }
            result.append(VillageItemState(
                id: "agg:" + first.id,
                section: first.section,
                dataID: first.dataID,
                base: first.base,
                name: first.name,
                category: first.category,
                currentLevel: first.currentLevel,
                count: aggregatedCount,
                timerSeconds: groupHasFinishedTimer ? group.compactMap(\.timerSeconds).first : nil,
                remainingSeconds: groupHasFinishedTimer ? 0 : nil,
                nextLevel: nil,
                nextLevelDurationSeconds: nil,
                maxLevel: first.maxLevel,
                status: first.status,
                missingReason: first.missingReason,
                icon: first.icon,
                levelVisual: first.levelVisual,
                isNested: first.isNested
            ))
        }

        return result
    }

    private static func aggregateKey(_ record: VillageItemState) -> String {
        "\(record.section):\(record.dataID):\(record.currentLevel.map(String.init) ?? "nil")"
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
