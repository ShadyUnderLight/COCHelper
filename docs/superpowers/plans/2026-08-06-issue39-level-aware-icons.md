# Issue #39 等级感知图标资产选择实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 升级总览/村庄详情列表行与详情 sheet 头部按 `currentLevel` 选择对应等级的 PNG 资产（`fireplace_lvl2.png` 而非固定 `fireplace_lvl1.png`），保持既有 levelVisual → icon → SF Symbol 回退语义。

**Architecture:** 投影层数据驱动。在 `VillageCatalogProjection.map()` 时把当前等级对应的 `CatalogLevel` 的两个资产 ref（`levelVisual`/`icon`）拷入 `VillageItemState` 新字段，`preferredAssetURLs` 候选链扩为 4 级（currentLevelVisual → currentLevelIcon → levelVisual → icon）。UI 层零逻辑改动（升级总览/村庄详情/详情头部已共用 `item.preferredAssetURLs`，自动生效且天然满足"同一 resolver"要求）。

**Tech Stack:** Swift 6.0 / SwiftPM / XCTest（无第三方依赖；property-based 用手写穷举 + `SeededRNG` 确定性随机，项目已有此模式）

---

## 设计分析（CoT）

**根因**（已在 Issue #39 评审中验证）：`VillageItemState.preferredAssetURLs` 只消费 item-level 的 `levelVisual`/`icon`；对建筑这两者恰好是 `*_lvl1.png`。数据层逐级 PNG 完备（buildings 72/73、buildings2 32/32、traps 16/16、traps2 4/5、capital_buildings 61/62 有逐级 levelVisual；units/spells/heroes 等无逐级资产 → 通用规则对它们自动退化为现状）。

**3 候选方案对比：**

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A（选）** | 投影时把 `CatalogLevel`（按 `currentLevel` 匹配）的 `levelVisual`/`icon` 拷入 `VillageItemState` 新字段，`preferredAssetURLs` 链扩为 4 级 | UI 零改动、resolver 保持纯函数（不依赖 catalog 查找）、无类别特判（数据驱动 → 无串线）、测试只需断言字段与链 | state 多 2 个字段；聚合层需传播 |
| B | state 存 `CatalogLevel?` 整体 | 字段少 1 个 | state 携带 duration/cost 等无关数据；耦合目录结构；Hashable/Sendable 语义膨胀 |
| C | UI 层 resolver 接收 catalog + currentLevel | 投影层不动 | 打破"UI 无 catalog 逻辑"与现有防漂移架构（两处列表 + sheet 都要传 catalog）；风险最高 |

**复杂度评估**：本修复属低复杂度（1 个模型字段扩展 + 1 个链式改动 + 数据拷贝），不触发 3 候选 subagent 投票；方案对比已在上述表格完成并由控制器裁定。

**类型契约（新增）：**

```swift
// VillageItemState 新增（level-level 资产，来自 currentLevel 匹配的 CatalogLevel）
public let currentLevelVisual: CatalogAssetRef?
public let currentLevelIcon: CatalogAssetRef?

// init 参数位置：icon、levelVisual 之后、isNested 之前
// (..., icon: CatalogAssetRef?, levelVisual: CatalogAssetRef?,
//  currentLevelIcon: CatalogAssetRef?, currentLevelVisual: CatalogAssetRef?,
//  isNested: Bool)

// preferredAssetURLs 候选链（顺序即优先级，与 issue #39 期望一致）：
// currentLevelVisual → currentLevelIcon → levelVisual → icon
public func preferredAssetURLs(version: String) -> [URL] {
    CatalogAssetRef.availableURLs(
        [currentLevelVisual, currentLevelIcon, levelVisual, icon], version: version)
}
```

**关键不变式（property-based 测试锚点）：**
- P1 链序保持：输出 URL 序列 == 输入候选序列中"可渲染且 Bundle 文件存在"者的**有序子序列**（4 槽位 × 4 状态穷举 256 组合）
- P2 无猜测：`currentLevelVisual/currentLevelIcon` 只可能 == 目录中 `level == currentLevel` 的 `CatalogLevel` 对应 ref，其他情况必为 nil（随机等级 property）
- P3 全空间覆盖：bundled 目录所有 buildings/buildings2/traps/traps2 的每个 level 组合，投影结果字段必须精确命中该 level 的 ref
- P4 聚合传播：同 `(section,dataID,level)` 非升级记录聚合后字段保留
- P5 升级中显示当前级：`nextLevel` 不参与资产选择

---

### Task 1: `VillageItemState` 类型契约扩展（字段 + init + 链）

**Files:**
- Modify: `Sources/COCHelperCore/VillageCatalogProjection.swift`（字段声明 ~L40-42、`preferredAssetURLs` L69-71、init 参数与赋值）
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`（`makeAssetState` 扩展 + 穷举真值表）

- [ ] **Step 1: 写失败测试 —— 扩展 `makeAssetState` 加默认参数**

```swift
private func makeAssetState(
    icon: CatalogAssetRef?,
    levelVisual: CatalogAssetRef?,
    currentLevelIcon: CatalogAssetRef? = nil,
    currentLevelVisual: CatalogAssetRef? = nil
) -> VillageItemState {
    VillageItemState(
        id: "units:0",
        section: "units",
        dataID: 4_000_000,
        base: .home,
        name: "野蛮人",
        category: .troops,
        currentLevel: 2,
        count: nil,
        timerSeconds: nil,
        remainingSeconds: nil,
        nextLevel: 3,
        nextLevelDurationSeconds: 3600,
        maxLevel: 3,
        status: .complete,
        missingReason: nil,
        icon: icon,
        levelVisual: levelVisual,
        currentLevelIcon: currentLevelIcon,
        currentLevelVisual: currentLevelVisual,
        isNested: false
    )
}
```

- [ ] **Step 2: 写失败测试 —— 链优先级穷举（P1，4 槽位 × 4 状态 = 256 组合）**

在 `testPreferredAssetURLsTruthTable` 之后新增：

```swift
/// P1 property-based（穷举全空间）：候选链 currentLevelVisual → currentLevelIcon
/// → levelVisual → icon，4 槽位 × 4 状态（nil / 真实可加载 / phantom 文件缺失 /
/// 带缺失原因）= 256 组合。断言：输出 == 候选序列中有序过滤「isRenderable 且
/// Bundle 文件真实存在」后的 URL 子序列（顺序保持、无泄漏、无乱序）。
func testPropertyAssetChainExhaustivePriority256() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    let realPaths = realRenderedPaths(catalog, count: 4)
    let version = GameCatalog.defaultBundledVersion
    enum Slot: Int, CaseIterable { case nilRef, real, phantom, missing }
    // 每个槽位一个独立真实路径（可区分顺序），phantom/missing 均为不可加载。
    let refFor: (Slot, Int) -> CatalogAssetRef? = { slot, idx in
        switch slot {
        case .nilRef: return nil
        case .real:
            return CatalogAssetRef(
                container: nil, exportName: nil,
                renderedPath: realPaths[idx], missingReason: nil
            )
        case .phantom:
            return CatalogAssetRef(
                container: nil, exportName: nil,
                renderedPath: "icons/buildings/phantom_lvl\(idx).png", missingReason: nil
            )
        case .missing:
            return CatalogAssetRef(
                container: nil, exportName: nil,
                renderedPath: nil, missingReason: "icons_not_rendered"
            )
        }
    }
    // 链槽位顺序：currentLevelVisual → currentLevelIcon → levelVisual → icon
    let chain: [(Slot, Int)] = [(.nilRef, 0), (.real, 0), (.phantom, 0), (.missing, 0)]
    var combos = 0
    for a in Slot.allCases { for b in Slot.allCases {
        for c in Slot.allCases { for d in Slot.allCases {
            let state = makeAssetState(
                icon: refFor(d, 3), levelVisual: refFor(c, 2),
                currentLevelIcon: refFor(b, 1), currentLevelVisual: refFor(a, 0)
            )
            let urls = state.preferredAssetURLs(version: version)
            // 期望：按链序取所有 .real 槽位的真实 URL
            var expected: [URL] = []
            var realRefs: [(Slot, CatalogAssetRef)] = []
            for (slot, idx) in [(a, 0), (b, 1), (c, 2), (d, 3)] where slot == .real {
                realRefs.append((slot, try XCTUnwrap(refFor(slot, idx))))
            }
            for (_, ref) in realRefs {
                expected.append(try XCTUnwrap(ref.bundledURL(version: version)))
            }
            XCTAssertEqual(
                urls, expected,
                "组合 a=\(a) b=\(b) c=\(c) d=\(d)：输出应为可加载候选的有序子序列"
            )
            combos += 1
        }}
    }}
    XCTAssertEqual(combos, 256, "穷举应覆盖 4^4 全空间")
}
```

- [ ] **Step 3: 运行测试确认失败（RED）**

Run: `swift test --filter VillageCatalogProjectionTests/testPropertyAssetChainExhaustivePriority256`
Expected: 编译失败 `cannot find 'currentLevelIcon' in scope` / 测试失败（链未包含新候选时组合 0 槽位 real 断言失败）。**必须看到失败。**

- [ ] **Step 4: 最小实现 —— 字段 + init + 链**

在 `Sources/COCHelperCore/VillageCatalogProjection.swift`：

```swift
// VillageItemState 属性区（icon 之后）：
public let icon: CatalogAssetRef?
public let levelVisual: CatalogAssetRef?
/// 当前等级（currentLevel）匹配的 CatalogLevel 资产（level-level，Issue #39）：
/// 列表行/详情头部按 currentLevel 显示对应等级外观；无匹配等级时为 nil。
/// 注意与 item-level 的 icon/levelVisual 区分：这两者来自 CatalogLevel，
/// 选择优先级高于 item-level 资产（见 preferredAssetURLs）。
public let currentLevelIcon: CatalogAssetRef?
public let currentLevelVisual: CatalogAssetRef?
public let isNested: Bool
```

```swift
public func preferredAssetURLs(version: String) -> [URL] {
    CatalogAssetRef.availableURLs(
        [currentLevelVisual, currentLevelIcon, levelVisual, icon],
        version: version
    )
}
```

init 签名在 `icon: CatalogAssetRef?, levelVisual: CatalogAssetRef?` 之后插入：

```swift
icon: CatalogAssetRef?,
levelVisual: CatalogAssetRef?,
currentLevelIcon: CatalogAssetRef?,
currentLevelVisual: CatalogAssetRef?,
isNested: Bool
```

并在 init 体补两行赋值 `self.currentLevelIcon = currentLevelIcon`、`self.currentLevelVisual = currentLevelVisual`。doc comment（L63-71 附近）更新链描述为 4 级。**其他构造点暂不改**（编译错误会在 Task 5 统一修复——但这样 Task 1 无法编译过？见 Step 5 说明）。

- [ ] **Step 5: 同步修复同文件其余 2 个构造点，跑测试确认通过（GREEN）**

`VillageCatalogProjection.swift` 内 `map()` 的 unavailable 分支（~L207）与 main 返回（~L296）、`aggregate()`（~L378）三个 `VillageItemState(...)` 调用全部补 `currentLevelIcon: nil, currentLevelVisual: nil`（Task 2/3 会替换为真实值）。测试文件里 `makeAssetState` 已带默认参数无需改。然后：

Run: `swift test --filter VillageCatalogProjectionTests/testPropertyAssetChainExhaustivePriority256 && swift test --filter VillageCatalogProjectionTests/testPreferredAssetURLsTruthTable`
Expected: 两个测试全绿（真值表测试因默认参数 nil 行为不变）。

- [ ] **Step 6: Commit**

```bash
git add Sources/COCHelperCore/VillageCatalogProjection.swift Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "feat(core): VillageItemState 增加当前等级资产候选字段（Issue #39）"
```

---

### Task 2: `map()` 解析当前等级资产 + `aggregate()` 传播

**Files:**
- Modify: `Sources/COCHelperCore/VillageCatalogProjection.swift`（`map()` ~L296 与 `aggregate()` ~L378）
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`（新增集成测试）

- [ ] **Step 1: 写失败测试 —— 投影解析当前等级（P2/P3 的合成版 + P4 聚合传播）**

在 `testPropertyEveryUpgradingRecordSurvivesProjection` 之前新增：

```swift
// MARK: - Issue #39: currentLevel 资产解析

/// 需要带资产的合成目录（bundled 之外的最小可控输入）：加农炮两级的
/// levelVisual 用「真实存在」的 bundled 路径，便于断言回退链。
private var levelAwareCatalog: GameCatalog {
    // 构造：buildings:1000001 levels[1].levelVisual = realPaths[0]，
    // levels[2].levelVisual = realPaths[1]，item-level 不设资产。
    get throws -> GameCatalog { ... }  // 见下，实际用 helper 构造
}
```

实现为测试方法内联构造（不新增 fixture JSON，避免大段 JSON 与 helper 漂移）：

```swift
func testProjectionResolvesCurrentLevelAssets() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    let realPaths = realRenderedPaths(catalog, count: 2)
    let level1Visual = CatalogAssetRef(
        container: nil, exportName: nil, renderedPath: realPaths[0], missingReason: nil
    )
    let level2Visual = CatalogAssetRef(
        container: nil, exportName: nil, renderedPath: realPaths[1], missingReason: nil
    )
    let item = CatalogItem(
        section: "buildings", category: "buildings", dataID: 1_000_001,
        base: "home", baseMissingReason: nil, name: "加农炮", maxLevel: 2,
        icon: nil, levelVisual: nil,
        levels: [
            CatalogLevel(level: 1, durationSeconds: 60, upgradeResource: nil,
                         upgradeCost: nil, requiredTownHallLevel: nil,
                         requiredLaboratoryLevel: nil,
                         icon: nil, levelVisual: level1Visual, missingReason: nil),
            CatalogLevel(level: 2, durationSeconds: 300, upgradeResource: nil,
                         upgradeCost: nil, requiredTownHallLevel: nil,
                         requiredLaboratoryLevel: nil,
                         icon: nil, levelVisual: level2Visual, missingReason: nil),
        ]
    )
    let catalog = GameCatalog(gameVersion: GameCatalog.defaultBundledVersion, items: [item])

    // 当前等级 2 → 命中 levels[2].levelVisual
    let village = makeVillage(objectSections: [
        "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0")]
    ])
    let home = project(village: village, catalog: catalog, base: .home)
    let state = try XCTUnwrap(home.items.first)
    XCTAssertEqual(state.currentLevel, 2)
    XCTAssertEqual(state.currentLevelVisual, level2Visual,
                   "currentLevel=2 → 命中 levels[2] 的 levelVisual")
    XCTAssertNil(state.currentLevelIcon)
    XCTAssertNil(state.levelVisual, "item-level 无资产 → nil（不被伪造）")

    // 聚合传播（P4）：两条同 (section,dataID,level=2) 非升级记录 → 聚合 1 条，字段保留
    let village2 = makeVillage(objectSections: [
        "buildings": [
            makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0"),
            makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "1"),
        ]
    ])
    let home2 = project(village: village2, catalog: catalog, base: .home)
    let aggregated = try XCTUnwrap(home2.items.first)
    XCTAssertEqual(aggregated.count, 2, "两条同键非升级记录应聚合为一条 ×2")
    XCTAssertEqual(aggregated.currentLevelVisual, level2Visual,
                   "聚合项必须保留当前等级资产（P4）")

    // 升级中（P5）：remaining > 0 且 currentLevel=2 → 仍命中 Lv2，与 nextLevel 无关
    let village3 = makeVillage(objectSections: [
        "buildings": [makeItem(
            section: "buildings", dataID: 1_000_001, level: 2, path: "0",
            timerSeconds: 600, remainingSeconds: 300
        )]
    ])
    let home3 = project(village: village3, catalog: catalog, base: .home)
    let upgrading = try XCTUnwrap(home3.items.first)
    XCTAssertTrue(upgrading.isUpgrading)
    XCTAssertEqual(upgrading.nextLevel, 3, "升级中 nextLevel = currentLevel + 1（#14 契约）")
    XCTAssertEqual(upgrading.currentLevelVisual, level2Visual,
                   "升级中仍显示当前等级外观，不提前显示目标等级（P5）")
}
```

注意：`CatalogLevel` 和 `CatalogItem` 的 init 是否 public memberwise？`CatalogItem`/`CatalogLevel` 是 `Codable, Identifiable, Hashable, Sendable` struct，**没有自定义 init** → 隐式 memberwise init 为 internal，测试 target 用 `@testable import COCHelperCore` 可访问（现有 `makeCatalog` 测试已用 JSON 构造，说明可用）。若编译报错改用 JSON 构造（沿用 `makeCatalog` 模式）。

- [ ] **Step 2: 运行测试确认失败（RED）**

Run: `swift test --filter VillageCatalogProjectionTests/testProjectionResolvesCurrentLevelAssets`
Expected: FAIL（state.currentLevelVisual 为 nil，实际 nil != level2Visual）。**必须看到失败。**

- [ ] **Step 3: 最小实现 —— `map()` 解析 + `aggregate()` 传播**

`map()` 中，在计算 `nextLevelDuration` 之后、构造 `VillageItemState` 之前插入：

```swift
// Issue #39：当前等级资产。按值匹配 level（目录等级号可能不连续），
// 仅 baseMatches 且目录命中时解析；currentLevel 为 nil / 超范围 / 未收录
// 时两字段均为 nil，UI 回退 item-level 资产（不按名称/位置猜测）。
let currentLevelAssets: (visual: CatalogAssetRef?, icon: CatalogAssetRef?)
if baseMatches, let catalogItem, let level = item.level {
    let matched = catalogItem.levels.first { $0.level == level }
    currentLevelAssets = (matched?.levelVisual, matched?.icon)
} else {
    currentLevelAssets = (nil, nil)
}
```

main 返回的 `VillageItemState(...)` 参数补：

```swift
icon: baseMatches ? catalogItem?.icon : nil,
levelVisual: baseMatches ? catalogItem?.levelVisual : nil,
currentLevelIcon: currentLevelAssets.icon,
currentLevelVisual: currentLevelAssets.visual,
isNested: isNested
```

`aggregate()` 的构造补：

```swift
icon: first.icon,
levelVisual: first.levelVisual,
currentLevelIcon: first.currentLevelIcon,
currentLevelVisual: first.currentLevelVisual,
isNested: first.isNested
```

- [ ] **Step 4: 运行测试确认通过（GREEN）**

Run: `swift test --filter VillageCatalogProjectionTests/testProjectionResolvesCurrentLevelAssets`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/VillageCatalogProjection.swift Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "feat(core): 投影按 currentLevel 解析等级资产并在聚合中传播（Issue #39）"
```

---

### Task 3: bundled 真实数据集成测试（数据锚点）

**Files:**
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`（新增）

- [ ] **Step 1: 写失败测试 —— bundled 目录等级解析 + 回退**

```swift
/// 数据锚点（Issue #39）：真实 bundled 目录中 buildings:1000000（壁炉）
/// Lv2 必须解析到 fireplace_lvl2.png、Lv14 到 fireplace_lvl14.png，
/// 而不是固定 item-level 的 fireplace_lvl1.png。目录数据漂移立即红。
func testBundledFireplaceResolvesLevelAppearance() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    let version = catalog.gameVersion

    func stateFor(level: Int) throws -> VillageItemState {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_000, level: level, path: "0")]
        ])
        return try XCTUnwrap(
            project(village: village, catalog: catalog, base: .home).items.first
        )
    }

    // Lv2 → 精确命中 levels[2].levelVisual（fireplace_lvl2.png）
    let lv2 = try stateFor(level: 2)
    XCTAssertEqual(lv2.currentLevelVisual?.renderedPath, "icons/buildings/fireplace_lvl2.png")
    XCTAssertEqual(
        lv2.preferredAssetURLs(version: version).first,
        try XCTUnwrap(lv2.currentLevelVisual?.bundledURL(version: version)),
        "Lv2 首选 URL 必须是 fireplace_lvl2.png 而非 lvl1"
    )

    // Lv14 → fireplace_lvl14.png
    let lv14 = try stateFor(level: 14)
    XCTAssertEqual(lv14.currentLevelVisual?.renderedPath, "icons/buildings/fireplace_lvl14.png")
    XCTAssertEqual(
        lv14.preferredAssetURLs(version: version).first,
        try XCTUnwrap(lv14.currentLevelVisual?.bundledURL(version: version)),
        "Lv14 首选 URL 必须是 fireplace_lvl14.png 而非 lvl1"
    )

    // 超范围（Lv15 > maxLevel 14）→ 不猜等级资源，回退 item-level lvl1
    let lv15 = try stateFor(level: 15)
    XCTAssertNil(lv15.currentLevelVisual, "超范围等级不得猜测资产")
    XCTAssertEqual(
        lv15.preferredAssetURLs(version: version).first,
        try XCTUnwrap(lv15.levelVisual?.bundledURL(version: version)),
        "超范围 → 回退 item-level levelVisual"
    )

    // currentLevel nil → 同样回退 item-level
    let noLevel = makeVillage(objectSections: [
        "buildings": [makeItem(section: "buildings", dataID: 1_000_000, level: nil, path: "0")]
    ])
    let nilState = try XCTUnwrap(project(village: noLevel, catalog: catalog, base: .home).items.first)
    XCTAssertNil(nilState.currentLevelVisual)
    XCTAssertEqual(
        nilState.preferredAssetURLs(version: version).first,
        try XCTUnwrap(nilState.levelVisual?.bundledURL(version: version)),
        "currentLevel nil → 回退 item-level levelVisual"
    )
}
```

- [ ] **Step 2: 运行测试确认失败（RED）**

Run: `swift test --filter VillageCatalogProjectionTests/testBundledFireplaceResolvesLevelAppearance`
Expected: FAIL（`lv2.currentLevelVisual` 为 nil —— 等 Task 2 实现后此测试可能已绿；若 Task 2 已合入则本测试应为 GREEN 状态，属于数据锚点确认测试。**注意**：若当前为 GREEN，需确认断言是"真正命中 lvl2"而非碰巧通过，可临时改为 Lv2 期望 lvl3 验证测试有效性后改回）。

- [ ] **Step 3: 写失败测试 —— 缺失回退 + 类别不串线**

```swift
/// 当前等级资产缺失 → 安全回退 item-level（traps2:12000011 Lv1 levelVisual
/// 为 export_not_found；buildings:1000059 Lv2 levelVisual 为 render_failed，
/// 均来自 GameCatalogTests 已知数据契约）。
func testBundledMissingLevelAssetFallsBackToItemLevel() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    let version = catalog.gameVersion

    // traps2:12000011 push_trap Lv1：level 级 levelVisual 带缺失原因
    let pushTrap = try XCTUnwrap(
        catalog.item(section: "traps2", dataID: 12_000_011),
        "bundled 目录应包含 traps2:12000011"
    )
    let trapVillage = makeVillage(objectSections: [
        "traps2": [makeItem(section: "traps2", dataID: 12_000_011, level: 1, path: "0")]
    ])
    let trapState = try XCTUnwrap(
        project(village: trapVillage, catalog: catalog, base: .builder).items.first
    )
    let trapLevelVisual = try XCTUnwrap(
        pushTrap.levels.first { $0.level == 1 }?.levelVisual
    )
    XCTAssertEqual(trapState.currentLevelVisual, trapLevelVisual,
                   "level 级 ref 原样暴露（含缺失原因），由链过滤")
    XCTAssertFalse(trapState.currentLevelVisual?.isRenderable ?? false)
    // 链过滤后首选回退 item-level（若可渲染）
    let trapURLs = trapState.preferredAssetURLs(version: version)
    XCTAssertFalse(trapURLs.contains { $0 == trapLevelVisual.bundledURL(version: version) },
                   "不可渲染的 level 资产不得出现在候选 URL 中")

    // buildings:1000059 siegeWorkshop Lv2 → render_failed 同样被过滤
    let siege = try XCTUnwrap(
        catalog.item(section: "buildings", dataID: 100_059),
        "bundled 目录应包含 buildings:1000059"
    )
    let siegeVillage = makeVillage(objectSections: [
        "buildings": [makeItem(section: "buildings", dataID: 100_059, level: 2, path: "0")]
    ])
    let siegeState = try XCTUnwrap(
        project(village: siegeVillage, catalog: catalog, base: .home).items.first
    )
    let siegeLevelVisual = try XCTUnwrap(
        siege.levels.first { $0.level == 2 }?.levelVisual
    )
    XCTAssertEqual(siegeState.currentLevelVisual, siegeLevelVisual)
    XCTAssertFalse(siegeState.currentLevelVisual?.isRenderable ?? false)
}

/// 类别不串线：buildings2:1000033（secondVillage_wall）Lv2 必须命中
/// buildings2 自己的逐级路径，不得命中 buildings 同名资源。
func testBundledSectionsDoNotCrossResolve() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    let village = makeVillage(objectSections: [
        "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 2, path: "0")]
    ])
    let state = try XCTUnwrap(
        project(village: village, catalog: catalog, base: .builder).items.first
    )
    XCTAssertEqual(
        state.currentLevelVisual?.renderedPath,
        catalog.item(section: "buildings2", dataID: 1_000_033)?
            .levels.first { $0.level == 2 }?.levelVisual?.renderedPath,
        "buildings2 资产必须来自 buildings2 目录项（按 section:dataID join）"
    )
    XCTAssertNotEqual(
        state.currentLevelVisual?.renderedPath,
        "icons/buildings/secondVillage_wall_lvl2.png".replacingOccurrences(of: "icons/buildings/", with: "icons/buildings2/") == ""
            ? nil : nil,
        "占位断言（见下）"
    )
}
```

（第二个断言为占位，实现时改为：显式断言该路径以 `icons/buildings2/` 开头即可，去掉占位逻辑。）

- [ ] **Step 4: 运行测试确认失败（RED）**

Run: `swift test --filter VillageCatalogProjectionTests/testBundledMissingLevelAssetFallsBackToItemLevel --filter VillageCatalogProjectionTests/testBundledSectionsDoNotCrossResolve`
Expected: FAIL（字段缺失或解析错误）。**必须看到失败。**

- [ ] **Step 5: 修复（若 Task 2 已实现这些应直接 GREEN；如 RED 则回到 Task 2 检查实现）**

Run: `swift test --filter VillageCatalogProjectionTests/testBundled`
Expected: 全部 PASS。

- [ ] **Step 6: Commit**

```bash
git add Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "test(core): bundled 目录等级资产数据锚点与缺失回退（Issue #39）"
```

---

### Task 4: property-based 全空间 + 随机等级测试

**Files:**
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`（新增）

- [ ] **Step 1: 写失败测试 —— P3 全空间穷举 + P2 无猜测随机**

```swift
/// P3 property-based（全空间穷举）：bundled 目录 buildings/buildings2/traps/traps2
/// 的每个 item × 每个 level 组合都投影一次，断言 currentLevelVisual/currentLevelIcon
/// 精确等于该 level 的 ref（ref 存在则相等、不存在则 nil）。
func testPropertyEveryBundledLevelResolvesExactly() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    var checked = 0
    for section in ["buildings", "buildings2", "traps", "traps2"] {
        let base: TrackerBase = section.hasSuffix("2") ? .builder : .home
        for item in catalog.items(in: section) {
            for level in item.levels {
                let village = makeVillage(objectSections: [
                    section: [makeItem(section: section, dataID: item.dataID,
                                       level: level.level, path: "0")]
                ])
                let state = try XCTUnwrap(
                    project(village: village, catalog: catalog, base: base).items.first,
                    "\(section):\(item.dataID)@Lv\(level.level) 投影应产出状态"
                )
                XCTAssertEqual(
                    state.currentLevelVisual?.renderedPath,
                    level.levelVisual?.renderedPath,
                    "\(section):\(item.dataID)@Lv\(level.level) currentLevelVisual 必须精确命中"
                )
                XCTAssertEqual(
                    state.currentLevelIcon?.renderedPath,
                    level.icon?.renderedPath,
                    "\(section):\(item.dataID)@Lv\(level.level) currentLevelIcon 必须精确命中"
                )
                checked += 1
            }
        }
    }
    XCTAssertGreaterThan(checked, 500, "穷举应覆盖 500+ 个 item×level 组合（实际约 \(checked)）")
}

/// P2 property-based（确定性随机）：随机 (section, dataID, level)，level 可能
/// 为 0 / 超范围 / 目录无此等级 —— 断言绝不猜测：字段只可能等于按值匹配的
/// CatalogLevel ref，无匹配则必为 nil。
func testPropertyRandomLevelsNeverGuessAssets() throws {
    var rng = SeededRNG(seed: 20_260_806)
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    let sections = ["buildings", "buildings2", "traps", "traps2", "units", "heroes"]
    for _ in 0..<60 {
        let section = sections[Int.random(in: 0..<sections.count, using: &rng)]
        let items = catalog.items(in: section)
        let item = items[Int.random(in: 0..<items.count, using: &rng)]
        let level = Int.random(in: 0...(item.maxLevel + 3), using: &rng)
        let base: TrackerBase = section.hasSuffix("2") ? .builder : .home
        let village = makeVillage(objectSections: [
            section: [makeItem(section: section, dataID: item.dataID, level: level, path: "0")]
        ])
        let state = try XCTUnwrap(
            project(village: village, catalog: catalog, base: base).items.first
        )
        let matched = item.levels.first { $0.level == level }
        XCTAssertEqual(
            state.currentLevelVisual?.renderedPath, matched?.levelVisual?.renderedPath,
            "\(section):\(item.dataID)@Lv\(level) 不得猜测等级资产"
        )
        XCTAssertEqual(
            state.currentLevelIcon?.renderedPath, matched?.icon?.renderedPath,
            "\(section):\(item.dataID)@Lv\(level) 不得猜测等级资产"
        )
    }
}
```

- [ ] **Step 2: 运行测试确认失败（RED）**

Run: `swift test --filter VillageCatalogProjectionTests/testProperty`
Expected: FAIL（若 Task 2/3 已实现则为 GREEN，此时可临时断言 `state.currentLevelVisual?.renderedPath == "icons/units/barbarian.png"` 验证测试有效后改回）。

- [ ] **Step 3: 确认 GREEN 后 Commit**

```bash
git add Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "test(core): property-based 等级资产解析全空间穷举与无猜测性质（Issue #39）"
```

---

### Task 5: 其余构造点 + UI doc + 全量验证

**Files:**
- Modify: `Tests/COCHelperCoreTests/VillageDetailProjectionTests.swift`（`VillageItemState(` 构造 ~L19）
- Modify: `Tests/COCHelperCoreTests/UpgradeOverviewProjectionTests.swift`（构造 ~L123、~L616）
- Modify: `Sources/COCHelper/UpgradeDisplayRow.swift`（doc comment：L8-13、L140-146）
- Modify: `Sources/COCHelper/LevelDetailSheet.swift`（doc comment：L74-77）
- Modify: `Tests/COCHelperCoreTests/UpgradeOverviewProjectionTests.swift`（可选：升级总览集成断言）

- [ ] **Step 1: 修复全部 `VillageItemState(` 构造点**

在 `VillageDetailProjectionTests.swift` 与 `UpgradeOverviewProjectionTests.swift` 的每个 `VillageItemState(...)` 调用中，`levelVisual:` 参数之后补 `currentLevelIcon: nil, currentLevelVisual: nil,`。

Run: `swift build 2>&1 | tail -5`
Expected: 编译通过，无 error。

- [ ] **Step 2: 新增升级总览集成断言（可选但推荐）**

在 `UpgradeOverviewProjectionTests.swift` 现有 activeRecords 测试（~L530 附近 `XCTAssertEqual(record.item.currentLevel, 2)`）之后补：

```swift
XCTAssertEqual(
    record.item.currentLevelVisual?.renderedPath,
    record.item.currentLevelVisual?.renderedPath,
    "升级总览记录保留投影等级资产（当前等级外观）"
)
```

（占位断言，实现时改为：对已知 dataID 断言其 currentLevelVisual 与 bundled 目录该 level 的 ref 相等。）

- [ ] **Step 3: UI doc comment 更新（无行为变化，不需 TDD）**

`UpgradeDisplayRow.swift` L8-13 与 L140-146 的注释中，把「levelVisual → icon 运行时候选」改为「currentLevelVisual → currentLevelIcon → levelVisual → icon（Issue #39：按 currentLevel 显示对应等级外观）」。`LevelDetailSheet.swift` L74-77 的 `headerImage` 注释同步。

- [ ] **Step 4: 全量验证**

Run:
```bash
swift test --filter VillageCatalogProjectionTests
swift test
swift build -c release
./scripts/build_app.sh
git diff --check
```
Expected: 全绿、Release 构建成功、App 打包成功、diff 无空白错误。

- [ ] **Step 5: 自查清单（Reflexion）**

- [ ] 三个 UI 调用点（升级总览行 / 村庄详情行 / 详情头部）共用 `item.preferredAssetURLs`，无新 UI 逻辑
- [ ] `currentLevel` 为 nil / 超范围 / 未收录时不崩溃、不猜测（P2 测试锁定）
- [ ] 聚合层传播完成（P4 测试锁定）
- [ ] 升级中显示当前级（P5 测试锁定）
- [ ] `assetMissingReason` 语义未改动（仍为 item-level icon 优先）
- [ ] 无类别特判（数据驱动，无串线可能）
- [ ] `CatalogLevel`/`CatalogItem` 模型未改动
- [ ] git diff 只含计划内文件

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "test(core): 补齐构造点参数与升级总览集成断言（Issue #39）"
```

---

## Self-Review（计划自检）

**Spec 覆盖**（对照 Issue #39 验收标准）：
- Lv2/Lv14 列表行显示对应 PNG → Task 3 `testBundledFireplaceResolvesLevelAppearance` ✅
- 升级总览与村庄详情同一 resolver → 架构层面（共用 `item.preferredAssetURLs`），Task 5 集成断言 ✅
- 详情 sheet 顶部显示当前等级 → 共用 `headerImage`（Task 5 doc 更新，行为由 Task 1 链生效）✅
- 升级中不提前显示目标等级 → Task 2 P5 断言 ✅
- 逐级行仍显示各自等级 → 未改 `CatalogLevel.preferredAssetURLs` ✅
- 资源不可用安全回退、SF Symbol 兜底 → Task 3 缺失回退 + Task 1 穷举链 ✅
- 至少一个建筑 + 一个陷阱窗口级验证 → 人工验证步骤（本计划不含 UI 自动化，需用户在 app 中确认）

**类型一致性**：`currentLevelVisual`/`currentLevelIcon` 在全部 Task 中命名一致；init 参数顺序 `icon, levelVisual, currentLevelIcon, currentLevelVisual, isNested` 在 Task 1/2/5 一致。

**风险**：
- Task 1 Step 5 与 Task 2/3 有编译耦合（构造点补齐），已通过同文件先补 nil 避免编译断裂
- 占位断言（Task 3 Step 3、Task 5 Step 2）需实现时替换为真实断言，禁止提交占位
- property 测试中 `CatalogItem`/`CatalogLevel` memberwise init 的 internal 可见性依赖 `@testable import`（测试文件已有），若编译失败改用 JSON + `makeCatalog` 构造
