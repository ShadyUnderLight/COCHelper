# Issue #74 seasonal 模型层实施设计（空阶段表契约）

日期：2026-08-08
分支：codex/issue-74-seasonal
依据：用户确认的方案（模型层先行；无日期 →「阶段信息未配置」；不从 specialAbility 推断 seasonal；不编造当前可用；暂不提交人工日期；verified/mismatch 不动）

## 1. 范围

- **模型**：`CatalogAvailability`（permanent / seasonal(phaseID, isActive) / unconfigured）+ `SeasonalPhase`/`SeasonalPhaseTable` 契约（空表起步）
- **投影**：`VillageItemState.availability`（阶段表驱动，clock 用 project 既有 `now` 注入）
- **UI**：LevelDetailSheet availability 标记（详情页低噪音；列表行不显示）
- **不做**：阶段表数据文件（暂不提交人工日期）；从 `specialAbility` 推断 seasonal（约束）；verified/mismatch 改动（等玩家 build 数据源）

## 2. 现状证据（已核实）

| 项 | 现状 |
|---|---|
| craft_table_catalog.json | source 标注 "APK seasonal defense logic tables"；14 个 defenses `specialAbility` 全为 `Seasonal*`（SeasonalDefenseHookTower 等），**无任何日期字段** |
| 生成器 | `Tools/game_catalog/` 零 seasonal/phase 代码 |
| clock | `VillageCatalogProjection.project(now: Date = Date())` 既有注入（计时用）——availability 判定复用同一 now，零新增 |
| deprecated | 已有 `isCatalogDeprecated`（独立维度，来自 CatalogItem.missingReason） |
| 嵌套项 | 快照嵌套项 dataID 段 102M/103M（craft table 同源）——availability 按 `(section, dataID)` 查表，嵌套项同规则 |

## 3. 类型契约（定稿）

```swift
/// 限时内容阶段配置（阶段表契约；空表起步，人工维护/APK 提取后填充）。
public struct SeasonalPhase: Codable, Hashable, Sendable {
    public let phaseID: String
    public let name: String?        // 展示名（官方公告名）
    public let from: Date
    public let until: Date          // 结束边界：from <= now < until 视为活动
    public let itemKeys: [String]   // "section:dataID"（与 CatalogItem.id 同格式）
}

public struct SeasonalPhaseTable: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let phases: [SeasonalPhase]
    public static let empty = SeasonalPhaseTable(schemaVersion: 1, phases: [])

    /// 查 item 的阶段：itemKeys 命中且 from <= date < until 的活动阶段；
    /// 多阶段命中（异常数据）→ 取 from 最晚者（确定性）；无命中 → nil。
    public func activePhase(forItemKey key: String, at date: Date) -> SeasonalPhase?

    /// bundled 加载：GameCatalog/<version>/seasonal_phases.json；缺失/损坏 → 空表
    ///（不报错——阶段信息是增强数据，缺失 = 未配置）。
    public static func loadBundled(version: String) -> SeasonalPhaseTable
}

/// 条目可用性状态（历史存在 vs 当前可用）。与 deprecated（isCatalogDeprecated）
/// 是独立维度：deprecated 来自源目录标记，availability 来自阶段表。
public enum CatalogAvailability: Hashable, Sendable {
    case permanent                    // 非限时内容
    case seasonal(phaseID: String, isActive: Bool)  // 阶段配置命中
    case unconfigured                 // 无阶段信息（UI：「阶段信息未配置」）
}

// VillageItemState 新增（必填 init 参数，与 #83/#84 同策略）
public let availability: CatalogAvailability
```

关键决策（CoT）：
1. **seasonal 判定完全来自阶段表**——不从 specialAbility 推断（用户约束）；空表 → 全部 unconfigured。
2. **unconfigured 是默认态**：空表时所有 item availability = unconfigured；UI 只在详情页显示（低噪音）。
3. **clock 注入**：project 既有 `now` 参数（零新增注入点）；`activePhase` 用 now 判定——测试注入固定日期保证确定性。
4. **deprecated 不并入 availability**：独立维度可叠加（如"已废弃 + 阶段未配置"），UI 分开显示。
5. **阶段表注入方式**：`project(seasonalPhases: SeasonalPhaseTable = .empty)` 参数（默认空表，测试注入；GameCatalog 不携带——阶段表生命周期独立于目录，未来可独立更新）。
6. **itemKey 格式**：`"\(section):\(dataID)"`（与 CatalogItem.id / 投影查询键同格式，嵌套项同规则）。

## 4. UI 定稿（LevelDetailSheet）

availability 标记行（caption2，tertiary）：
- `.permanent` → 不显示
- `.seasonal(_, true)` → 「限时内容：\(phase.name ?? phaseID)（活动）」
- `.seasonal(_, false)` → 「限时内容：\(phase.name ?? phaseID)（已结束，仅历史数据）」
- `.unconfigured` → 「阶段信息未配置」

阶段名解析：project 注入表按 phaseID 反查 name（VillageItemState.availability 只带 phaseID + isActive，name 由 UI 从注入表查？——不，UI 无表。**设计修正**：availability case 携带 `phaseName: String?`（投影时从表解析），UI 零查表）。重新定义：

```swift
public enum CatalogAvailability: Hashable, Sendable {
    case permanent
    case seasonal(phaseID: String, phaseName: String?, isActive: Bool)
    case unconfigured
}
```

## 5. TDD 测试计划

1. `GameCatalogTests`（或新 SeasonalPhaseTableTests）：
   - 空表 load（缺失文件 → empty）
   - activePhase：命中/未命中/边界（from 含、until 不含）/多阶段取 from 最晚
   - loadBundled 解析合成 JSON（有/无阶段文件）
2. `VillageCatalogProjectionTests`：
   - 空表（默认）→ 全 unconfigured
   - 注入表命中 → seasonal(phaseID, name, isActive) 按注入 now 判定（活动/已结束）
   - now 确定性：同一输入不同 now → 不同 isActive 但确定（测试断言）
   - 聚合透传 availability（property-based：SeededRNG 随机 now/阶段 → 不变量）
   - deprecated + seasonal 叠加（独立维度）
3. UI 无测试先例（View 层）——文案经 Core 计算属性暴露可测？availability 的 label 逻辑抽 Core（`CatalogAvailability.displayLabel`）可测。

## 6. 风险与边界

- 不提交 seasonal_phases.json（空表 = 文件缺失 → empty）；PR 描述注明阶段表数据源待用户拍板
- 不从 specialAbility 推断（约束）；specialAbility 字段维持现状（CraftTableCatalog 不动）
- 列表行不加 availability 标记（噪音控制；详情页承担）
- 嵌套项：同 (section,dataID) 规则（空表恒 unconfigured，无行为影响）
- 阶段表 schemaVersion=1 预留迁移
- 不做 replacedByPhaseID（等数据源时按需加，避免 YAGNI）

## 7. 实现状态（2026-08-08 完成）

- ✅ `SeasonalPhase`/`SeasonalPhaseTable`（empty/activePhase 边界 from 含 until 不含/多阶段取 from 最晚/loadBundled 缺失→空表）
- ✅ `CatalogAvailability`（permanent/seasonal(phaseID, phaseName, isActive)/unconfigured）+ `displayLabel`（Core 可测；permanent nil 不显示）
- ✅ 投影：`VillageItemState.availability`（必填）+ project `seasonalPhases: SeasonalPhaseTable = .empty`（复用既有 now 注入）；map 开头计算（unavailable 分支也携带）；3 构造点
- ✅ BuildingGroupProjection records 调用补 `.empty`（组卡暂不消费阶段表）
- ✅ UI：LevelDetailSheet availability 标记行（tertiary caption；permanent 不显示）
- ✅ 测试 +11：阶段表（empty/命中/边界/多阶段/loadBundled 缺失）、availability label、投影（unconfigured 默认/活动/已结束/now 确定性/property 聚合 50 轮）
- ✅ 验证：pytest 573 + swift test 760 全绿，0 警告
- ⚠️ 踩坑：多步脚本断言失败不落盘（availability 字段/init 参数先插代码后补字段——编译错误定位）；availability 必须在 map 头计算（unavailable 分支先于 status 使用）
- ⚠️ 未做（用户约束）：不提交 seasonal_phases.json（数据源待拍板：官方公告→人工维护）；不从 specialAbility 推断；verified/mismatch 不动
