# Issue #72：保存并展示部落对战 battleModifier

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

- `swift test` 全量通过（基线 589 → 新增约 10+ 测试）
- round-trip 等值断言覆盖 known/unknown/null 分支
- fuzz 迭代内 `unrecognizedKeys` 为空（battleModifier 是 known key）

## 非目标 / 边界

- 不把 modifier 用于结果/星数/摧毁率推导（#69 范围外）
- 不修改战争分页或成员攻击层级
- 不做 Legend 值之外的猜测映射；未知值 raw 兜底即可
- 不新建 UI 测试 target、不动 `.build`/依赖
