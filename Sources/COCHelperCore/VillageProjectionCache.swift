//  Issue #200：静态村庄投影缓存。
import Foundation
//
//  Village Detail 每 60s tick 会完整重跑 目录投影 + 组卡投影 + 精制台投影。
//  其中绝大部分（目录解析、effective state、进度、诊断）在「内容身份」
//  （快照、manual core、目录 epoch、base、seasonal phase bucket）不变时是
//  幂等的——真正随时间变化的只有 remainingSeconds 递减与到期翻转。
//
//  本缓存：相同 key 只构建一次静态投影，tick 之间做 O(records) 的动态刷新；
//  到期（remaining >0 → 0）意味着「完成事实」翻转，立即重建（与现状每 tick
//  重建的行为一致，不自行推断完成事实）。
//
//  设计约束：
//  - 同步缓存，无后台计算/actor；调用方（AppModel）持有于主 actor。
//  - key 不含 now：时间维度收敛到 PhaseBucket（bucket 内 seasonal
//    availability 恒定），命中后在 builtAt 基础上动态刷新。
//  - buildingGroups 不入条目：每 tick 从刷新后的 projection 派生
//    （O(records)），保证与 detail/overview 消费一致。
//  - 内容身份变化 → 自动 miss → 重建，无需显式 invalidate。
//  - 不修改 snapshotHistoryProjectionCache / 历史缓存语义（#200 范围外）。
public final class VillageProjectionCache {
    // MARK: - 类型

    /// 单次 render 的完整输出（与 VillageDetailView 消费一致）。
    public struct RenderResult {
        public let projection: VillageCatalogProjection
        public let buildingGroups: [BuildingGroup]
        public let craftTable: [CraftTableDefenseState]

        public init(
            projection: VillageCatalogProjection,
            buildingGroups: [BuildingGroup],
            craftTable: [CraftTableDefenseState]
        ) {
            self.projection = projection
            self.buildingGroups = buildingGroups
            self.craftTable = craftTable
        }
    }

    /// 内容身份 key（不含 now）。
    struct Key: Hashable {
        let villageID: UUID
        let snapshot: AccountSnapshot
        let base: TrackerBase
        let manualCore: ManualUpgradeCore?
        let catalogEpoch: Int
        let catalogVersion: String?
        let phaseBucket: PhaseBucket
    }

    private struct Entry {
        let builtAt: Date
        let projection: VillageCatalogProjection
        let craftTable: [CraftTableDefenseState]
    }

    // MARK: - 状态

    private var entries: [Key: Entry] = [:]

    /// 静态投影构建次数（测试断言用）。
    public private(set) var buildCount = 0
    /// 缓存命中次数（测试断言用）。
    public private(set) var hitCount = 0

    public let maxEntries: Int

    public init(maxEntries: Int = 64) {
        self.maxEntries = max(1, maxEntries)
    }

    // MARK: - 入口

    /// 取村庄静态投影（缓存命中则动态刷新）。返回与直接构建完全一致的输出。
    public func render(
        village: VillageProfile,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        base: TrackerBase,
        now: Date,
        manualUpgradeCore: ManualUpgradeCore?,
        catalogEpoch: Int
    ) -> RenderResult {
        guard let snapshot = village.accountSnapshot else {
            // 无快照无法投影（project 对 nil snapshot 容忍）；直接构建、不缓存。
            let projection = VillageCatalogProjection.project(
                village: village,
                catalog: catalog,
                seasonalPhases: seasonalPhases,
                craftTableCatalog: craftTableCatalog,
                base: base,
                now: now,
                manualUpgradeCore: manualUpgradeCore
            )
            return RenderResult(
                projection: projection,
                buildingGroups: BuildingGroupProjection.project(
                    projection: projection,
                    catalog: catalog,
                    base: base,
                    manualUpgradeCore: manualUpgradeCore
                ),
                craftTable: []
            )
        }

        let key = Key(
            villageID: village.id,
            snapshot: snapshot,
            base: base,
            manualCore: manualUpgradeCore,
            catalogEpoch: catalogEpoch,
            catalogVersion: catalog?.gameVersion,
            phaseBucket: seasonalPhases.bucket(at: now)
        )

        // 命中 → 动态刷新；任何到期 → 重建（完成事实不推断）。
        if let entry = entries[key] {
            let refreshed = entry.projection.refreshingTimers(at: now, builtAt: entry.builtAt)
            let craftRefreshed = entry.craftTable.refreshingModules(at: now, builtAt: entry.builtAt)
            if refreshed.expired || craftRefreshed.expired {
                return buildAndStore(
                    village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
                    seasonalPhases: seasonalPhases, base: base, now: now,
                    manualUpgradeCore: manualUpgradeCore, key: key
                )
            }
            hitCount += 1
            return RenderResult(
                projection: refreshed.projection,
                buildingGroups: BuildingGroupProjection.project(
                    projection: refreshed.projection,
                    catalog: catalog,
                    base: base,
                    manualUpgradeCore: manualUpgradeCore
                ),
                craftTable: craftRefreshed.modules
            )
        }

        return buildAndStore(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: seasonalPhases, base: base, now: now,
            manualUpgradeCore: manualUpgradeCore, key: key
        )
    }

    public func removeAll() {
        entries.removeAll()
    }

    // MARK: - 内部

    private func buildAndStore(
        village: VillageProfile,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        base: TrackerBase,
        now: Date,
        manualUpgradeCore: ManualUpgradeCore?,
        key: Key
    ) -> RenderResult {
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            seasonalPhases: seasonalPhases,
            craftTableCatalog: craftTableCatalog,
            base: base,
            now: now,
            manualUpgradeCore: manualUpgradeCore
        )
        let craftTable = CraftTableProjection.project(
            village: village,
            catalog: craftTableCatalog,
            base: base,
            seasonalPhases: seasonalPhases,
            now: now
        )
        let buildingGroups = BuildingGroupProjection.project(
            projection: projection,
            catalog: catalog,
            base: base,
            manualUpgradeCore: manualUpgradeCore
        )

        if entries.count >= maxEntries {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = Entry(builtAt: now, projection: projection, craftTable: craftTable)
        buildCount += 1

        return RenderResult(
            projection: projection,
            buildingGroups: buildingGroups,
            craftTable: craftTable
        )
    }
}