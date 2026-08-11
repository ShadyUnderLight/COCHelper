# Issue #37 展示分类拆分实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把村庄详情页的单一「建筑与防御」分类拆分为「防御建筑 / 军事设施 / 精制台」三个展示分类，未知 ID 安全兜底不丢失。

**Architecture:** 新增独立展示分类层 `TrackerDisplayCategory`（枚举）+ `BuildingDisplayCategoryRules`（集中式 dataID 白名单规则表），`VillageItemState` 增加 `displayCategory` 字段（投影时计算，聚合透传）；`VillageDetailProjection` 分组/统计切换到展示分类；UI 三层（筛选 chip、分组标题、行副标题/图标/颜色）消费展示分类。保留 `TrackerCategory` 完全不动（来源/兼容层，快照与目录 join 不受影响）。

**Tech Stack:** Swift 6 / SwiftPM（Package.swift），COCHelperCore 库 + COCHelper App 目标，XCTest。

**基线:** `main@0b1625e6146faf1a82248c46956709b380848d3c`（383 测试通过）。Worktree: `.worktrees/feat-issue37-display-category`，分支 `feat/issue37-display-category`。

---

## 设计分析（SDD：设计）

### 数据事实（已验证）

- `TrackerCategory.from(section:)` 把 `buildings`/`buildings2` 归一到 `.buildings`（`TrackerModels.swift:80-93`），`.buildings.title == "建筑与防御"`（L39）。
- 目录 `catalog.json` 中 `buildings` 73 项、`buildings2` 32 项，原始 `category` 字段全部为 `"buildings"`，**无法作为分类依据** → 必须 dataID 白名单。
- 精制台结构：`buildings:1000097`（名「精制台」）、`types:103000011..013`（火热蜡烛/英雄猎台/蛋糕投掷器）、`modules:102000033..041`，全部存在于 `account_name_catalog.json`；匿名真实快照 fixture 含完整嵌套。
- **id 格式**：`AccountItem.id = section + ":" + 数组索引路径`（`AccountSnapshot.swift:414`），如 `buildings:6`、`buildings:6.types.0.modules.2`。**根父 id 不含 dataID** → 嵌套项归属精制台必须通过「平铺项 id → dataID」映射（在 `VillageCatalogProjection` 内第一遍扫描构建）。
- **关键约束**：`VillageDetailView.swift:54` 过滤 `status != .unavailable`（category == nil 的项全被过滤）→ 兜底（资源建筑/大本营/未知 ID）**必须保留在 `.buildings` 组**（displayCategory == nil），不能落入 category == nil，否则项目从详情页消失。

### 3 候选方案（投票点）

| 候选 | 方案 | 评价 |
|---|---|---|
| **A（推荐）** | `VillageItemState` 预计算 `displayCategory` 字段；`VillageDetailProjection` 按它分组；`TrackerCategory` 保留 | 单一计算点、聚合透传简单、测试最直接；UI 无逻辑 |
| B | `VillageDetailProjection.groups` 分组时动态调规则表 | 规则表需在 Core 暴露并重解析根父映射（每 tick 重算），聚合层与分组层口径易漂移 |
| C | 直接改 `TrackerCategory` 枚举加 case | 破坏快照 section→category 映射、目录 join、`sortOrder`、现有 9 处测试断言；issue 明确反对 |

**投票结论（实施前确认）：A。** 分组 key 采用结构化 `GroupKey`（display / category / other）而非字符串拼接，避免 key 碰撞。

### 类型契约

```swift
// Sources/COCHelperCore/BuildingDisplayCategory.swift（新文件；Issue #123 增补 walls）
public enum TrackerDisplayCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case defense, walls, military, craftTable
    public var id: String { rawValue }
    public var title: String { /* 防御建筑 / 城墙 / 军事设施 / 精制台 */ }
    public var systemImage: String { /* shield.lefthalf.filled / square.grid.3x3 / figure.arms.open / hammer.fill */ }
    public var sortOrder: Int { /* 0 / 1 / 2 / 3 */ }
}

public enum BuildingDisplayCategoryRules {
    public static let craftTableDataID: Int64 = 1000097
    /// 平铺 id（"buildings:6.types.0"）→ 根父 id（"buildings:6"）；无 "." 时返回原 id。
    public static func rootID(of id: String) -> String
    /// 主分类判定。section 非 "buildings" 或 base 非 .home 一律 nil（兜底走原分类）。
    /// rootParentDataID：嵌套项传根父 dataID，平铺项传 nil。
    public static func displayCategory(
        section: String, dataID: Int64, base: TrackerBase, rootParentDataID: Int64?
    ) -> TrackerDisplayCategory?
}
```

- `VillageItemState` 增加 `public let displayCategory: TrackerDisplayCategory?`（init 参数默认 `= nil`，置于 `isNested` 之后）。
- `VillageDetailGroup` 增加 `public let displayCategory: TrackerDisplayCategory?`；`id = displayCategory?.rawValue ?? category?.rawValue ?? "other"`。
- `VillageCategoryCompletion` 增加 `public let displayCategory: TrackerDisplayCategory?`；id 同上。
- UI `CategoryFilter` 增加 `case display(TrackerDisplayCategory)`。

### 白名单规则表（Task 0 投票结论：3 agent 投票，多数票 + 保守原则）

**投票汇总（2026-08-06）**：
- 防御/军事/兜底 3 票一致项全部采纳；分歧项（6 个 Lv1 加农炮变体 1000060/87/88/94/95/96、英雄祭坛 1000022/25/30/66）按多数票（2:1）进兜底。
- 兜底依据：Lv1 加农炮变体 TH 需求=1000（事件建筑）、exportName 前缀 `ch_`/`clashmas24_`/`deco_`/`candy_cage`/`sour_elixir`；英雄祭坛按 issue 定义归兜底。
- 新防御（1000077/79/84/85/86/89/102）3 票一致确认是正式主世界防御（Multi-Gear Tower/Multi-Archer Tower/Ricochet Cannon/Revenge Tower/Firespitter/Super Wizard Tower/Monolith），纳入防御。

- **防御**（20 项，3 票一致；原 21 项含 1000010 城墙，Issue #123 已迁出至「城墙」）：`1000008, 1000009, 1000011, 1000012, 1000013, 1000019, 1000021, 1000027, 1000028, 1000031, 1000032, 1000067, 1000072, 1000077, 1000079, 1000084, 1000085, 1000086, 1000089, 1000102`
- **城墙**（1 项，Issue #123 新增展示分类）：`1000010`（仅 home；buildings2:1000033 夜世界城墙、capital_buildings:110000002 都城城墙不并入，另议）
- **军事**（11 项，3 票一致）：`1000000, 1000006, 1000007, 1000014, 1000020, 1000026, 1000029, 1000059, 1000068, 1000070, 1000071`
- **精制台**：`1000097`（仅 home；buildings2/base .builder 不命中）
- **兜底**（40 项，displayCategory == nil → 保持「建筑与防御」）：`1000001, 1000002, 1000003, 1000004, 1000005, 1000015, 1000016, 1000017, 1000018, 1000022, 1000023, 1000024, 1000025, 1000030, 1000060, 1000061, 1000062, 1000064, 1000066, 1000069, 1000073, 1000074, 1000075, 1000076, 1000083, 1000087, 1000088, 1000090, 1000091, 1000092, 1000093, 1000094, 1000095, 1000096, 1000098, 1000099, 1000100, 1000101, 1000103, 1000104`
- 合计 20+1+11+1+40 = 73 ✓（已分类 33 项不变）

---

## Task 0: 白名单投票确认（3 候选 subagent）

**Files:** 无代码变更。

- [ ] **Step 1**: 派发 3 个独立 subagent（`general`），各读 `Sources/COCHelperCore/GameCatalog/18.400.13/catalog.json` 中 buildings section 的 73 项 dataID/名称，独立给出「防御 / 军事 / 兜底」三分类归属表。输入相同：issue #37 分类定义（防御=主世界普通防御；军事=训练/研究/法术/英雄/作战准备设施；其余兜底）。
- [ ] **Step 2**: 汇总 3 份归属表；白名单取 3 票一致（或 2 票一致且无反对票）的 dataID；有分歧的 dataID 一律进兜底（保守）。
- [ ] **Step 3**: 把最终归属表写回本计划的「白名单规则表」小节（Edit 追加），作为 Task 1 的测试数据源。

---

## Task 1: Core 规则表（枚举 + 白名单 + rootID 解析）

**Files:**
- Create: `Sources/COCHelperCore/BuildingDisplayCategory.swift`
- Test: `Tests/COCHelperCoreTests/BuildingDisplayCategoryTests.swift`

- [ ] **Step 1: 写失败测试**（完整文件）

```swift
import XCTest
@testable import COCHelperCore

final class BuildingDisplayCategoryTests: XCTestCase {
    // MARK: - 防御建筑

    func testDefenseMappings() {
        for id in [1000008, 1000009, 1000010, 1000011, 1000012, 1000013,
                   1000019, 1000021, 1000027, 1000028, 1000031, 1000032,
                   1000067, 1000072] {
            XCTAssertEqual(
                BuildingDisplayCategoryRules.displayCategory(
                    section: "buildings", dataID: Int64(id), base: .home, rootParentDataID: nil
                ),
                .defense,
                "dataID \(id) 应为防御建筑"
            )
        }
    }

    // MARK: - 军事设施

    func testMilitaryMappings() {
        for id in [1000000, 1000006, 1000007, 1000014, 1000020, 1000026,
                   1000029, 1000059, 1000068, 1000070, 1000071] {
            XCTAssertEqual(
                BuildingDisplayCategoryRules.displayCategory(
                    section: "buildings", dataID: Int64(id), base: .home, rootParentDataID: nil
                ),
                .military,
                "dataID \(id) 应为军事设施"
            )
        }
    }

    // MARK: - 精制台

    func testCraftTableParent() {
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 1000097, base: .home, rootParentDataID: nil
            ),
            .craftTable
        )
    }

    func testCraftTableNestedChild() {
        // 嵌套项自身 dataID（types/modules 段）不在任何白名单，必须按根父归属
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 103000011, base: .home, rootParentDataID: 1000097
            ),
            .craftTable
        )
        XCTAssertEqual(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings", dataID: 102000041, base: .home, rootParentDataID: 1000097
            ),
            .craftTable
        )
    }

    // MARK: - 不误判

    func testBuilderBaseNeverCraftTable() {
        // 建筑工人基地 1000097 同名建筑（buildings2）不得归入精制台
        XCTAssertNil(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings2", dataID: 1000097, base: .builder, rootParentDataID: nil
            )
        )
    }

    func testBuilderBaseDefenseNotClassified() {
        XCTAssertNil(
            BuildingDisplayCategoryRules.displayCategory(
                section: "buildings2", dataID: 1000008, base: .builder, rootParentDataID: nil
            )
        )
    }

    func testNonBuildingsSectionNeverClassified() {
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "traps", dataID: 1000008, base: .home, rootParentDataID: nil
        ))
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "units", dataID: 1000000, base: .home, rootParentDataID: nil
        ))
    }

    // MARK: - 兜底

    func testResourceBuildingsFallThroughToNil() {
        for id in [1000001, 1000002, 1000003, 1000004, 1000005, 1000015, 1000023, 1000024] {
            XCTAssertNil(
                BuildingDisplayCategoryRules.displayCategory(
                    section: "buildings", dataID: Int64(id), base: .home, rootParentDataID: nil
                ),
                "dataID \(id) 应兜底（不细分）"
            )
        }
    }

    func testUnknownIDFallsThroughToNil() {
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 9999999, base: .home, rootParentDataID: nil
        ))
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 0, base: .home, rootParentDataID: nil
        ))
    }

    func testNestedChildOfNonCraftTableFallsThrough() {
        XCTAssertNil(BuildingDisplayCategoryRules.displayCategory(
            section: "buildings", dataID: 103000011, base: .home, rootParentDataID: 1000008
        ))
    }

    // MARK: - rootID 解析

    func testRootIDParsing() {
        XCTAssertEqual(BuildingDisplayCategoryRules.rootID(of: "buildings:6.types.0.modules.2"), "buildings:6")
        XCTAssertEqual(BuildingDisplayCategoryRules.rootID(of: "buildings:6"), "buildings:6")
        XCTAssertEqual(BuildingDisplayCategoryRules.rootID(of: "traps:0"), "traps:0")
    }

    // MARK: - Property-based（固定种子可复现）

    func testPropertyRulesNeverCrashAndStayInDomain() {
        var rng = SeededRNG(seed: 0x13_37)
        let sections = ["buildings", "buildings2", "traps", "units", "spells", "heroes", "equipment"]
        for _ in 0..<2000 {
            let section = sections[Int(rng.next() % UInt64(sections.count))]
            let dataID = Int64(rng.next() % 2_000_000)
            let base: TrackerBase = rng.next() % 2 == 0 ? .home : .builder
            let nested = rng.next() % 2 == 0
            let rootParent: Int64? = nested ? Int64(rng.next() % 2_000_000) : nil
            let result = BuildingDisplayCategoryRules.displayCategory(
                section: section, dataID: dataID, base: base, rootParentDataID: rootParent
            )
            XCTAssertTrue(
                result == nil || result == .defense || result == .military || result == .craftTable,
                "非法结果 \(String(describing: result))"
            )
            // 不变量：非 home / 非 buildings 一律 nil
            if section != "buildings" || base != .home {
                XCTAssertNil(result, "\(section)/\(base) 不应细分")
            }
        }
    }
}
```

> 注：`SeededRNG` 已在 `VillageCatalogProjectionTests.swift` 定义（internal，同 target 可见，直接复用）。

- [ ] **Step 2: 运行验证失败**

```bash
swift test --filter BuildingDisplayCategoryTests
```
Expected: 编译失败（类型不存在）。

- [ ] **Step 3: 最小实现**

```swift
import Foundation

// Issue #123：新增 walls（城墙）展示分类，排序 防御→城墙→军事→精制台。
public enum TrackerDisplayCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case defense
    case walls
    case military
    case craftTable

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .defense: "防御建筑"
        case .walls: "城墙"
        case .military: "军事设施"
        case .craftTable: "精制台"
        }
    }

    public var systemImage: String {
        switch self {
        case .defense: "shield.lefthalf.filled"
        case .walls: "square.grid.3x3"
        case .military: "figure.arms.open"
        case .craftTable: "hammer.fill"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .defense: 0
        case .walls: 1
        case .military: 2
        case .craftTable: 3
        }
    }
}

/// Issue #37：主世界建筑展示分类的集中式规则表（稳定 dataID，不依赖本地化名称）。
/// 规则：section == "buildings" 且 base == .home 才细分；精制台按根父归属；
/// 其余（资源/大本营/活动/未知）返回 nil → UI 走原「建筑与防御」兜底，项目不丢失。
public enum BuildingDisplayCategoryRules {
    public static let craftTableDataID: Int64 = 1000097

    /// 已确认的主世界普通防御建筑（issue #37 定义）。
    static let defenseDataIDs: Set<Int64> = [
        1000008, 1000009, 1000010, 1000011, 1000012, 1000013,
        1000019, 1000021, 1000027, 1000028, 1000031, 1000032,
        1000067, 1000072,
    ]

    /// 已确认的军事/作战支持设施（issue #37 定义）。
    static let militaryDataIDs: Set<Int64> = [
        1000000, 1000006, 1000007, 1000014, 1000020, 1000026,
        1000029, 1000059, 1000068, 1000070, 1000071,
    ]

    /// 平铺 id 的根父段：`"buildings:6.types.0.modules.2"` → `"buildings:6"`；
    /// 无嵌套段时返回原 id。
    public static func rootID(of id: String) -> String {
        id.split(separator: ".").first.map(String.init) ?? id
    }

    /// 展示分类判定。嵌套项必须传 `rootParentDataID`（其自身 dataID 是 types/modules 段，
    /// 不在任何白名单内）；平铺项传 nil。
    public static func displayCategory(
        section: String,
        dataID: Int64,
        base: TrackerBase,
        rootParentDataID: Int64?
    ) -> TrackerDisplayCategory? {
        guard section == "buildings", base == .home else { return nil }
        if let rootParentDataID {
            // 嵌套项：仅精制台细分（根父 1000097）；其余嵌套后代不细分。
            return rootParentDataID == craftTableDataID ? .craftTable : nil
        }
        if dataID == craftTableDataID { return .craftTable }
        if defenseDataIDs.contains(dataID) { return .defense }
        if militaryDataIDs.contains(dataID) { return .military }
        return nil
    }
}
```

- [ ] **Step 4: 运行验证通过**

```bash
swift test --filter BuildingDisplayCategoryTests
```
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/BuildingDisplayCategory.swift Tests/COCHelperCoreTests/BuildingDisplayCategoryTests.swift
git commit -m "feat: 主世界建筑展示分类规则表（防御/军事/精制台）(Issue #37)"
```

---

## Task 2: VillageItemState.displayCategory + 投影计算

**Files:**
- Modify: `Sources/COCHelperCore/VillageCatalogProjection.swift`
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`

- [ ] **Step 1: 写失败测试**（追加到 VillageCatalogProjectionTests）

```swift
// MARK: - Issue #37 展示分类

func testRealFixtureDisplayCategoryForCraftTableAndNested() throws {
    let sections = try loadRealFixture()
    let village = makeVillage(objectSections: sections)
    let catalog = GameCatalog.loadBundled()
    let home = project(village: village, catalog: catalog, base: .home)

    // 精制台父项（fixture dataID 1000097）
    let craftParent = try XCTUnwrap(home.items.first {
        !$0.isNested && $0.section == "buildings" && $0.dataID == 100_0097
    })
    XCTAssertEqual(craftParent.displayCategory, .craftTable)

    // 嵌套 types/modules 后代全部归精制台（按根父归属）
    let nested = home.items.filter(\.isNested)
    XCTAssertFalse(nested.isEmpty)
    XCTAssertTrue(nested.allSatisfy { $0.displayCategory == .craftTable },
                   "fixture 嵌套项（精制台后代）应全部归精制台")

    // 兵营 → 军事设施；加农炮 → 防御建筑
    XCTAssertEqual(
        home.items.first { $0.dataID == 1_000_000 && !$0.isNested }?.displayCategory, .military
    )
    XCTAssertEqual(
        home.items.first { $0.dataID == 1_000_013 && !$0.isNested }?.displayCategory, .defense
    )
}

func testBuilderBaseItemsHaveNilDisplayCategory() throws {
    let sections = try loadRealFixture()
    let village = makeVillage(objectSections: sections)
    let catalog = GameCatalog.loadBundled()
    let builder = project(village: village, catalog: catalog, base: .builder)
    XCTAssertFalse(builder.items.isEmpty)
    XCTAssertTrue(builder.items.allSatisfy { $0.displayCategory == nil },
                   "建筑工人基地项目不应细分")
}

func testAggregatedItemPreservesDisplayCategory() throws {
    let village = makeVillage(objectSections: [
        "buildings": [
            makeItem(section: "buildings", dataID: 1_000_013, level: 18, count: nil, path: "0"),
            makeItem(section: "buildings", dataID: 1_000_013, level: 18, count: 1, path: "1"),
        ],
    ])
    let home = project(village: village, catalog: syntheticCatalog, base: .home)
    let agg = home.items.first { $0.id.hasPrefix("agg:") }
    XCTAssertEqual(agg?.displayCategory, .defense, "聚合项应透传展示分类")
}
```

> 注：`syntheticCatalog` 中 1000013 不存在 → join 失败 unknown，但 displayCategory 不依赖目录 join，仍应分类。若 makeItem 的 dataID 走 syntheticCatalog 未收录，displayCategory 断言不受影响（规则表独立于目录）。为稳妥，testAggregatedItemPreservesDisplayCategory 依赖规则表而非目录命中——1000013 在 defense 白名单。

- [ ] **Step 2: 运行验证失败**

```bash
swift test --filter VillageCatalogProjectionTests
```
Expected: `displayCategory` 编译失败（字段不存在）。

- [ ] **Step 3: 实现**

`VillageItemState`：
- 属性：`public let displayCategory: TrackerDisplayCategory?`（置于 `isNested` 后）。
- init 参数：`displayCategory: TrackerDisplayCategory? = nil`（默认 nil，现有构造点不破坏）。

`VillageCatalogProjection.records(from:catalog:base:now:)`：

```swift
private static func records(
    from snapshot: AccountSnapshot,
    catalog: GameCatalog?,
    base: TrackerBase,
    now: Date
) -> [VillageItemState] {
    // Issue #37：第一遍扫描构建「根父 id → dataID」映射（id 是数组索引路径，
    // 嵌套项归属精制台必须回查根父 dataID）。
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
```

`map(...)` 增加参数 `rootParentDataIDs: [String: Int64]`，并在函数开头计算：

```swift
let displayCategory = BuildingDisplayCategoryRules.displayCategory(
    section: item.section,
    dataID: item.dataID,
    base: base,
    rootParentDataID: item.id.contains(".types.") || item.id.contains(".modules.")
        ? rootParentDataIDs[BuildingDisplayCategoryRules.rootID(of: item.id)]
        : nil
)
```

两处 `VillageItemState(...)` 构造（unavailable 分支 + 正常分支）均传入 `displayCategory: displayCategory`。

`aggregate(...)` 聚合项构造：`displayCategory: first.displayCategory`（透传）。

- [ ] **Step 4: 运行验证通过**

```bash
swift test --filter VillageCatalogProjectionTests
```
Expected: 全部 PASS（含新增 3 个测试与既有 25+ 测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/VillageCatalogProjection.swift Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "feat: 投影层计算并透传展示分类（精制台嵌套按根父归属）(Issue #37)"
```

---

## Task 3: VillageDetailProjection 分组/统计切换到展示分类

**Files:**
- Modify: `Sources/COCHelperCore/VillageDetailProjection.swift`
- Test: `Tests/COCHelperCoreTests/VillageDetailProjectionTests.swift`

- [ ] **Step 1: 写失败测试**（追加）

```swift
// MARK: - Issue #37 展示分类分组

func testGroupsSplitBuildingsIntoDisplayCategories() throws {
    let items = [
        item(id: "def1", category: .buildings, displayCategory: .defense),
        item(id: "def2", category: .buildings, displayCategory: .defense),
        item(id: "mil1", category: .buildings, displayCategory: .military),
        item(id: "craft", category: .buildings, displayCategory: .craftTable),
        item(id: "fallback", category: .buildings),  // 兜底：资源/大本营等
        item(id: "trap", category: .traps),
        item(id: "other", category: nil, status: .unavailable),
    ]
    let groups = VillageDetailProjection.groups(from: items)
    let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    XCTAssertEqual(byID["defense"]?.items.map(\.id), ["def1", "def2"])
    XCTAssertEqual(byID["military"]?.items.map(\.id), ["mil1"])
    XCTAssertEqual(byID["craftTable"]?.items.map(\.id), ["craft"])
    XCTAssertEqual(byID["buildings"]?.items.map(\.id), ["fallback"])
    XCTAssertEqual(byID["traps"]?.items.map(\.id), ["trap"])
    // 守恒：分组 flatten 不丢不重
    XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(), items.map(\.id).sorted())
}

func testGroupsOrderDisplayCategoriesFirst() {
    let items = [
        item(id: "trap", category: .traps),
        item(id: "craft", category: .buildings, displayCategory: .craftTable),
        item(id: "def", category: .buildings, displayCategory: .defense),
        item(id: "b", category: .buildings),  // 兜底
    ]
    let groups = VillageDetailProjection.groups(from: items)
    XCTAssertEqual(groups.map(\.id), ["defense", "craftTable", "buildings", "traps"])
}

func testCompletionStatsConserveAcrossDisplaySplit() {
    let items = [
        item(id: "def", category: .buildings, displayCategory: .defense, status: .maxed),
        item(id: "mil", category: .buildings, displayCategory: .military, status: .complete),
        item(id: "fb", category: .buildings, status: .unknown, maxLevel: nil),
        item(id: "trap", category: .traps, status: .complete),
    ]
    let stats = VillageDetailProjection.completionStats(from: items)
    let total = VillageDetailProjection.totalCompletion(from: items)
    XCTAssertEqual(total.knownCount, stats.reduce(0) { $0 + $1.knownCount })
    XCTAssertEqual(total.completedCount, stats.reduce(0) { $0 + $1.completedCount })
    XCTAssertEqual(total.unknownCount, stats.reduce(0) { $0 + $1.unknownCount })
    let defense = try? XCTUnwrap(stats.first { $0.displayCategory == .defense })
    XCTAssertEqual(defense.map { ($0.knownCount, $0.completedCount) } ?? nil, (1, 1))
}

func testCraftTableGroupParentedRowsStillNest() throws {
    // 精制台父项 + 3 types × 3 modules（id 索引路径格式）
    let children: [VillageItemState] = (0..<12).map { idx in
        item(id: "buildings:0.types.\(idx / 3).modules.\(idx % 3)",
             category: .buildings, displayCategory: .craftTable, nested: true,
             status: .unknown, level: nil, maxLevel: nil)
    }
    let parent = item(id: "buildings:0", category: .buildings, displayCategory: .craftTable)
    let groups = VillageDetailProjection.groups(from: [parent] + children)
    let craft = try XCTUnwrap(groups.first { $0.displayCategory == .craftTable })
    let rows = VillageDetailProjection.parentedRows(from: craft.items)
    let root = try XCTUnwrap(rows.first { $0.item.id == "buildings:0" })
    XCTAssertEqual(root.children.count, 12)
}

// MARK: - Property-based：展示分类随机输入不变量

func testPropertyDisplayCategoryGroupsConserveItems() {
    var rng = SeededRNG(seed: 0xAB_CD)
    let displayCats: [TrackerDisplayCategory?] = [.defense, .military, .craftTable, nil]
    for _ in 0..<200 {
        let items = (0..<Int(rng.next() % 40)).map { idx in
            let dc = displayCats[Int(rng.next() % UInt64(displayCats.count))]
            let category: TrackerCategory? = dc == nil && rng.next() % 3 == 0 ? nil : .buildings
            return item(id: "i\(idx)", category: category, displayCategory: dc,
                        status: rng.next() % 2 == 0 ? .complete : .maxed)
        }
        let groups = VillageDetailProjection.groups(from: items)
        XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(), items.map(\.id).sorted())
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        for group in groups {
            if let dc = group.displayCategory {
                XCTAssertTrue(group.items.allSatisfy { $0.displayCategory == dc })
            } else if let c = group.category {
                XCTAssertTrue(group.items.allSatisfy { $0.displayCategory == nil && $0.category == c })
            } else {
                XCTAssertTrue(group.items.allSatisfy { $0.category == nil })
            }
        }
    }
}
```

> 注：`item()` helper 需增加 `displayCategory: TrackerDisplayCategory? = nil` 参数（默认 nil，现有调用不破坏）。`category: nil` 且 `displayCategory: nil` 时 helper 需传 `status: .unavailable`（或保持默认 .complete——测试只关心分组，不关心状态）。

- [ ] **Step 2: 运行验证失败**

```bash
swift test --filter VillageDetailProjectionTests
```
Expected: `displayCategory` 相关编译失败。

- [ ] **Step 3: 实现**

`VillageDetailProjection.swift`：

```swift
public struct VillageDetailGroup: Identifiable, Hashable, Sendable {
    public let category: TrackerCategory?
    public let displayCategory: TrackerDisplayCategory?
    public let items: [VillageItemState]
    public var id: String {
        displayCategory?.rawValue ?? category?.rawValue ?? "other"
    }
    public init(category: TrackerCategory?, displayCategory: TrackerDisplayCategory? = nil,
                items: [VillageItemState]) { ... }
}
```

分组 key 改为结构化枚举：

```swift
private enum GroupKey: Hashable, Comparable {
    case display(TrackerDisplayCategory)   // 展示分类（排最前，按 sortOrder）
    case category(TrackerCategory)          // 原分类（buildings 兜底保留）
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
```

`groups(from:)` 重写为使用 GroupKey；`VillageDetailGroup(category:displayCategory:items:)` 由 key 构造。`completionStats` 中 `VillageCategoryCompletion` 增加 `displayCategory` 字段（默认 nil），从 key 提取。`VillageCategoryCompletion.id` 同组逻辑。

> `totalCompletion` 不变（与分组无关）。

- [ ] **Step 4: 运行验证通过**

```bash
swift test --filter VillageDetailProjectionTests
```
Expected: 全部 PASS（新增 5 测试 + 既有测试：既有测试 item() 默认 displayCategory == nil → 分组行为与旧版完全一致）。

- [ ] **Step 5: 适配真实 fixture 测试**

`VillageDetailProjectionTests.testParentedRowsWithRealSnapshot`（L340-378）：`groups.first { $0.category == .buildings }` 现含兜底项；精制台父项在 craftTable 组。改为：

```swift
let craftGroup = try XCTUnwrap(
    VillageDetailProjection.groups(from: tracked).first { $0.displayCategory == .craftTable }
)
let rows = VillageDetailProjection.parentedRows(from: craftGroup.items)
// fixture：buildings:6 = dataID 1000097（精制台）3 types × 3 modules = 12 个嵌套后代
let craftTable = try XCTUnwrap(
    rows.first { Self.normalizeAggPrefix($0.item.id) == "buildings:6" },
    "根父行 buildings:6 应存在"
)
XCTAssertEqual(craftTable.children.count, 12, "全部 12 个嵌套后代应归入根父行")
XCTAssertTrue(craftTable.children.allSatisfy(\.isNested))
let orphans = rows.filter { $0.item.isNested }
XCTAssertTrue(orphans.isEmpty, "精制台组内嵌套项不应独立成行")
```

- [ ] **Step 6: 全量测试 + Commit**

```bash
swift test --filter VillageDetailProjectionTests
git add Sources/COCHelperCore/VillageDetailProjection.swift Tests/COCHelperCoreTests/VillageDetailProjectionTests.swift
git commit -m "feat: 详情分组/完成度切换到展示分类，兜底保持建筑与防御 (Issue #37)"
```

---

## Task 4: UI 层消费展示分类

**Files:**
- Modify: `Sources/COCHelper/VillageDetailView.swift`
- Modify: `Sources/COCHelper/UpgradeDisplayRow.swift`
- Modify: `Sources/COCHelper/LevelDetailSheet.swift`

- [ ] **Step 1: 实现（UI 无测试覆盖，以构建验证；Core 逻辑已在 Task 1-3 测试）**

`VillageDetailView.swift`：

1. `CategoryFilter` 增加 `case display(TrackerDisplayCategory)`。
2. `categoryFilterBar(groups:)` 重构：先「全部」，再三个展示分类 chip（`filter: .display(dc)`，count 来自 `$0.displayCategory == dc`），再原 `TrackerCategory.allCases` chip（count 只算 `$0.displayCategory == nil` 的组），再「其他」。buildings chip 自然退化为兜底计数。
3. `filtered(_:)` 增加 `.display(let dc)` → `groups.filter { $0.displayCategory == dc }`。
4. 分组标题：`group.displayCategory?.title ?? group.category?.title ?? "其他"`；图标同理 `group.displayCategory?.systemImage ?? group.category?.systemImage ?? "ellipsis.circle"`。

```swift
private func categoryFilterBar(groups: [VillageDetailGroup]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            filterChip(title: "全部", count: groups.reduce(0) { $0 + $1.items.count }, filter: .all)
            ForEach(TrackerDisplayCategory.allCases) { display in
                let count = groups.first(where: { $0.displayCategory == display })?.items.count ?? 0
                filterChip(title: display.title, count: count, filter: .display(display))
            }
            ForEach(TrackerCategory.allCases) { category in
                let count = groups.first(where: { $0.displayCategory == nil && $0.category == category })?.items.count ?? 0
                filterChip(title: category.title, count: count, filter: .category(category))
            }
            let otherCount = groups.first(where: { $0.displayCategory == nil && $0.category == nil })?.items.count ?? 0
            if otherCount > 0 {
                filterChip(title: "其他", count: otherCount, filter: .other)
            }
        }
    }
}
```

`UpgradeDisplayRow.swift`：

- `subtitle`：`(item.displayCategory?.title ?? item.category?.title ?? item.section) + ...`
- `iconImageName`：`item.displayCategory?.systemImage ?? item.category?.systemImage ?? "hammer.fill"`
- `iconView` 颜色与 `TrackerDisplayCategory.tint` 扩展（追加到文件底部现有 `extension TrackerCategory { var tint }` 旁）：

```swift
extension TrackerDisplayCategory {
    var tint: Color {
        switch self {
        case .defense: .blue
        case .military: .orange
        case .craftTable: .purple
        }
    }
}
```

`LevelDetailSheet.swift`（L96-105, L178-180 同模式）：title/icon/tint 改为 `item.displayCategory?.title ?? item.category?.title` 等。

- [ ] **Step 2: 构建验证**

```bash
swift build
```
Expected: 编译通过。

- [ ] **Step 3: Commit**

```bash
git add Sources/COCHelper/VillageDetailView.swift Sources/COCHelper/UpgradeDisplayRow.swift Sources/COCHelper/LevelDetailSheet.swift
git commit -m "feat: 村庄详情 UI 消费展示分类（chip/分组/行副标题/图标）(Issue #37)"
```

---

## Task 5: 全量验证与自查（Reflexion）

- [ ] **Step 1: 全量测试**

```bash
swift test
```
Expected: 全部 PASS（383 + 新增 ~15，无失败）。

- [ ] **Step 2: Release 构建 + App 脚本 + 空白检查**

```bash
swift build -c release
./scripts/build_app.sh
git diff --check
```

- [ ] **Step 3: 自查清单（Reflexion）**

- 精制台嵌套项 displayCategory 是否全部 .craftTable？（fixture 测试覆盖）
- buildings2 / builder base 是否全部 nil？（测试覆盖）
- 聚合项（agg: 前缀）displayCategory 是否透传？（测试覆盖）
- 兜底（资源/大本营/未知 ID）是否仍显示在「建筑与防御」组、不从详情页消失？（VillageDetailView L54 过滤是 category==nil 项，兜底项 category == .buildings → 保留 ✓）
- 分组总数/完成度守恒（property-based 覆盖）
- `selectedFilter` 切换 base 后残留问题：CategoryFilter 是 @State，切换 base 后若所选展示分类无内容 → 空筛选面板 + 提示文案（现有行为，可接受；无崩溃）
- 升级总览页（UpgradeOverviewProjection + UpgradeDisplayRow）：只改副标题文本/图标，排序不变

- [ ] **Step 4: Commit 收尾**

```bash
git log --oneline
git status
```

---

## 验收标准对照（Issue #37）

| 验收项 | 覆盖 |
|---|---|
| 不再统一显示「建筑与防御」 | Task 3/4：defense/military/craftTable 分组 + chip |
| 防御建筑在「防御建筑」 | Task 1 白名单 + Task 2 投影 + Task 4 UI |
| 军事设施在「军事设施」 | 同上 |
| 精制台父项+types+modules 在「精制台」 | Task 2（根父归属）+ Task 3（parentedRows） |
| buildings2 不误判精制台 | Task 1 `testBuilderBaseNeverCraftTable` |
| 陷阱独立 | 规则表 section guard（traps → nil） |
| 未知 ID 不崩溃不丢失 | Task 1 兜底测试 + Task 3 守恒 property |
| 分类前后数量/完成度一致 | Task 3 守恒测试 + totalCompletion 不变 |
| 精制台嵌套父子缩进/详情 sheet | Task 3 `testCraftTableGroupParentedRowsStillNest` + Task 4 UI 复用 itemRow |

## 非目标（不做）

- 不改账号 JSON / 静态目录 / 生成器 / APK 解析
- 不重定义升级状态/时长/队列
- 不把 buildings2 改名精制台；不并入陷阱
- 不处理 PNG/levelVisual（Issue #34 另做）
- 不接官方 API
