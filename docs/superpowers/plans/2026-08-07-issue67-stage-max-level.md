# Issue #67 当前阶段上限 + 统一 Requirement 模型 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立统一 Requirement 模型（TH/BH/Lab/StarLab/HeroHall），让投影区分 `globalMaxLevel` 与 `currentStageMaxLevel`，满级判定按当前基地阶段上限，prerequisite 缺失时降级不伪推。

**Architecture:** 三层改动：(1) Python 生成器提取 APK heroes.csv 的 `RequiredHeroTavernLevel` 列并重新生成目录（新增 `requiredHeroTavernLevel` 字段，全 optional 兼容）；(2) Swift Core 模型：`UpgradeRequirement` enum + `CatalogLevel.requirements`（按 item.base 解析 village 语义）+ `VillageItemState.currentStageMaxLevel`；(3) 投影：从快照 buildings/buildings2 按 dataID 推导 5 个解锁建筑等级 → 计算当前阶段上限 → `.maxed` 判定改用阶段上限（不可计算时回退全局，保守不误报）。UI 最小改动：LevelDetailSheet 类型化文案 + 阶段满级/全局剩余区分。

**Tech Stack:** Python 3（生成器，pytest 130 测试）、Swift 6（SPM，XCTest 647 测试）、APK `/path/to/base.apk`（546MB，已在场）。

**关键设计决策（已投票，D1=A/D2=A/D3=A，见评审记录）：**
- D1=A：玩家解锁等级从 `AccountSnapshot` buildings/buildings2 按 dataID 推导（fixture 实测：TH 1000001=18/Lab 1000007=16/HeroHall 1000071=12/BH 1000034=10/StarLab 1000046=10）
- D2=A：扩展生成器提取 `RequiredHeroTavernLevel`（heroes.csv 主村 480 行非空值 1-12；heroes2 全 0）→ 重新生成 catalog
- D3=A：Swift 端按 `CatalogItem.base` 解析——home: townHall/laboratory/heroHall；builder: builderHall/starLaboratory（数据已隐含语义，生成器无需改字段名）
- **阶段上限缺失回退**：`currentStageMaxLevel` 可计算时用阶段上限判 maxed；不可计算（快照缺 prerequisite 建筑）时回退全局 maxLevel 判定——严格上限判定不误报满级（level >= 全局上限 才 maxed），符合「不产生看似权威的满级状态」fail-safe 方向；12 本玩家（快照有 TH）正常走阶段上限

**工作区**：`.worktrees/issue-67-stage-max-level`，分支 `codex/issue-67-stage-max-level`，基于 origin/main（9ad5d95）。647 XCTest + 130 pytest 基线全绿。

---

### Task 1: Python 生成器提取 RequiredHeroTavernLevel

**Files:**
- Modify: `Tools/game_catalog/model.py`
- Modify: `Tools/game_catalog/tables.py`
- Modify: `Tools/game_catalog/builders.py`
- Modify: `Tools/tests/conftest.py`
- Test: `Tools/tests/test_builders.py`, `Tools/tests/test_model.py`

- [ ] **Step 1: model.py 增加字段（默认 None 保持所有构造点兼容）**

```python
# Tools/game_catalog/model.py 的 CatalogLevel dataclass
@dataclass(frozen=True)
class CatalogLevel:
    level: int
    durationSeconds: int | None
    missingReason: str | None = None
    upgradeResource: str | None = None
    upgradeCost: int | None = None
    requiredTownHallLevel: int | None = None
    requiredLaboratoryLevel: int | None = None
    requiredHeroTavernLevel: int | None = None   # 新增：英雄殿堂门槛（17 本英雄）
    icon: AssetRef | None = None
    levelVisual: AssetRef | None = None
```

同时 `to_dict()`（L45-52 附近）加 `"requiredHeroTavernLevel": self.requiredHeroTavernLevel`，`from_dict`（L60-66 附近）加 `requiredHeroTavernLevel=d.get("requiredHeroTavernLevel")`。

- [ ] **Step 2: tables.py heroes spec 加列声明**

```python
# Tools/game_catalog/tables.py 的 heroes TableSpec（现 L144-153 附近）
TableSpec(
    table="heroes.csv", section="heroes", section2="heroes2",
    category="heroes", level_column="VisualLevel",
    time_columns=("UpgradeTimeH",),
    resource_column="UpgradeResource", cost_column="UpgradeCost",
    town_hall_column="RequiredTownHallLevel",
    hero_tavern_column="RequiredHeroTavernLevel",   # 新增字段，仅 heroes 表有
    icon_columns=("IconSWF", "IconExportName"),
    village_type_column="VillageType",
    fill_columns=("TID", "VillageType", "IconSWF", "IconExportName",
                  "UpgradeResource", "UpgradeCost", "RequiredTownHallLevel",
                  "RequiredHeroTavernLevel"),      # 加入 fill 白名单（前置列需要 ffill）
    upgrade_semantics="to_next_level",
    id_base=28_000_000,
)
```

TableSpec 类（L70-88 附近）加字段：`hero_tavern_column: str | None = None`。

- [ ] **Step 3: builders.py 传递新列**

```python
# _ParsedRow dataclass（L26-36 附近）加字段
    town_hall: int | None
    laboratory: int | None
    hero_tavern: int | None       # 新增

# _parse_row（L85-95 附近）加读取
    tavern = parse_optional_int(row.get(spec.hero_tavern_column, "")) if spec.hero_tavern_column else None
    # 加入 _ParsedRow(...) 构造

# _level_from_row（L104-115 附近）
    return CatalogLevel(
        ...
        requiredTownHallLevel=rec.town_hall,
        requiredLaboratoryLevel=rec.laboratory,
        requiredHeroTavernLevel=rec.hero_tavern,   # 新增
        ...
    )

# _level_initial（L118-132 附近）加 requiredHeroTavernLevel=None
```

- [ ] **Step 4: conftest.py `_doc_rows` 同步列声明**

查看 `Tools/tests/conftest.py` L33-38 的 `_doc_rows`（遍历列属性生成 doc 行）。heroes 相关 doc 行增加 `RequiredHeroTavernLevel` 列，保持「表头行 + 数据行 + 类型行」对齐。

- [ ] **Step 5: 写失败测试（TDD）**

```python
# Tools/tests/test_builders.py 新增
def test_heroes_tavern_level_extracted():
    rows = [
        {"Name": "String", "VisualLevel": "int", "TID": "String",
         "UpgradeTimeH": "int", "VillageType": "String",
         "RequiredTownHallLevel": "int", "RequiredHeroTavernLevel": "int"},
        {"Name": "Barbarian King", "VisualLevel": "1", "TID": "TID_BK",
         "UpgradeTimeH": "0", "VillageType": "",
         "RequiredTownHallLevel": "4", "RequiredHeroTavernLevel": "1"},
    ]
    items = build_items(rows, spec_for_table("heroes.csv"), {})
    assert items[0].levels[0].requiredHeroTavernLevel == 1
    assert items[0].levels[0].requiredTownHallLevel == 4
```

- [ ] **Step 6: 跑测试验证 RED**

Run: `cd Tools && python3 -m pytest tests/test_builders.py -x -q`
Expected: 新测试 FAIL（requiredHeroTavernLevel 属性不存在或为 None）

- [ ] **Step 7: 实现后验证 GREEN**

Run: `cd Tools && python3 -m pytest tests/ -q`
Expected: 全部通过（130+1 个）

- [ ] **Step 8: 重新生成目录并落库**

```bash
python3 Tools/generate_game_catalog.py --apk /path/to/base.apk \
  --game-version 18.400.13 --output /tmp/coc-catalog-67
# 自检（生成器内建 validate），再核对新字段
python3 -c "
import json
d = json.load(open('/tmp/coc-catalog-67/catalog.json'))
for it in d['items']:
    if it['section']=='heroes' and it['dataID']==28000000:
        print(it['name'], 'lvl1 tavern:', it['levels'][1].get('requiredHeroTavernLevel'),
              'lvl110 tavern:', it['levels'][-1].get('requiredHeroTavernLevel'))
"
# 期望：野蛮人之王 lvl1 tavern=1、lvl110 tavern=12
# 与现库 diff（应只有新字段）
diff <(python3 -c "import json;print(json.dumps(json.load(open('Sources/COCHelperCore/GameCatalog/18.400.13/catalog.json')),sort_keys=True))") \
     <(python3 -c "import json;print(json.dumps(json.load(open('/tmp/coc-catalog-67/catalog.json')),sort_keys=True))") | head -20
# 确认差异仅为 requiredHeroTavernLevel 后，落库
rm -rf Sources/COCHelperCore/GameCatalog/18.400.13
cp -r /tmp/coc-catalog-67 Sources/COCHelperCore/GameCatalog/18.400.13
```

注意：manifest.json 一并重新生成（fingerprint/counts 联动）；`.gitignore` 已含空 icons/。

- [ ] **Step 9: 全量验证 + 提交**

```bash
cd Tools && python3 -m pytest tests/ -q   # 131 passed
cd .. && swift test 2>&1 | grep -E "Executed" | tail -1   # 647 passed（数据不变，仅加字段）
git add Tools/ Sources/COCHelperCore/GameCatalog/18.400.13/
git commit -m "feat(catalog): extract RequiredHeroTavernLevel from APK heroes table (Issue #67)"
```

---

### Task 2: Swift 模型 — UpgradeRequirement + CatalogLevel.requirements

**Files:**
- Modify: `Sources/COCHelperCore/GameCatalog.swift`
- Test: `Tests/COCHelperCoreTests/GameCatalogTests.swift`

- [ ] **Step 1: 写失败测试（TDD）**

```swift
// Tests/COCHelperCoreTests/GameCatalogTests.swift 追加

final class RequirementTests: XCTestCase {
    /// 按 base 解析 village 语义：home → townHall/laboratory/heroHall。
    func testHomeBaseRequirementsParseVillageSemantics() {
        let item = makeRequirementItem(base: "home",
            th: 12, lab: nil, tavern: 8)
        XCTAssertEqual(item.requirements, [
            .townHall(level: 12), .heroHall(level: 8)
        ])
    }

    /// builder → builderHall/starLaboratory（数据源字段复用但语义不同）。
    func testBuilderBaseRequirementsParseBuilderSemantics() {
        let item = makeRequirementItem(base: "builder",
            th: 10, lab: 8, tavern: nil)
        XCTAssertEqual(item.requirements, [
            .builderHall(level: 10), .starLaboratory(level: 8)
        ])
    }

    /// 无 requirement 的 item（equipment 等）→ 空数组。
    func testNoRequirementsYieldsEmpty() {
        let item = makeRequirementItem(base: "home", th: nil, lab: nil, tavern: nil)
        XCTAssertEqual(item.requirements, [])
    }

    /// 旧目录（无 requiredHeroTavernLevel 键）仍可解码（Codable 向后兼容）。
    func testLegacyLevelDecodesWithoutHeroTavernField() throws {
        let json = """
        {"gameVersion":"v","items":[
          {"section":"heroes","category":"heroes","dataID":28000000,"base":"home",
           "name":"野蛮人之王","maxLevel":2,"icon":null,"levelVisual":null,
           "baseMissingReason":null,"missingReason":null,
           "levels":[
             {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,
              "requiredTownHallLevel":4,"requiredLaboratoryLevel":null,
              "icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"}
           ]}
        ]}
        """
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        XCTAssertNil(payload.items[0].levels[0].requiredHeroTavernLevel)
        XCTAssertEqual(payload.items[0].levels[0].requirements, [.townHall(level: 4)])
    }

    private struct Payload: Decodable { let gameVersion: String; let items: [CatalogItem] }

    private func makeRequirementItem(base: String?, th: Int?, lab: Int?, tavern: Int?) -> CatalogItem {
        CatalogItem(
            section: "heroes", category: "heroes", dataID: 1, base: base,
            baseMissingReason: nil, name: "测试", maxLevel: 2, icon: nil, levelVisual: nil,
            levels: [CatalogLevel(
                level: 2, durationSeconds: nil, upgradeResource: nil, upgradeCost: nil,
                requiredTownHallLevel: th, requiredLaboratoryLevel: lab,
                requiredHeroTavernLevel: tavern, icon: nil, levelVisual: nil, missingReason: nil
            )]
        )
    }
}
```

- [ ] **Step 2: 跑测试验证 RED**

Run: `swift test --filter RequirementTests 2>&1 | tail -5`
Expected: FAIL（CatalogItem/CatalogLevel 无 requirements/requiredHeroTavernLevel，编译错误或断言失败）

- [ ] **Step 3: GameCatalog.swift 实现**

```swift
// Sources/COCHelperCore/GameCatalog.swift 新增（放在 CatalogLevel 之前）

/// 升级前置条件（issue #67）。village 语义在投影/展示层按 item.base 解析
///（home: townHall/laboratory/heroHall；builder: builderHall/starLaboratory）。
public enum UpgradeRequirement: Hashable, Sendable {
    case townHall(level: Int)
    case builderHall(level: Int)
    case laboratory(level: Int)
    case starLaboratory(level: Int)
    case heroHall(level: Int)
}

extension CatalogItem {
    /// 本 item 各级升级前置条件的 village 语义列表（按 item.base 解析）。
    /// 无 requirement 的 item（equipment/guardians/capital 等）→ 空数组。
    /// base == nil（capital）→ 空数组（capital 无大本营门槛语义）。
    public var requirements: [UpgradeRequirement] {
        switch base {
        case "home":
            levels.flatMap { level in
                var out: [UpgradeRequirement] = []
                if let th = level.requiredTownHallLevel { out.append(.townHall(level: th)) }
                if let lab = level.requiredLaboratoryLevel { out.append(.laboratory(level: lab)) }
                if let ht = level.requiredHeroTavernLevel { out.append(.heroHall(level: ht)) }
                return out
            }
        case "builder":
            levels.flatMap { level in
                var out: [UpgradeRequirement] = []
                if let th = level.requiredTownHallLevel { out.append(.builderHall(level: th)) }
                if let lab = level.requiredLaboratoryLevel { out.append(.starLaboratory(level: lab)) }
                return out
            }
        default:
            []
        }
    }
}
```

CatalogLevel 增加字段（保持 init 默认参数 nil 兼容既有调用）：

```swift
public let requiredHeroTavernLevel: Int?
// init 加参数 requiredHeroTavernLevel: Int? = nil
// Codable 合成自动处理（optional 缺键容忍）
```

- [ ] **Step 4: 跑测试验证 GREEN**

Run: `swift test --filter RequirementTests 2>&1 | tail -5` → PASS
Run: `swift test 2>&1 | grep -E "Executed" | tail -1` → 全部通过（含 647 基线）

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperCore/GameCatalog.swift Tests/COCHelperCoreTests/GameCatalogTests.swift
git commit -m "feat(core): UpgradeRequirement model with base-aware village semantics (Issue #67)"
```

---

### Task 3: 投影 — currentStageMaxLevel 计算与 maxed 判定

**Files:**
- Modify: `Sources/COCHelperCore/VillageCatalogProjection.swift`
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`

- [ ] **Step 1: 写失败测试（TDD）**

```swift
// VillageCatalogProjectionTests.swift 追加（合成目录需含大本营/实验室/英雄殿堂记录，
// 或对 syntheticCatalogJSON 补充 1000001/1000007/1000071 条目）

func testStageMaxLevelRespectsTownHall() throws {
    // TH=12 的村庄：加农炮（目录 TH 门槛 1→2）阶段上限 = 2（12 >= 2）
    let village = makeVillage(objectSections: [
        "buildings": [
            makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),  // 大本营
            makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "1"),  // 加农炮 lvl12（目录 max 2 → maxed）
        ]
    ])
    // 加农炮 dataID 用 1000002 之类；断言 currentStageMaxLevel == 2、status == .maxed
}

func testStageMaxLevelBelowGlobalShowsCompleteNotMaxed() throws {
    // 加农炮 level 1、TH=1：阶段上限 1（level2 需 TH2）→ complete，currentStageMaxLevel == 1
}

func testUnlockBuildingMissingFallsBackToGlobal() throws {
    // 快照无大本营记录 → currentStageMaxLevel == nil → 满级判定回退全局 maxLevel
    // level == maxLevel 仍 maxed；level < maxLevel 为 complete（保守不误报）
}

func testHeroStageMaxLevelRespectsHeroHall() throws {
    // 英雄殿堂 8 级 + TH 18 的村庄：野蛮人之王目录 tavern 门槛 1..12
    // → 阶段上限 = 目录中 tavern <= 8 的最高等级（合成数据便于精确断言）
}
```

- [ ] **Step 2: 跑测试验证 RED** → 编译/断言失败

- [ ] **Step 3: VillageCatalogProjection.swift 实现**

```swift
// 新增：解锁建筑 dataID 常量
enum UnlockBuildingDataID {
    static let townHall: Int64 = 1_000_001
    static let laboratory: Int64 = 1_000_007
    static let heroHall: Int64 = 1_000_071
    static let builderHall: Int64 = 1_000_034
    static let starLaboratory: Int64 = 1_000_046
}

/// 玩家当前解锁状态（从快照 buildings/buildings2 按 dataID 推导；缺失 nil）。
public struct PlayerUnlockLevels: Equatable, Sendable {
    public let townHall: Int?
    public let builderHall: Int?
    public let laboratory: Int?
    public let starLaboratory: Int?
    public let heroHall: Int?
}

// VillageCatalogProjection 内部：从快照推导
static func playerUnlockLevels(from village: VillageProfile) -> PlayerUnlockLevels {
    guard let snapshot = village.accountSnapshot else { return .init(all: nil) }
    let buildings = snapshot.objectSections["buildings"] ?? []
    let buildings2 = snapshot.objectSections["buildings2"] ?? []
    func level(of id: Int64, in items: [AccountItem]) -> Int? {
        items.first { $0.dataID == id }?.level
    }
    return PlayerUnlockLevels(
        townHall: level(of: UnlockBuildingDataID.townHall, in: buildings),
        builderHall: level(of: UnlockBuildingDataID.builderHall, in: buildings2),
        laboratory: level(of: UnlockBuildingDataID.laboratory, in: buildings),
        starLaboratory: level(of: UnlockBuildingDataID.starLaboratory, in: buildings2),
        heroHall: level(of: UnlockBuildingDataID.heroHall, in: buildings)
    )
}

/// 计算单个 item 的当前阶段上限。
/// - requirements 全部可验证（对应解锁等级非 nil）→ 满足所有 requirement 的最高 level；
/// - 有 requirement 但解锁等级缺失 → nil（不可计算）；
/// - 无 requirement → maxLevel（阶段上限 == 全局上限）。
static func currentStageMaxLevel(for item: CatalogItem, unlocks: PlayerUnlockLevels) -> Int? {
    let reqs = item.requirements
    guard !reqs.isEmpty else { return item.maxLevel }
    func unlockLevel(_ r: UpgradeRequirement) -> Int? {
        switch r {
        case .townHall(let l): return unlocks.townHall.map { $0 >= l } == true ? l : nil
        case .builderHall(let l): return unlocks.builderHall.map { $0 >= l } == true ? l : nil
        case .laboratory(let l): return unlocks.laboratory.map { $0 >= l } == true ? l : nil
        case .starLaboratory(let l): return unlocks.starLaboratory.map { $0 >= l } == true ? l : nil
        case .heroHall(let l): return unlocks.heroHall.map { $0 >= l } == true ? l : nil
        }
    }
    // 任一 requirement 的解锁等级缺失 → 无法验证 → nil
    // （注意：返回 nil 表示「不可计算」，调用方回退全局）
    ...
}
```

实现语义（务必与测试一致）：
- 对 item.levels 按 level 升序，找「所有 requirement 均满足」的最高 level；
- 若任一 requirement 的对应解锁等级为 nil → 返回 nil（不可计算）；
- 若解锁等级存在但小于 requirement 要求 → 该 level 及其后均不满足，取之前满足的最高 level；
- 无 requirement → maxLevel。

VillageItemState 增加字段：

```swift
/// 当前基地条件下可达到的最高等级（issue #67）；nil = 不可计算（回退全局 maxLevel 判定）。
public let currentStageMaxLevel: Int?
// init 参数加 currentStageMaxLevel: Int? = nil（默认值保 8 处既有构造编译通过）
```

`.maxed` 判定改（map 函数内）：

```swift
if let catalogItem, baseMatches {
    let stageMax = currentStageMaxLevel(for: catalogItem, unlocks: unlocks)
    let effectiveMax = stageMax ?? catalogItem.maxLevel  // 不可计算回退全局
    if item.level ?? -1 >= effectiveMax {
        status = .maxed
    } else {
        status = .complete
    }
    // 若 stageMax != nil 且 < maxLevel：stageMaxed 但非全局 maxed —— status 仍 .maxed
    // （完成度口径：阶段满级即完成）；currentStageMaxLevel 字段暴露给 UI 区分文案
}
```

注意：`project()` 入口需要 `unlocks` 传入 map（从 village 推导一次，传给 records → map）。

- [ ] **Step 4: 跑测试验证 GREEN** → 新测试 PASS + 全量 647+ 通过

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperCore/VillageCatalogProjection.swift Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "feat(core): currentStageMaxLevel projection with fail-safe global fallback (Issue #67)"
```

---

### Task 4: 完成度联动与聚合传播

**Files:**
- Modify: `Sources/COCHelperCore/VillageCatalogProjection.swift`（aggregate）
- Test: `Tests/COCHelperCoreTests/VillageDetailProjectionTests.swift`

- [ ] **Step 1: 写失败测试（TDD）**

```swift
// VillageDetailProjectionTests.swift 追加
func testStageMaxedCountsAsCompleted() {
    // status == .maxed（阶段满级，currentStageMaxLevel < maxLevel）计入 completed
}

func testAggregationPreservesStageMaxLevel() {
    // 两条同键记录聚合后 currentStageMaxLevel 保留（aggregate 用 first 复制）
}
```

- [ ] **Step 2: RED** → FAIL

- [ ] **Step 3: aggregate() 传播字段**

aggregate 的 `VillageItemState(...)` 构造（现 L454-476 附近）加 `currentStageMaxLevel: first.currentStageMaxLevel`。

VillageDetailProjection 无需改逻辑（`isKnown`/completed 按 `.maxed` 语义天然联动）；但确认注释更新：「完成（completed）：status == .maxed（阶段满级）且计入 known」。

- [ ] **Step 4: GREEN + 全量测试**

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperCore/VillageCatalogProjection.swift Tests/COCHelperCoreTests/VillageDetailProjectionTests.swift
git commit -m "test(core): stage-maxed completion semantics and aggregate propagation (Issue #67)"
```

---

### Task 5: UI 文案 — 类型化 unlockLabel + 阶段满级/全局剩余

**Files:**
- Modify: `Sources/COCHelper/LevelDetailSheet.swift`
- Modify: `Sources/COCHelper/UpgradeDisplayRow.swift`（如涉及徽标文案）
- Test: 无（View 私有函数不可测，按项目惯例核心逻辑在 Core 层）

- [ ] **Step 1: LevelDetailSheet.unlockLabel 类型化**

```swift
private func unlockLabel(_ level: CatalogLevel, base: String?) -> String {
    var parts: [String] = []
    // 按 item.base 解析（与 CatalogItem.requirements 同规则，但此处是单级）
    if base == "builder" {
        if let bh = level.requiredTownHallLevel { parts.append("所需建筑大师大本营等级 " + String(bh) + "级") }
        if let sl = level.requiredLaboratoryLevel { parts.append("所需星空实验室等级 " + String(sl) + "级") }
    } else {
        if let th = level.requiredTownHallLevel { parts.append("所需大本营等级 " + String(th) + "级") }
        if let lab = level.requiredLaboratoryLevel { parts.append("所需实验室等级 " + String(lab) + "级") }
        if let ht = level.requiredHeroTavernLevel { parts.append("所需英雄殿堂等级 " + String(ht) + "级") }
    }
    return parts.isEmpty ? "无解锁条件" : parts.joined(separator: " · ")
}
```

调用处传 `catalogItem?.base`。

- [ ] **Step 2: statusLabel / 满级徽标区分阶段与全局**

LevelDetailSheet.statusLabel（L30-39）：
```swift
case .maxed:
    if let stage = item.currentStageMaxLevel, stage < (item.maxLevel ?? Int.max) {
        "当前阶段已满级（全局尚有 \(item.maxLevel.map { String($0 - stage) } ?? "?") 级）"
    } else {
        "已满级"
    }
```

UpgradeDisplayRow 若 hasVersionMismatch 逻辑涉及 nextLevel > maxLevel，检查是否需区分 stage 语义（评审风险 4：升级中 nextLevel > stageMaxLevel 不是目录过时）——确认现状：`nextLevel > maxLevel` 仍指全局上限，目录过时判定不变（阶段语义不影响该判定；若升级中目标超过阶段上限但 <= 全局上限，属正常升级）。若发现误报风险，`isKnown` 的版本不匹配检查保持全局语义（不改）。

- [ ] **Step 3: 构建验证**

```bash
swift build 2>&1 | tail -3   # 0 errors 0 warnings
swift test 2>&1 | grep -E "Executed" | tail -1
```

- [ ] **Step 4: 提交**

```bash
git add Sources/COCHelper/LevelDetailSheet.swift Sources/COCHelper/UpgradeDisplayRow.swift
git commit -m "feat(ui): stage-aware maxed labels and typed unlock requirements (Issue #67)"
```

---

### Task 6: 验收场景测试（12 本合成村庄 + property-based）

**Files:**
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`

- [ ] **Step 1: 验收场景：12 本玩家阶段满级**

构造合成村庄：TH=12、加农炮 level=12（目录 max 14，TH 门槛 12/13/14）→
- `currentStageMaxLevel == 12`（12 本可升到的最高等级）
- `status == .maxed`（阶段满级）
- `maxLevel == 14`（全局）
- 断言「阶段满级但全局未满」可区分（currentStageMaxLevel < maxLevel）

- [ ] **Step 2: TH/BH/Lab/StarLab/HeroHall 正反例**

- home 建筑 TH 门槛满足/不满足
- builder 建筑 BH 门槛满足/不满足
- home 单位 Lab 门槛满足/不满足
- builder 单位 StarLab 门槛满足/不满足
- 英雄 HeroHall 门槛满足/不满足（合成 heroes 目录带 requiredHeroTavernLevel）
- 反例：prerequisite 缺失（快照无英雄殿堂）→ currentStageMaxLevel == nil → 不判阶段满级（回退全局）

- [ ] **Step 3: property-based 测试（SeededRNG 先例）**

```swift
func testPropertyStageMaxLevelMonotonicInUnlockLevels() {
    // 随机解锁等级：解锁等级越高，currentStageMaxLevel 不降
    // 随机 item levels + requirement 分布，验证：
    // 1) currentStageMaxLevel <= maxLevel
    // 2) 解锁等级全满足 → currentStageMaxLevel == maxLevel
    // 3) 解锁等级缺失 → nil
    // 4) 单调性：unlocks 提升后 stageMax 不减
}
```

- [ ] **Step 4: 全量验证**

```bash
swift test 2>&1 | grep -E "Executed" | tail -1   # 全绿
swift build 2>&1 | tail -2
```

- [ ] **Step 5: 提交**

```bash
git add Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "test(core): acceptance scenarios and property-based stage max level tests (Issue #67)"
```

---

## Self-Review（对照 issue #67 验收标准）

| 验收标准 | 对应任务 |
|---|---|
| 同一项目暴露 globalMaxLevel 与 currentStageMaxLevel | Task 2/3：maxLevel 保留全局 + currentStageMaxLevel 新增 |
| 12 本玩家显示「当前大本营阶段已满级」 | Task 3/5/6：阶段上限判 maxed + UI 文案 + 验收测试 |
| 目录更高等级显示「全局尚有 N 级」不当作可升级项 | Task 5：statusLabel 区分文案 |
| 英雄等级纳入 Hero Hall；缺失时未验证/unknown | Task 1/2/3：RequiredHeroTavernLevel 提取 + heroHall requirement + 缺失回退 |
| BH 显示建筑大师大本营/星空实验室语义 | Task 2/5：builder 解析 + 类型化文案 |
| 现有 requiredTownHallLevel/LaboratoryLevel 迁移不丢 | Task 2：requirements 由旧字段派生，旧字段保留 |
| 目录缺失/版本不匹配/缺失 prerequisite 无权威满级 | Task 3：catalogIsUsable 复用 + 回退全局保守判定 |
| TH/BH/Lab/StarLab/HeroHall 正反例测试 | Task 6 |
| swift test 通过 | 每个 Task 验证 |

**边界（不做）**：#68 下一级可升级性/「需先升基地」文案；#70 完成度三拆；#74 目录生命周期；资源库存/工人占用/自动排程。
