# Issue #70 阶段 2：实例数量宇宙数据管线实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立每大本营阶段的完整实例数量宇宙（townhall_levels 数据源），使 stage/global 进度指标获得真实完整分母（`completeDenominator: true` 可达 ready），并产出 `.available` 项使覆盖率成为完整覆盖率。

**Architecture:** Python 管线（Tools/game_catalog）解析 `townhall_levels.csv` → catalog.json 新增 `instanceCounts` 字段（`"section:dataID": [18 个整数]`，index = TH-1）；Swift 侧 `GameCatalog` 解码 + 查询；`VillageCatalogProjection.project` 合成宇宙差集项（status `.available`，level 0）；`VillageProgressProjection.metrics` 用宇宙做完整分母。

**Tech Stack:** Python 3.14 纯 stdlib（现有管线惯例）/ Swift 6 / SwiftUI / XCTest（property 测试沿用 SeededGenerator LCG）。

**前置基线（已验证）**：worktree `.worktrees/issue70-phase2`（分支 `codex/issue-70-phase2-universe`，基于 main `ddae692`），`swift test` 838 全绿；APK `/path/to/base.apk` 在场（546MB）。

**数据源实证（已验证，SDD 事实基础）**：
- `assets/logic/townhall_levels.csv`：19 行（类型行 + TH1-18），列 = 建筑名，值 = 该 TH 可建造数量。主村 42 个非空数量列（Wall=325@TH18、Wizard Tower=6、Air Bomb=8…）；配置列（ResourceStorageLootCap/HeroBoostHours/TreasuryGold/FriendlyCost/UnlockStage/LeagueTier/ResourceScalingPercentage 等）与 `_gearup` 强化列（Cannon_gearup 等）非数量列需跳过；`Mega Cannon` 全空跳过。
- 列名 join：主村数量列全部命中 `buildings.csv.Name`（106 个）或 `traps.csv.Name`（22 个）——已验证 STILL missing 仅剩配置列/gearup/全空列。
- 单位/法术/英雄/宠物/装备不在 townhall_levels（无 Barbarian 等）→ 解锁型宇宙 = 每 dataID 1 实例，解锁 TH 从目录 `CatalogLevel.requiredTownHallLevel`（level==1 行）读取，**无需管线解析**。
- BB（建筑大师基地）：`bb_stages.csv` 只覆盖 8 类 BB 建筑；townhall_levels 的 BB 列稀疏且语义异常（TH14+ 全空）→ **BB 宇宙不做**（阶段 2 边界，BB 保持 partial）。
- 当前 TH 判定：`PlayerUnlockLevels.townHall`（#67 已有，从快照 buildings:1000001 读）复用；nil（快照无 TH）→ 宇宙不可算。

---

## 设计分析（CoT）与 3 候选投票

### 决策 1：宇宙数据形态（Swift 侧）

| 候选 | 方案 | 优劣 |
|---|---|---|
| A 独立字段（推荐） | catalog.json 新增 `instanceCounts: { "section:dataID": [Int]×18 }`，`GameCatalog` 内嵌存储 + `universeCount(section:dataID:townHallLevel:)` 查询；Payload 解码 `[String: [Int]]?`（nil = 旧目录向后兼容） | 与 items 平级、查询封装、旧目录兼容；体积小（~100 项 × 18 ints） |
| B CatalogItem 内嵌 | `CatalogItem.countsPerTownHall: [Int]?` | item 语义膨胀（levels 已复杂）；需要 items 全量遍历改构造 |
| C 独立 JSON 文件 | universe.json 单独解码 | 多文件加载/资源管理复杂；SPM 资源拍平风险 |

**投票：A。**

### 决策 2：解锁型实例宇宙 → **修正为不做**（设计评审 B1，数据前提被实证推翻）

原推荐「目录 requiredTownHallLevel（level==1）派生」被实证否决：
- `builders.py:_level_initial` 硬编码 level==1 行 `requiredTownHallLevel=None`（builders.py:209）；
- 真实 catalog.json 18.400.13：heroes 6/6 level1=nil（解锁值落在 level2 且与真实解锁 TH 不符），units/spells/pets/equipment/guardians/siege 全目录 0 个非 nil（这些表无 town_hall 列）。

**定稿：解锁型（units/spells/heroes/pets/equipment/guardians）不做宇宙**——保持"已观测实例"语义（其宇宙 = 观测到的实例）。验收口径相应明确：**「全村庄进度」= 数量型（buildings/traps）宇宙完整 + 解锁型已观测**。覆盖率分母 = known + unknown + available（available 仅数量型宇宙差集）。不伪造不可靠的解锁数据。

### 决策 3：`.available` 项产出范围

| 候选 | 方案 | 优劣 |
|---|---|---|
| A 投影产出 + UI 过滤（推荐） | `VillageCatalogProjection.project` 合成宇宙差集项（快照无、宇宙有、level 0、count=宇宙数、status `.available`）；**消费拆分**（设计评审 B2）：详情列表/筛选 chip/组卡消费「过滤 .available」数组，`metrics` 消费「仅排除 .unavailable」数组 + `completeDenominator: projection.universeComplete` | 实现 #12 预留枚举；覆盖率分母完整；UI 无产品变化 |
| B 列表也显示 | 详情列表显示未建造项"可建造" | 产品行为大改（列表爆炸），YAGNI |
| C metrics 内部合成 | 不产出 VillageItemState，metrics 内部合成 | 投影层与指标层逻辑重复；.available 枚举继续空置 |

**投票：A。** 合成项 id = `"universe:\(section):\(dataID)"`（rawRecordID 只剥 `agg:` 前缀，安全；合成放 `project()` 不放 `records()`，BuildingGroupProjection/CraftTableProjection 走原始记录层不受影响）。

### 决策 4：未观测实例等级

| 候选 | 方案 | 优劣 |
|---|---|---|
| A level 0（推荐） | 未建造实例分子贡献 0、分母贡献 cap×count；**覆盖率 < 100% 时 stage/global 仍 partial**（快照可能不全的保守，与覆盖指标联动） | 物理语义（未建造=0）；快照不全风险由覆盖率承担 |
| B 不算分子不算分母 | 分母只含观测∩宇宙 | 分母不完整，退回"已观测"语义 |
| C 按未知降级 | 宇宙项全部 unknown | 宇宙白做 |

**投票：A。** 文档明确：宇宙未建造项 level 0 是"该实例不存在"的物理事实，不是"观测到 0 级"（issue「未观测不能默认为 0 级」针对的是快照有记录但等级未知的项，走 unknown 侧不变）。

### 决策 5：BB 宇宙

| 候选 | 方案 | 优劣 |
|---|---|---|
| A 不做（推荐） | 阶段 2 宇宙只覆盖 home base；BB 保持 `completeDenominator = false`（partial + 已观测文案） | 数据源不可靠（bb_stages 8 类、townhall_levels BB 列稀疏），不伪造 |
| B townhall_levels BB 列 | 按主村 TH 取 BB 数量 | 语义错误（BB 数量与主村 TH 无关） |
| C bb_stages 部分覆盖 | 8 类有数据，其余缺失 | 分母不一致（部分完整部分不完整），最坏形态 |

**投票：A。**

### 决策 6：TH 缺失（快照无大本营记录）→ **定稿：partial（阶段 1 现状）**

`PlayerUnlockLevels.townHall == nil` → `universeComplete = false` → 调用方传 `completeDenominator: false` → stage/global 走阶段 1 语义（`.partial` + 「分母为已观测项目」文案），**不新增 unavailable 分支**（已观测信息仍有价值，unavailable 过强）。coverage 不受影响（不依赖 TH）。

### 决策 7（评审 I4）：指标标题

阶段 2 home 侧完整分母后，「已观测阶段进度/已观测全局进度」标题过时 → **改回「当前阶段进度/全局养成进度」**；partial 时（BB/TH 缺失）由降级文案「分母为已观测项目，非村庄全部实例」承担"已观测"限定。

### 决策 8（评审 I3）：总览卡 detail 文案

`aggregateCoverage` 分母含 available 后成为完整覆盖率 → ContentView 总览卡 detail 文案「已观测项目 · 全部村庄」改为「已观测实例 · 全部村庄」（语义：已观测占宇宙比例）。

---

## 类型契约（SDD 产物）

### Python 侧（Tools/game_catalog）

```python
# instance_counts.py（新文件）
"""townhall_levels.csv → 每 TH 实例数量宇宙（纯 stdlib）。"""

# 需要跳过的非数量列（townhall_levels 配置列 + gearup 强化列 + Treasury 配置列；
# 设计评审 B3：Treasury 6 列必须含，否则 fail-loud 失败）
CONFIG_COLUMNS = frozenset({
    "AttackCost", "ResourceStorageLootPercentage", "DarkElixirStorageLootPercentage",
    "ResourceStorageLootCap", "DarkElixirStorageLootCap", "WarPrizeResourceCap",
    "WarPrizeDarkElixirCap", "WarPrizeCommonOreCap", "WarPrizeRareOreCap",
    "WarPrizeEpicOreCap", "WarPrizeAllianceExpCap", "CartLootCapResource",
    "CartLootReengagementResource", "CartLootCapDarkElixir", "CartLootReengagementDarkElixir",
    "ReengagementBuildingBudget", "ReengagementHeroBudget", "ReengagementWallBudget",
    "ReengagementLabBudget", "HeroBoostHours", "PowerBoostHours",
    "ResourceProductionBoostHours", "StarBonusBoostHours", "FriendlyCost",
    "PackElixir", "PackGold", "PackDarkElixir", "PackGold2", "PackElixir2",
    "DuelPrizeResourceCap", "AttackCostVillage2", "ElixirCartStorageCap",
    "ResourceScalingPercentage", "ResourceScalingPercentage2", "LeagueTier",
    "UnrankedGoldRewardStarBonus", "UnrankedElixirRewardStarBonus",
    "UnrankedDarkElixirRewardStarBonus", "UnrankedCommonOreRewardStarBonus",
    "UnrankedRareOreRewardStarBonus", "UnrankedEpicOreRewardStarBonus",
    "SeasonPassResourceScalingPercentage", "SeasonPassResourceScalingPercentage2",
    "ScaleByTHPercent", "UnlockStage", "StrengthMaxTroopTypes",
    "StrengthMaxSpellTypes", "StrengthMaxSiegeTypes", "Mega Cannon", "Hidden",
    "TreasuryGold", "TreasuryElixir", "TreasuryDarkElixir",
    "TreasuryWarGold", "TreasuryWarElixir", "TreasuryWarDarkElixir",
})

def build_instance_counts(townhall_rows, buildings_rows, traps_rows) -> dict[str, list[int]]:
    """townhall_levels 主村列 → {"section:dataID": [TH1..TH18 数量]}。

    - TH 行 = Name ∈ {"1".."18"} 且恒 18 行（缺行 → CatalogError）；全空列
      判定只看 TH 行（类型行不计）；
    - 列跳过：CONFIG_COLUMNS、BB 前缀（"BB "）、TH 行全空、非整数值；
    - 列名 join buildings.csv.Name（→ "buildings"）与 traps.csv.Name（→ "traps"），
      按 dataID 映射；任一非空数量列 join 失败 → CatalogError（fail loud）；
    - 输出键 "section:dataID" 排序，值长度恒 18（index = TH-1）。
    """
```

### Swift 侧（COCHelperCore）

```swift
// GameCatalog.swift 增量
public struct GameCatalog: Sendable {
    // ...
    /// 实例数量宇宙（Issue #70 阶段 2）："section:dataID" → 每大本营等级
    /// （index = TH-1，恒 18 个元素）的可建造实例数。nil = 旧目录无宇宙数据。
    private let instanceCounts: [String: [Int]]?

    /// 宇宙查询：该 dataID 在指定大本营等级的可建造实例数；目录无宇宙数据、
    /// dataID 不在宇宙表、TH 越界（<1 或 >18）→ nil（fail-closed）。
    public func universeCount(section: String, dataID: Int64, townHallLevel: Int) -> Int?
}

// VillageCatalogProjection.swift 增量
public struct VillageCatalogProjection: Sendable {
    // ...
    /// 宇宙是否完整可用：目录含宇宙数据 且 快照已知大本营等级。
    /// true → 调用方可将 completeDenominator 置 true。
    public let universeComplete: Bool
    // project 内：宇宙差集项（快照无、宇宙 count>0）以 status == .available、
    // currentLevel == 0、count == 宇宙数 产出到 items；
    // 解锁型（category 非 buildings/traps 的目录项）每 dataID 1 实例，
    // 解锁 TH = 目录 level==1 的 requiredTownHallLevel（nil → 不计入）。
}

// VillageProgressMetrics.swift 增量
// metrics(from:catalogIsUsable:compatibility:completeDenominator:) 语义变化：
// - completeDenominator == true 时，stage/global 分母 = Σcap×count over
//   (known ∪ available)；available 项 level 0 → 分子贡献 0；
// - coverage 分母 = known ∪ unknown ∪ available 权重（完整覆盖率）；
// - 其余语义不变（unavailable/unknown/partial/ready 判定、饱和、缺失侧）。
```

### 不变量（测试即契约）

- 宇宙项 `count > 0`（TH 下可建造）才产出 `.available`；count == 0 的宇宙项不产出（该 TH 未解锁该建筑）。
- 宇宙差集项仅限数量型（buildings/traps，home base）；解锁型（units/spells/heroes/pets/equipment/guardians）不做宇宙（决策 2 定稿）。
- `completeDenominator == true` 且分母含 available 项时，stage/global 的 ratio = 全村庄进度（分母 = 宇宙完整 = known ∪ available）。
- 覆盖率 = known / (known + unknown + available)；覆盖率 100% ⟺ 快照覆盖全部宇宙项（无 unknown 无 available）。
- 覆盖率 < 100%（存在 available 或 unknown）→ stage/global 恒 partial（快照可能不全，保守）。
- `universeComplete == false`（TH 缺失或目录无宇宙）→ 调用方传 completeDenominator=false → 阶段 1 语义（partial + 已观测文案），coverage 不受影响。
- 旧目录（instanceCounts nil）→ 行为与阶段 1 完全一致（universeComplete=false，无 .available 产出）。
- BB base 恒 universeComplete=false（决策 5）。
- `universeCount` 越界防御：TH < 1 或 > 18 → nil；宇宙数组长度 ≠ 18 → 视为无宇宙（解码时校验，fail-closed 不 crash）。

---

## Task 1：Python 管线（townhall_levels → instanceCounts）

**Files:**
- Create: `Tools/game_catalog/instance_counts.py`
- Modify: `Tools/game_catalog/catalog.py`（generate 输出 instanceCounts）
- Modify: `Tools/game_catalog/validate.py`（instanceCounts 校验）
- Test: `Tools/tests/test_instance_counts.py`

- [ ] **Step 1: 写失败测试**（TDD）

```python
# Tools/tests/test_instance_counts.py
import io
import zipfile

import pytest

from game_catalog.errors import CatalogError
from game_catalog.instance_counts import build_instance_counts, CONFIG_COLUMNS


def _rows(csv_text: str) -> list[dict[str, str]]:
    import csv
    return list(csv.DictReader(io.StringIO(csv_text)))


def _sample_archive(buildings: str, traps: str, townhall: str) -> zipfile.ZipFile:
    """合成最小 APK：三张 CSV 用 SC2 编码——测试直接写纯文本经 apk.rows_from_text
    读取；build_instance_counts 接受 rows 而非 archive，故此处只构造 rows。"""


class TestBuildInstanceCounts:
    def test_home_building_counts_by_th(self):
        # Cannon: TH1=1, TH2=1, TH3=2 …（只给 3 个 TH 级验证 index 映射）
        buildings = _rows(
            '"Name","GlobalID","BuildingLevel","VillageType"\n'
            '"Cannon","1000001","1","home"\n'
        )
        traps = _rows('"Name","GlobalID","BuildingLevel"\n')
        townhall = _rows(
            '"Name","Cannon","Wall","HeroBoostHours"\n'
            '"1","1","10","120"\n'
            '"2","1","25","120"\n'
            '"3","2","40","120"\n'
        )
        counts = build_instance_counts(townhall, buildings, traps)
        # TH index = level-1；测试只给 TH1-3，缺 4-18 → CatalogError（长度契约）
        # 因此测试给全 18 行。见下。
```

**实现契约**：
- `build_instance_counts(townhall_rows, buildings_rows, traps_rows) -> dict[str, list[int]]`
- TH 行 = Name ∈ {"1".."18"}，恒 18 行，缺行 → CatalogError
- 每列：跳过 CONFIG_COLUMNS ∪ BB 前缀 ∪ 全空列 ∪ 非整数列；join buildings.Name/traps.Name → dataID；失败 → CatalogError（消息含列名）
- 输出 `{"buildings:1000001": [1,1,2,...]}` 长度恒 18
- 集成：`catalog.py generate` 读 townhall_levels.csv（`apk.rows`），调 build_instance_counts，写入 catalog payload `instanceCounts`；`validate.py` 校验：instanceCounts 存在性（非必填，旧产物兼容）、每项长度 18、值非负、键 `section:dataID` 全部存在于 items、items 中 buildings/traps 每 dataID 有宇宙项（双向 join 完整性）——**注意 validate 校验应允许"解锁型无宇宙项"**（buildings/traps 必须有，其他类别可以有）。

- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**（instance_counts.py + catalog.py + validate.py）
- [ ] **Step 4: 跑测试确认通过**（`pytest Tools/tests`，含真实 APK 集成测试：TH18 Cannon/Wall 锚点）
- [ ] **Step 5: 提交**

## Task 2：Swift 模型（GameCatalog 宇宙查询）

**Files:**
- Modify: `Sources/COCHelperCore/GameCatalog.swift`
- Modify: `Sources/COCHelperCore/GameCatalog/18.400.13/catalog.json`（重新生成，含 instanceCounts）
- Test: `Tests/COCHelperCoreTests/GameCatalogTests.swift`

- [ ] **Step 1: 写失败测试**（universeCount 查询：命中/越界/缺失/旧目录 nil）
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**（Payload 加 `instanceCounts: [String: [Int]]?`，存储 + `universeCount(section:dataID:townHallLevel:)`；`townHallLevel` 越界（<1 或 >18）→ nil）
- [ ] **Step 4: 重新生成 catalog.json**（设计评审 B4：真实入口是 `python3 Tools/generate_game_catalog.py --apk /path/to/base.apk --game-version 18.400.13 --output Sources/COCHelperCore/GameCatalog/18.400.13`——catalog.py 无 CLI；`generate()` 要求输出目录不存在或为空，**需先清空 18.400.13 目录**（仅保留 icons/.gitkeep 时先 rm 再重建，或移到临时目录对比后替换；**commit 前用 git diff 核对 catalog.json 只新增 instanceCounts 字段**，其余字节应一致——validate 会保证）
- [ ] **Step 5: 提交**

## Task 3：投影层（.available 宇宙项 + metrics 完整分母）

**Files:**
- Modify: `Sources/COCHelperCore/VillageCatalogProjection.swift`
- Modify: `Sources/COCHelperCore/VillageProgressMetrics.swift`
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift` + `VillageProgressMetricsTests.swift`

- [ ] **Step 1: 写失败测试**
  - universeComplete：TH 已知 + 目录有宇宙 → true；TH nil / 目录无宇宙 / BB base → false
  - .available 产出（仅数量型 home）：快照无 Cannon 且 TH18 宇宙 count 6 → 产 .available 项（id = "universe:buildings:1000002"、level 0、count 6、status .available、maxLevel/currentStageMaxLevel 从目录 join）
  - 宇宙 count 0 的项不产出；已观测项不产出 .available；解锁型（units/heroes）不产出 .available（决策 2）
  - metrics completeDenominator=true：分母 = known ∪ available（available level 0 贡献分子 0），ratio 正确；覆盖率 = known/(known+unknown+available)
  - 覆盖率 < 100%（含 available 或 unknown）→ stage/global partial；覆盖率 100% → ready
  - TH 缺失 / BB base → completeDenominator=false 语义（partial + 已观测文案，无 unavailable 新分支）
  - 旧目录（instanceCounts nil）→ 行为与阶段 1 一致（无 .available 产出、universeComplete=false）
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**
  - project：`universeComplete = base == .home && catalog?.hasUniverseData == true && playerUnlocks.townHall != nil`（BB 恒 false，决策 5）
  - project 合成宇宙项（在 aggregate 之后追加，不进 aggregate）：遍历 `catalog.universeKeys()`（数量型仅 buildings/traps），`universeCount(TH) > 0` 且快照无该 (section,dataID) → 产 .available 项（id = "universe:section:dataID"、currentLevel = 0、count = 宇宙数、status .available、maxLevel/currentStageMaxLevel 从目录 item join、missingReason nil）
  - metrics：`completeDenominator == true` 时，stage/global eligible = known ∪ available（available 的 level 0 贡献分子 0、cap×count 贡献分母；available 需过 stageMax > 0 过滤，同 known 规则）；coverage 分母 = 全部 items 权重（含 available）；available 存在或 unknown > 0 → partial；否则 ready
- [ ] **Step 4: 跑测试确认通过** + 全量
- [ ] **Step 5: 提交**

## Task 4：UI 接入（拆分消费数组 + 标题回退）

**Files:**
- Modify: `Sources/COCHelper/VillageDetailView.swift`（**拆分 trackedItems**：`displayItems`（过滤 .unavailable + .available）供 groups/stats/chips/列表；metrics 输入 `trackedItems`（仅滤 .unavailable）传 `completeDenominator: projection.universeComplete`；标题改回「当前阶段进度/全局养成进度」——决策 7）
- Modify: `Sources/COCHelperCore/UpgradeOverviewProjection.swift`（allRecords：records 过滤 .unavailable + .available；metrics 用未过滤输入 + `completeDenominator: projection.universeComplete`——设计评审 B2）
- Modify: `Sources/COCHelper/ContentView.swift`（总览卡 detail 文案「已观测项目 · 全部村庄」→「已观测实例 · 全部村庄」——决策 8）

- [ ] **Step 1: 改代码**（三处）
- [ ] **Step 2: 编译 + 全量测试**
- [ ] **Step 3: 提交**

## Task 5：Reflexion 自查 + property 测试

**Files:**
- Test: `Tests/COCHelperCoreTests/VillageProgressMetricsPropertyTests.swift`

- [ ] **Step 1: property 测试扩展**：随机宇宙项（随机 TH/随机 counts）验证：
  - 0 ≤ ratio ≤ 1（含 available level 0 贡献）
  - coverage 守恒：known + unknown + available == 分母
  - 覆盖率 100% ⟺ 无 unknown 无 available
  - completeDenominator=true 且宇宙完整 → stage ≥ global（per-instance 性质受限生成器下）
- [ ] **Step 2: 对照 #70 验收标准逐条自查**（7 项 + 实现要求 6 项，尤其验收 3：分母契约 = 数量型全村庄实例宇宙 + 解锁型已观测 → 可称全村庄进度）
- [ ] **Step 3: 全量验证**（swift test + pytest + release build + git diff --check）
- [ ] **Step 4: 提交（如有修正）**

---

## 不做（边界）

- BB（建筑大师基地）宇宙（数据源不可靠，决策 5）
- Capital（都城）宇宙（无数据源）
- 解锁型（units/spells/heroes/pets/equipment/guardians）宇宙（level==1 门槛恒 nil，数据不可靠不伪造，决策 2 定稿）
- 详情列表显示未建造项（决策 3，UI 过滤 .available）
- 管线解析 UnlockByTH（决策 2 否决后无必要）
- `.available` 项在升级总览显示（过滤）
