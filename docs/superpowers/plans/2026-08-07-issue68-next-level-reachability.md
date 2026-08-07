# Issue #68 下一等级可达性语义（升级中/阶段上限/Requirement）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「下一等级」从整数推断改为带可达性语义的共享投影结果，覆盖升级中/非升级两条路径；阶段满级时显示具体阻塞 Requirement；UI 三处（列表行/详情 sheet/组卡）消费同一投影结果，不各自 `currentLevel + 1`。

**依赖:** Issue #67 已合入 main（`fd4f0cf`）：`UpgradeRequirement` enum、`PlayerUnlockLevels`、`currentStageMaxLevel`、`.unverified` fail-closed 均已就绪。本计划不重复实现。

**Architecture:** Core 层新增 `VillageNextUpgrade` 单枚举投影字段（`VillageItemState.nextUpgrade`），投影层用「目录真实下一等级」（`levels.first(> currentLevel)`，非连续安全）计算；升级中记录保持事实语义（`inProgressFact`）但版本不匹配/缺 prereq 时不再泄漏旧目录阶梯；`UpgradeRequirement` 增加公共格式化，UI 三处统一消费。组卡 `steps(for:)` 增加 `catalogIsUsable` 参数，升级中 + 版本不匹配/缺 prereq → 阶梯空（T17b 同口径扩展到升级中）。

**Tech Stack:** Swift 6（SPM，XCTest 基线 701/701）。Python 目录生成器本次无改动（不新增字段），pytest 基线不改。

**关键设计决策（已投票，D1=A/D2=C/D3=A/D4=A）：**
- D1=A：单枚举 `VillageNextUpgrade`（`available(level:durationSeconds:)` / `requires(nextLevel:requirements:referenceDurationSeconds:)` / `globalMaxed` / `inProgressFact(level:durationSeconds:)` / `unverified` / `unknown`），编译器穷尽 switch 保证 UI 不遗漏
- D2=C：升级中目标等级是**快照事实**（`inProgressFact`），时长来自目录目标等级记录；版本不匹配时 duration=nil 且 `missingReason` 显式标注（旧目录时长/阶梯不泄漏）；缺 prereq（stageMax==nil）时时长保留（进行中事实）但组卡阶梯按 unverified 同规则 fail-closed
- D3=A：真实下一等级 = `catalogItem.levels.first(where: { $0.level > currentLevel })`；`nextLevelDurationSeconds` 计算同步改为真实下一级（修复非连续目录下 `currentLevel + 1` 推时长恒 nil 的潜在 bug）
- D4=A：`UpgradeRequirement` 扩展 `displayLabel(base:)`（中文文案，与现有 unlockLabel 措辞一致），LevelDetailSheet 手写分支改为消费它，UpgradeDisplayRow/BuildingGroupSummaryView 复用

**边界（不做）：** 不引入队列拥有者/资源库存/开始升级操作（#68 声明）；不动 #66 完成度加权口径；不改 #14 `nextLevel` 契约（仍仅升级中非 nil）；不动 Python 生成器。

**工作区:** `.worktrees/issue-68-next-level`，分支 `codex/issue-68-next-level-reachability`，基于 `main@fd4f0cf`。基线 701 XCTest 全绿。

---

### Task 1: Core 投影层——`VillageNextUpgrade` 枚举 + 真实下一等级 + 升级中语义

**Files:**
- Modify: `Sources/COCHelperCore/VillageCatalogProjection.swift`
- Test: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`

**类型契约（新增，public）：**

```swift
/// 单个物品的「下一等级」投影语义（Issue #68）。
/// UI 三处（列表行/详情 sheet/组卡）必须消费本字段，禁止各自 currentLevel + 1 推导。
public enum VillageNextUpgrade: Hashable, Sendable {
    /// 可操作升级：未达阶段上限，下一等级（目录真实等级）gate 全部满足。
    case available(level: Int, durationSeconds: Int64?)
    /// 阶段满级且目录存在更高等级：nextLevel 是第一个超过 currentStageMax 的真实
    /// 等级，requirements 为其解锁条件；referenceDurationSeconds 是「解锁后参考」
    /// 时长，UI 不得与 available 混用（不得显示为当前可操作升级时长）。
    case requires(nextLevel: Int, requirements: [UpgradeRequirement], referenceDurationSeconds: Int64?)
    /// 全局已满级：currentLevel >= 目录 maxLevel。
    case globalMaxed
    /// 升级中：目标等级是快照事实（非可达性判断）；durationSeconds 是目录目标等级
    /// 时长（版本不匹配/目录不可用时为 nil，不得泄漏旧目录时长）。
    case inProgressFact(level: Int, durationSeconds: Int64?)
    /// 缺 prerequisite 无法验证阶段上限（fail-closed，不推断可升级）。
    case unverified
    /// 目录不可用/版本不匹配（非升级）/未收录（fail-closed，不推断可升级）。
    case unknown
}
```

`VillageItemState` 新增存储属性 `public let nextUpgrade: VillageNextUpgrade?`（unavailable/嵌套项为 nil，沿用现有 nextLevelDurationSeconds nil 语义）；init 加默认值 nil 参数；`aggregate` 透传 `first.nextUpgrade`。

**投影规则（map 内，在 stageMax 计算之后）：**

```
guard 目录命中且 baseMatches，否则 nextUpgrade = nil（unknown 语义沿用 status）
if isUpgrading:
    factLevel = currentLevel + 1（#14 契约，仅升级中显式推断）
    duration = catalogIsUsable ? durationToUpgradeLevel(factLevel) : nil
    // 版本不匹配时 missingReason 设为「目录版本不匹配，旧目录等级/时长不可信」
    nextUpgrade = .inProgressFact(level: factLevel, durationSeconds: duration)
else if stageMax == nil:            // 缺 prereq
    nextUpgrade = .unverified
else if currentLevel >= maxLevel:   // 全局满级（含 currentLevel > maxLevel 目录过时）
    nextUpgrade = .globalMaxed
else if currentLevel >= stageMax:   // 阶段满级且有更高等级
    realNext = levels.first(> stageMax)   // 第一个超过阶段上限的真实等级
    requirements = realNext.requirements(base:)（空数组 → .globalMaxed？不，数据异常；非空是正常）
    referenceDuration = durationToUpgradeLevel(realNext.level)
    nextUpgrade = .requires(nextLevel: realNext.level, requirements: ..., referenceDurationSeconds: referenceDuration)
else:                               // 可升级
    realNext = levels.first(> currentLevel)
    duration = durationToUpgradeLevel(realNext.level)（真实下一级，非 currentLevel + 1）
    nextUpgrade = .available(level: realNext.level, durationSeconds: duration)
    // 同时修正 nextLevelDurationSeconds：改用 realNext（非连续目录修复）
```

注意 `nextLevelDurationSeconds` 现有语义保持非 nil 条件不变（仅时长来源从 `level + 1` 改为 realNext），确保现有 #16/#67 测试不破坏。

**测试（TDD，全部先 RED）：**

 - [x] `testNextUpgradeAvailableBelowStageMax`：加农炮 level 1、TH 12 → `.available(level: 2, duration: 300)`
 - [x] `testNextUpgradeRealNextLevelNonContiguous`：非连续目录 levels [1,2,3,5,7]、level 3、gate 全满足 → `.available(level: 5, ...)` 且 `nextLevelDurationSeconds` 为 5 级时长（非 nil）
 - [x] `testNextUpgradeRequiresWhenStageMaxed`：野蛮人 level 2（=stageMax，lab gate）、TH 12 → `.requires(nextLevel: 3, requirements: [.laboratory(level: 2)], ...)`
 - [x] `testNextUpgradeHeroHallGateRequires`：英雄 level 8（=stageMax，tavern 10 gate）、heroHall 8 → `.requires` 含 `.heroHall(level: 10)`、referenceDuration 为 9 级时长
 - [x] `testNextUpgradeGlobalMaxed`：level == maxLevel → `.globalMaxed`；level > maxLevel（目录过时）→ `.globalMaxed`
 - [x] `testNextUpgradeInProgressFact`：升级中 → `.inProgressFact(level: current+1, durationSeconds: 目录目标级时长)`
 - [x] `testNextUpgradeUpgradingVersionMismatchNoDuration`：升级中 + 版本不匹配 → `.inProgressFact(durationSeconds: nil)` 且 missingReason 含「版本不匹配」
 - [x] `testNextUpgradeUpgradingMissingPrerequisiteKeepsFact`：升级中 + 快照缺大本营（stageMax nil）→ `.inProgressFact(level: current+1, durationSeconds: 非 nil)`
 - [x] `testNextUpgradeUnverifiedWhenPrerequisiteMissing`：非升级 + 缺 prereq → `.unverified`
 - [x] `testNextUpgradeUnknownWhenVersionMismatchIdle`：非升级 + 版本不匹配 → `.unknown`
 - [x] `testNextUpgradeNilForNestedAndUnavailable`：嵌套项/unavailable → nil
 - [x] `testAggregatePropagatesNextUpgrade`：聚合后 nextUpgrade 保留
 - [x] `testPropertyNextUpgradeInvariants`（property-based，SeededRNG）：随机 levels/requirement gate/unlocks/currentLevel → 不变量：(1) `.available` 的 level ∈ 目录 levels；(2) `.requires` 的 nextLevel > currentStageMaxLevel；(3) `.inProgressFact` 的 level == currentLevel + 1；(4) status == .maxed ⟺ nextUpgrade ∈ {.requires, .globalMaxed}（有目录且可计算时）；(5) nextUpgrade == nil ⟺ 嵌套/unavailable/目录未命中

---

### Task 2: 组卡——升级中 fail-closed + 阶梯截断

**Files:**
- Modify: `Sources/COCHelperCore/BuildingGroupProjection.swift`
- Test: `Tests/COCHelperCoreTests/BuildingGroupProjectionTests.swift`

 - [x] `steps(for:item:catalog:)` 增加 `catalogIsUsable: Bool` 参数：false → 空数组（升级中版本不匹配不再泄漏旧目录阶梯，T17b 口径扩展）
 - [x] 升级中 + 缺 prereq（status == .upgrading 且 currentStageMaxLevel == nil）→ 空数组（与 unverified 同口径 fail-closed）
 - [x] 升级中 + stageMax 可计算：阶梯仍按 `level ∈ (currentLevel, effectiveMax]` 过滤（现状逻辑已正确，加测试锁定）
 - [x] `testUpgradingVersionMismatchNoLadder`：升级中 + 版本不匹配 → steps 空、completeness 不为 versionMismatch 之外的误导
 - [x] `testUpgradingMissingPrerequisiteNoLadder`：升级中 + 快照缺 prereq → steps 空
 - [x] `testUpgradingLadderCappedAtStageMax`：升级中 + stageMax < maxLevel → 阶梯不含超过 stageMax 的等级（若升级目标 > stageMax 属数据异常，阶梯截断到 stageMax）
 - [x] 现有 T8（upgrading ladder）回归通过（无 gate 目录 → stageMax == maxLevel → 不变）

---

### Task 3: UI 统一消费——LevelDetailSheet / UpgradeDisplayRow / 组卡摘要

**Files:**
- Modify: `Sources/COCHelperCore/GameCatalog.swift`（`UpgradeRequirement.displayLabel(base:)` 扩展）
- Modify: `Sources/COCHelper/LevelDetailSheet.swift`
- Modify: `Sources/COCHelper/UpgradeDisplayRow.swift`
- Modify: `Sources/COCHelper/BuildingGroupSummaryView.swift`
- Test: `Tests/COCHelperCoreTests/GameCatalogTests.swift`（displayLabel 单测）

 - [x] `UpgradeRequirement.displayLabel(base:)`：`.townHall(12)` home → 「所需大本营等级 12级」；builder → 「所需建筑大师大本营等级 12级」；`.laboratory` → 「所需实验室等级 X级」；`.starLaboratory` → 「所需星空实验室等级 X级」；`.heroHall` → 「所需英雄殿堂等级 X级」；`[UpgradeRequirement].displayLabels(base:)` → 「A · B」连接（与现有 unlockLabel 措辞逐字一致）
 - [x] `LevelDetailSheet`：`effectiveNext` 改为消费 `item.nextUpgrade`（`.available` → level；`.inProgressFact` → level；其余 nil）；`unlockLabel` 改用 `requirements(base:)` + `displayLabels`；升级中 + 版本不匹配（missingReason 非 nil 且 status == .upgrading）→ missingNote 分支显示，不渲染旧目录等级列表；阶段满级（`.requires`）时 statusLabel 下方加一行「下一级 N 级 解锁条件：…」（用 displayLabels；评审后措辞统一）
 - [x] `UpgradeDisplayRow`：非升级「下一级：N级」编号改用 `nextUpgrade.available.level`（删除 `currentLevel + 1`）；`.requires` 时在 durationLabel 区域显示「下一级 N 级 解锁条件：…」阻塞文案（替换「当前阶段已满级」的时长位或并列）
 - [x] `BuildingGroupSummaryView`：组内实例存在 `.requires` 时，阶段上限文案下加阻塞 requirement 摘要（取第一个 requires 的 displayLabels）
 - [x] `testRequirementDisplayLabelHomeBuilder`：displayLabel 全类型 + base 分支单测
 - [x] UI 层无单测基建（项目现状），SwiftUI 改动靠交叉 code review 验证

---

### Task 4: 全量回归 + 自查

 - [x] `swift test` 全绿（预期 ~715+）
 - [x] `python3 -m pytest -q Tools/tests` 全绿（应无改动，防目录校验回归）
 - [x] `git diff --check`、`swift build`（Debug + Release）
 - [x] Reflexion：对照 #68 验收标准 8 条逐条核对（验收 7 的测试场景逐项列出）

**验收标准映射（#68）：**
1. 阶段满级显示「当前阶段已满级」→ #67 已有 + `.requires` 文案增强
2. 有未来等级显示缺失 Requirement → `.requires(requirements:)` + 列表行/详情/组卡消费
3. Requirement 满足才显示时长、时长来自目标等级记录 → `.available(durationSeconds:)` + realNext 修复
4. TH/BH/Lab/StarLab/HeroHall 统一模型 → `UpgradeRequirement` + `displayLabel(base:)`
5. 缺失/目录不匹配/等级未知 → `.unverified`/`.unknown` fail-closed（#67 已有 + 升级中路径补齐）
6. 三处消费同一投影结果 → `nextUpgrade` 单字段
7. 测试覆盖 → Task 1/2/3 测试清单
8. `swift test` 通过 → Task 4
