//  Issue #200：静态村庄投影缓存。
//  Issue #210：key 轻量化（内容指纹 + 显示名称），改名自然 miss。
import Foundation
//
//  Village Detail 每 60s tick 会完整重跑 目录投影 + 组卡投影 + 精制台投影。
//  其中绝大部分（目录解析、effective state、进度、诊断）在「内容身份」
//  （快照、manual core、目录 epoch、base、seasonal phase bucket、显示名称）
//  不变时是幂等的——真正随时间变化的只有 remainingSeconds 递减与到期翻转。
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
//  - 内容身份变化 → 自动 miss → 重建，无需显式 invalidate：
//    key 用 AccountSnapshot.contentFingerprint / ManualUpgradeCore
//    .contentFingerprint（init 一次性生成）表示快照与 manual 身份，
//    villageName 直接入 key（改名 → 重建），tick 查找不再 Hash 完整
//    payload（issue #210 目标 3）。
//  - 不修改 snapshotHistoryProjectionCache / 历史缓存语义（#200 范围外）。
public final class VillageProjectionCache {
    // MARK: - 类型

    /// 单次 render 的完整输出（与 VillageDetailView 消费一致）。
    public struct RenderResult {
        public let projection: VillageCatalogProjection
        public let buildingGroups: [BuildingGroup]
        public let craftTable: [CraftTableDefenseState]
        /// Issue #212：静态投影构建代次。普通 timer refresh 不变；`buildAndStore`
        ///（含 timer expiry）递增，供 flat-row cache 与动态语义重建对齐。
        public let projectionGeneration: UInt64

        public init(
            projection: VillageCatalogProjection,
            buildingGroups: [BuildingGroup],
            craftTable: [CraftTableDefenseState],
            projectionGeneration: UInt64
        ) {
            self.projection = projection
            self.buildingGroups = buildingGroups
            self.craftTable = craftTable
            self.projectionGeneration = projectionGeneration
        }
    }

    /// 内容身份 key（不含 now；Issue #210：轻量身份，不用完整值类型）。
    ///
    /// 快照/manual core 用「init 时一次性生成的 contentFingerprint」表示
    /// 内容身份：每次 tick 的字典查找只 Hash 两个短字符串 + 小标量，
    /// 不遍历快照（含 originalText 大字符串）与 manual core（records 增长）。
    /// villageName 属于显示身份：改名 → 新 key → 自然 miss 重建。
    /// （不得用 updatedAt/Date/数组地址冒充内容身份——issue #210 红线。）
    struct Key: Hashable {
        let villageID: UUID
        let villageName: String
        let snapshotFingerprint: String
        let base: TrackerBase
        let manualFingerprint: String?
        let catalogEpoch: Int
        let catalogVersion: String?
        let phaseBucket: PhaseBucket
    }

    private struct Entry {
        let builtAt: Date
        /// 计时锚点（与 `liveRemainingSeconds` 同一语义；刷新用
        /// `floor(now - importedAt) - floor(builtAt - importedAt)` 精确对齐）。
        let importedAt: Date
        let projection: VillageCatalogProjection
        let craftTable: [CraftTableDefenseState]
        /// 本条目最后一次 `buildAndStore` 的代次（timer refresh 不递增）。
        let projectionGeneration: UInt64
        /// LRU 驱逐时间戳（命中/构建时更新）。
        var lastUsedAt: Date
    }

    // MARK: - 状态

    private var entries: [Key: Entry] = [:]
    private var nextProjectionGeneration: UInt64 = 1

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
                craftTable: [],
                projectionGeneration: allocateProjectionGeneration()
            )
        }

        let key = Key(
            villageID: village.id,
            villageName: village.name,
            snapshotFingerprint: snapshot.contentFingerprint,
            base: base,
            manualFingerprint: manualUpgradeCore?.contentFingerprint,
            catalogEpoch: catalogEpoch,
            catalogVersion: catalog?.gameVersion,
            phaseBucket: seasonalPhases.bucket(at: now)
        )

        // 命中 → 动态刷新；任何到期 → 重建（完成事实不推断）。
        if let entry = entries[key] {
            let refreshed = entry.projection.refreshingTimers(
                at: now, builtAt: entry.builtAt, importedAt: entry.importedAt
            )
            let craftRefreshed = entry.craftTable.refreshingModules(
                at: now, builtAt: entry.builtAt, importedAt: entry.importedAt
            )
            if refreshed.expired || craftRefreshed.expired {
                return buildAndStore(
                    village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
                    seasonalPhases: seasonalPhases, base: base, now: now,
                    manualUpgradeCore: manualUpgradeCore, importedAt: snapshot.importedAt, key: key
                )
            }
            hitCount += 1
            entries[key]?.lastUsedAt = now
            return RenderResult(
                projection: refreshed.projection,
                buildingGroups: BuildingGroupProjection.project(
                    projection: refreshed.projection,
                    catalog: catalog,
                    base: base,
                    manualUpgradeCore: manualUpgradeCore
                ),
                craftTable: craftRefreshed.modules,
                projectionGeneration: entry.projectionGeneration
            )
        }

        return buildAndStore(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: seasonalPhases, base: base, now: now,
            manualUpgradeCore: manualUpgradeCore, importedAt: snapshot.importedAt, key: key
        )
    }

    public func removeAll() {
        entries.removeAll()
        // Issue #212 review P2：不重置 generation——它是跨 cache 的 invalidation
        // token；重置可能导致 flat-row cache 与重建后的 projection 碰撞。
    }

    // MARK: - 内部

    private func allocateProjectionGeneration() -> UInt64 {
        let generation = nextProjectionGeneration
        nextProjectionGeneration += 1
        return generation
    }

    private func buildAndStore(
        village: VillageProfile,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        base: TrackerBase,
        now: Date,
        manualUpgradeCore: ManualUpgradeCore?,
        importedAt: Date,
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

        // Issue #210 review P2：改名（villageName 入 key）插入新 key 时删除
        // 同村庄（villageID + base）的旧 key 条目——旧名不可能再被请求，
        // 残留条目会让 32 村 × 2 基地顶满 maxEntries 时触发 LRU 驱逐其他村庄。
        // （`$0 != key`：到期重建路径 key 已存在，防止误删当前条目。）
        if let stale = entries.keys.first(where: {
            $0.villageID == key.villageID && $0.base == key.base && $0 != key
        }) {
            entries.removeValue(forKey: stale)
        }

        // 容量满：驱逐最久未命中的单条（LRU），不清空其余条目——
        // 全清会让 32+ 村庄 × 2 基地（>64 条）在遍历中反复清空、tick 全 miss
        // （外部 review P2）。
        if entries.count >= maxEntries,
           let oldest = entries.min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt }) {
            entries.removeValue(forKey: oldest.key)
        }
        let projectionGeneration = allocateProjectionGeneration()
        entries[key] = Entry(
            builtAt: now, importedAt: importedAt,
            projection: projection, craftTable: craftTable,
            projectionGeneration: projectionGeneration,
            lastUsedAt: now
        )
        buildCount += 1

        return RenderResult(
            projection: projection,
            buildingGroups: buildingGroups,
            craftTable: craftTable,
            projectionGeneration: projectionGeneration
        )
    }
}