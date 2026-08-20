import Foundation

/// Issue #212：村庄详情扁平 row 元数据缓存。
///
/// 与 `VillageProjectionCache` 的 render 身份对齐；筛选/排序/分类变化自然
/// miss。`.remaining` 排序依赖 `now`，tick 间不缓存。View body 仍由
/// LazyVStack 按需构建；本缓存只避免重复分配 row descriptor 数组。
public final class VillageDetailFlatRowCache {
    /// 与投影缓存对齐的静态输入身份（不含 now）。
    public struct RenderIdentityKey: Hashable, Sendable {
        public let villageID: UUID
        public let villageName: String
        public let snapshotFingerprint: String
        public let base: TrackerBase
        public let manualFingerprint: String?
        public let catalogEpoch: Int
        public let catalogVersion: String?
        public let phaseBucket: PhaseBucket

        public init(
            villageID: UUID,
            villageName: String,
            snapshotFingerprint: String,
            base: TrackerBase,
            manualFingerprint: String?,
            catalogEpoch: Int,
            catalogVersion: String?,
            phaseBucket: PhaseBucket
        ) {
            self.villageID = villageID
            self.villageName = villageName
            self.snapshotFingerprint = snapshotFingerprint
            self.base = base
            self.manualFingerprint = manualFingerprint
            self.catalogEpoch = catalogEpoch
            self.catalogVersion = catalogVersion
            self.phaseBucket = phaseBucket
        }

        public init?(
            village: VillageProfile,
            base: TrackerBase,
            now: Date,
            manualUpgradeCore: ManualUpgradeCore?,
            catalogEpoch: Int,
            catalog: GameCatalog?,
            seasonalPhases: SeasonalPhaseTable
        ) {
            guard let snapshot = village.accountSnapshot else { return nil }
            self.villageID = village.id
            self.villageName = village.name
            self.snapshotFingerprint = snapshot.contentFingerprint
            self.base = base
            self.manualFingerprint = manualUpgradeCore?.contentFingerprint
            self.catalogEpoch = catalogEpoch
            self.catalogVersion = catalog?.gameVersion
            self.phaseBucket = seasonalPhases.bucket(at: now)
        }
    }

    /// 展示筛选身份（search/state/sort/category；不含 now）。
    public struct FilterKey: Hashable, Sendable {
        public let searchText: String
        public let stateFilter: UpgradeDisplayStateFilter?
        public let sortOrder: UpgradeDisplaySort
        /// 分类 chip 的稳定编码（由 UI 层提供，如 `all` / `display:walls`）。
        public let categoryFilterKey: String

        public init(
            searchText: String,
            stateFilter: UpgradeDisplayStateFilter?,
            sortOrder: UpgradeDisplaySort,
            categoryFilterKey: String
        ) {
            self.searchText = searchText
            self.stateFilter = stateFilter
            self.sortOrder = sortOrder
            self.categoryFilterKey = categoryFilterKey
        }
    }

    private struct Entry {
        let rows: [VillageDetailFlatRow]
        let groupByInstanceID: [String: BuildingGroup]
    }

    private struct Key: Hashable {
        let render: RenderIdentityKey
        let filter: FilterKey
    }

    private var entry: Entry?
    private var entryKey: Key?

    /// 构建次数（测试断言用）。
    public private(set) var buildCount = 0
    /// 命中次数（测试断言用）。
    public private(set) var hitCount = 0

    public init() {}

    public func removeAll() {
        entry = nil
        entryKey = nil
    }

    /// 取扁平 row 元数据；`sortDependsOnNow == true` 时跳过缓存（如 `.remaining`）。
    public func rows(
        renderKey: RenderIdentityKey,
        filterKey: FilterKey,
        sortDependsOnNow: Bool,
        displayGroups: [VillageDetailGroup],
        statsByKey: [String: VillageCategoryCompletion],
        buildingGroups: [BuildingGroup]
    ) -> (rows: [VillageDetailFlatRow], groupByInstanceID: [String: BuildingGroup]) {
        let key = Key(render: renderKey, filter: filterKey)
        if !sortDependsOnNow, let entry, entryKey == key {
            hitCount += 1
            return (entry.rows, entry.groupByInstanceID)
        }

        buildCount += 1
        let groupByInstanceID = VillageDetailFlatRowProjection.groupByInstanceID(
            from: buildingGroups
        )
        let built = VillageDetailFlatRowProjection.build(
            displayGroups: displayGroups,
            statsByKey: statsByKey,
            groupByInstanceID: groupByInstanceID
        )
        let newEntry = Entry(rows: built, groupByInstanceID: groupByInstanceID)
        entry = newEntry
        entryKey = key
        return (newEntry.rows, newEntry.groupByInstanceID)
    }
}
