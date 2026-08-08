# Issue #74（74b + deprecated provenance）实施设计

日期：2026-08-07
分支：codex/issue-74-duration-semantics
依据：Issue #74 评审定稿（未拆分 #74 = 需先澄清；74b 与 deprecated provenance = 可立即实施；74a/seasonal = 待数据源契约）

## 1. 范围

- **74b 时长语义**：把 `durationSeconds: Int64?` + `missingReason` 字符串抽象为可区分状态，覆盖 Python counts 拆分、Swift 核心模型、投影层、3 个 UI 消费方（LevelDetailSheet / UpgradeDisplayRow / BuildingGroupSummaryView）。
- **deprecated provenance**：Swift `CatalogItem` 补 `missingReason` 字段，保留 `deprecated_in_source`（37 item / 132 level）来源信息，不再静默丢弃。
- **不做**：74a（兼容性状态/玩家 build——数据源未定）、seasonal 生命周期（阶段日期数据源未定）、#70/#73 消费方。

## 2. 现状证据（已核实）

| 层 | 现状 | 位置 |
|---|---|---|
| Python 生成 | `durationSeconds is None` 时 reason 已区分：`time_missing`(1847) / `no_time_source`(1032) / `min_level_initial_no_upgrade`(429) / `time_invalid` / `upgrade_data_missing` | builders.py L75/L127/L302、durations.py L41/L49 |
| Python counts | `missingTime` 合并全部 nil（3308），不拆分 | catalog.py L116、validate.py L212 |
| Swift 模型 | `CatalogLevel.missingReason: String?` 已存在；**`CatalogItem` 无 `missingReason`** → deprecated 信息解码时静默丢弃 | GameCatalog.swift |
| Swift 投影 | `VillageItemState.nextLevelDurationSeconds: Int64?` 无伴随状态 | VillageCatalogProjection.swift L475-493 |
| Swift 组卡 | `BuildingUpgradeStep.durationSeconds: Int64?` 无 reason 透传 | BuildingGroupProjection.swift L174-179 |
| UI | 三处 nil → "暂无目录数据"（装备/初始等级误导） | LevelDetailSheet.swift L79、UpgradeDisplayRow.swift L104、BuildingGroupSummaryView.swift L75 |

## 3. 设计决策（CoT 分析）

### 3.1 duration-state 语义分类（唯一事实源）

```
durationSeconds != nil:
    > 0   → timed(seconds)
    == 0  → instant            # 0 秒是真实即时升级，不得归为缺失（既有 UI 已处理）
durationSeconds == nil:
    missingReason == "min_level_initial_no_upgrade" → initialLevel   # 语义确定：起点等级无升级
    missingReason == "no_time_source"               → notApplicable  # 源表无时间列；展示为中性「类别无时长数据」，
                                                                     # 不得宣称「游戏内无需升级时间」（评审定稿：
                                                                     # 无游戏语义证据不得伪造语义）
    missingReason == "time_invalid"                 → parseFailed
    missingReason == "time_missing" | "upgrade_data_missing" → sourceMissing
    missingReason == nil                            → 未知（UI 回退「暂无目录数据」）
    其他 unknown reason                              → unknownReason(reason)（防御，不改值域契约）
```

关键决策：`no_time_source` 映射为 `notApplicable` **仅表示数据源层面无时长数据**，UI 文案中性化，不宣称游戏语义（评审定稿明确）。

### 3.2 counts 拆分（manifest，向后兼容）

新增可选字段（旧 manifest 缺失不报错，validate 只在存在时校验一致性）：

```json
"counts": {
  "items": 683, "levels": 5479,
  "missingTime": 3308,          // 保留，兼容统计（= 全部 durationSeconds is None）
  "timed": ..., "instant": ..., // 有值等级拆分
  "notApplicable": 1032, "initialLevel": 429,
  "sourceMissing": ..., "parseFailed": ...
}
```

一致性不变量：`timed + instant + missingTime == levels`；`notApplicable + initialLevel + sourceMissing + parseFailed + unknown == missingTime`（unknown = nil reason 的 nil duration，当前为 0，但仍计入校验）。

### 3.3 Swift 类型契约

```swift
public enum CatalogDurationState: Hashable, Sendable {
    case timed(seconds: Int64)
    case instant
    case initialLevel
    case notApplicable
    case sourceMissing
    case parseFailed
    case unknownReason(String)
}

extension CatalogLevel {
    /// missingReason + durationSeconds → 可区分状态（单一映射点，UI/投影共用防漂移）
    public var durationState: CatalogDurationState? { ... }
}

extension CatalogDurationState {
    /// 展示文案（无 prefix；prefix 由 UI 上下文拼接）。Core 层可测。
    public var durationLabel: String { ... }
}

public struct CatalogCounts: Codable, Hashable, Sendable {
    public let items: Int
    public let levels: Int
    public let missingIcons: Int?
    public let missingTime: Int?
    public let timed: Int?          // 新增，可选
    public let instant: Int?        // 新增，可选
    public let notApplicable: Int?  // 新增，可选
    public let initialLevel: Int?   // 新增，可选
    public let sourceMissing: Int?  // 新增，可选
    public let parseFailed: Int?    // 新增，可选
}

public struct CatalogItem: Codable, ... {
    // 新增：deprecated_in_source 等来源信息（缺键 → nil，向后兼容）
    public let missingReason: String?
}

public struct VillageItemState: ... {
    // 新增：nextLevelDurationSeconds 的伴随状态；nil = 无目录/未命中/超范围/满级
    public let nextLevelDurationState: CatalogDurationState?
}

public struct BuildingUpgradeStep: ... {
    // 新增：阶梯单元格透传目录缺失原因
    public let missingReason: String?
}
```

### 3.4 UI 文案

- `LevelDetailSheet.durationLabel(level)`：改用 `level.durationState?.durationLabel`，nil → "暂无目录数据"
- `UpgradeDisplayRow.durationLabel`：maxed 分支保留；`item.nextLevelDurationState` 非 nil 时用 `durationLabel` + 既有 prefix（"完整时长："/"下一级：N级 · 完整时长："）；nil → "暂无目录数据"
- `BuildingGroupSummaryView.totalDurationLabel`：新增分支——steps 非空且全部 `durationSeconds == nil` → "目录无时长数据"；其余保持现有语义

文案候选（投票点）：见第 4 节。

## 4. 3 候选方案（投票）

投票结果（3 个独立 agent 并行评审）：**方案 A 以 3:0 胜出**。B 的评审结论实际是"A 的变体"（反对 UI 各自 switch，建议 Core 单点枚举）；C 有条件支持但 prefix 拼接与文案耦合风险更高。

### 方案 A（选定）：Core 枚举 + 计算属性 + 投影透传
如上 3.3。单一映射点、类型安全、3 消费方共用、Core 可测。

**投票修正（全部采纳）**：
1. **单一查表**：`GameCatalog` 新增 `catalogLevel(toUpgrade:for:) -> CatalogLevel?` 返回完整等级记录（含 reason），投影层从同一记录同时取 `durationSeconds` 与 `durationState`，杜绝双查表漂移；`durationToUpgradeLevel` 保留兼容（内部复用新 API）
2. **`VillageItemState` init 新参数必填**（3 处调用点同步改，防漏传静默降级为旧行为）
3. **Python `classify_duration` 共用函数**：放 `durations.py`，`catalog.py` 与 `validate.py` 共用，不双实现
4. **UpgradeDisplayRow prefix 规则**：缺失类（initialLevel/notApplicable/sourceMissing/parseFailed/unknownReason/nil）**不带** "完整时长："/"下一级：N级 · 完整时长：" 前缀，直接显示 reason 文案；timed/instant 保留 prefix（修复"下一级：Lv N · 完整时长：目录缺失"怪句）
5. **组卡规则（确定性，无需优先级排序）**：steps 非空且全部 `durationSeconds == nil` → "目录无时长数据"；其余保持现有语义（partialMissing 时 seconds > 0 走数值分支）
6. nil（无 reason）与 `.unknownReason` 语义区分：nil = 无目录记录/未命中（UI 兜底"暂无目录数据"）；unknownReason = 目录记录存在但 reason 未知（防御，同样兜底文案，doc 注明）

### 方案 B：投影层透传 missingReason 字符串，UI 各自 switch
- 反对理由：分类逻辑 3 处复制必漂移；字符串魔数；label 无法 Core 单测。评审结论支持"Core 单点枚举"，即 A。

### 方案 C：Core 直接产出中文文案字符串透传
- 反对理由（有条件支持）：prefix 拼接"下一级：Lv N · 完整时长："+缺失文案成怪句，零分支不成立；文案与语义耦合在数据层；BuildingUpgradeStep 无 reason 无法归因。

## 5. TDD 测试计划

### Python（Tools/tests）
1. `test_durations.py` 或新增 `test_duration_classify.py`：classify 函数全分支（timed/instant/initialLevel/notApplicable/sourceMissing/parseFailed/nil reason/未知 reason）
2. `test_catalog.py`：合成 items 生成 manifest counts 拆分正确性 + 不变量（sum 一致性）
3. `test_validate.py`：新字段重算一致、旧 manifest 无新字段不报错、未知 reason 不落入任何桶、sum 不变量校验
4. `test_render_generator.py`：既有 counts fixture 兼容性（新字段可选）

### Swift（Tests/COCHelperCoreTests）
1. `GameCatalogTests`：`durationState` 全 reason 映射（6 类 + nil + 0 秒 + >0 + 未知 reason）；`CatalogItem.missingReason` 解码（有/无字段）；`CatalogCounts` 新字段解码（有/无字段，旧 JSON 兼容）；`durationLabel` 文案
2. `VillageCatalogProjectionTests`：`nextLevelDurationState` 透传——升级中（有值/缺失 reason）、非升级（真实下一级有值/缺失）、满级/未命中/版本不匹配 → nil
3. `BuildingGroupProjectionTests`：`BuildingUpgradeStep.missingReason` 透传；组卡 summary 语义不变

## 6. 风险与边界

- **不做**：74a 兼容性状态、seasonal 生命周期、UI 重构、manifest 运行时读取
- JSON 向后兼容：所有新增 Swift 字段 optional / 缺键 nil；Python manifest 新 counts 字段可选
- `nextLevelDurationSeconds` 与 `nextLevelDurationState` 一致性：state.timed(seconds) 必须与字段相等（测试断言）
- 不修改 LEVEL_MISSING_REASONS 值域契约（未知 reason 走 unknownReason 防御，不新增 reason）
- 组卡聚合语义不变（partialMissing/versionMismatch 分支不动）

## 7. 实现状态（2026-08-07 完成）

- ✅ 投票：方案 A 3:0 胜出，修正 1-6 全部采纳
- ✅ Python：`classify_duration`（durations.py）、`counts_for`（catalog.py，validate 共用）、
  validate 新字段校验 + sum 不变量哨兵；tests +9
- ✅ Swift：`CatalogDurationState` + `CatalogLevel.durationState` + `durationLabel`；
  `CatalogItem.missingReason`（deprecated provenance，显式 init 保兼容）；
  `CatalogCounts` 6 个可选新字段；`GameCatalog.catalogLevel(toUpgrade:for:)` 单一查表；
  `VillageItemState.nextLevelDurationState`（3 处构造点显式传）；
  `BuildingUpgradeStep.missingReason` 透传；3 个 UI 消费方（LevelDetailSheet /
  UpgradeDisplayRow prefix 规则 / BuildingGroupSummaryView 全部缺失分支）；tests +10
- ✅ 验证：`pytest -q Tools/tests` 572 passed；`swift test` 733 passed；无编译警告
- ✅ 交叉审核修复（PR #83 两独立 reviewer）：`VillageItemState.init` 恢复必填
  （交叉审核 N1：plan 定稿「必填」被默认值静默偏离——8 处测试构造点已补参）；
  Swift 负数/契约外 reason 映射级测试补全；MARK 段缩进 4 格；doc 补防御场景；
  UpgradeDisplayRow 遗留矛盾注释修正
- ⚠️ 踩坑记录：Swift 合成 memberwise init 对「let 带默认值」的字段显式传参会报
  "extra argument"（Swift 6.3）→ 必须写显式 init（`CatalogItem`/`BuildingUpgradeStep`）；
  `CatalogItem` 参数顺序为 (section, category, dataID)（label 顺序敏感，测试锚定）
