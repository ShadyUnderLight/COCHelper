import Foundation

/// Issue #15：升级总览的展示聚合层。
///
/// 旧 `UpgradeTracker.activeRecords` 只显示快照中的进行中项目，缺少完整升级时长、
/// 目录状态与版本信息。本层在 `VillageCatalogProjection`（快照 × 静态目录 join）之上，
/// 把「全部村庄 × 全部基地」的投影结果聚合成按剩余时间排序的展示记录，供升级总览
/// UI 直接消费。
public struct UpgradeDisplayRecord: Identifiable, Hashable, Sendable {
    /// 全局唯一 id：`villageID:base:itemID`（不同村庄/不同 base/不同项目不冲突）。
    public let id: String
    public let villageID: UUID
    public let villageName: String
    public let villageTag: String?
    public let base: TrackerBase
    /// 投影项（含 nextLevel、nextLevelDurationSeconds、remainingSeconds、status 等）。
    public let item: VillageItemState
    /// 目录版本；目录不可用时 nil。
    public let catalogVersion: String?

    public var remainingSeconds: Int64? { item.remainingSeconds }

    /// 预计完成时间；remainingSeconds 不存在或非正时返回 nil。
    ///
    /// 必须传入 `UpgradeOverviewProjection.activeRecords` 调用时的同一个 `now`：
    /// 传入更晚的时间会系统性高估完成时间（now + remaining 随 now 右移）。
    public func completionDate(from now: Date) -> Date? {
        guard let remainingSeconds, remainingSeconds > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(remainingSeconds))
    }
}

/// 升级总览展示聚合入口。
public enum UpgradeOverviewProjection {
    /// 全部村庄 × 全部 base 的进行中升级记录。
    ///
    /// 每条记录由 `VillageCatalogProjection.project` 产出并过滤 `isUpgrading`；
    /// 按剩余时间升序（nil 视为最大排最后），再按 villageName、base、id 稳定排序。
    /// villageName 用 `localizedStandardCompare`（与旧层 UpgradeTracker 排序语义一致）。
    ///
    /// `now` 用于计算实时剩余时间；`completionDate(from:)` 必须回传同一个 `now`，
    /// 否则完成时间会与实际不一致（详见该方法 doc comment）。
    public static func activeRecords(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        at now: Date = Date()
    ) -> [UpgradeDisplayRecord] {
        let records = villages.flatMap { village in
            TrackerBase.allCases.flatMap { base in
                let projection = VillageCatalogProjection.project(
                    village: village,
                    catalog: catalog,
                    base: base,
                    now: now
                )
                return projection.items
                    .filter(\.isUpgrading)
                    .map { item in
                        UpgradeDisplayRecord(
                            id: village.id.uuidString + ":" + base.rawValue + ":" + item.id,
                            villageID: village.id,
                            villageName: village.name,
                            villageTag: village.tag,
                            base: base,
                            item: item,
                            catalogVersion: projection.catalogVersion
                        )
                    }
            }
        }
        return records.sorted { lhs, rhs in
            let lhsRemaining = lhs.item.remainingSeconds ?? .max
            let rhsRemaining = rhs.item.remainingSeconds ?? .max
            if lhsRemaining != rhsRemaining { return lhsRemaining < rhsRemaining }
            let villageOrder = lhs.villageName.localizedStandardCompare(rhs.villageName)
            if villageOrder != .orderedSame { return villageOrder == .orderedAscending }
            if lhs.base.rawValue != rhs.base.rawValue { return lhs.base.rawValue < rhs.base.rawValue }
            return lhs.id < rhs.id
        }
    }
}
