import Foundation

/// Issue #212：扁平 render rows 构建（纯函数）。
///
/// 保持旧 sectionCard/groupedRows/legacyRows 的顺序与分隔线语义（组按 items
/// 首现顺序、实例按快照输入序、父项先于缩进子项），只产出轻量 row 元数据。
public enum VillageDetailFlatRowProjection {
    public static func build(
        displayGroups: [VillageDetailGroup],
        statsByKey: [String: VillageCategoryCompletion],
        groupByInstanceID: [String: BuildingGroup]
    ) -> [VillageDetailFlatRow] {
        let signpostID = PerformanceSignpost.begin(
            .villageDetailFlatRowsBuild,
            dataScale: displayGroups.count,
            count: groupByInstanceID.count
        )
        var rows: [VillageDetailFlatRow] = []
        for group in displayGroups {
            if group.displayCategory == .craftTable {
                rows.append(.craftTable(
                    groupID: group.id,
                    stats: statsByKey[group.id]
                ))
                continue
            }
            rows.append(.sectionHeader(
                groupID: group.id,
                stats: statsByKey[group.id]
            ))

            var orderedGroups: [BuildingGroup] = []
            var seenGroupIDs = Set<String>()
            var fallbackItems: [VillageItemState] = []
            for item in group.items {
                if let buildingGroup = groupByInstanceID[rawRecordID(item.id)] {
                    if !seenGroupIDs.contains(buildingGroup.id) {
                        seenGroupIDs.insert(buildingGroup.id)
                        orderedGroups.append(buildingGroup)
                    }
                } else {
                    fallbackItems.append(item)
                }
            }
            for buildingGroup in orderedGroups {
                rows.append(.groupHeader(groupID: buildingGroup.id))
                for (index, instance) in buildingGroup.instances.enumerated() {
                    rows.append(.instance(
                        groupID: buildingGroup.id,
                        instanceID: instance.id,
                        leadingDivider: index > 0
                    ))
                }
            }
            let parented = VillageDetailProjection.parentedRows(from: fallbackItems)
            for (index, row) in parented.enumerated() {
                rows.append(.legacy(
                    itemID: row.item.id,
                    groupID: group.id,
                    indented: false,
                    leadingDivider: index > 0
                ))
                for child in row.children {
                    rows.append(.legacy(
                        itemID: child.id,
                        groupID: group.id,
                        indented: true,
                        leadingDivider: true
                    ))
                }
            }
        }
        PerformanceSignpost.end(
            .villageDetailFlatRowsBuild,
            id: signpostID,
            count: rows.count
        )
        return rows
    }

    /// 由 `buildingGroups` 派生实例 id → 组字典（与详情页消费一致）。
    public static func groupByInstanceID(
        from buildingGroups: [BuildingGroup]
    ) -> [String: BuildingGroup] {
        Dictionary(
            buildingGroups.flatMap { group in group.instances.map { ($0.id, group) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 聚合记录 id 归一化：`agg:` 前缀 → 原始快照记录 id。
    public static func rawRecordID(_ id: String) -> String {
        id.hasPrefix("agg:") ? String(id.dropFirst(4)) : id
    }
}
