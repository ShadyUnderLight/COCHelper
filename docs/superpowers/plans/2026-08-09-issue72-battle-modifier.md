# Issue #72：保存并展示部落对战 battleModifier

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 保存并展示官方 `battleModifier`（Hard Mode / 传奇杯战争规则）：模型保存原始值、round-trip 不丢、已知键不进审计、UI 显示"规则：…"（nil 不渲染占位），currentwar 与 warlog 共用同一格式化层。不把 modifier 用作结果推导来源。

**Architecture:** `OfficialClanWarSnapshot` 手写 Codable 各加一处 decode/encode；`OfficialWarLogEntry` 合成 Codable 加字段 + init 参数；格式化层 `BattleModifierText` 放 Core（executable UI target 不可测）。parserVersion 随解析范围递增（`clan-war-0.2→0.3`、`clan-war-log-0.3→0.4`）。

日期：2026-08-09 · 分支：`issue-72-battle-modifier`

## 背景（评审结论摘要）

- `OfficialClanWarSnapshot` 把 `battleModifier` 列入 `knownKeys` 但无属性：解码读取后**静默丢弃**，
  编码不输出 → round-trip 丢字段。用户无法区分困难模式/传奇杯规则战争与普通战争。
- fixture `official_clan_war_full.json` 已带 `"battleModifier": "hardMode"`，现有测试锁定"不进 unrecognizedKeys"的 deferred 行为。
- 外部依据（clashy v26.6.5 changelog + BattleModifier 枚举文档）确认官方值域：
  `none` / `hardMode` / `minusOne`（传奇杯 I）/ `minusTwo`（传奇杯 II）/ `minusThree`（传奇杯 III）；
  **currentwar 与 warlog 条目都返回该字段**。
- 生产代码无 `OfficialClanWarSnapshot(...)` 直接构造（全部走解码）；init 签名变更只影响测试调用点（7 处）。

## 目标

1. `OfficialClanWarSnapshot` 保存可选原始 `battleModifier`（String，不做本地枚举映射，与 state/result 契约一致）。
2. 稳定中文映射：`hardMode`→困难模式、`minusOne`→传奇杯 I、`minusTwo`→传奇杯 II、`minusThree`→传奇杯 III；
   `none`/`nil` → 不显示；未知非空值 → 保留 raw（可审计 fallback）。
3. 编解码 round-trip 不丢字段；`unrecognizedKeys` 不再包含已支持字段。
4. `OfficialWarLogEntry`（warlog 条目）同样保存该字段（外部证据确认官方返回）。
5. 战争卡片摘要顶部显示"规则：…"；无字段/`none` 时不显示占位。
6. warlog 行复用同一格式化层，不复制字符串表。
7. 不把 modifier 当作结果/星数/摧毁率的推导来源。

## 类型契约（public）

```swift
// Sources/COCHelperCore/ClanWarModels.swift

public struct OfficialClanWarSnapshot {
    /// 官方 battleModifier：hardMode / minusOne / minusTwo / minusThree / none / null。
    /// 保存原始值（不做本地枚举映射）；"none" 与缺失均视为无规则。
    public let battleModifier: String?
    // init / decode / encode 各加一处；knownKeys 已含该键，不动。
}

/// 格式化层（放 Core：UI 两个卡片共用 + 可测；测试 target 依赖 Core）。
public enum BattleModifierText {
    /// 稳定中文映射；nil / "none" → nil（UI 不显示）；未知非空 → 原样（可审计）。
    public static func localizedText(for raw: String?) -> String?
}

// Sources/COCHelperCore/ClanPaginationModels.swift

public struct OfficialWarLogEntry {
    public let battleModifier: String?   // 合成 Codable 自动编解码；init 加参数
}
```

## 任务分解

### Task 1：模型字段 + 格式化层（TDD + property-based fuzz）

文件：
- `Sources/COCHelperCore/ClanWarModels.swift`（属性/init/decode/encode + `BattleModifierText`）
- `Sources/COCHelperCore/ClanPaginationModels.swift`（`OfficialWarLogEntry.battleModifier` + init 参数）
- `Tests/COCHelperCoreTests/ClanWarDecodeTests.swift`（更新 deferred 测试 + 新增 decode/round-trip/未知值/null）
- `Tests/COCHelperCoreTests/BattleModifierTests.swift`（新文件：映射表 + 未知值 + fuzz round-trip）
- 7 处既有 `OfficialClanWarSnapshot(...)` 测试调用点补参（`battleModifier: nil` 或对应值）

TDD 顺序（每个先 RED 再 GREEN）：
1. full fixture decode → `battleModifier == "hardMode"`（改造既有 deferred 测试）
2. 未知值 `{"state":"inWar","battleModifier":"futureX"}` 解码成功、保留、不进 unrecognizedKeys
3. 缺失/null → nil；encode 时 nil 不输出键
4. round-trip 保留（含 fuzz：LCG 伪随机 200 迭代，参考 `ClanMemberDecodeFuzzTests` 风格）
5. `BattleModifierText`：hardMode/minusOne/minusTwo/minusThree/none/nil/未知值 全分支
6. warlog 条目 decode + round-trip 保留 battleModifier

### Task 2：UI 展示（两卡片复用格式化层）

文件：
- `Sources/COCHelper/ClanWarCardView.swift`：`scoreRow` 顶部加规则行（"对战规模"行同风格：
  `.font(.caption).foregroundStyle(.secondary)`；`localizedText` 返回 nil 时不渲染）
- `Sources/COCHelper/WarLogCardView.swift`：`warLogSummary` 加规则标签（复用 `BattleModifierText`）

注意：COCHelper 是 executable target（不可被测试 target 依赖），格式化逻辑已在 Core 测过，UI 层仅一行调用，不新建 UI 测试 target。

## 验证

- `swift test` 全量通过（基线 589 → 598，新增 9 个测试）
- round-trip 等值断言覆盖 known/unknown/null 分支
- fuzz 迭代内 `unrecognizedKeys` 为空（battleModifier 是 known key）

## parserVersion bump（解析范围变化，评审补充）

按项目成文惯例（ce26c50「成员级解析范围变化递增 parserVersion (Issue #20)」），
本次给 `OfficialClanWarSnapshot` 与 `OfficialWarLogEntry` 都新增了解析字段：

- `clan-war-0.2 → clan-war-0.3`（`OfficialEndpointState.swift`，注释同步）
- `clan-war-log-0.3 → clan-war-log-0.4`（`ClanPaginationModels.swift`，注释同步）

理由：`AppModel.loadMoreWarLog` 的 `needsRebuild = current.parserVersion != parserVersion`
依赖版本号变化触发累计页重建；若不 bump，旧页条目（battleModifier == nil）与新页条目
（有值）在 Equatable 不相等时会出现合并残留重复，防御机制静默失效。

升级影响：所有用户的既有持久化状态被标记旧版——currentwar 旧 lastGood 保留不丢弃
（新字段缺失仅规则行不显示，刷新后恢复）；warlog 旧累计页首次 load-more 时重建
（与 Issue #20 ce26c50 升级行为一致）。

测试断言同步：`GenericEndpointStateTests`（两处）、`AppModelTests` L426（升级到
当前版本断言）。旧版本 fixture（`"clan-war-log-0.2"`、`"clan-war-0.1"`）保持不动。

## 非目标 / 边界

- 不把 modifier 用于结果/星数/摧毁率推导（#69 范围外）
- 不修改战争分页或成员攻击层级
- 不做 Legend 值之外的猜测映射；未知值 raw 兜底即可
- 不新建 UI 测试 target、不动 `.build`/依赖

## 修订记录

- 2026-08-09 初版（SDD 类型契约 + 任务分解）
- 2026-08-09 评审修复：补充 parserVersion bump 章节（code review 发现）；
  格式化层 `""`/纯空白 → nil（交叉审核 A 发现）；fuzz 增加 decode 侧 expected 断言；
  测试复用既有 LCG；warlog 编码护栏断言不依赖 JSON 键顺序（交叉审核 A 发现，
  合成 Codable 键顺序非语言契约——swiftc 与 swift 解释器产物顺序不同）
