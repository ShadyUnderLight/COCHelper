import Foundation

// MARK: - 分组

public struct VillageDetailGroup: Identifiable, Hashable, Sendable {
    /// 来源分类。`displayCategory != nil` 时本字段仅为归属提示（恒为 .buildings），
    /// UI 不得用它做标题/计数/筛选——必须优先 `displayCategory`（issue #37）。
    public let category: TrackerCategory?
    public let displayCategory: TrackerDisplayCategory?
    public let items: [VillageItemState]
    public var id: String {
        displayCategory?.rawValue ?? category?.rawValue ?? "other"
    }

    public init(category: TrackerCategory?, displayCategory: TrackerDisplayCategory? = nil, items: [VillageItemState]) {
        self.category = category
        self.displayCategory = displayCategory
        self.items = items
    }
}

// MARK: - 嵌套归父（issue #24）

/// 展示行：根父项（或独立项）+ 其嵌套后代（types/modules，UI 缩进显示）。
public struct VillageParentedRow: Identifiable, Hashable, Sendable {
    public let item: VillageItemState
    public let children: [VillageItemState]
    public var id: String { item.id }

    public init(item: VillageItemState, children: [VillageItemState]) {
        self.item = item
        self.children = children
    }
}

// MARK: - 完成度

public struct VillageCategoryCompletion: Identifiable, Hashable, Sendable {
    public let category: TrackerCategory?
    public let displayCategory: TrackerDisplayCategory?
    /// 实例权重语义（issue #66）：按 `count` 加权后的实例数，非聚合行数。
    /// 权重契约单一来源为 `VillageItemState.instanceWeight`
    /// （`count > 0 ? count : 1`，nil 或 ≤0 均按 1 计，floor，不产生负权重），
    /// 聚合层与统计层共用。known = 计入分母的实例数；completed = 其中
    /// 已满级的实例数；unknown = 未知实例权重独立求和（正常数据下
    /// known + unknown == Σweight；饱和数据下未知实例不因减法推导而消失）。
    public let knownCount: Int
    public let completedCount: Int
    public let unknownCount: Int

    /// 任一计数字段求和时发生溢出饱和（数据超出 Int 表示范围，仅恶意/损坏快照可达）。
    /// 饱和时数值不完整，`isFullyMaxed`/`completionRatio` 不得做权威判定（fail closed）。
    public let saturated: Bool
    public var id: String { displayCategory?.rawValue ?? category?.rawValue ?? "other" }
    public var completionRatio: Double? {
        guard !saturated, knownCount > 0 else { return nil }
        return Double(completedCount) / Double(knownCount)
    }

    /// 全部可确认且已满级（issue #53 契约）：known > 0 且无未知项且完成 == 已知，
    /// 且未饱和（fail closed：饱和时数值不完整，不做权威判定，宁可判否）。
    /// 刻意比 `completionRatio == 1.0` 更严格——unknownCount > 0 时 ratio 也可能
    /// 为 1.0（completed 只统计 maxed 项，分母仍为 known），但不得判满级。
    public var isFullyMaxed: Bool {
        !saturated && knownCount > 0 && unknownCount == 0 && completedCount == knownCount
    }

    public init(
        category: TrackerCategory?,
        displayCategory: TrackerDisplayCategory? = nil,
        knownCount: Int,
        completedCount: Int,
        unknownCount: Int,
        saturated: Bool = false
    ) {
        self.category = category
        self.displayCategory = displayCategory
        self.knownCount = knownCount
        self.completedCount = completedCount
        self.unknownCount = unknownCount
        self.saturated = saturated
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
    /// Issue #37：分组桶键。有展示分类的项（防御/军事/精制台）从 `.buildings`
    /// 拆到独立展示分类组；无细分的项走原分类兜底；category 为 nil 的项归 other。
    private enum GroupKey: Hashable {
        case display(TrackerDisplayCategory)
        case category(TrackerCategory)
        case other
    }

    private static func key(for item: VillageItemState) -> GroupKey {
        if let displayCategory = item.displayCategory {
            return .display(displayCategory)
        }
        if let category = item.category {
            return .category(category)
        }
        return .other
    }

    /// Issue #37：组是否属于「原分类」筛选。display 组（防御/军事/精制台）的
    /// category 恒为 .buildings 仅作归属提示，必须排除——否则点「建筑与防御」
    /// 会误含全部展示分类组，与 chip 计数矛盾。
    public static func matchesCategoryFilter(_ group: VillageDetailGroup, category: TrackerCategory) -> Bool {
        group.displayCategory == nil && group.category == category
    }

    /// 组顺序：展示分类组（按 sortOrder）→ 原分类组（按 sortOrder）→ other 最后。
    private static func orderedKeys(_ keys: [GroupKey]) -> [GroupKey] {
        keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case (.display(let l), .display(let r)): l.sortOrder < r.sortOrder
            case (.display, _): true
            case (_, .display): false
            case (.category(let l), .category(let r)): l.sortOrder < r.sortOrder
            case (.category, .other): true
            case (.other, _): false
            }
        }
    }

    public static func groups(from items: [VillageItemState]) -> [VillageDetailGroup] {
        var buckets: [GroupKey: [VillageItemState]] = [:]
        var keyOrder: [GroupKey] = []
        for item in items {
            let key = Self.key(for: item)
            if buckets[key] == nil { keyOrder.append(key) }
            buckets[key, default: []].append(item)
        }
        return orderedKeys(keyOrder).map { key in
            switch key {
            case .display(let dc):
                VillageDetailGroup(category: .buildings, displayCategory: dc, items: buckets[key] ?? [])
            case .category(let c):
                VillageDetailGroup(category: c, displayCategory: nil, items: buckets[key] ?? [])
            case .other:
                VillageDetailGroup(category: nil, displayCategory: nil, items: buckets[key] ?? [])
            }
        }
    }

    /// 按分类完成度；顺序同 groups。`catalogIsUsable == false`（目录不可用或
    /// 全局版本不匹配）时不产生任何可确认分母，全部归 unknown（issue #16：
    /// 「目录无上限或版本不匹配：不纳入可确认完成度，并显示诊断」）。
    ///
    /// 计数按实例权重（issue #66）：聚合行（`count > 1`）按 count 计入，
    /// 不再把行数当实例数。正常数据下 `known + unknown == Σweight` 精确成立；
    /// 恶意/损坏数据（和 > Int.max）时三列各自独立饱和，未知实例不因饱和而
    /// 消失，此时守恒退化为逐项饱和上界、三列数值仅为饱和上界而非精确值，
    /// `saturated` 标志置位驱动 fail-closed（isFullyMaxed/ratio 不判定）。
    /// 三个计数字段均为实例权重语义。
    public static func completionStats(
        from items: [VillageItemState],
        catalogIsUsable: Bool = true
    ) -> [VillageCategoryCompletion] {
        groups(from: items).map { group in
            let knownInfo = catalogIsUsable
                ? Self.instanceCountAndOverflow(of: group.items.filter { isKnown($0) })
                : (count: 0, didOverflow: false)
            let completedInfo = catalogIsUsable
                ? Self.instanceCountAndOverflow(of: group.items.filter { $0.status == .maxed && isKnown($0) })
                : (count: 0, didOverflow: false)
            // unknown 独立求和（不再用减法推导）：catalogIsUsable == false 时
            // 已知侧归 0，全部权重进 unknown（issue #16「全部归 unknown」）；
            // 目录可用时仅统计未知侧，正常数据下与减法等价，饱和时不丢实例。
            let unknownInfo = Self.instanceCountAndOverflow(
                of: catalogIsUsable ? group.items.filter { !isKnown($0) } : group.items
            )
            return VillageCategoryCompletion(
                category: group.category,
                displayCategory: group.displayCategory,
                knownCount: knownInfo.count,
                completedCount: completedInfo.count,
                unknownCount: unknownInfo.count,
                saturated: knownInfo.didOverflow || completedInfo.didOverflow || unknownInfo.didOverflow
            )
        }
    }

    /// 全村庄完成度合计。`catalogIsUsable` 语义同 `completionStats`。
    /// 计数按实例权重（issue #66）。正常数据下 `known + unknown == Σweight`
    /// 精确成立；恶意/损坏数据（和 > Int.max）时三列各自独立饱和，未知实例
    /// 不因饱和而消失，此时守恒退化为逐项饱和上界、三列数值仅为饱和上界而
    /// 非精确值，`saturated` 标志置位驱动 fail-closed（isFullyMaxed/ratio 不判定）。
    public static func totalCompletion(
        from items: [VillageItemState],
        catalogIsUsable: Bool = true
    ) -> VillageCategoryCompletion {
        let knownInfo = catalogIsUsable
            ? Self.instanceCountAndOverflow(of: items.filter { isKnown($0) })
            : (count: 0, didOverflow: false)
        let completedInfo = catalogIsUsable
            ? Self.instanceCountAndOverflow(of: items.filter { $0.status == .maxed && isKnown($0) })
            : (count: 0, didOverflow: false)
        let unknownInfo = Self.instanceCountAndOverflow(
            of: catalogIsUsable ? items.filter { !isKnown($0) } : items
        )
        return VillageCategoryCompletion(
            category: nil,
            knownCount: knownInfo.count,
            completedCount: completedInfo.count,
            unknownCount: unknownInfo.count,
            saturated: knownInfo.didOverflow || completedInfo.didOverflow || unknownInfo.didOverflow
        )
    }

    // MARK: - 实例权重（issue #66）

    /// 按实例权重求和（单一契约在 `VillageItemState.instanceWeight`，issue #66）。
    /// 仅供本文件统计函数内部使用；UI 分类 chip 计数经 completionStats 的 known+unknown
    /// 派生（见 VillageDetailView），不直接调用本函数。聚合行（count > 1，如 6 门 21 级
    /// 加农炮）按 count 计入，避免把行数当实例数。溢出防御：恶意/损坏快照可含
    /// `count == Int.max`，加法溢出时饱和到 Int.max——debug/release 均不崩溃、
    /// 不产生垃圾负数（审核 A Minor 1）。
    internal static func instanceCount(of items: [VillageItemState]) -> Int {
        instanceCountAndOverflow(of: items).count
    }

    /// 同 `instanceCount`，额外返回是否发生溢出饱和（任一加法和溢出）。
    /// 饱和后 count 保持 Int.max，后续加法继续溢出，didOverflow 恒 true；
    /// 恰好等于 Int.max 无溢出则 false（精确）。
    internal static func instanceCountAndOverflow(of items: [VillageItemState]) -> (count: Int, didOverflow: Bool) {
        var didOverflow = false
        let count = items.reduce(0) { acc, item in
            let (sum, overflow) = acc.addingReportingOverflow(item.instanceWeight)
            if overflow {
                didOverflow = true
                return Int.max
            }
            return sum
        }
        return (count, didOverflow)
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

    // MARK: - 嵌套归父（issue #24）

    /// 把嵌套 types/modules 项归入最近的非嵌套祖先（根父）下，供 UI 缩进展示。
    ///
    /// 规则（issue #24「父项 id 前缀匹配」）：
    /// - 平铺项（非嵌套）独立成行；嵌套项挂到根父的 `children`；
    /// - 嵌套项 id 形如 `section:path`（如 `buildings:5.types.0.modules.2`），从最后
    ///   一段逐级截断上溯，直到路径段不再含 `types`/`modules`（即根父）；
    /// - 父项 id 可能带 `agg:` 前缀（聚合后 id = `agg:` + 原始 id），匹配时归一化忽略；
    /// - 同一归一化父 id 可能对应多个平铺项（升级记录单独保留 + 聚合项并存），
    ///   children 只挂到输入中最先出现的那个，其余行 children 为空；
    /// - 根父不在输入中（防御：父项被 UI 过滤）时，嵌套项独立成行，信息不丢失；
    /// - 行与 children 均保持输入相对顺序。
    public static func parentedRows(from items: [VillageItemState]) -> [VillageParentedRow] {
        let flatNormalizedIDs = Set(items.filter { !$0.isNested }.map { Self.normalizedID($0.id) })
        var childrenByRoot: [String: [VillageItemState]] = [:]
        for item in items where item.isNested {
            if let root = Self.rootParentPath(of: item.id), flatNormalizedIDs.contains(root) {
                childrenByRoot[root, default: []].append(item)
            }
        }

        var rows: [VillageParentedRow] = []
        var seenRoots = Set<String>()
        for item in items {
            if item.isNested {
                // 孤儿（根父不在输入中）：原位成行，保持输入相对顺序（P3）。
                if let root = Self.rootParentPath(of: item.id), flatNormalizedIDs.contains(root) {
                    continue // 已挂到根父 children，不占行
                }
                rows.append(VillageParentedRow(item: item, children: []))
            } else {
                let key = Self.normalizedID(item.id)
                let children = seenRoots.contains(key) ? [] : (childrenByRoot[key] ?? [])
                seenRoots.insert(key)
                rows.append(VillageParentedRow(item: item, children: children))
            }
        }
        return rows
    }

    /// 归一化聚合前缀：`agg:xxx` → `xxx`。
    private static func normalizedID(_ id: String) -> String {
        id.hasPrefix("agg:") ? String(id.dropFirst(4)) : id
    }

    /// id 是否仍处于嵌套路径：`:` 后的路径段含 `types` 或 `modules` 段。
    ///
    /// 注意不能对整个字符串做 `contains(".modules.")`：截断数字段后的中间态
    /// （如 `heroes:0.modules`）没有尾点，会误判为平铺提前返回。
    private static func isNestedPath(_ id: String) -> Bool {
        guard let colon = id.firstIndex(of: ":") else { return false }
        let path = id[id.index(after: colon)...]
        return path.split(separator: ".").contains { $0 == "types" || $0 == "modules" }
    }

    /// 嵌套项 id → 最近的非嵌套祖先（根父）的归一化 id；无法推导时返回 nil。
    ///
    /// 从最后一段逐级截断上溯，直到路径段不再含 `types`/`modules` 段。
    /// 中间态（如 `heroes:0.modules`）不是合法快照 id，仅作为上溯过程
    /// 经过的状态；最终根父形如 `heroes:0`（与真实快照父项 id 一致）。
    private static func rootParentPath(of id: String) -> String? {
        var current = id
        while Self.isNestedPath(current) {
            guard let dot = current.lastIndex(of: ".") else { return nil }
            current = String(current[..<dot])
        }
        return Self.normalizedID(current)
    }
}
