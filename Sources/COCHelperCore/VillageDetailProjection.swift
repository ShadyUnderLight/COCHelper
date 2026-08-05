import Foundation

// MARK: - 分组

public struct VillageDetailGroup: Identifiable, Hashable, Sendable {
    public let category: TrackerCategory?
    public let items: [VillageItemState]
    public var id: String { category?.rawValue ?? "other" }

    public init(category: TrackerCategory?, items: [VillageItemState]) {
        self.category = category
        self.items = items
    }
}

// MARK: - 完成度

public struct VillageCategoryCompletion: Identifiable, Hashable, Sendable {
    public let category: TrackerCategory?
    public let knownCount: Int
    public let completedCount: Int
    public let unknownCount: Int
    public var id: String { category?.rawValue ?? "other" }
    public var completionRatio: Double? {
        knownCount > 0 ? Double(completedCount) / Double(knownCount) : nil
    }

    public init(category: TrackerCategory?, knownCount: Int, completedCount: Int, unknownCount: Int) {
        self.category = category
        self.knownCount = knownCount
        self.completedCount = completedCount
        self.unknownCount = unknownCount
    }
}

/// Issue #16：村庄详情页的分组与完成度统计。纯函数，输入为
/// `VillageCatalogProjection.project` 输出的 `[VillageItemState]`。
///
/// 完成度语义（issue #16「完成度规则」）：
/// - 分母（known）：状态非 unknown/unavailable/available，且已观测并关联目录
///   （maxLevel != nil、currentLevel != nil）且非版本不匹配
///   （upgrading 且 nextLevel > maxLevel）的项目；
/// - 完成（completed）：`status == .maxed` 且计入 known（投影层保证 maxed 时
///   currentLevel >= maxLevel；缺失目录的 maxed 不计完成，防御不可达组合）；
/// - 未知（unknown）：其余全部（unknown/unavailable/available/缺失上限/缺失等级/版本不匹配）；
/// - 快照缺失项目由投影层不产出，天然不计为 0 级。
public enum VillageDetailProjection {
    public static func groups(from items: [VillageItemState]) -> [VillageDetailGroup] {
        var buckets: [String: [VillageItemState]] = [:]
        var keyOrder: [String] = []
        for item in items {
            let key = Self.key(for: item.category)
            if buckets[key] == nil { keyOrder.append(key) }
            buckets[key, default: []].append(item)
        }
        let sortedKeys = keyOrder
            .filter { $0 != "other" }
            .sorted { (lhs, rhs) in
                guard let l = TrackerCategory(rawValue: lhs), let r = TrackerCategory(rawValue: rhs) else {
                    return lhs < rhs
                }
                return l.sortOrder < r.sortOrder
            }
            + (keyOrder.contains("other") ? ["other"] : [])
        return sortedKeys.map { key in
            VillageDetailGroup(
                category: key == "other" ? nil : TrackerCategory(rawValue: key),
                items: buckets[key] ?? []
            )
        }
    }

    /// 按分类完成度；顺序同 groups。`catalogIsUsable == false`（目录不可用或
    /// 全局版本不匹配）时不产生任何可确认分母，全部归 unknown（issue #16：
    /// 「目录无上限或版本不匹配：不纳入可确认完成度，并显示诊断」）。
    public static func completionStats(
        from items: [VillageItemState],
        catalogIsUsable: Bool = true
    ) -> [VillageCategoryCompletion] {
        groups(from: items).map { group in
            let known = catalogIsUsable ? group.items.filter { isKnown($0) }.count : 0
            let completed = catalogIsUsable ? group.items.filter { $0.status == .maxed && isKnown($0) }.count : 0
            return VillageCategoryCompletion(
                category: group.category,
                knownCount: known,
                completedCount: completed,
                unknownCount: group.items.count - known
            )
        }
    }

    /// 全村庄完成度合计。`catalogIsUsable` 语义同 `completionStats`。
    public static func totalCompletion(
        from items: [VillageItemState],
        catalogIsUsable: Bool = true
    ) -> VillageCategoryCompletion {
        let known = catalogIsUsable ? items.filter { isKnown($0) }.count : 0
        let completed = catalogIsUsable ? items.filter { $0.status == .maxed && isKnown($0) }.count : 0
        return VillageCategoryCompletion(
            category: nil,
            knownCount: known,
            completedCount: completed,
            unknownCount: items.count - known
        )
    }

    private static func key(for category: TrackerCategory?) -> String {
        category?.rawValue ?? "other"
    }

    /// 计入完成度分母的条件（见类型 doc comment）。
    private static func isKnown(_ item: VillageItemState) -> Bool {
        // unknown/unavailable：目录未命中/类别不支持；available：目录存在但快照
        // 无记录（投影层不产出）。三者均不计入可确认完成度，显式排除使
        // 不可达组合（如测试构造的 unknown + maxLevel）也归入 unknown。
        guard item.status != .unknown, item.status != .unavailable, item.status != .available else { return false }
        guard item.maxLevel != nil, item.currentLevel != nil else { return false }
        if item.isUpgrading,
           let nextLevel = item.nextLevel,
           let maxLevel = item.maxLevel,
           nextLevel > maxLevel {
            return false // 版本不匹配：目录可能过时，不纳入可确认完成度
        }
        return true
    }
}
