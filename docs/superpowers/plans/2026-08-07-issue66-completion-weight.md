# Issue #66 完成度统计按实例加权 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development 实现本计划。步骤用 checkbox（`- [ ]`）追踪。

**Goal:** 完成度相关统计（总完成度、分类完成度、分类 chip 数量、`isFullyMaxed`、"X / Y 已满级"）从"按聚合行数"改为"按实例数量加权"（`count ?? 1`），保留列表行级聚合与 ×N 展示。

**Bug 证据：** `VillageCatalogProjection.aggregate`（L414-480）已按 `(section, dataID, currentLevel, isNested, 根父)` 聚合非升级记录并写入 `count`；但 `VillageDetailProjection.completionStats`（L145-160）/`totalCompletion`（L163-175）对聚合后的行做 `.count`。6 门满级 + 1 门未满级 → 1/2（应为 6/7）；300 满级墙 + 25 未满级 → 1/2（应为 300/325）。

**Architecture:** 只改纯逻辑层 `VillageDetailProjection.swift`（核心加权 + saturated fail-closed）+ `VillageDetailView.swift`（chip 计数消费）。`BuildingGroupProjection` 已有 `×count ?? 1` 加权先例（L47-52），本 issue 拉齐该口径。**修订（P2 外部评审引入）：** 原边界 1「`aggregate()` 不动」已不适用——行级聚合保留，但 `VillageCatalogProjection.aggregate` 的 count 计算改为实例权重归一化 + 饱和求和（见「修订记录」）。

**Tech Stack:** Swift 6 / SwiftUI（macOS 14）/ XCTest（无第三方依赖，property-based 用仓库既有固定 seed SplitMix64 PRNG 模式）。

---

## 设计分析（CoT，3 候选投票）

### 决策 1：非法 count（0/负数）的权重语义

| 候选 | 方案 | 评 |
|---|---|---|
| **A（推荐）** | `weight = max(count ?? 1, 1)`：nil→1、≤0→1、>0→原值 | 与 `TrackerModels.countLabel`（L164 `count > 1` 才显示 ×N，≤1 按单条展示）口径一致；杜绝负权重（issue 边界 3） |
| B | 原样 `count ?? 1`（0 贡献 0、负数贡献负） | 与聚合层一致但 0/负数会制造 0/负权重，违反边界 3 |
| C | 非法 count 归入 unknown | 引入新"非法"语义，快照层无证据会产生 0/负数，过度设计 |

### 决策 2：字段命名 knownCount/completedCount/unknownCount

| 候选 | 方案 | 评 |
|---|---|---|
| **A（推荐）** | 保留字段名，doc comment 注明"实例权重"语义 | issue 允许保留；改名波及 UI + 全部测试，diff 膨胀 |
| B | 改名 knownWeight 等 | 语义更准但破坏面大，且 issue 明确"不要同时保留两套口径" |

### 决策 3：chip 计数的加权 API

| 候选 | 方案 | 评 |
|---|---|---|
| **A（推荐）** | `VillageDetailProjection` 提供加权求和 API，UI 与统计共用 | 单一加权口径（issue 边界 2），weight 逻辑不复制到 UI 层 |
| B | UI 层内联 `count ?? 1` 求和 | 两处口径，漂移风险 |

**最终实现（第 5 轮修订）：** 加权 API 收敛为 `internal static func instanceCount(of:)` 与溢出感知版 `instanceCountAndOverflow(of:) -> (count, didOverflow)`，仅供统计函数内部使用；UI 分类 chip 计数不直接调用，而是由 `completionStats` 的 `known + unknown` 派生（`chipInstanceCount`，饱和加法兜底，见 VillageDetailView）。`VillageItemState.instanceWeight`（internal，VillageCatalogProjection.swift）为权重契约单一来源，聚合层与统计层共用。

## 类型契约（最终语义，第 5 轮）

```swift
// VillageCatalogProjection.swift（权重单一来源）
/// 实例权重：count == nil → 1；count <= 0（malformed）→ 1（与 countLabel 展示口径一致）；
/// count > 0 → count。不得产生负权重（issue #66 边界 3）。
internal var instanceWeight: Int { ... }   // 聚合层 + 统计层共用
// aggregate 的 count：同键记录按 instanceWeight 归一化后求和，和溢出时饱和到 Int.max
//（P2 修订：原边界 1「aggregate() 不动」不适用——行级聚合保留，但 count 计算改
//  归一化 + 饱和，避免 debug SIGTRAP 崩溃 / release 负数回绕）。

// VillageDetailProjection.swift
/// 按实例权重求和；仅供统计函数内部使用（UI chip 计数经 completionStats 派生）。
internal static func instanceCount(of items: [VillageItemState]) -> Int
/// 溢出感知版：任一加法和溢出 → count 饱和到 Int.max 且 didOverflow == true；
/// 恰好等于 Int.max 无溢出则 false（精确）。饱和后继续加法恒溢出，didOverflow 恒 true。
internal static func instanceCountAndOverflow(of items: [VillageItemState]) -> (count: Int, didOverflow: Bool)

// completionStats / totalCompletion 签名不变：
public static func completionStats(from items: [VillageItemState], catalogIsUsable: Bool = true) -> [VillageCategoryCompletion]
// knownCount    = catalogIsUsable ? Σ weight(where isKnown)              : 0（独立饱和求和）
// completedCount = catalogIsUsable ? Σ weight(where maxed && isKnown)    : 0（独立饱和求和）
// unknownCount  = Σ weight(unknown 侧)（独立求和，不用减法推导——catalogIsUsable ==
//                false 时全量归 unknown，issue #16「全部归 unknown」；饱和数据下
//                未知实例不因减法推导而消失。正常数据下与减法等价）
// saturated     = 三列任一 didOverflow（catalogIsUsable == false 时 known/completed 为
//                (0, false)，unknown 照常求和）

public static func totalCompletion(from items: [VillageItemState], catalogIsUsable: Bool = true) -> VillageCategoryCompletion
// 同上，作用于全部 items。

// VillageCategoryCompletion
public let saturated: Bool   // init 默认 false——既有构造调用（含测试直接构造）零改动
// completionRatio / isFullyMaxed：saturated == true 时 fail-closed——
// ratio 返回 nil、isFullyMaxed 返回 false（饱和时数值不完整，不做权威判定；
// 宁可判否，不误判满级绿勾，issue #66 第 5 轮）。
```

```swift
// VillageDetailView.swift categoryFilterBar
// 4 处 chip 计数：groups.reduce(0){$0 + $1.items.count} → chipInstanceCount(statsByKey[...])
//（known + unknown 派生；独立饱和后相加可能溢出，chipInstanceCount 用饱和加法兜底）
// 筛选语义（按组键）不变，仅显示数字改为实例数。
```

## Tasks

- [ ] **Task 1（TDD）** Core 加权：`VillageDetailProjection.swift` 加 `weight`/`instanceCount`，`completionStats`/`totalCompletion` 改加权；`VillageDetailProjectionTests.swift` 先写失败用例（6/7、300/325、nil→1、≤0→1、升级+空闲不重复、加权守恒、isFullyMaxed 加权、目录不可用时按权重归 unknown），再实现。
- [ ] **Task 2** UI chip：`VillageDetailView.swift` 4 处计数改 `instanceCount`，doc comment 注明口径。
- [ ] **Task 3** Property-based + 全链路：`VillageDetailProjectionTests` 加固定 seed fuzz（守恒：known+unknown == Σweight；completed ≤ known；全 count=1 时与旧口径一致；满级权重全 maxed → isFullyMaxed）；`VillageCatalogProjectionTests` 加真实 `AccountSnapshot → project → totalCompletion` 链路用例（6/7 与 300/325）。
- [ ] **Task 4** 收尾：`swift test` 全绿 → 自查 → PR。

## 验收标准（issue #66）

- [ ] 6 满级 + 1 未满级 → 6/7（非 1/2）
- [ ] 300 满级 + 25 未满级 → 300/325
- [ ] `count == nil` 按 1
- [ ] 升级中单条 + 已聚合空闲并存不重复不丢失
- [ ] 分类完成度之和 == 总完成度（守恒）
- [ ] 未知/版本不匹配/缺失等级按实例权重计入未知；待重新导入（needsReimport）按实例权重计入分母（known）但不计完成（快照等级即满级时才按满级计，真实导出为升级前旧等级不会误判）；isKnown 语义保持不变（issue #16 契约）
- [ ] UI 保留单行 ×N，分母改为实例数
- [ ] 投影层 + UI 消费侧（全链路）回归测试
- [ ] `swift test` 通过

## 非目标

- 不动 `aggregate()` 的**行级聚合**（×N 展示保留）；~~完全不动 aggregate~~ —— count 计算已由 P2 修订为归一化 + 饱和（见「修订记录」）
- 不引入库存/工人占用/排程；不假设未观测项目为 0 级；不合并"当前满级"与"全局最终上限"
- 不改 chip 筛选逻辑，只改显示数字

## 修订记录

| 时间 | 修订 | 内容 |
|---|---|---|
| 033bccf | 初始实施 + 审核补测 | 加权统计落地、饱和加法、`unknownCount` 独立求和（弃减法推导）、isFullyMaxed 严格谓词、fuzz 补测 |
| 1b28686 | P2 修复（外部评审） | `VillageCatalogProjection.aggregate` count 改为 instanceWeight 归一化 + 饱和求和（原边界 1「不动 aggregate()」不适用：行级聚合保留，仅 count 计算修订）；统计层与聚合层共用饱和语义 |
| 本 commit | 第 5 轮修复（saturated fail-closed） | 饱和（任一列溢出）时 `VillageCategoryCompletion.saturated == true`，`isFullyMaxed`/`completionRatio` 不做权威判定（ratio nil、满级 false，宁可判否不误判绿勾）；新增 `instanceCountAndOverflow(of:)` 供统计函数上报溢出；新增 `testMixedSaturationNeverFullyMaxed`、`testSaturationAllMaxedFailsClosed`（原 `...StillFullyMaxed` 改名） |
