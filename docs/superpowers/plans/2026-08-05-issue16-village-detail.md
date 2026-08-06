# Issue #16 村庄详情页（分类列表 + 逐级详情 + 完成度）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development 实现本计划。步骤用 checkbox（`- [ ]`）追踪。

**Goal:** 把侧边栏村庄入口从"仅看正在升级"扩展为完整村庄详情页：主村/建筑工人基地切换、分类筛选、完整项目列表（复用 #15 `UpgradeDisplayRow`）、逐级详情 sheet、分类完成度。

**Architecture:** 纯逻辑（分组、完成度、排序）全部下沉 `COCHelperCore` 新文件 `VillageDetailProjection.swift`（可 TDD、可复用、符合 #14/#15 "逻辑下沉 Core" 惯例）；UI 层保持薄，新增 `VillageDetailView.swift`（详情页）与 `LevelDetailSheet.swift`（逐级 sheet），`ContentView` 只改一处路由。数据全部来自现有 `VillageCatalogProjection.project` + `AppModel.gameCatalog`，不新增数据管道、不改持久化。

**Tech Stack:** Swift 6 / SwiftUI（macOS 14）/ XCTest（无第三方依赖，property-based 测试用手写固定 seed PRNG 生成器）。

---

## 设计分析（CoT，3 候选投票）

### 决策 1：详情页列表行数据模型

| 候选 | 方案 | 评 |
|---|---|---|
| **A（推荐）** | 复用 `UpgradeDisplayRecord` + 在 Core 补显式 `public init`（参数与隐式 memberwise 相同，不破坏现有调用） | 改动最小；#15 `UpgradeDisplayRow` 注释明确预留 `showsVillageColumn = false` 给村庄详情页 |
| B | 把 `UpgradeDisplayRow` 输入改为裸 `VillageItemState` | 重构已验收共享组件，风险大 |
| C | 详情页自己画行 | 复制代码，违背 #15 预留意图 |

### 决策 2：完成度 + 分组纯逻辑位置

| 候选 | 方案 | 评 |
|---|---|---|
| **A（推荐）** | Core 新文件 `VillageDetailProjection.swift` | 可 TDD、可复用、UI 薄 |
| B | UI 层 struct | 项目无 UI 测试，逻辑不可测 |
| C | 塞进 `VillageCatalogProjection.swift` | 混入已验收文件，职责混杂 |

### 决策 3：UI 文件组织

| 候选 | 方案 | 评 |
|---|---|---|
| **A（推荐）** | `VillageDetailView.swift` + `LevelDetailSheet.swift` 两文件 | 职责清晰，文件大小可控 |
| B | 单文件全包 | 重蹈 ContentView 966 行覆辙 |
| C | 三文件（再加 header） | 过度拆分 |

### 决策 4：`TrackerCategory.sortOrder` 可见性

| 候选 | 方案 | 评 |
|---|---|---|
| **A（推荐）** | `fileprivate` → `internal`（一行） | DRY，同 module 直接用 |
| B | Core 新文件自定义排序映射 | 重复定义，漂移风险 |

### 决策 5：property-based 测试（无 SwiftCheck）

固定 seed 的 SplitMix64 PRNG 生成随机 `VillageItemState` 集合 + 小空间穷举，验证不变量（详见 Task 1）。固定 seed 保证可复现，不引入依赖。

### 完成度契约（issue #16 语义，逐条落测试）

计入分母（known）的条件——全部满足：
1. `maxLevel != nil`（目录关联，排除 unknown/unavailable/maxLevel 缺失）
2. `currentLevel != nil`（等级已知）
3. 非版本不匹配：若 `isUpgrading` 且 `nextLevel > maxLevel`（`hasVersionMismatch`）→ 不计入（issue："目录无上限或版本不匹配：不纳入可确认完成度"）

完成（completed）：`status == .maxed`（投影层保证 maxed 时 currentLevel >= maxLevel）。
未知（unknown）：不满足 known 的项。快照缺失项目投影层不产出（`.available` 仅枚举），天然不显示为 0 级（issue 验收："快照缺少项目时不会错误显示为 0 级"）。

---

### 任务分解

- **Task 1**：Core `VillageDetailProjection`（分组 + 完成度）— TDD + property-based
- **Task 2**：`UpgradeDisplayRecord` 显式 `public init` + `TrackerCategory.sortOrder` → internal
- **Task 3**：`LevelDetailSheet`（逐级详情 sheet）
- **Task 4**：`VillageDetailView` + `ContentView` 路由
- **Task 5**：全量验证（swift test + build_app.sh）

---

### Task 1: Core `VillageDetailProjection`（分组 + 完成度）

**Files:**
- Create: `Sources/COCHelperCore/VillageDetailProjection.swift`
- Modify: `Sources/COCHelperCore/TrackerModels.swift`（`sortOrder` fileprivate → internal，仅此一行；若 Task 1 需排序则本改动并入本任务）
- Test: `Tests/COCHelperCoreTests/VillageDetailProjectionTests.swift`

**类型契约（本任务产出，后续任务依赖）：**

```swift
public struct VillageDetailGroup: Identifiable, Hashable, Sendable {
    public let category: TrackerCategory?   // nil = 未分类（helpers/decos/obstacles 等）
    public let items: [VillageItemState]
    public var id: String { category?.rawValue ?? "other" }
}

public struct VillageCategoryCompletion: Identifiable, Hashable, Sendable {
    public let category: TrackerCategory?   // nil = 未分类合计
    public let knownCount: Int              // 分母
    public let completedCount: Int          // maxed 数
    public let unknownCount: Int            // 不满足 known 的项
    public var id: String { category?.rawValue ?? "other" }
    public var completionRatio: Double? {   // known == 0 → nil
        knownCount > 0 ? Double(completedCount) / Double(knownCount) : nil
    }
    public init(category: TrackerCategory?, knownCount: Int, completedCount: Int, unknownCount: Int)
}

public enum VillageDetailProjection {
    /// 按分类分组；组序 = sortOrder 升序，未分类组最后；组内保持输入相对顺序（稳定分组）。
    public static func groups(from items: [VillageItemState]) -> [VillageDetailGroup]
    /// 按分类完成度；顺序同 groups。
    public static func completionStats(from items: [VillageItemState]) -> [VillageCategoryCompletion]
    /// 全村庄完成度合计。
    public static func totalCompletion(from items: [VillageItemState]) -> VillageCategoryCompletion
}
```

- [ ] **Step 1: 先写测试** `Tests/COCHelperCoreTests/VillageDetailProjectionTests.swift`（内容见下方代码块）
- [ ] **Step 2: 运行确认 FAIL**（`VillageDetailProjection` 不存在 → 编译失败即为预期 RED）
- [ ] **Step 3: 实现** `Sources/COCHelperCore/VillageDetailProjection.swift`（内容见下方代码块）+ TrackerModels.swift 一行改动
- [ ] **Step 4: 运行确认 PASS**
- [ ] **Step 5: Commit** `feat: village detail grouping and completion stats (Issue #16)`

**测试代码（完整，含穷举 + property-based）：**

```swift
import XCTest
@testable import COCHelperCore

/// Issue #16：村庄详情页分组与完成度统计。
final class VillageDetailProjectionTests: XCTestCase {
    // MARK: - Helpers

    private func item(
        id: String = "id",
        category: TrackerCategory? = .buildings,
        status: VillageItemStatus = .complete,
        level: Int? = 3,
        maxLevel: Int? = 10,
        isUpgrading: Bool = false,
        nextLevel: Int? = nil
    ) -> VillageItemState {
        // VillageItemState 的 init 是 internal，测试 target 可通过 @testable 使用。
        // 构造时 nextLevel 仅当 isUpgrading 且 level 存在时有意义（投影层语义）。
        let effectiveNext = nextLevel ?? (isUpgrading ? level.map { $0 + 1 } : nil)
        return VillageItemState(
            id: id,
            section: "buildings",
            dataID: Int64(id.hashValue) & 0xFFFF,
            base: .home,
            name: "item-" + id,
            category: category,
            currentLevel: level,
            count: 1,
            timerSeconds: isUpgrading ? 3600 : nil,
            remainingSeconds: isUpgrading ? 1800 : nil,
            nextLevel: effectiveNext,
            nextLevelDurationSeconds: isUpgrading ? 3600 : nil,
            maxLevel: maxLevel,
            status: status,
            missingReason: nil,
            icon: nil,
            levelVisual: nil,
            isNested: false
        )
    }

    private func stat(_ c: VillageCategoryCompletion) -> (known: Int, completed: Int, unknown: Int) {
        (c.knownCount, c.completedCount, c.unknownCount)
    }

    // MARK: - 分组

    func testGroupsPreserveOrderAndItems() {
        let a = item(id: "a", category: .traps, status: .complete)
        let b = item(id: "b", category: .buildings, status: .maxed)
        let c = item(id: "c", category: nil, status: .unavailable)
        let groups = VillageDetailProjection.groups(from: [a, b, c])
        // 稳定分组：flatten == 输入（顺序也一致）
        XCTAssertEqual(groups.flatMap(\.items), [a, b, c])
    }

    func testGroupsOrderBySortOrderWithOtherLast() {
        let a = item(id: "a", category: .troops)
        let b = item(id: "b", category: .buildings)
        let c = item(id: "c", category: nil)
        let groups = VillageDetailProjection.groups(from: [a, b, c])
        XCTAssertEqual(groups.map(\.category), [.buildings, .troops, nil])
    }

    func testGroupIDsUniqueAndStable() {
        let items = (0..<20).map { item(id: "i\($0)", category: [TrackerCategory?]([.buildings, .traps, .heroes, nil])[$0 % 4]) }
        let groups = VillageDetailProjection.groups(from: items)
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        XCTAssertEqual(groups.flatMap(\.items).map(\.id), items.map(\.id))
    }

    func testGroupItemsShareCategory() {
        let items = (0..<10).map { item(id: "i\($0)", category: $0 % 2 == 0 ? .spells : nil) }
        for group in VillageDetailProjection.groups(from: items) {
            let expected = group.category
            XCTAssertTrue(group.items.allSatisfy { $0.category == expected })
        }
    }

    // MARK: - 完成度（穷举 status × level/maxLevel 组合）

    func testCompletionCountsByStatus() {
        // status → (known, completed, unknown) 期望
        let cases: [(VillageItemStatus, (Int, Int, Int))] = [
            (.complete, (1, 0, 0)),    // 有上限、等级已知、未满 → known 未完成
            (.maxed, (1, 1, 0)),       // 满级 → known + completed
            (.upgrading, (1, 0, 0)),   // 进行中且 next <= max → known 未完成
            (.unknown, (0, 0, 1)),     // 目录未收录 → unknown
            (.unavailable, (0, 0, 1)), // 不支持类别 → unknown
        ]
        for (status, expected) in cases {
            let level = 3, maxLevel = 10
            let it = item(status: status, level: level, maxLevel: maxLevel,
                          isUpgrading: status == .upgrading,
                          nextLevel: status == .upgrading ? level + 1 : nil)
            let total = VillageDetailProjection.totalCompletion(from: [it])
            XCTAssertEqual(stat(total), expected, "status=\(status)")
        }
    }

    func testMaxedWithoutMaxLevelCountsUnknown() {
        // 防御：maxed 但 maxLevel 缺失（不该由投影产生，但统计不得崩溃）
        let it = item(status: .maxed, level: 10, maxLevel: nil)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertEqual(stat(total), (0, 0, 1))
    }

    func testUpgradingBeyondMaxIsVersionMismatchUnknown() {
        // next > max：版本不匹配 → 不纳入完成度（issue 语义）
        let it = item(status: .upgrading, level: 10, maxLevel: 10, isUpgrading: true, nextLevel: 11)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertEqual(stat(total), (0, 0, 1))
    }

    func testUpgradingAtMaxBoundaryIsKnown() {
        // next == max：边界合法，计入 known
        let it = item(status: .upgrading, level: 9, maxLevel: 10, isUpgrading: true, nextLevel: 10)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertEqual(stat(total), (1, 0, 0))
    }

    func testNilLevelCountsUnknown() {
        let it = item(status: .complete, level: nil, maxLevel: 10)
        let total = VillageDetailProjection.totalCompletion(from: [it])
        XCTAssertEqual(stat(total), (0, 0, 1))
    }

    func testTotalEqualsSumOfCategoryStats() {
        let items = [
            item(id: "a", category: .buildings, status: .maxed),
            item(id: "b", category: .buildings, status: .complete),
            item(id: "c", category: .troops, status: .unknown, maxLevel: nil),
            item(id: "d", category: nil, status: .unavailable),
        ]
        let stats = VillageDetailProjection.completionStats(from: items)
        let total = VillageDetailProjection.totalCompletion(from: items)
        XCTAssertEqual(total.knownCount, stats.reduce(0) { $0 + $1.knownCount })
        XCTAssertEqual(total.completedCount, stats.reduce(0) { $0 + $1.completedCount })
        XCTAssertEqual(total.unknownCount, stats.reduce(0) { $0 + $1.unknownCount })
    }

    func testCompletionRatio() {
        let full = VillageDetailProjection.totalCompletion(from: [item(status: .maxed)])
        XCTAssertEqual(full.completionRatio, 1.0)
        let half = VillageDetailProjection.totalCompletion(
            from: [item(id: "a", status: .maxed), item(id: "b", status: .complete)])
        XCTAssertEqual(half.completionRatio ?? -1, 0.5, accuracy: 0.0001)
        let none = VillageDetailProjection.totalCompletion(from: [item(status: .unknown, maxLevel: nil)])
        XCTAssertNil(none.completionRatio)
    }

    // MARK: - Property-based 不变量（固定 seed SplitMix64，可复现）

    func testPropertyInvariantsAcrossRandomCollections() {
        var rng = SplitMix64(seed: 0xC0C_16)
        for _ in 0..<500 {
            let items = randomItems(&rng, count: 1 + Int(rng.next() % 30))
            let groups = VillageDetailProjection.groups(from: items)
            let stats = VillageDetailProjection.completionStats(from: items)
            let total = VillageDetailProjection.totalCompletion(from: items)

            // 不变量 1：稳定分组（flatten == 输入，含顺序）
            XCTAssertEqual(groups.flatMap(\.items), items)
            // 不变量 2：known + unknown == 总数
            let known = stats.reduce(0) { $0 + $1.knownCount }
            let unknown = stats.reduce(0) { $0 + $1.unknownCount }
            XCTAssertEqual(known + unknown, items.count)
            // 不变量 3：completed <= known
            let completed = stats.reduce(0) { $0 + $1.completedCount }
            XCTAssertLessThanOrEqual(completed, known)
            // 不变量 4：maxed 项必计入 completed 且 known
            let maxedItems = items.filter { $0.status == .maxed }
            XCTAssertEqual(completed, maxedItems.count)
            XCTAssertEqual(known, items.count - unknown)
            // 不变量 5：unknown/unavailable 项必计入 unknown
            let unknownStatusItems = items.filter { $0.status == .unknown || $0.status == .unavailable }
            XCTAssertEqual(unknown, unknownStatusItems.count)
            // 不变量 6：total == 分类之和
            XCTAssertEqual(total.knownCount, known)
            XCTAssertEqual(total.completedCount, completed)
            XCTAssertEqual(total.unknownCount, unknown)
            // 不变量 7：组 id 唯一
            XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        }
    }

    // MARK: - 随机生成器（无第三方依赖）

    private func randomItems(_ rng: inout SplitMix64, count: Int) -> [VillageItemState] {
        (0..<count).map { i in
            let statusRoll = rng.next() % 6
            let status: VillageItemStatus
            switch statusRoll {
            case 0: status = .complete
            case 1: status = .maxed
            case 2: status = .upgrading
            case 3: status = .unknown
            case 4: status = .unavailable
            default: status = .available
            }
            let level: Int? = rng.next() % 4 == 0 ? nil : Int(rng.next() % 20)
            let maxLevel: Int? = rng.next() % 3 == 0 ? nil : Int(rng.next() % 20)
            let isUpgrading = status == .upgrading
            // 版本不匹配：随机让 nextLevel 超过 maxLevel
            let nextLevel: Int? = isUpgrading ? level.map { l in
                (maxLevel != nil && rng.next() % 5 == 0) ? l + 2 : l + 1
            } : nil
            let cats: [TrackerCategory?] = [.buildings, .traps, .troops, .spells,
                .siegeMachines, .heroes, .equipment, .pets, .guardians, nil]
            let category = cats[Int(rng.next() % UInt64(cats.count))]
            return item(id: "r\(i)", category: category, status: status,
                        level: level, maxLevel: maxLevel,
                        isUpgrading: isUpgrading, nextLevel: nextLevel)
        }
    }
}

/// 可复现 PRNG（SplitMix64），替代 SwiftCheck 的 property-based 测试。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
```

**实现代码（完整）：**

```swift
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
/// - 分母（known）：已观测且能与目录关联（maxLevel != nil、currentLevel != nil）
///   且非版本不匹配（upgrading 且 nextLevel > maxLevel）的项目；
/// - 完成（completed）：`status == .maxed`（投影层保证 currentLevel >= maxLevel）；
/// - 未知（unknown）：其余全部（unknown/unavailable/缺失上限/缺失等级/版本不匹配）；
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

    public static func completionStats(from items: [VillageItemState]) -> [VillageCategoryCompletion] {
        groups(from: items).map { group in
            let known = group.items.filter { isKnown($0) }.count
            let completed = group.items.filter { $0.status == .maxed }.count
            return VillageCategoryCompletion(
                category: group.category,
                knownCount: known,
                completedCount: completed,
                unknownCount: group.items.count - known
            )
        }
    }

    public static func totalCompletion(from items: [VillageItemState]) -> VillageCategoryCompletion {
        let known = items.filter { isKnown($0) }.count
        let completed = items.filter { $0.status == .maxed }.count
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
```

- [ ] **Step 6: Commit**
```bash
git add Sources/COCHelperCore/VillageDetailProjection.swift Sources/COCHelperCore/TrackerModels.swift Tests/COCHelperCoreTests/VillageDetailProjectionTests.swift
git commit -m "feat: village detail grouping and completion stats (Issue #16)"
```

**注意（implementer 必须遵守）：**
- 只 add 上述三个文件，绝不要 `git add .`（工作区有用户未提交的 README.md / Tools/smoke-api/main.swift / scripts/configure_coc_api.sh，不属于本任务）
- `TrackerModels.swift` 只改 `fileprivate var sortOrder` → `var sortOrder`（internal），其余不动
- `VillageItemState` 的 init 是 internal，测试通过 `@testable import COCHelperCore` 访问（现有测试惯例）

---

### Task 2: `UpgradeDisplayRecord` 显式 public init

**Files:**
- Modify: `Sources/COCHelperCore/UpgradeOverviewProjection.swift`（struct 内加 public init）
- Test: 无新测试文件；`UpgradeOverviewProjectionTests` 编译通过即验证

- [ ] **Step 1: 修改**——在 `UpgradeDisplayRecord` 结构体中、`catalogVersion` 属性后加：
```swift
    /// 显式 public init（隐式 memberwise 为 internal，UI 层（COCHelper target）
    /// 无法跨模块构造；参数与 memberwise 完全一致，不破坏现有调用）。
    public init(
        id: String,
        villageID: UUID,
        villageName: String,
        villageTag: String?,
        base: TrackerBase,
        item: VillageItemState,
        catalogVersion: String?
    ) {
        self.id = id
        self.villageID = villageID
        self.villageName = villageName
        self.villageTag = villageTag
        self.base = base
        self.item = item
        self.catalogVersion = catalogVersion
    }
```
- [ ] **Step 2: 验证** `swift test --filter UpgradeOverviewProjectionTests`（应全部 PASS，证明现有调用未破坏）
- [ ] **Step 3: Commit**
```bash
git add Sources/COCHelperCore/UpgradeOverviewProjection.swift
git commit -m "feat: public init for UpgradeDisplayRecord for village detail rows (Issue #16)"
```

---

### Task 3: `LevelDetailSheet`（逐级详情 sheet）

**Files:**
- Create: `Sources/COCHelper/LevelDetailSheet.swift`
- Test: 无（SwiftUI 无 UI 测试基础设施，项目惯例：逻辑已下沉 Core，UI 靠 build + 手工验收）

- [ ] **Step 1: 实现**（完整代码见下）
- [ ] **Step 2: 验证** `swift build`（exit 0）
- [ ] **Step 3: Commit** `feat: per-level upgrade detail sheet (Issue #16)`

**实现代码（完整）：**

```swift
import SwiftUI
import COCHelperCore

/// Issue #16：项目逐级升级详情 sheet。
///
/// 数据来源：`GameCatalog.item(section:dataID:)` 的 `levels` 数组（逐级时长、
/// 费用、解锁条件、图标）。嵌套 items（`.types.`/`.modules.`）与目录未收录项
/// 与投影层同规则不 join，显示缺失原因而不是伪造数据。
struct LevelDetailSheet: View {
    let item: VillageItemState
    let catalog: GameCatalog?
    let now: Date

    @Environment(\.dismiss) private var dismiss

    /// 目录项；嵌套项/未收录返回 nil（与投影层 join 规则一致）。
    private var catalogItem: CatalogItem? {
        guard !item.isNested else { return nil }
        return catalog?.item(section: item.section, dataID: item.dataID)
    }

    private var levelRows: [CatalogLevel] {
        catalogItem?.levels.sorted { $0.level < $1.level } ?? []
    }

    private var statusLabel: String {
        switch item.status {
        case .upgrading: "正在升级"
        case .maxed: "已满级"
        case .complete: "已记录"
        case .unknown: "目录未收录"
        case .unavailable: "不参与升级追踪"
        case .available: "目录中可用"
        }
    }

    private var missingNote: String? {
        if item.isNested {
            return "嵌套模块/类型不参与静态目录 join（\(item.section):\(item.dataID)），无逐级数据。"
        }
        if catalogItem == nil {
            return item.missingReason ?? "静态目录未收录该项目，无逐级数据。"
        }
        return nil
    }

    private func durationLabel(_ level: CatalogLevel) -> String {
        guard let seconds = level.durationSeconds else { return "暂无目录数据" }
        if seconds > 0 { return AccountDurationFormatter.label(seconds) }
        return "即时"
    }

    private func unlockLabel(_ level: CatalogLevel) -> String {
        var parts: [String] = []
        if let th = level.requiredTownHallLevel { parts.append("大本营 " + String(th) + " 级") }
        if let lab = level.requiredLaboratoryLevel { parts.append("实验室 " + String(lab) + " 级") }
        return parts.isEmpty ? "无解锁条件" : parts.joined(separator: " · ")
    }

    private func costLabel(_ level: CatalogLevel) -> String {
        guard let cost = level.upgradeCost else { return "无费用数据" }
        let resource = level.upgradeResource ?? "资源"
        return resource + " " + String(cost)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 项目头部
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: item.category?.systemImage ?? "hammer.fill")
                            .font(.title2)
                            .foregroundStyle(item.category?.tint ?? Color.secondary)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.title3.weight(.bold))
                            Text(item.category?.title ?? item.section)
                                + Text(" · #" + String(item.dataID))
                            Text(statusLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.status == .maxed ? .green : (item.isUpgrading ? .orange : .secondary))
                        }
                    }

                    if let missingNote {
                        Label(missingNote, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text("全部等级（目录 v" + (catalog?.gameVersion ?? "?") + "）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 0) {
                            ForEach(levelRows) { level in
                                levelRow(level)
                                if level.id != levelRows.last?.id {
                                    Divider().padding(.leading, 12)
                                }
                            }
                        }
                        .background(Color.cocPanel, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(24)
            }
            .background(Color.cocBackground)
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func levelRow(_ level: CatalogLevel) -> some View {
        let isCurrent = item.currentLevel == level.level
        let isNext = item.nextLevel == level.level
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Lv " + String(level.level))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                    if isCurrent {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15), in: Capsule())
                    }
                    if isNext {
                        Text("下一级")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(durationLabel(level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(costLabel(level))
                    .font(.caption)
                Text(unlockLabel(level))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isCurrent ? Color.blue.opacity(0.07) : Color.clear)
    }
}
```

**注意：**
- `Color.cocPanel` / `Color.cocBackground` 在 ContentView.swift 的 `extension Color` 中，同 target 可用
- `TrackerCategory.tint/systemImage` 在 ContentView.swift 的 private extension 中（`private extension TrackerCategory` 里的 `tint` 是 private！）。**检查**：`UpgradeDisplayRow.swift` 的 extension `TrackerCategory { var tint }` 是 **internal**（无 private），ContentView 里的是 `private extension`。两个文件都在 COCHelper target——同 target 同名 extension 成员：ContentView 的 private tint 与 UpgradeDisplayRow 的 internal tint 冲突吗？不会——private 只在本文件可见，internal 的 wins？实际 Swift 规则：同一类型两个 extension 定义同名成员（一个 private 一个 internal）会编译报错吗？不会，private 成员只在该文件内可见，另一个 extension 的 internal 成员全局可见，无冲突（文件内访问优先 private 的？这有歧义风险——如果 ContentView.swift 里有 `private extension TrackerCategory { var tint }`，而 UpgradeDisplayRow.swift 有 internal 的，ContentView.swift 内用 tint 会解析到 private 的，其他文件解析到 internal 的。Swift 允许，无冲突）。
  - 结论：LevelDetailSheet.swift 可以安全使用 `item.category?.tint`（解析到 UpgradeDisplayRow.swift 的 internal 版本）。若编译报歧义再处理——implementer 验证时注意。

---

### Task 4: `VillageDetailView` + `ContentView` 路由

**Files:**
- Create: `Sources/COCHelper/VillageDetailView.swift`
- Modify: `Sources/COCHelper/ContentView.swift`（一行路由）
- Test: 无（逻辑已下沉 Core，UI 靠 build + 手工）

- [ ] **Step 1: 实现 `VillageDetailView.swift`**（完整代码见下）
- [ ] **Step 2: 修改 `ContentView.swift`** 第 97-100 行：
```swift
            case .villageTracker(let villageID):
                UpgradeTrackerView(villageID: villageID) {
                    selection = .accountData
                }
```
改为：
```swift
            case .villageTracker(let villageID):
                VillageDetailView(villageID: villageID) {
                    selection = .accountData
                }
```
- [ ] **Step 3: 验证** `swift build`（exit 0）
- [ ] **Step 4: Commit** `feat: village detail page with category filter and base switch (Issue #16)`

**实现代码（完整）：**

```swift
import SwiftUI
import COCHelperCore

/// Issue #16：村庄详情页。
///
/// 数据流：`VillageCatalogProjection.project(village:catalog:base:now:)`（#14 投影层）
/// → `VillageDetailProjection`（分组/完成度，本页纯展示）。
/// 列表行复用 #15 的 `UpgradeDisplayRow`（`showsVillageColumn = false`）。
struct VillageDetailView: View {
    @EnvironmentObject private var model: AppModel
    let villageID: UUID
    let openImport: () -> Void

    @State private var selectedBase: TrackerBase = .home
    @State private var selectedFilter: CategoryFilter = .all
    @State private var selectedItem: VillageItemState?

    private var village: VillageProfile? {
        model.villages.first(where: { $0.id == villageID })
    }

    private var catalog: GameCatalog? { model.gameCatalog }

    var body: some View {
        Group {
            if let village {
                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    detailContent(village: village, now: context.date)
                }
            } else {
                ContentUnavailableView(
                    "村庄不存在",
                    systemImage: "questionmark.folder",
                    description: Text("该村庄可能已被删除。")
                )
            }
        }
        .background(Color.cocBackground)
        .sheet(item: $selectedItem) { item in
            LevelDetailSheet(item: item, catalog: catalog, now: Date())
        }
    }

    private func detailContent(village: VillageProfile, now: Date) -> some View {
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            base: selectedBase,
            now: now
        )
        let groups = VillageDetailProjection.groups(from: projection.items)
        let total = VillageDetailProjection.totalCompletion(from: projection.items)
        let displayGroups = filtered(groups)

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(village: village, projection: projection, total: total)
                basePicker()
                categoryFilterBar(groups: groups)

                if displayGroups.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("当前筛选下没有项目", systemImage: "line.3.horizontal.decrease.circle")
                                .font(.subheadline.weight(.semibold))
                            Text("切换基地或分类查看其他项目；导入快照后这里会列出该村庄全部已观测建筑与部队。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(displayGroups) { group in
                        sectionCard(group: group)
                    }
                }
            }
            .padding(28)
        }
    }

    // MARK: - 头部

    private func header(
        village: VillageProfile,
        projection: VillageCatalogProjection,
        total: VillageCategoryCompletion
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(village.name)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(village.tag ?? "尚未导入账号 JSON")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        snapshotTimeLabel(village)
                        if let version = projection.catalogVersion {
                            Text("目录 v" + version)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Button(action: openImport) {
                    Label("更新快照", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .tint(Color.cocAccent)
            }

            completionBar(total: total)
            diagnosticsNote(projection)
        }
    }

    private func snapshotTimeLabel(_ village: VillageProfile) -> some View {
        let text: String
        if let capturedAt = village.accountSnapshot?.capturedAt {
            text = "快照 " + capturedAt.formatted(date: .abbreviated, time: .shortened)
        } else if let importedAt = village.accountSnapshot?.importedAt {
            text = "导入 " + importedAt.formatted(date: .abbreviated, time: .shortened)
        } else {
            text = "尚未导入快照"
        }
        return Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
    }

    private func completionBar(total: VillageCategoryCompletion) -> some View {
        HStack(spacing: 12) {
            Text("完成度")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let ratio = total.completionRatio {
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .tint(Color.cocAccent)
                    .frame(maxWidth: 260)
                Text(String(Int((ratio * 100).rounded())) + "%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.cocAccent)
                Text(String(total.completedCount) + " / " + String(total.knownCount) + " 已满级")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("无可确认项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if total.unknownCount > 0 {
                Text(String(total.unknownCount) + " 项未知")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.cocAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func diagnosticsNote(_ projection: VillageCatalogProjection) -> some View {
        ForEach(projection.diagnostics) { diagnostic in
            Label(diagnostic.message, systemImage: diagnostic.severity == .warning
                ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.caption)
                .foregroundStyle(diagnostic.severity == .warning ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 筛选

    private func basePicker() -> some View {
        Picker("基地", selection: $selectedBase) {
            ForEach(TrackerBase.allCases) { base in
                Text(base.title).tag(base)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }

    private func categoryFilterBar(groups: [VillageDetailGroup]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "全部", count: groups.reduce(0) { $0 + $1.items.count }, filter: .all)
                ForEach(TrackerCategory.allCases) { category in
                    let count = groups.first(where: { $0.category == category })?.items.count ?? 0
                    filterChip(title: category.title, count: count, filter: .category(category))
                }
                let otherCount = groups.first(where: { $0.category == nil })?.items.count ?? 0
                if otherCount > 0 {
                    filterChip(title: "其他", count: otherCount, filter: .other)
                }
            }
        }
    }

    private func filterChip(title: String, count: Int, filter: CategoryFilter) -> some View {
        Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if count > 0 {
                    Text(String(count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selectedFilter == filter ? Color.white.opacity(0.8) : .secondary)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selectedFilter == filter ? Color.white : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                selectedFilter == filter ? Color.cocAccent : Color.white.opacity(0.06),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func filtered(_ groups: [VillageDetailGroup]) -> [VillageDetailGroup] {
        switch selectedFilter {
        case .all: return groups
        case .category(let c): return groups.filter { $0.category == c }
        case .other: return groups.filter { $0.category == nil }
        }
    }

    // MARK: - 列表

    private func sectionCard(group: VillageDetailGroup) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        group.category?.title ?? "其他",
                        systemImage: group.category?.systemImage ?? "ellipsis.circle"
                    )
                    .font(.headline)
                    Spacer()
                    sectionCompletionLabel(group: group)
                }

                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            UpgradeDisplayRow(
                                record: UpgradeDisplayRecord(
                                    id: villageID.uuidString + ":" + selectedBase.rawValue + ":" + item.id,
                                    villageID: villageID,
                                    villageName: village.name,
                                    villageTag: village.tag,
                                    base: selectedBase,
                                    item: item,
                                    catalogVersion: catalog?.gameVersion
                                ),
                                now: Date(),
                                showsVillageColumn: false
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        if item.id != group.items.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
    }

    private func sectionCompletionLabel(group: VillageDetailGroup) -> some View {
        let stats = VillageDetailProjection.completionStats(from: group.items).first
        guard let stats, let ratio = stats.completionRatio else {
            return Text("无可确认完成度").font(.caption2).foregroundStyle(.tertiary)
        }
        return Text(String(stats.completedCount) + "/" + String(stats.knownCount)
            + " · " + String(Int((ratio * 100).rounded())) + "%")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(stats.completedCount == stats.knownCount ? .green : .secondary)
    }

    private enum CategoryFilter: Hashable {
        case all
        case category(TrackerCategory)
        case other
    }
}
```

**注意：**
- `sectionCompletionLabel` 的 guard/return 类型问题：SwiftUI 的 `some View` 分支返回不同文本需类型一致——`Text` 都是 `Text`，OK（两个分支都返回 Text）。
- `TimelineView` 内 `detailContent` 中 `let projection = ...` 在 ViewBuilder 中定义局部变量：`private func detailContent(...) -> some View` 返回 `ScrollView`，函数体内定义局部 let 是普通 Swift 代码（非 ViewBuilder），合法。
- `group.category?.systemImage`——`systemImage` 是 TrackerCategory 的 internal 属性（TrackerModels.swift），可用。
- `model.gameCatalog` 是 lazy 属性，首次访问触发加载（#15 已确认无感）。

---

### Task 5: 全量验证

- [ ] **Step 1**: `swift test`（全量，0 failures）
- [ ] **Step 2**: `./scripts/build_app.sh`（exit 0，APK 构建成功）
- [ ] **Step 3**: 手工验收清单（交给用户，此处列出）：
  1. 侧边栏点击村庄进入详情页；名称/Tag/快照时间/目录版本/完成度显示正确
  2. 主村/建筑工人基地切换后项目列表更新、无串数据
  3. 分类 chips 筛选正确；"其他"包含 unavailable 项
  4. 墙（count > 1）显示 ×N；进行中项显示进度条/剩余时间
  5. 点行打开逐级 sheet：每级时长/费用/解锁条件；嵌套项显示缺失提示
  6. 切换村庄后无上一个村庄残留

**验收命令（issue #16 原文）：**
```bash
swift test --filter VillageProfileTests
swift test --filter UpgradeTrackerTests
swift test --filter CatalogProjectionTests
swift test --filter UpgradeOverviewProjectionTests
swift test
./scripts/build_app.sh
```

---

## Self-Review（writing-plans 要求）

- **Spec 覆盖**：issue 验收 12 条 —— 详情页入口（Task 4）、base 切换（Task 4）、分类查看（Task 4）、每行图标/等级/下一级/完整时间/状态（复用 UpgradeDisplayRow，Task 4）、墙汇总（投影层已聚合 + Task 4 显示 ×N）、进行中完整/剩余/进度（UpgradeDisplayRow 已含）、逐级详情（Task 3）、图标缺失状态（UpgradeDisplayRow 已含）、目录缺失提示（Task 3 missingNote + Task 4 diagnostics）、快照缺失不显示 0 级（投影层语义 + Task 1 unknown）、村庄切换无残留（Task 4 每 tick 重新投影 + 验收清单 6）、现有测试保持通过（Task 5）。✅
- **Placeholder 扫描**：无 TBD/待补充；所有代码块完整。✅
- **类型一致性**：`VillageDetailProjection.groups/completionStats/totalCompletion` 签名在 Task 1 定义、Task 4 调用一致；`UpgradeDisplayRecord` public init 在 Task 2 定义、Task 4 构造一致；`VillageItemState`/`TrackerCategory`/`CatalogLevel` 字段名与现有代码核对一致。✅
