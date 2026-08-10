# Issue #96 universeCoverage 覆盖契约实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现。步骤用 checkbox（`- [ ]`）语法跟踪。

**Goal:** 拆分 `universeComplete`（建筑/陷阱实例宇宙）与全村庄完整分母权限：新增 `ProgressUniverseCoverage` 三态枚举作为唯一覆盖判定点，未建模类别 fail-closed，三个消费者统一判定口径。

**Architecture:** 投影层（`VillageCatalogProjection.project`）内计算一次 `progressCoverage`；`GameCatalog` 暴露 `universeSections`（从 instanceCounts 键推导，单一事实源）；`VillageProgressMetrics.metrics` 参数从 `completeDenominator: Bool` 改为 `coverage: ProgressUniverseCoverage`；`UpgradeOverviewProjection` / `VillageDetailView` 只传参，不各自解释。

**Tech Stack:** Swift 6 / SwiftPM / XCTest（自研 `SeededGenerator` property 测试）

---

## 设计决策记录（SDD 阶段，3 候选投票结论）

三个独立设计评审 subagent 并行评估候选（A 单枚举 / B 双 Bool / C 保留原名+派生），结论均为"有条件推荐"。投票采用 **方案 A**，并吸收三评审共同决策：

| 决策 | 结论 | 依据 |
|---|---|---|
| D1 覆盖模型 | 方案 A：`ProgressUniverseCoverage` 三态枚举（unavailable / partial(关联诊断) / complete） | 验收 5"单一判定点"结构性最强；A 评审：风格与 CatalogCompatibility 一致；B 评审：Bool+集合非法组合可表示需运行时防御；C 评审：universeComplete 保留命名=验收 1 残留 |
| D2 差集门禁与宣称门禁 | **解耦**：`universeSupplement` 合成门禁 = 内部 `buildingUniverseAvailable`（原布尔逻辑）；stage/global 完整分母门禁 = `coverage.isComplete` | A 评审 R1 + C 评审 R2：partial 时 coverage 分母仍含建筑/陷阱差集（= 建筑覆盖率，真实有用）；stage/global 退回已观测口径；三行指标分开显示恰好满足验收 3 |
| D3 空数组语义 | 键存在即 present：空数组不算缺失 section | 三评审一致（R6/F4/C-R3）；真实 fixture 证实导出工具输出空数组 key（skins2） |
| D4 complete 正例 fixture | 9-section 合成宇宙目录（每类别至少一个非全 0 宇宙键） | A 评审 R2：现有 makeUniverseCatalog 只有 buildings/traps，任何 fixture 都到不了 .complete |
| D5 生产行为 | 生产目录（仅 buildings/traps 宇宙）+ 真实快照 → `.partial(unmodeledCategories: 7 类)` → 全局进度 partial + 诊断（诚实 fail-closed，不宣称完整） | 验收 1/2 的必然结果；A 评审确认不构成过度 fail-closed |
| D6 missingSections 的 base | 仅 home 检查 9 个追踪 section；BB 恒 `.unavailable`（决策 5），不进 partial 分支，无 BB 噪音 | B 评审 F3 |
| D7 判定清单单点化 | `progressSections` 常量定义于 `VillageCatalogProjection`（9 个 home section 字符串）；类别映射复用 `TrackerCategory.from(section:)` | C 评审 R3：防第二份白名单漂移 |

## 类型契约

```swift
/// 全村庄进度覆盖状态（Issue #96）。拆分布局：建筑/陷阱实例宇宙可用
///（`buildingUniverseAvailable`，universeSupplement 合成门禁）只证明 buildings/traps
/// 的差集能力；全村庄完整分母必须「所有追踪类别建模 + 快照 section 完整」。
/// 生产目录现状（仅 buildings/traps 有宇宙）→ 恒 partial + 诊断（fail-closed）。
public enum ProgressUniverseCoverage: Hashable, Sendable {
    /// 建筑/陷阱实例宇宙不可用：目录不可用 / 无宇宙数据 / TH 未知或越界 / 非 home。
    case unavailable
    /// 建筑/陷阱宇宙可用，但全村庄完整分母不成立。
    /// missingSections：快照缺失的追踪 section（home 形态键，键存在即 present，
    /// 空数组不算缺失）。unmodeledCategories：目录无宇宙数据的追踪类别
    ///（TrackerCategory.from 映射，复用现有映射防漂移）。
    case partial(missingSections: Set<String>, unmodeledCategories: Set<TrackerCategory>)
    /// 全部追踪类别具备明确宇宙且快照 section 完整：允许完整分母。
    case complete

    /// 完整分母许可：仅 .complete 为 true（调用方唯一判定入口）。
    public var isComplete: Bool { self == .complete }
}
```

不变量：`.partial` 至少一个关联集合非空（`.partial(空,空)` 是无效形态，生产代码不可达；测试构造须遵守）。

## 验收标准映射（issue #96）

| 验收 | 落点 |
|---|---|
| 1 生产不宣称"全村庄完整宇宙" | D1 移除 public `universeComplete`；生产 → `.partial` |
| 2 缺 section → completeDenominator false + 可诊断 | Task 2/3：missingSections → .partial → metrics 强制 partial + 诊断文案 |
| 3 已观测建筑/陷阱覆盖与全局养成分开 | D2 解耦：coverage 行=建筑/陷阱覆盖率；stage/global=观测口径+诊断 |
| 4 四态测试 | Task 2：缺失 section / 空数组（不算缺失）/ TH 未知（unavailable）/ 目录不支持（unmodeled） |
| 5 三消费者同一判定 | Task 3/4：metrics 参数改为 coverage；两消费者只传参 |
| 6 923 测试 + #70 回归 | Task 5 全量回归 |

---

### Task 1: GameCatalog.universeSections API

**Files:**
- Modify: `Sources/COCHelperCore/GameCatalog.swift`（`universeKeys` 附近，~L948）
- Test: `Tests/COCHelperCoreTests/GameCatalogTests.swift`

- [ ] **Step 1: 写失败测试**（追加到 GameCatalogTests.swift 宇宙相关区块；若文件无宇宙测试则新建区块，参照现有 `universeKeys` 测试的构造方式）

```swift
// MARK: - Issue #96：universeSections（覆盖契约输入）

func testUniverseSectionsDerivedFromInstanceCountsKeys() throws {
    // 宇宙数据存在 → section 集合从键推导（去重）
    let catalog = GameCatalog(
        gameVersion: "18.400.13",
        items: [/* 至少一个 buildings item + 一个 traps item，dataID 与键匹配 */],
        manifest: /* 含 catalog.json sha256 声明的 manifest */,
        instanceCounts: [
            "buildings:1000002": Array(repeating: 1, count: 18),
            "traps:12000000": Array(repeating: 1, count: 18),
        ]
    )
    XCTAssertEqual(catalog.universeSections, ["buildings", "traps"])
}

func testUniverseSectionsEmptyWithoutUniverseData() {
    // 无 manifest / 无 instanceCounts → 空（与 hasUniverseData 同一信任门）
    let catalog = GameCatalog(gameVersion: "18.400.13", items: [])
    XCTAssertTrue(catalog.universeSections.isEmpty)
}
```

- [ ] **Step 2: 运行确认失败**

```bash
swift test --filter GameCatalogTests/testUniverseSections
```
Expected: FAIL（`universeSections` 不存在，编译错误）

- [ ] **Step 3: 最小实现**（GameCatalog.swift，`universeKeys` 之后）

```swift
/// 有宇宙数据的 section 集合（Issue #96）：从 instanceCounts 键推导，
/// 与 `universeKeys` 同一信任门（旧目录 / 校验失败 / 无 manifest → 空）。
/// 覆盖契约输入：投影层用它判定「目录对哪些追踪类别建模了实例数量」。
public var universeSections: Set<String> {
    guard hasUniverseData else { return [] }
    return Set((instanceCounts ?? [:]).keys.compactMap { key in
        key.split(separator: ":", maxSplits: 1).first.map(String.init)
    })
}
```

- [ ] **Step 4: 运行确认通过**

```bash
swift test --filter GameCatalogTests/testUniverseSections
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/GameCatalog.swift Tests/COCHelperCoreTests/GameCatalogTests.swift
git commit -m "feat(core): GameCatalog.universeSections 覆盖契约输入（Issue #96）"
```

---

### Task 2: ProgressUniverseCoverage + 投影层集成

**Files:**
- Modify: `Sources/COCHelperCore/VillageCatalogProjection.swift`
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`

先改测试，再改生产代码。本任务同时更新现有 `universeComplete` 相关断言（~10 处）并新增四态测试。

- [ ] **Step 1: 新增 fixture `makeCompleteUniverseCatalog`**（VillageCatalogProjectionTests.swift，`makeUniverseCatalog` 之后）

9 个追踪类别每类一个宇宙键（validatedInstanceCounts 拒绝全 0 键，count 数组用非全 0 值；每个键的目录 item 必须存在）：

```swift
/// Issue #96 正例 fixture：9 个追踪类别每类至少一个宇宙键 + 对应目录 item。
/// 生产目录当前只有 buildings/traps 宇宙——本 fixture 表达「未来目录全类别
/// 建模」形态（解锁型类别的宇宙 count 仅为存在性标记，语义不深究）。
private func makeCompleteUniverseCatalog() -> GameCatalog {
    func levels(_ max: Int) -> [CatalogLevel] {
        (1...max).map {
            CatalogLevel(level: $0, durationSeconds: nil, upgradeCosts: nil,
                         requiredTownHallLevel: nil, requiredLaboratoryLevel: nil,
                         icon: nil, levelVisual: nil, missingReason: nil)
        }
    }
    let specs: [(section: String, category: String, dataID: Int64, name: String)] = [
        ("buildings", "buildings", 1_000_002, "圣水收集器"),
        ("traps", "traps", 12_000_000, "炸弹"),
        ("units", "troops", 4_000_000, "野蛮人"),
        ("spells", "spells", 4_000_001, "闪电法术"),
        ("siege_machines", "siegeMachines", 4_000_010, "攻城战车"),
        ("heroes", "heroes", 4_000_100, "野蛮人之王"),
        ("equipment", "equipment", 4_001_000, "狂暴药水瓶"),
        ("pets", "pets", 4_000_200, "独角兽"),
        ("guardians", "guardians", 4_000_300, "守护者"),
    ]
    let items = specs.map { spec in
        CatalogItem(section: spec.section, category: spec.category, dataID: spec.dataID,
                    base: "home", baseMissingReason: nil, name: spec.name, maxLevel: 5,
                    icon: nil, levelVisual: nil, levels: levels(5))
    }
    var instanceCounts: [String: [Int]] = [:]
    for spec in specs {
        instanceCounts["\(spec.section):\(spec.dataID)"] = Array(repeating: 1, count: 18)
    }
    return GameCatalog(
        gameVersion: "18.400.13",
        items: items,
        manifest: makeUniverseManifestStub(),
        instanceCounts: instanceCounts
    )
}
```

- [ ] **Step 2: 新增四态测试**（追加到 `testUniverseCompleteRequiresTHAndUniverseData` 附近，替代原断言）

```swift
// MARK: - Issue #96：progressCoverage（覆盖契约）

/// 四态之一：unavailable——TH 缺失 / 旧目录 / BB / TH 越界（与旧 universeComplete
/// false 的四种原因一一对应）。
func testProgressCoverageUnavailableStates() throws {
    let noTH = makeVillage(objectSections: [:])
    XCTAssertEqual(project(village: noTH, catalog: makeUniverseCatalog(), base: .home).progressCoverage, .unavailable)
    let withTH = makeVillage(objectSections: [
        "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
    ])
    XCTAssertEqual(project(village: withTH, catalog: stageCatalog, base: .home).progressCoverage, .unavailable,
                   "旧目录（无宇宙）→ unavailable")
    XCTAssertEqual(project(village: withTH, catalog: makeUniverseCatalog(), base: .builder).progressCoverage, .unavailable,
                   "BB 恒 unavailable（决策 5）")
    let th19 = makeVillage(objectSections: [
        "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 19, path: "th")],
    ])
    XCTAssertEqual(project(village: th19, catalog: makeUniverseCatalog(), base: .home).progressCoverage, .unavailable,
                   "TH=19 超出宇宙表范围（1...18）→ unavailable")
}

/// 四态之二：partial(missingSections)——快照缺失追踪 section（键不存在；
/// 空数组不算缺失）。
func testProgressCoveragePartialWhenSectionsMissing() throws {
    // 只有 buildings（TH）+ units：缺 traps/spells/siege_machines/heroes/
    // equipment/pets/guardians 七个 section
    let village = makeVillage(objectSections: [
        "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
        "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
    ])
    let coverage = project(village: village, catalog: makeCompleteUniverseCatalog(), base: .home).progressCoverage
    guard case .partial(let missing, let unmodeled) = coverage else {
        return XCTFail("期望 .partial，实际 \(coverage)")
    }
    XCTAssertEqual(missing, ["traps", "spells", "siege_machines", "heroes", "equipment", "pets", "guardians"])
    XCTAssertTrue(unmodeled.isEmpty, "全类别宇宙 fixture → unmodeled 为空")
}

/// 四态之三：空数组 section 不算缺失（键存在即 present）。
func testProgressCoverageEmptyArraySectionIsPresent() throws {
    let village = makeVillage(objectSections: [
        "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
        "traps": [], "units": [], "spells": [], "siege_machines": [],
        "heroes": [], "equipment": [], "pets": [], "guardians": [],
    ])
    XCTAssertEqual(project(village: village, catalog: makeCompleteUniverseCatalog(), base: .home).progressCoverage, .complete,
                   "空数组键存在 → present，不产生 missingSections")
}

/// 四态之四：partial(unmodeledCategories)——目录对追踪类别无宇宙数据
///（生产目录形态：仅 buildings/traps 有宇宙）。
func testProgressCoveragePartialWhenCategoriesUnmodeled() throws {
    let village = makeVillage(objectSections: [
        "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
        "traps": [], "units": [], "spells": [], "siege_machines": [],
        "heroes": [], "equipment": [], "pets": [], "guardians": [],
    ])
    let coverage = project(village: village, catalog: makeUniverseCatalog(), base: .home).progressCoverage
    guard case .partial(let missing, let unmodeled) = coverage else {
        return XCTFail("期望 .partial，实际 \(coverage)")
    }
    XCTAssertTrue(missing.isEmpty, "快照 section 全 → missing 为空")
    XCTAssertEqual(unmodeled, [.troops, .spells, .siegeMachines, .heroes, .equipment, .pets, .guardians])
}

/// 正例：9 个追踪 section 全 + 9 类别宇宙全 → .complete（isComplete true）。
func testProgressCoverageCompleteRequiresAllSectionsAndAllCategoryUniverses() throws {
    let village = makeVillage(objectSections: [
        "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
        "traps": [], "units": [], "spells": [], "siege_machines": [],
        "heroes": [], "equipment": [], "pets": [], "guardians": [],
    ])
    let projection = project(village: village, catalog: makeCompleteUniverseCatalog(), base: .home)
    XCTAssertEqual(projection.progressCoverage, .complete)
    XCTAssertTrue(projection.progressCoverage.isComplete)
}

/// 真实 fixture（section 全）+ 生产 bundled 目录 → partial（7 类未建模）。
func testProgressCoverageRealFixtureWithBundledCatalogIsPartial() throws {
    let sections = try loadRealFixture()
    let village = makeVillage(objectSections: sections)
    let coverage = project(village: village, catalog: GameCatalog.loadBundled(), base: .home).progressCoverage
    guard case .partial(_, let unmodeled) = coverage else {
        return XCTFail("生产目录 + 真实快照期望 .partial，实际 \(coverage)")
    }
    XCTAssertEqual(unmodeled, [.troops, .spells, .siegeMachines, .heroes, .equipment, .pets, .guardians])
}
```

- [ ] **Step 3: 运行确认失败**

```bash
swift test --filter VillageCatalogProjectionTests
```
Expected: 编译失败（`progressCoverage` 不存在）

- [ ] **Step 4: 实现**（VillageCatalogProjection.swift）

4a. 新增类型（文件顶部，`VillageCatalogProjection` 之前）：

```swift
/// 全村庄进度覆盖状态（Issue #96）。拆分布局：建筑/陷阱实例宇宙可用
///（`buildingUniverseAvailable`，universeSupplement 合成门禁）只证明 buildings/traps
/// 的差集能力；全村庄完整分母必须「所有追踪类别建模 + 快照 section 完整」。
/// 生产目录现状（仅 buildings/traps 有宇宙）→ 恒 partial + 诊断（fail-closed）。
/// 与旧 `universeComplete` 的对应：旧字段把「建筑/陷阱宇宙可用」直接当作
/// 「全村庄完整宇宙」证据（#96 病根）——本类型拆开两层语义。
public enum ProgressUniverseCoverage: Hashable, Sendable {
    /// 建筑/陷阱实例宇宙不可用：目录不可用 / 无宇宙数据 / TH 未知或越界 / 非 home。
    case unavailable
    /// 建筑/陷阱宇宙可用，但全村庄完整分母不成立。
    /// missingSections：快照缺失的追踪 section（home 形态键；键存在即 present，
    /// 空数组不算缺失——真实导出会输出空数组 key）。unmodeledCategories：
    /// 目录无宇宙数据的追踪类别（TrackerCategory.from 映射，复用现有映射防漂移）。
    case partial(missingSections: Set<String>, unmodeledCategories: Set<TrackerCategory>)
    /// 全部追踪类别具备明确宇宙且快照 section 完整：允许完整分母。
    case complete

    /// 完整分母许可：仅 .complete 为 true（metrics/UI 唯一判定入口，防各自解释）。
    public var isComplete: Bool { self == .complete }
}
```

4b. `progressSections` 常量（`VillageCatalogProjection` 内）：

```swift
/// 全村庄进度追踪的 home section 集合（Issue #96 快照完整性契约）。
/// 与 TrackerCategory 九类别一一对应；BB（"2" 后缀）由决策 5 恒
/// unavailable，不参与检查（避免 BB 诊断噪音）。
private static let progressSections: Set<String> = [
    "buildings", "traps", "units", "spells", "siege_machines",
    "heroes", "equipment", "pets", "guardians",
]
```

4c. 替换 `universeComplete` 字段声明（~L313-321）→ `progressCoverage`：

```swift
    /// Issue #96：全村庄进度覆盖状态（唯一覆盖判定点）。生产门禁与判定逻辑见
    /// `project()`；`universeSupplement` 合成门禁使用内部 `buildingUniverseAvailable`
    ///（本字段的布尔前提），stage/global 完整分母用 `progressCoverage.isComplete`。
    /// BB base 恒 .unavailable（决策 5：BB 数据源不可靠，不做宇宙）。
    public let progressCoverage: ProgressUniverseCoverage
```

4d. `project()` 内替换判定（~L367-393）：

```swift
        // Issue #96：拆分布局（原 Issue #70 阶段 2 的 universeComplete 判定）：
        // 1) buildingUniverseAvailable —— 建筑/陷阱实例宇宙门禁（universeSupplement
        //    唯一生产入口；含 catalogIsUsable 与 TH 范围守卫，同旧判定，BB 恒 false）；
        // 2) progressCoverage —— 全村庄覆盖状态：在宇宙可用基础上，再要求
        //    快照 9 个追踪 section 完整（键存在即 present，空数组不算缺失）且
        //    目录对全部追踪类别建模了宇宙。生产目录（仅 buildings/traps 宇宙）
        //    → 恒 .partial(unmodeledCategories) —— 诚实 fail-closed，不得宣称
        //    「全村庄完整宇宙」（验收 1/2）。
        let buildingUniverseAvailable = base == .home
            && catalogIsUsable
            && catalog?.hasUniverseData == true
            && unlocks.townHall.map { (1...GameCatalog.universeTownHallCount).contains($0) } ?? false
        let progressCoverage: ProgressUniverseCoverage
        if !buildingUniverseAvailable {
            progressCoverage = .unavailable
        } else if let snapshot = village.accountSnapshot {
            let missingSections = Self.progressSections.subtracting(snapshot.objectSections.keys)
            let unmodeledCategories = Set(TrackerCategory.allCases)
                .subtracting(Set((catalog?.universeSections ?? []).compactMap(TrackerCategory.from)))
            if missingSections.isEmpty && unmodeledCategories.isEmpty {
                progressCoverage = .complete
            } else {
                progressCoverage = .partial(
                    missingSections: missingSections,
                    unmodeledCategories: unmodeledCategories
                )
            }
        } else {
            // 无快照 → TH 未知 → 宇宙不可用（与旧判定一致，fail-closed）。
            progressCoverage = .unavailable
        }
```

4e. 合成门禁改接 `buildingUniverseAvailable`（~L386-392）：

```swift
            )) + (buildingUniverseAvailable ? Self.universeSupplement(
```

4f. 构造调用（~L405）`universeComplete: universeComplete` → `progressCoverage: progressCoverage`

4g. `universeSupplement` doc comment 中"调用方门禁（评审 I1）……已由 universeComplete 守卫"改为 `buildingUniverseAvailable` 守卫。

- [ ] **Step 5: 运行确认通过 + 更新旧断言**

```bash
swift test --filter VillageCatalogProjectionTests
```
修复同一文件内旧 `universeComplete` 断言的编译错误（~6 处），语义映射：
- `testUniverseCompleteRequiresTHAndUniverseData` → 并入/替换为新四态测试（Step 2 已写，删除原测试）
- `testUniverseSupplementProducesAvailableItems` / 其他使用 `XCTAssertTrue(home.universeComplete)` 处：改用 `XCTAssertNotEqual(home.progressCoverage, .unavailable)`（差集合成门禁语义）或具体 `.partial(...)`
- 检查 `universe:units:4000000` 不产出断言保持不变

Expected: 全绿

- [ ] **Step 6: Commit**

```bash
git add Sources/COCHelperCore/VillageCatalogProjection.swift Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "feat(core): ProgressUniverseCoverage 覆盖契约（Issue #96，拆分完整分母权限）"
```

---

### Task 3: VillageProgressMetrics coverage 参数 + 诊断文案

**Files:**
- Modify: `Sources/COCHelperCore/VillageProgressMetrics.swift`
- Modify: `Tests/COCHelperCoreTests/VillageProgressMetricsTests.swift`
- Modify: `Tests/COCHelperCoreTests/VillageProgressMetricsPropertyTests.swift`

- [ ] **Step 1: 写失败测试**（VillageProgressMetricsTests.swift，`testIncompleteDenominatorReasonText` 附近追加）

```swift
// MARK: - Issue #96：coverage 参数与诊断

func testPartialCoverageAddsSectionDiagnostic() {
    let m = metrics(
        [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
        coverage: .partial(missingSections: ["units", "spells"], unmodeledCategories: [])
    )
    XCTAssertEqual(m.globalProgress.state, .partial)
    XCTAssertTrue(m.globalProgress.degradedReason?.contains("快照缺少类别数据") == true)
    XCTAssertTrue(m.globalProgress.degradedReason?.contains("units") == true)
}

func testPartialCoverageAddsUnmodeledDiagnostic() {
    let m = metrics(
        [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
        coverage: .partial(missingSections: [], unmodeledCategories: [.troops, .heroes])
    )
    XCTAssertTrue(m.globalProgress.degradedReason?.contains("目录未对") == true)
    XCTAssertTrue(m.globalProgress.degradedReason?.contains("兵种") == true)
}

func testCompleteCoverageAllowsReady() {
    let m = metrics(
        [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
        coverage: .complete
    )
    XCTAssertEqual(m.globalProgress.state, .ready)
    XCTAssertNil(m.globalProgress.degradedReason)
}

/// partial 时差集项不进 stage/global 分母（available 过滤 = coverage.isComplete）。
func testPartialCoverageExcludesAvailableFromEligible() {
    let available = item(id: "u:1", level: nil, maxLevel: nil, stageMax: nil,
                         status: .available, count: 7)
    let known = item(id: "a", level: 3, maxLevel: 10, stageMax: 6)
    let partial = metrics([known, available], coverage: .partial(missingSections: ["units"], unmodeledCategories: []))
    XCTAssertEqual(partial.globalProgress.denominator, 10, "partial → 差集不进分母")
    let complete = metrics([known, available], coverage: .complete)
    XCTAssertEqual(complete.globalProgress.denominator, 17, "complete → 差集进分母（10 + 7）")
}
```

Step 1b: 修改测试 helper（`VillageProgressMetricsTests.swift` ~L94-99）：`completeDenominator: Bool = true` → `coverage: ProgressUniverseCoverage = .complete`，调用透传；原有 `completeDenominator: false` 调用点（~5 处）改为 `.partial(missingSections: [], unmodeledCategories: [])` 或 `.unavailable`（语义等价处用 `.unavailable`，涉及诊断语义的用 `.partial`）。

- [ ] **Step 2: 运行确认失败**

```bash
swift test --filter VillageProgressMetricsTests
```
Expected: 编译失败（`coverage:` 参数不存在）

- [ ] **Step 3: 实现**（VillageProgressMetrics.swift）

3a. 签名（~L116）：

```swift
    public static func metrics(
        from items: [VillageItemState],
        catalogIsUsable: Bool,
        compatibility: CatalogCompatibility?,
        coverage: ProgressUniverseCoverage = .unavailable
    ) -> VillageProgressMetrics {
```

3b. 函数体内（~L150）：

```swift
        // Issue #96：完整分母许可 = 覆盖契约 .complete（三消费者唯一判定点，
        // 不各自解释旧 universeComplete）。partial/unavailable → 阶段 1 语义
        //（差集不进 eligible，分母为已观测项目 + 覆盖诊断）。
        let completeDenominator = coverage.isComplete
        // 覆盖诊断（partial 专属）：缺失 section / 未建模类别，透传给降级文案。
        let coverageDiagnostic = Self.coverageDiagnostic(for: coverage)
```

3c. `makeMetric` 调用处（stage/global 两处）追加 `coverageDiagnostic: coverageDiagnostic` 参数；snapshotCoverage 不传（口径为观测+差集，`denominatorIsComplete: true` 硬编码，与 coverage 无关——C 评审确认 aggregateCoverage 行为不变）。

3d. `makeMetric` 签名加参数并在两分支追加：

```swift
    private static func makeMetric(
        ...
        coverageDiagnostic: String? = nil
    ) -> ProgressMetric {
        ...
        if denominator == 0 {
            state = .unknown
            reasons.append(emptyReason)
            if let extraReason { reasons.append(extraReason) }
            if let coverageDiagnostic { reasons.append(coverageDiagnostic) }
        } else {
            ...
            if let extraReason { reasons.append(extraReason) }
            if let coverageDiagnostic { reasons.append(coverageDiagnostic) }
            ...
        }
```

3e. 新辅助函数：

```swift
    /// Issue #96：覆盖诊断文案（partial 专属）。unavailable（目录/TH/BB 侧）
    /// 由既有「分母为已观测项目」文案覆盖；complete 无诊断。
    private static func coverageDiagnostic(for coverage: ProgressUniverseCoverage) -> String? {
        guard case .partial(let missing, let unmodeled) = coverage else { return nil }
        var parts: [String] = []
        if !missing.isEmpty {
            parts.append("快照缺少类别数据（" + missing.sorted().joined(separator: "、") + "），无法确认完整村庄进度。")
        }
        if !unmodeled.isEmpty {
            parts.append("目录未对" + unmodeled.map(\.title).sorted().joined(separator: "、") + "建模实例数量，无法确认完整村庄进度。")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
```

- [ ] **Step 4: 更新 PropertyTests 生成器与调用点**

`VillageProgressMetricsPropertyTests.swift`：
- 新增生成器（`randomItem` 附近）：

```swift
    /// Issue #96：coverage 三态生成器。partial 随机携带一个非空诊断集合
    ///（不变量：至少一个集合非空）。
    private func randomCoverage(_ g: inout SeededGenerator) -> ProgressUniverseCoverage {
        switch g.int(in: 0..<3) {
        case 0: return .unavailable
        case 1: return .complete
        default:
            let missing: Set<String> = g.bool()
                ? ["units", "spells"] : []
            let unmodeled: Set<TrackerCategory> = g.bool()
                ? [.troops, .heroes] : []
            if missing.isEmpty && unmodeled.isEmpty {
                return .partial(missingSections: ["units"], unmodeledCategories: [])
            }
            return .partial(missingSections: missing, unmodeledCategories: unmodeled)
        }
    }
```

- 全部 `completeDenominator: g.bool()`（11 处）→ `coverage: randomCoverage(&g)`
- 语义锚点处（如 `completeDenominator: true` 专测差集入分母 → `.complete`；`false` 专测排除 → `.partial(missingSections: [], unmodeledCategories: [.troops])`）
- `testIncompleteDenominatorIgnoresAvailableNumerics`（L395-410）→ 用 `.partial`/`.complete` 语义改写
- 新增 property：**coverage 非 complete 时绝无 ready**（可计算且非饱和时 state ∈ {partial, unknown}）；complete 且无 unknown/差集/extra 时可 ready

- [ ] **Step 5: 运行确认通过**

```bash
swift test --filter VillageProgressMetricsTests
swift test --filter VillageProgressMetricsPropertyTests
```
Expected: 全绿

- [ ] **Step 6: Commit**

```bash
git add Sources/COCHelperCore/VillageProgressMetrics.swift Tests/COCHelperCoreTests/VillageProgressMetricsTests.swift Tests/COCHelperCoreTests/VillageProgressMetricsPropertyTests.swift
git commit -m "feat(core): metrics 消费 ProgressUniverseCoverage + 覆盖诊断文案（Issue #96）"
```

---

### Task 4: 消费者改造（UpgradeOverviewProjection + VillageDetailView）

**Files:**
- Modify: `Sources/COCHelperCore/UpgradeOverviewProjection.swift`
- Modify: `Sources/COCHelper/VillageDetailView.swift`
- Test: `Tests/COCHelperCoreTests/UpgradeOverviewProjectionTests.swift`

- [ ] **Step 1: 生产代码改造**

1a. `UpgradeOverviewProjection.swift`（~L191）：`completeDenominator: projection.universeComplete` → `coverage: projection.progressCoverage`，同步注释（"completeDenominator 按 universeComplete 置位" → "coverage 按 projection.progressCoverage"）。

1b. `VillageDetailView.swift`（L113、L155）：`completeDenominator: projection.universeComplete` → `coverage: projection.progressCoverage`。

1c. `metricsBar`（~L325-340）：

> **历史草案标注（P1 审核后修正）**：本示例的 partial 文案「已建模（当前仅建筑/陷阱）
> 可建造」在最终实现中**被 P1 口径契约否决**——覆盖率分母 = 全部追踪类别已观测
> ∪ 建筑/陷阱差集（未建模类别只计观测），并非「已建模可建造数量」。最终实现见
> `VillageDetailView.helpText` 与 `VillageProgressMetrics` coverageDen 契约注释
>（commit a66309b）：partial 文案为「分母为已观测实例与建筑/陷阱宇宙差集合计，
> 非村庄全部可建造」。

```swift
    /// Issue #96：help 文案按覆盖状态三分支——complete 才宣称「村庄全部可建造」；
    /// partial 准确表述为「已建模（当前仅建筑/陷阱）可建造」；unavailable 为
    /// 已观测口径。覆盖率行分母 = 观测 ∪ 差集（差集门禁 = buildingUniverseAvailable，
    /// 与 stage/global 的完整分母门禁解耦，决策 D2）。
    private func metricsBar(metrics: VillageProgressMetrics, coverage: ProgressUniverseCoverage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metricRow(metrics.currentStageProgress, title: "当前阶段进度")
            metricRow(metrics.globalProgress, title: "全局养成进度")
            metricRow(metrics.snapshotCoverage, title: "观测数据完整性")
                .help(coverage.isComplete
                    ? "已观测实例占村庄全部可建造数量"
                    : "已观测实例占已建模可建造数量（当前仅建筑/陷阱），其余类别未完整建模")
        }
        .padding(12)
        .background(Color.cocAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
```

注意：`.unavailable` 时文案"已建模（当前仅建筑/陷阱）"不准确（无差集、纯观测）——用 `switch coverage` 三分支：

```swift
            metricRow(metrics.snapshotCoverage, title: "观测数据完整性")
                .help(helpText(for: coverage))

    private func helpText(for coverage: ProgressUniverseCoverage) -> String {
        switch coverage {
        case .complete:
            "已观测实例占村庄全部可建造数量"
        case .partial:
            "已观测实例占已建模可建造数量（当前仅建筑/陷阱），其余类别未完整建模"
        case .unavailable:
            "分母为已观测实例，非全部可能建筑"
        }
    }
```

- [ ] **Step 2: 更新 UpgradeOverviewProjectionTests 断言**

`testUniverseDiffExcludedFromRecordsIncludedInMetrics`（~L943-1010）按新语义重写：
- 快照只有 buildings+units → `projection.progressCoverage` 为 `.partial(missing: 7 sections, unmodeled: 7 categories)`（用 `guard case` 断言或 `XCTAssertFalse(projection.progressCoverage.isComplete)`）
- 差集项仍产出（门禁 = buildingUniverseAvailable）：`universe:buildings:1000002` 存在断言保留
- stage/global 分母：17 → **3**（观测口径，差集不进 eligible）；coverage 分母 9 不变
- `completeDenominator: projection.universeComplete` 处 → `coverage: projection.progressCoverage`
- 新增一个"完整分母接线"正例（用 9-section fixture 快照 + 全类别宇宙 JSON 目录，断言 stage/global 分母含差集、record.villageMetrics == 独立投影）——若 fixture JSON 构造成本高，改为在 VillageCatalogProjectionTests 层已覆盖 `.complete` 语义，此处仅验证"coverage 透传一致"（保留现有 expected==actual 对比即可，语义自动随投影层收紧）

`testLegacyCatalogKeepsPhase1Semantics`：`XCTAssertFalse(projection.universeComplete)` → `XCTAssertEqual(projection.progressCoverage, .unavailable)`。

- [ ] **Step 3: 运行确认通过**

```bash
swift test --filter UpgradeOverviewProjectionTests
```
Expected: 全绿

- [ ] **Step 4: Commit**

```bash
git add Sources/COCHelperCore/UpgradeOverviewProjection.swift Sources/COCHelper/VillageDetailView.swift Tests/COCHelperCoreTests/UpgradeOverviewProjectionTests.swift
git commit -m "feat(ui): 三消费者统一消费 progressCoverage（Issue #96）"
```

---

### Task 5: 全量回归 + Reflexion 自查

- [ ] **Step 1: 全量测试**

```bash
swift test
python3 -m pytest -q Tools/tests
git diff --check
```
Expected: Swift 923 既有 + 新增全绿；Python 676 passed；无空白错误

- [ ] **Step 2: grep 残留检查**

```bash
git grep -n "universeComplete" -- Sources Tests
```
Expected: 0 处（除计划/文档外全部移除或改注释）

- [ ] **Step 3: Reflexion 自查清单**

- 验收 1：生产目录 + 真实 fixture → `.partial`，UI 无"村庄全部可建造"宣称 ✓
- 验收 2：缺 section → `.partial` + metrics partial + 诊断文案 ✓
- 验收 3：coverage 行（建筑/陷阱覆盖率）与 stage/global（观测口径）分离 ✓
- 验收 4：四态测试齐（缺失/空数组/TH 未知/目录不支持）✓
- 验收 5：三消费者只读 `projection.progressCoverage`，metrics 参数单一 ✓
- 验收 6：923 测试 + #70 回归通过 ✓
- 边界：`.partial(空,空)` 不可达；Set 文案排序确定性（sorted）；无新增白名单漂移（progressSections 单点、TrackerCategory.from 复用）

- [ ] **Step 4: Commit（如有自查修正）**

## 风险和边界（本计划之外不要做）

- 不给 units/heroes 等补齐实例数量宇宙（issue 明确：无可靠 source 时 unknown 是正确结果）
- 不改三指标公式；不碰 BB/Capital；不用 UI 隐藏缺失类别
- `ContentView.aggregateCoverage`（第 4 消费点）行为不变，不传 coverage（默认 .unavailable，覆盖率口径天然不受完整分母影响）——只确认不回归，不改造
- 回归风险：~4-8 处 #70 阶段 2 断言按新语义更新（预期行为收紧，非 bug）；`universeComplete` 全部移除，编译器强制所有调用点更新（无静默漏改）

---

## 实现偏差与风险登记（执行后回写，2026-08-10）

### 与计划的偏差（均为评审驱动或编译必需）
1. **Task 2 边界调整**：移除 `universeComplete` 会立即破坏 `UpgradeOverviewProjection`/`VillageDetailView` 编译 → Task 2 同步做消费点过渡（`completeDenominator: projection.progressCoverage.isComplete`）与 UpgradeOverviewProjectionTests 断言更新（分母 17→3，预期行为收紧）。
2. **Task 2 评审修复**（commit 39389a3）：`unmodeledCategories` 推导加 `hasSuffix("2")` 过滤（防 BB 宇宙键经 `TrackerCategory.from` dropLast 映射误判 home 已建模，fail-open 方向）。
3. **UpgradeOverviewProjectionTests unmodeled 为 8 类**（非计划说的 7 类）：该文件 `universeCatalogJSON` 只有 buildings 宇宙键（无 traps item），fixture 事实。
4. **Task 3 偏差**：`SeededGenerator(seed: UInt32)` + `int(in: ClosedRange)`（仓库 API）；`testPartialCoverageExcludesAvailableFromEligible` 的 available 项 `maxLevel: 1`（计划草稿 nil 会被 `(maxLevel ?? 0) > 0` 过滤，断言 17 不可能成立）。
5. **Task 4 扩展**：helpText 由计划的三分支扩为成因细分（missing/unmodeled 双缺、仅 unmodeled、仅 missing）——修复计划原 partial 单文案在 missing-only 成因下失实（交叉审核发现）。
6. **交叉审核修复**（commit 68748ba）：诊断文案 missing 段映射中文 title（消除中英混排）；validate.py 白名单注释声明（future 契约断点）；aggregateCoverage doc「全部村庄」= 聚合范围澄清；3 个边界测试（TH=1/18、BB 宇宙键 filter 突变守护、快照 BB 段不补 home 缺失）。
7. **交叉审核第二轮修复**（F1/N3）：missing-only help 文案删括号（缺失类别按宇宙差集计入分母，分母恒=已建模宇宙量）；诊断排序统一为 title 序（missing 与 unmodeled 顺序一致）。

### 风险登记（当前接受，未来动作项）
- **R-A（部分建模 fail-open）**：`universeSections` 粒度 =「任一宇宙键即该 section 已建模」；`validatedInstanceCounts` 正向契约只强制 buildings/traps 全覆盖。未来 validate.py 放开其他类别后，若生成器只产部分宇宙键 → Swift 校验接受 → 可能达成 `.complete` 而该类宇宙不完整。**动作项**：扩展类别宇宙时同步扩展 Swift 正向契约 + Tools/tests。
- **R-B（validate.py 白名单）**：`_check_instance_counts` 只接受 buildings/traps section（Tools/game_catalog/validate.py:72 已注释声明）——生产目录永远无法产出 9 类宇宙，`.complete` 生产不可达（注入可达的预留分支）。当前是 issue #96 非目标（不补齐类别宇宙）的正确状态。
- **R-C（ContentView 文案）**：升级总览卡「已观测实例 · 全部村庄」中「全部村庄」指聚合范围（跨全部已导入村庄），非分母宣称——已由 aggregateCoverage doc 澄清，UI 保留（决策 8）。
