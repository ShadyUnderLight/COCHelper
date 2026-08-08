# Issue #70 三指标拆分（阶段 1）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把村庄详情页单一"完成度"拆成三个显式指标（当前阶段进度 / 全局养成进度 / 观测数据完整性），带 ready/partial/unavailable/unknown 状态、分子/分母、降级文案。

**Architecture:** Core 层新增 `VillageProgressMetrics.swift`（纯函数投影，输入与 `VillageDetailProjection.totalCompletion` 同口径的 trackedItems）；UI 层 `VillageDetailView.completionBar` 替换为三指标卡。保留 `VillageCategoryCompletion`（筛选 chip 的 `isFullyMaxed` 契约不动）。

**Tech Stack:** Swift 6 / SwiftUI / XCTest（零第三方依赖，property 测试用文件内 LCG）。

**前置基线（已验证）**：worktree `.worktrees/issue70`（分支 `codex/issue-70-completion-metrics`，基于 main `80b40d3`），`swift test` 795 全绿。

---

## 设计分析（CoT）与 3 候选投票

### 决策 1：指标公式风格

| 候选 | 公式 | 优劣 |
|---|---|---|
| A 等级式（推荐） | `Σmin(level, cap) / Σcap`，cap = currentStageMaxLevel 或 maxLevel | 连续表达"养成进度"（半途实例也贡献）；与 issue 第 2 条"比较当前等级与静态目录上限"字面一致；公式统一可测 |
| B 计数式 | `maxed 实例 / known 实例` | 与现有 completed/known 同构；但"6/7 已满级"正是 #70 要消除的误导（离散、半途实例贡献为 0） |
| C 混合 | stage 计数式 + global 等级式 | 语义最细但两套公式、测试面翻倍，YAGNI |

**投票：A。** `currentStageProgress`/`globalProgress` 都用等级式（仅 cap 不同），公式同一实现参数化。

### 决策 2：unverified 目录（CatalogCompatibility）映射

`catalogIsUsable` 在 `.unverified` 时仍为 true（#74a 契约），旧完成度在未验证目录下继续可用——正是 #70 要修的点。

| 候选 | 映射 | 优劣 |
|---|---|---|
| A partial（推荐） | 可计算，但 state 强制降为 partial + degradedReason"目录与玩家版本未验证" | 数据真实存在，只是精度未验证；UI 必须显示降级提示，永不伪装 ready |
| B unavailable | 完全不可计算 | 过强：无玩家 build 是默认路径，等于永久不可用 |
| C unknown | 归入无数据 | 语义错误：有数据 |

**投票：A。** 显式映射：`compatibility == .unverified && 指标可计算 → state = .partial`。

### 决策 3：目录不可用 / 版本不匹配（catalogIsUsable == false）

| 候选 | 映射 | 优劣 |
|---|---|---|
| A 三指标全 unavailable（推荐） | 统一 fail-closed，UI 显示"目录不可用，暂无法计算指标" | 符合 #70 验收 4"不显示看似权威的百分比"；最小惊讶 |
| B 仅进度指标 unavailable，coverage 显示 0% | 覆盖率与目录无关 | 0% 会被误读为"没观测"而非"没目录"，仍误导 |

**投票：A。**

### 决策 4：snapshotCoverage 分母

| 候选 | 分母 | 优劣 |
|---|---|---|
| A 追踪类别观测实例（推荐） | `Σweight(items)`（调用方已过滤 .unavailable，与 UI 现状一致） | decos/obstacles 不稀释；与 `trackedItems` 口径一致 |
| B 全部观测含 unavailable | 含不参与追踪项 | 覆盖率被无关类别稀释 |
| C 仅 known+unknown | 等价于 A | —— |

**投票：A。** 命名锁定为「观测数据完整性」：分子 = 已关联目录实例（known），分母 = 追踪类别观测实例。不做 `.available`（目录有快照无）枚举——投影层不产出，阶段 1 明确不声称"完整覆盖率"。

### 决策 5：partial 判定（每指标独立）

- `unknownWeight > 0`（非 known 的实例权重）→ partial（该指标有缺失输入）；
- `compatibility == .unverified` 且可计算 → partial（决策 2）；
- currentStage 额外：known 但 `currentStageMaxLevel` 缺失（nil 或 ≤0）的实例计入阶段专用缺失权重 → partial（最终实现修订：升级中项可能 stageMax == nil——投影 isUpgrading 分支先于 stageMax 检查，真实可达；「known ⇒ stageMax 非 nil」只对非升级项成立；恶意目录 ≤0 cap 同样归缺失侧，不静默 0 贡献）。

### 决策 6：饱和（继承 #66 fail-closed）

分子/分母各自 `addingReportingOverflow` 饱和求和；任一饱和 → `saturated = true` → `ratio = nil`，UI 显示"数据异常（超出可表示范围）"。状态判定不受饱和影响（值本身不权威由 ratio 层拦截）。

---

## 类型契约（SDD 产物）

```swift
// Sources/COCHelperCore/VillageProgressMetrics.swift（新文件）

/// 指标可计算状态（issue #70 契约）。
public enum ProgressMetricState: String, Hashable, Sendable, CaseIterable {
    /// 分母完整、无缺失输入、目录已验证：可直接展示百分比。
    case ready
    /// 可计算但输入部分缺失（未知项/目录未验证）：展示百分比 + 降级说明。
    case partial
    /// 不可计算：目录不可用或版本不匹配（fail-closed，禁止假精度）。
    case unavailable
    /// 无数据：无快照或无可计算实例（分母为 0）。
    case unknown
}

/// 单个指标的展示模型。
public struct ProgressMetric: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// 当前阶段进度：等级和 / 当前阶段上限和（cap = currentStageMaxLevel）。
        case currentStageProgress
        /// 全局养成进度：等级和 / 目录全局上限和（cap = maxLevel）。
        case globalProgress
        /// 观测数据完整性：已关联目录实例数 / 追踪类别观测实例数。
        case snapshotCoverage
    }

    public let kind: Kind
    /// 分子（实例加权，饱和求和）。
    public let numerator: Int
    /// 分母（实例加权，饱和求和）。
    public let denominator: Int
    public let state: ProgressMetricState
    /// 任一求和饱和（issue #66 fail-closed）：ratio 恒 nil，UI 显示异常。
    public let saturated: Bool
    /// 分子/分母的展示单位（"级"/"实例"）。
    public let units: String
    /// 降级原因（ready 时 nil）。
    public let degradedReason: String?

    public var id: String { kind.rawValue }

    /// 展示比例；saturated、分母 ≤ 0、state 不可计算（unavailable/unknown）时 nil。
    public var ratio: Double? {
        guard !saturated, denominator > 0, state == .ready || state == .partial else { return nil }
        return Double(numerator) / Double(denominator)
    }

    public init(
        kind: Kind,
        numerator: Int,
        denominator: Int,
        state: ProgressMetricState,
        saturated: Bool = false,
        units: String,
        degradedReason: String? = nil
    )
}

/// 一个村庄、一个基地的三指标聚合（issue #70）。
public struct VillageProgressMetrics: Hashable, Sendable {
    public let currentStageProgress: ProgressMetric
    public let globalProgress: ProgressMetric
    public let snapshotCoverage: ProgressMetric
}

public enum VillageProgressProjection {
    /// 核心入口。输入口径与 `VillageDetailProjection.totalCompletion` 一致
    /// （调用方已过滤 status == .unavailable 的 trackedItems）。
    ///
    /// `catalogIsUsable == false` → 三指标全部 unavailable（决策 3，fail-closed）。
    /// `compatibility == .unverified` → 可计算指标强制 partial + 降级原因（决策 2）。
    public static func metrics(
        from items: [VillageItemState],
        catalogIsUsable: Bool,
        compatibility: CatalogCompatibility?   // 必传（评审要求：防漏传静默 ready，生产恒 unverified）
    ) -> VillageProgressMetrics
}
```

内部实现要点（`VillageProgressProjection`，与最终实现一致）：

- `weightedCappedSum(_ items: [VillageItemState], value: (VillageItemState) -> Int) -> (value: Int, saturated: Bool)`：对每项 `value(item) × instanceWeight`（`multipliedReportingOverflow`，溢出置位）后饱和求和，聚合行 `countOverflowed` 标志补位上报——等级式公式的实例加权（count=6 的 3 级建筑贡献 6×3）。原计划的 `sumCapped` 未单独落地：饱和逻辑已并入 weightedCappedSum，覆盖率计数直接复用 `instanceCountAndOverflow`。
- 未知权重与覆盖率计数复用现成 internal `VillageDetailProjection.instanceCountAndOverflow(of:)`（返回 `(count, didOverflow)`，含 countOverflowed 并入），不重复实现。
- 小口径谓词 `isKnown`：`VillageDetailProjection.isKnown` 已由 private 改为 **internal**（评审要求单一来源防漂移），本投影直接调用，无逐字复制。
- known 过滤：`items.filter { VillageDetailProjection.isKnown($0) && !$0.needsReimport }`——计时结束待重新导入项等级为最后记录值，归未知侧降级（实现要求 4）。
- currentStageProgress：
  - `eligible = known.filter { ($0.currentStageMaxLevel ?? 0) > 0 }`；`stageMissingWeightInfo = Σ weight(known.filter { ($0.currentStageMaxLevel ?? 0) <= 0 })`（nil 与 ≤0 恶意 cap 统一归缺失侧 → partial 降级，不静默丢分母）
  - denominator = Σ max(0, currentStageMaxLevel)；numerator = Σ min(max(0, currentLevel), max(0, currentStageMaxLevel))（cap 先 max(0,·) 钳制，恶意负 cap 不产生负贡献）
  - unknownWeight = Σ weight(items.filter { !isKnown($0) || needsReimport }（独立求和，饱和不丢失）
  - state：`catalogIsUsable == false` → unavailable；denominator == 0 → unknown（extraReason 拼接保留成因说明）；unknownWeight > 0 或 stage 缺失权重 > 0 或决策 2（unverified）→ partial；否则 ready
- globalProgress：同上，cap = maxLevel（isKnown 保证非 nil），units = "级"
- snapshotCoverage：denominator = Σ weight(items)（全部 trackedItems）；numerator = Σ weight(items.filter { isKnown($0) })；state：catalogIsUsable false → unavailable；denominator == 0（空 items）→ unknown；numerator < denominator（未知实例存在）→ partial；否则决策 2 → ready；units = "实例"
- degradedReason 文案（中文，与项目术语一致）：
  - unavailable："目录不可用或版本不匹配，暂无法计算该指标。"
  - unknown（stage/global 分母 0）："无可确认项目，暂无法计算。"
  - unknown（coverage 分母 0）："尚未导入快照。"
  - partial（unknownWeight > 0）："N 项未知或待重新导入，结果仅为已观测项目。"（N 用 unknownWeight 插值；needsReimport 项计入 unknownWeight）
  - partial（stage 缺失权重 > 0）："N 项缺少阶段上限，未计入阶段进度。"
  - partial（unverified 目录）："目录与玩家版本未验证，百分比可能过时。"
  - partial 两条并存时拼接（"、"，unverified 文案优先在前）。

### 不变量（测试即契约）

- 正常数据（无饱和）下 currentStage 与 global 的 eligible 集合相同（都是 known 项）。
- **per-instance** 恒有 `currentStageRatio ≥ globalRatio`（stageMax ≤ maxLevel 时 f(x)=min(l,x)/x 非增）；**聚合层面不成立**（Σa/Σb ≥ Σc/Σd 不保序，反例：item1(level 50, stageMax 10, maxLevel 100) + item2(level 20, stageMax 100, maxLevel 100) → stage 30/110 < global 70/200，该形态真实可达：level ≥ stageMax 判 .maxed）。property 断言只在「全部 level ≤ stageMax」的专门生成器下做。
- `0 ≤ ratio ≤ 1`（min 封顶 + 分母为正）。
- 饱和时 `saturated = true ⇒ ratio = nil`（饱和不改变 state，UI 层饱和优先）。
- 无饱和时 `knownWeight + unknownWeight == Σweight`（守恒）。
- 饱和（count == Int.max）不崩溃、saturated = true。

---

## Task 1：VillageProgressMetrics.swift 类型与指标计算

**Files:**
- Create: `Sources/COCHelperCore/VillageProgressMetrics.swift`
- Test: `Tests/COCHelperCoreTests/VillageProgressMetricsTests.swift`

- [ ] **Step 1: 写失败测试**（新建 `VillageProgressMetricsTests.swift`，测试先于实现）

```swift
import XCTest
@testable import COCHelperCore

/// Issue #70：三指标（当前阶段进度/全局养成进度/观测数据完整性）。
final class VillageProgressMetricsTests: XCTestCase {
    // MARK: - Helpers（与 VillageDetailProjectionTests 同构）

    private func item(
        id: String = "id",
        status: VillageItemStatus = .complete,
        level: Int? = 3,
        maxLevel: Int? = 10,
        stageMax: Int? = 6,
        count: Int? = 1,
        isUpgrading: Bool = false,
        nextLevel: Int? = nil
    ) -> VillageItemState {
        let effectiveNext = nextLevel ?? (isUpgrading ? level.map { $0 + 1 } : nil)
        return VillageItemState(
            id: id,
            section: "buildings",
            dataID: 1,
            base: .home,
            name: "item-" + id,
            category: .buildings,
            currentLevel: level,
            count: count,
            timerSeconds: isUpgrading ? 3600 : nil,
            remainingSeconds: isUpgrading ? 1800 : nil,
            nextLevel: effectiveNext,
            nextLevelDurationSeconds: isUpgrading ? 3600 : nil,
            nextLevelDurationState: isUpgrading ? .timed(seconds: 3600) : nil,
            maxLevel: maxLevel,
            currentStageMaxLevel: stageMax,
            status: status,
            missingReason: nil,
            catalogItemMissingReason: nil,
            availability: .unconfigured,
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: false,
            displayCategory: nil
        )
    }

    private func metrics(_ items: [VillageItemState],
                         usable: Bool = true,
                         compatibility: CatalogCompatibility? = nil) -> VillageProgressMetrics {
        VillageProgressProjection.metrics(from: items, catalogIsUsable: usable, compatibility: compatibility)
    }

    // MARK: - currentStageProgress

    func testStageProgressReadyComputesLevelRatio() {
        // 2 个实例：level 3/6、level 5/6 → (3+5)/(6+6) = 8/12
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6),
        ]
        let m = metrics(items).currentStageProgress
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.numerator, 8)
        XCTAssertEqual(m.denominator, 12)
        XCTAssertEqual(m.ratio, 8.0 / 12.0, accuracy: 1e-9)
        XCTAssertNil(m.degradedReason)
        XCTAssertEqual(m.units, "级")
    }

    func testStageProgressCapsLevelAtStageMax() {
        // level 8 > stageMax 6 → 分子贡献 min(8,6)=6（封顶）
        let m = metrics([item(id: "a", level: 8, maxLevel: 10, stageMax: 6)]).currentStageProgress
        XCTAssertEqual(m.numerator, 6)
        XCTAssertEqual(m.denominator, 6)
        XCTAssertEqual(m.ratio, 1.0)
    }

    func testStageProgressPartialWhenUnknownExists() {
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "u", status: .unknown, level: nil, maxLevel: nil, stageMax: nil),
        ]
        let m = metrics(items).currentStageProgress
        XCTAssertEqual(m.state, .partial)
        XCTAssertEqual(m.numerator, 3)
        XCTAssertEqual(m.denominator, 6)
        XCTAssertEqual(m.ratio, 0.5)
        XCTAssertNotNil(m.degradedReason)
    }

    func testStageProgressExcludesUnverifiedFromDenominator() {
        // unverified 项不计入 known（#67 fail-closed）→ 分母只有 known 项
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "v", status: .unverified, level: 4, maxLevel: 10, stageMax: nil),
        ]
        let m = metrics(items).currentStageProgress
        XCTAssertEqual(m.denominator, 6)
        XCTAssertEqual(m.state, .partial) // unverified 归未知侧 → partial
    }

    func testStageProgressUnavailableWhenCatalogNotUsable() {
        let m = metrics([item(id: "a", level: 3, maxLevel: 10, stageMax: 6)], usable: false)
        XCTAssertEqual(m.currentStageProgress.state, .unavailable)
        XCTAssertNil(m.currentStageProgress.ratio)
        XCTAssertEqual(m.globalProgress.state, .unavailable)
        XCTAssertEqual(m.snapshotCoverage.state, .unavailable)
    }

    func testStageProgressUnknownWhenNoEligible() {
        let m = metrics([item(id: "u", status: .unknown, level: nil, maxLevel: nil, stageMax: nil)])
        XCTAssertEqual(m.currentStageProgress.state, .unknown)
        XCTAssertNil(m.currentStageProgress.ratio)
    }

    func testEmptyItemsAllUnknown() {
        let m = metrics([])
        XCTAssertEqual(m.currentStageProgress.state, .unknown)
        XCTAssertEqual(m.globalProgress.state, .unknown)
        XCTAssertEqual(m.snapshotCoverage.state, .unknown)
    }

    // MARK: - globalProgress

    func testGlobalProgressReady() {
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6),
        ]
        let m = metrics(items).globalProgress
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.numerator, 8)
        XCTAssertEqual(m.denominator, 20)
        XCTAssertEqual(m.ratio, 0.4)
    }

    func testGlobalProgressCapsLevelAtMaxLevel() {
        // 版本不匹配遗留：level 12 > maxLevel 10（非 upgrading 时 isKnown 放行）→ 封顶
        let m = metrics([item(id: "a", level: 12, maxLevel: 10, stageMax: 6)]).globalProgress
        XCTAssertEqual(m.numerator, 10)
        XCTAssertEqual(m.denominator, 10)
        XCTAssertEqual(m.ratio, 1.0)
    }

    func testStageRatioIsAtLeastGlobalRatio() {
        // 同一实例 stageRatio ≥ globalRatio（stageMax ≤ maxLevel）
        for (level, stageMax, maxLevel) in [(3, 6, 10), (6, 6, 10), (9, 6, 10), (12, 6, 10)] {
            let items = [item(id: "a", level: level, maxLevel: maxLevel, stageMax: stageMax)]
            let m = metrics(items)
            let stage = m.currentStageProgress.ratio!
            let global = m.globalProgress.ratio!
            XCTAssertGreaterThanOrEqual(stage, global, "level=\(level) stageMax=\(stageMax) maxLevel=\(maxLevel)")
        }
    }

    // MARK: - snapshotCoverage

    func testCoverageCountsKnownOverObserved() {
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),          // known
            item(id: "u", status: .unknown, level: nil, maxLevel: nil, stageMax: nil), // unknown
        ]
        let m = metrics(items).snapshotCoverage
        XCTAssertEqual(m.state, .partial)
        XCTAssertEqual(m.numerator, 1)
        XCTAssertEqual(m.denominator, 2)
        XCTAssertEqual(m.ratio, 0.5)
        XCTAssertEqual(m.units, "实例")
    }

    func testCoverageReadyWhenAllKnown() {
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6),
        ]
        let m = metrics(items).snapshotCoverage
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.numerator, 2)
        XCTAssertEqual(m.denominator, 2)
        XCTAssertEqual(m.ratio, 1.0)
    }

    // MARK: - 实例权重（#66）

    func testMetricsUseInstanceWeight() {
        // count = 6 → 权重 6
        let items = [item(id: "a", level: 3, maxLevel: 10, stageMax: 6, count: 6)]
        let m = metrics(items)
        XCTAssertEqual(m.currentStageProgress.denominator, 36)  // 6 × 6
        XCTAssertEqual(m.currentStageProgress.numerator, 18)   // 3 × 6
        XCTAssertEqual(m.snapshotCoverage.numerator, 6)
        XCTAssertEqual(m.snapshotCoverage.denominator, 6)
    }

    // MARK: - unverified 目录（决策 2）

    func testUnverifiedCatalogDegradesToPartial() {
        let items = [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)]
        let m = metrics(items, compatibility: .unverified(gameVersion: "18.400.13"))
        XCTAssertEqual(m.currentStageProgress.state, .partial)
        XCTAssertEqual(m.globalProgress.state, .partial)
        XCTAssertEqual(m.snapshotCoverage.state, .partial)
        XCTAssertNotNil(m.currentStageProgress.degradedReason)
        XCTAssertEqual(m.currentStageProgress.ratio, 0.5)
    }

    func testVerifiedCatalogKeepsReady() {
        let items = [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)]
        let m = metrics(items, compatibility: .verified(gameVersion: "18.400.13"))
        XCTAssertEqual(m.currentStageProgress.state, .ready)
    }

    // MARK: - 饱和（#66 fail-closed）

    func testSaturatedFailsClosed() {
        let items = [item(id: "a", level: 3, maxLevel: 10, stageMax: 6, count: Int.max)]
        let m = metrics(items)
        XCTAssertTrue(m.currentStageProgress.saturated)
        XCTAssertNil(m.currentStageProgress.ratio)
        XCTAssertTrue(m.snapshotCoverage.saturated)
    }

    func testSaturatedDoesNotCrash() {
        // 两条 Int.max 相加溢出 → 饱和不崩溃
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6, count: Int.max),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6, count: Int.max),
        ]
        let m = metrics(items)
        XCTAssertTrue(m.currentStageProgress.saturated)
        XCTAssertTrue(m.globalProgress.saturated)
        XCTAssertTrue(m.snapshotCoverage.saturated)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**（预期编译失败——类型不存在）

Run: `swift test --filter VillageProgressMetricsTests`
Expected: 编译错误 "cannot find 'VillageProgressMetrics' in scope"

- [ ] **Step 3: 实现 `VillageProgressMetrics.swift`**（完整代码见下节"实现全量代码"）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter VillageProgressMetricsTests`
Expected: 全部 PASS（约 19 个）

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperCore/VillageProgressMetrics.swift Tests/COCHelperCoreTests/VillageProgressMetricsTests.swift
git commit -m "feat(core): 三指标模型与计算（当前阶段/全局养成/观测完整性）(Issue #70)"
```

---

## Task 2：property-based 测试

**Files:**
- Test: `Tests/COCHelperCoreTests/VillageProgressMetricsPropertyTests.swift`

- [ ] **Step 1: 写 property 测试**（新文件；`SeededGenerator` 是 CoAPIPropertyTests 文件内 **internal** 类型，同 target 直接可见，**不要复制**——复制会同名重定义编译错误）

```swift
import XCTest
@testable import COCHelperCore

/// Issue #70：三指标 property 测试（守恒/边界/状态完备）。
final class VillageProgressMetricsPropertyTests: XCTestCase {
    // MARK: - 随机 item 生成

    /// 合法状态池：known 侧（complete/maxed/upgrading）与 unknown 侧（unknown/unverified）。
    private static let knownStatuses: [VillageItemStatus] = [.complete, .maxed, .upgrading]
    private static let unknownStatuses: [VillageItemStatus] = [.unknown, .unverified]

    /// `levelLimitedToStage == true` 时 level 限定在 1...stageMax（用于
    /// stageRatio ≥ globalRatio 的专门生成器；聚合不变量只在全部 level ≤ stageMax
    /// 时成立——设计评审 Important-1）。
    private func randomItem(_ g: inout SeededGenerator, levelLimitedToStage: Bool = false) -> VillageItemState {
        let isKnownSide = g.bool()
        let status = isKnownSide
            ? Self.knownStatuses[g.int(in: 0...(Self.knownStatuses.count - 1))]
            : Self.unknownStatuses[g.int(in: 0...(Self.unknownStatuses.count - 1))]
        let maxLevel = g.int(in: 1...20)
        let stageMax = g.int(in: 1...maxLevel)
        let level: Int?
        if isKnownSide {
            let bound = levelLimitedToStage ? stageMax : (maxLevel + 5)
            level = g.int(in: 1...bound)
        } else {
            level = nil
        }
        let count = g.bool() ? g.int(in: 1...8) : 1
        return VillageItemState(
            id: "i\(g.int(in: 0...100_000))",
            section: "buildings",
            dataID: 1,
            base: .home,
            name: "item",
            category: .buildings,
            currentLevel: level,
            count: count,
            timerSeconds: status == .upgrading ? 3600 : nil,
            remainingSeconds: status == .upgrading ? 1800 : nil,
            nextLevel: status == .upgrading ? level.map { $0 + 1 } : nil,
            nextLevelDurationSeconds: status == .upgrading ? 3600 : nil,
            nextLevelDurationState: status == .upgrading ? .timed(seconds: 3600) : nil,
            maxLevel: isKnownSide ? maxLevel : nil,
            currentStageMaxLevel: isKnownSide ? stageMax : nil,
            status: status,
            missingReason: nil,
            catalogItemMissingReason: nil,
            availability: .unconfigured,
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: false,
            displayCategory: nil
        )
    }

    /// 随机 items；count 全 1 时（无权重干扰）检查守恒。
    private func run(_ rounds: Int = 300, body: (inout SeededGenerator) -> Void) {
        var g = SeededGenerator(seed: 70)
        for _ in 0..<rounds { body(&g) }
    }

    // MARK: - Properties

    func testRatioWithinZeroOne() {
        run { g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"))
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                if let ratio = metric.ratio {
                    XCTAssertTrue(ratio >= 0 && ratio <= 1, "ratio \(ratio) out of [0,1]")
                }
                XCTAssertGreaterThanOrEqual(metric.numerator, 0)
                XCTAssertGreaterThanOrEqual(metric.denominator, 0)
            }
        }
    }

    func testConservationKnownPlusUnknownEqualsTotal() {
        run { g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"))
            // 覆盖指标守恒：已知 + 未知 == 观测总数（无饱和时）
            if !m.snapshotCoverage.saturated {
                let total = items.reduce(0) { $0 + ($1.instanceWeight) }
                XCTAssertEqual(m.snapshotCoverage.denominator, total)
                XCTAssertLessThanOrEqual(m.snapshotCoverage.numerator, total)
            }
        }
    }

    func testStageRatioAtLeastGlobalRatioWhenLevelsWithinStage() {
        // 聚合不变量只在全部 level ≤ stageMax 时成立（设计评审 Important-1）：
        // 此时 stage = Σlevel/ΣstageMax ≥ Σlevel/ΣmaxLevel = global（分母小）。
        run { g in
            let items = (0..<g.int(in: 1...10)).map { _ in randomItem(&g, levelLimitedToStage: true) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"))
            if !m.currentStageProgress.saturated && !m.globalProgress.saturated,
               let stage = m.currentStageProgress.ratio, let global = m.globalProgress.ratio {
                XCTAssertGreaterThanOrEqual(stage, global)
            }
        }
    }

    func testUnusableCatalogAlwaysUnavailable() {
        run { g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: false)
            XCTAssertEqual(m.currentStageProgress.state, .unavailable)
            XCTAssertEqual(m.globalProgress.state, .unavailable)
            XCTAssertEqual(m.snapshotCoverage.state, .unavailable)
            XCTAssertNil(m.currentStageProgress.ratio)
        }
    }

    func testStateCompletenessAndConsistency() {
        run { g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: g.bool(),
                                                      compatibility: g.bool() ? .verified(gameVersion: "x") : .unverified(gameVersion: "x"))
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                XCTAssertTrue(ProgressMetricState.allCases.contains(metric.state))
                switch metric.state {
                case .ready, .partial:
                    XCTAssertGreaterThan(metric.denominator, 0)
                case .unavailable:
                    XCTAssertNil(metric.ratio)
                case .unknown:
                    XCTAssertNil(metric.ratio)
                }
            }
        }
    }

    func testSaturationNeverCrashes() {
        run(200) { g in
            // 混入 Int.max count 的恶意数据
            let items = (0..<g.int(in: 1...5)).map { _ in
                let normal = randomItem(&g)
                return VillageItemState(
                    id: normal.id + "m",
                    section: normal.section, dataID: 2, base: .home, name: "mal",
                    category: .buildings, currentLevel: 3, count: Int.max,
                    timerSeconds: nil, remainingSeconds: nil, nextLevel: nil,
                    nextLevelDurationSeconds: nil, nextLevelDurationState: nil,
                    maxLevel: 10, currentStageMaxLevel: 6, status: .complete,
                    missingReason: nil, catalogItemMissingReason: nil,
                    availability: .unconfigured, icon: nil, levelVisual: nil,
                    currentLevelIcon: nil, currentLevelVisual: nil,
                    isNested: false, displayCategory: nil
                )
            }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true)
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                XCTAssertTrue(metric.saturated)
                XCTAssertNil(metric.ratio)
            }
        }
    }
}
```

注意：`instanceWeight` 是 internal——测试用 `@testable import` 可访问。`SeededGenerator` 定义复制自 CoAPIPropertyTests（测试文件间不共享，保持文件独立惯例——检查现有文件是否已有共享，若 CoAPIPropertyTests 的 SeededGenerator 是文件级私有，则复制到本文件）。

- [ ] **Step 2: 跑测试确认通过**

Run: `swift test --filter VillageProgressMetricsPropertyTests`
Expected: 全部 PASS

- [ ] **Step 3: 提交**

```bash
git add Tests/COCHelperCoreTests/VillageProgressMetricsPropertyTests.swift
git commit -m "test(core): 三指标 property 测试（守恒/边界/状态完备/饱和）(Issue #70)"
```

---

## Task 3：UI 三指标卡

**Files:**
- Modify: `Sources/COCHelper/VillageDetailView.swift`

- [ ] **Step 1: 改 `VillageDetailView.swift`**：

1. 计算属性区（约 L97 附近）在 `total` 构造后新增：

```swift
        let progressMetrics = VillageProgressProjection.metrics(
            from: trackedItems,
            catalogIsUsable: projection.catalogIsUsable,
            compatibility: projection.compatibility
        )
```

2. L141 `completionBar(total: total)` 替换为 `metricsBar(metrics: progressMetrics)`。

3. 删除 `completionBar(total:)` 方法（L305-330 区域），替换为：

```swift
    /// Issue #70：三指标卡（当前阶段进度 / 全局养成进度 / 观测数据完整性）。
    /// 每个指标显示名称、百分比、分子/分母（带单位）与降级文案；saturated
    /// 优先于 state 文案（fail-closed，数值不权威时显示异常而非百分比）。
    private func metricsBar(metrics: VillageProgressMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metricRow(metrics.currentStageProgress, title: "当前阶段进度")
            metricRow(metrics.globalProgress, title: "全局养成进度")
            metricRow(metrics.snapshotCoverage, title: "观测数据完整性")
        }
        .padding(12)
        .background(Color.cocAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metricRow(_ metric: ProgressMetric, title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            if metric.saturated {
                Text("数据异常（超出可表示范围）")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let ratio = metric.ratio {
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .tint(Color.cocAccent)
                    .frame(maxWidth: 180)
                Text(String(Int((ratio * 100).rounded())) + "%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.cocAccent)
                    .frame(width: 44, alignment: .trailing)
                Text(String(metric.numerator) + " / " + String(metric.denominator) + " " + metric.units)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(degradedText(for: metric))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = metric.degradedReason, metric.ratio != nil {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 不可计算状态文案（unknown/unavailable；saturated 已在 metricRow 提前处理）。
    private func degradedText(for metric: ProgressMetric) -> String {
        switch metric.state {
        case .unavailable: return "目录不可用或版本不匹配，暂无法计算该指标"
        case .unknown:
            if metric.kind == .snapshotCoverage, metric.denominator == 0 {
                return "尚未导入快照"
            }
            return "无可确认项目，暂无法计算"
        case .ready, .partial: return "—"
        }
    }
```

- [ ] **Step 2: 编译验证**

Run: `swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED，0 警告

- [ ] **Step 3: 跑相关测试确认无回归**

Run: `swift test --filter "VillageDetailProjectionTests|VillageProgressMetrics"`（UI target 无测试，Core 全量兜底）
Expected: 全 PASS

- [ ] **Step 4: 全量测试**

Run: `swift test`
Expected: 795 + 新增全绿，0 失败

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelper/VillageDetailView.swift
git commit -m "feat(ui): 村庄详情页完成度拆为三指标卡（当前阶段/全局养成/观测完整性）(Issue #70)"
```

---

## Task 4：Reflexion 自查与验收

**Files:** 无新文件；对照 issue #70 验收标准逐条检查。

- [ ] **Step 1: 对照验收标准自查**（逐条核对代码，写入 PR body）：
  1. 页面不再用单个无限定"完成度"覆盖三种含义 → metricsBar 三行，各自命名 ✓/✗
  2. 能分别展示三指标或明确"暂不可计算" → 各 state 文案 ✓/✗
  3. 实例加权结果不误称全村庄 → 分子/分母显式 + "观测数据完整性"命名 ✓/✗
  4. 目录不可用/版本不匹配不显示权威百分比 → catalogIsUsable false → unavailable ✓/✗
  5. 旧缓存/未知 dataID/缺失快照有降级文案 → unknown/unverified/empty ✓/✗
  6. 新增分母、未知状态、跨基地隔离、无快照测试 → Task 1/2 覆盖 ✓/✗
  7. `swift test` 通过 + 窗口级检查（用户手测）✓/✗
- [ ] **Step 2: 全量验证**

Run: `swift test`
Expected: 全绿；`git diff --check` 干净；release 构建无警告（`swift build -c release 2>&1 | tail -3`）

- [ ] **Step 3: 提交（如有自查修正）**

---

## 实现全量代码（Task 1 Step 3 用）

```swift
// Sources/COCHelperCore/VillageProgressMetrics.swift
import Foundation

// MARK: - 状态

/// 指标可计算状态（issue #70 契约）。
public enum ProgressMetricState: String, Hashable, Sendable, CaseIterable {
    /// 分母完整、无缺失输入、目录已验证：可直接展示百分比。
    case ready
    /// 可计算但输入部分缺失（未知项/目录未验证）：展示百分比 + 降级说明。
    case partial
    /// 不可计算：目录不可用或版本不匹配（fail-closed，禁止假精度）。
    case unavailable
    /// 无数据：无快照或无可计算实例（分母为 0）。
    case unknown
}

// MARK: - 指标

/// 单个指标的展示模型。
public struct ProgressMetric: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// 当前阶段进度：等级和 / 当前阶段上限和（cap = currentStageMaxLevel）。
        case currentStageProgress
        /// 全局养成进度：等级和 / 目录全局上限和（cap = maxLevel）。
        case globalProgress
        /// 观测数据完整性：已关联目录实例数 / 追踪类别观测实例数。
        case snapshotCoverage
    }

    public let kind: Kind
    /// 分子（实例加权，饱和求和）。
    public let numerator: Int
    /// 分母（实例加权，饱和求和）。
    public let denominator: Int
    public let state: ProgressMetricState
    /// 任一求和饱和（issue #66 fail-closed）：ratio 恒 nil，UI 显示异常。
    public let saturated: Bool
    /// 分子/分母的展示单位（"级"/"实例"）。
    public let units: String
    /// 降级原因（ready 时 nil）。
    public let degradedReason: String?

    public var id: String { kind.rawValue }

    /// 展示比例；saturated、分母 ≤ 0、state 不可计算（unavailable/unknown）时 nil。
    public var ratio: Double? {
        guard !saturated, denominator > 0, state == .ready || state == .partial else { return nil }
        return Double(numerator) / Double(denominator)
    }

    public init(
        kind: Kind,
        numerator: Int,
        denominator: Int,
        state: ProgressMetricState,
        saturated: Bool = false,
        units: String,
        degradedReason: String? = nil
    ) {
        self.kind = kind
        self.numerator = numerator
        self.denominator = denominator
        self.state = state
        self.saturated = saturated
        self.units = units
        self.degradedReason = degradedReason
    }
}

/// 一个村庄、一个基地的三指标聚合（issue #70）。
public struct VillageProgressMetrics: Hashable, Sendable {
    public let currentStageProgress: ProgressMetric
    public let globalProgress: ProgressMetric
    public let snapshotCoverage: ProgressMetric
}

// MARK: - 投影

/// Issue #70：三指标投影。纯函数，输入与 `VillageDetailProjection.totalCompletion`
/// 同口径（调用方已过滤 status == .unavailable 的 trackedItems）。
///
/// 指标语义：
/// - currentStageProgress：`Σmin(level, currentStageMaxLevel) / ΣcurrentStageMaxLevel`，
///   分母只含 known 且阶段上限可计算的实例（#67 保证 known ⇒ stageMax 非 nil）；
/// - globalProgress：`Σmin(level, maxLevel) / ΣmaxLevel`，同样只含 known 实例；
/// - snapshotCoverage：`known 实例权重 / 全部追踪类别观测实例权重`——观测数据
///   完整性（已知/未知比例），不是村庄实例宇宙的完整覆盖率（目录侧缺失项
///   枚举未落地，阶段 2 数据管线）；issue #70 契约明确不得称"全村庄完成度"。
///
/// 状态判定（决策 2/3/5）：
/// - `catalogIsUsable == false` → 三指标全部 `.unavailable`（目录不可用/版本不匹配，
///   fail-closed，禁止假精度）；
/// - 分母 == 0 → `.unknown`（无快照或无可确认实例）；
/// - 未知实例权重 > 0 → `.partial`；
/// - `compatibility == .unverified` → 可计算指标强制 `.partial`（未验证目录不伪装
///   ready），degradedReason 说明；
/// - 其余 → `.ready`。
/// 饱和（issue #66 fail-closed）：分子/分母各自 `addingReportingOverflow` 饱和求和，
/// 任一饱和 → `saturated = true` → ratio 恒 nil；饱和不改变 state（UI 层饱和优先）。
public enum VillageProgressProjection {
    public static func metrics(
        from items: [VillageItemState],
        catalogIsUsable: Bool,
        compatibility: CatalogCompatibility? = nil
    ) -> VillageProgressMetrics {
        guard catalogIsUsable else {
            return unavailableMetrics()
        }
        // 与 VillageDetailProjection.isKnown 同一规则（private 不可跨类型调用，逐字复制）。
        let known = items.filter { isKnown($0) }
        // 未知实例权重（独立求和，饱和不丢失；溢出标志并入 unknownWeightInfo）
        let unknownWeightInfo = VillageDetailProjection.instanceCountAndOverflow(of: items.filter { !isKnown($0) })

        // 阶段进度：分母 = Σ(stageMax × weight)，分子 = Σ(min(level, stageMax) × weight)
        let stageEligible = known.filter { $0.currentStageMaxLevel != nil }
        let stageDen = weightedCappedSum(stageEligible) { $0.currentStageMaxLevel ?? 0 }
        let stageNum = weightedCappedSum(stageEligible) {
            min($0.currentLevel ?? 0, $0.currentStageMaxLevel ?? 0)
        }

        // 全局进度：分母 = Σ(maxLevel × weight)，分子 = Σ(min(level, maxLevel) × weight)
        let globalEligible = known
        let globalDen = weightedCappedSum(globalEligible) { $0.maxLevel ?? 0 }
        let globalNum = weightedCappedSum(globalEligible) {
            min($0.currentLevel ?? 0, $0.maxLevel ?? 0)
        }

        // 覆盖率：分母 = 全部观测实例权重，分子 = known 实例权重（饱和信息保留）
        let coverageDen = VillageDetailProjection.instanceCountAndOverflow(of: items)
        let coverageNum = VillageDetailProjection.instanceCountAndOverflow(of: known)

        let unverifiedCatalog = compatibility?.isUnverified ?? false

        return VillageProgressMetrics(
            currentStageProgress: makeMetric(
                kind: .currentStageProgress,
                numerator: stageNum.value,
                denominator: stageDen.value,
                saturated: stageNum.saturated || stageDen.saturated,
                unknownWeight: unknownWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                units: "级",
                emptyReason: "无可确认项目，暂无法计算"
            ),
            globalProgress: makeMetric(
                kind: .globalProgress,
                numerator: globalNum.value,
                denominator: globalDen.value,
                saturated: globalNum.saturated || globalDen.saturated,
                unknownWeight: unknownWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                units: "级",
                emptyReason: "无可确认项目，暂无法计算"
            ),
            snapshotCoverage: makeMetric(
                kind: .snapshotCoverage,
                numerator: coverageNum.count,
                denominator: coverageDen.count,
                saturated: coverageNum.didOverflow || coverageDen.didOverflow,
                unknownWeight: unknownWeightInfo.count,
                unverifiedCatalog: unverifiedCatalog,
                units: "实例",
                emptyReason: "尚未导入快照"
            )
        )
    }

    // MARK: - Helpers

    private static func unavailableMetrics() -> VillageProgressMetrics {
        let reason = "目录不可用或版本不匹配，暂无法计算该指标。"
        return VillageProgressMetrics(
            currentStageProgress: ProgressMetric(
                kind: .currentStageProgress, numerator: 0, denominator: 0,
                state: .unavailable, units: "级", degradedReason: reason),
            globalProgress: ProgressMetric(
                kind: .globalProgress, numerator: 0, denominator: 0,
                state: .unavailable, units: "级", degradedReason: reason),
            snapshotCoverage: ProgressMetric(
                kind: .snapshotCoverage, numerator: 0, denominator: 0,
                state: .unavailable, units: "实例", degradedReason: reason)
        )
    }

    private static func makeMetric(
        kind: ProgressMetric.Kind,
        numerator: Int,
        denominator: Int,
        saturated: Bool,
        unknownWeight: Int,
        unverifiedCatalog: Bool,
        units: String,
        emptyReason: String
    ) -> ProgressMetric {
        let state: ProgressMetricState
        var reasons: [String] = []
        if denominator == 0 {
            state = .unknown
            reasons.append(emptyReason)
        } else {
            if unknownWeight > 0 {
                reasons.append(String(unknownWeight) + " 项未知，结果仅为已观测项目。")
            }
            if unverifiedCatalog {
                reasons.append("目录与玩家版本未验证，百分比可能过时。")
            }
            state = (reasons.isEmpty) ? .ready : .partial
        }
        return ProgressMetric(
            kind: kind,
            numerator: numerator,
            denominator: denominator,
            state: state,
            saturated: saturated,
            units: units,
            degradedReason: reasons.isEmpty ? nil : reasons.joined(separator: " ")
        )
    }

    /// 计入指标分母的条件（与 VillageDetailProjection.isKnown 逐字同规则）：
    /// unknown/unavailable/available/unverified 不计；maxLevel/currentLevel 缺失
    /// 不计；upgrading 且 nextLevel > maxLevel（版本不匹配）不计。
    private static func isKnown(_ item: VillageItemState) -> Bool {
        guard item.status != .unknown, item.status != .unavailable,
              item.status != .available, item.status != .unverified else { return false }
        guard item.maxLevel != nil, item.currentLevel != nil else { return false }
        if item.isUpgrading,
           let nextLevel = item.nextLevel,
           let maxLevel = item.maxLevel,
           nextLevel > maxLevel {
            return false
        }
        return true
    }

    /// 等级式公式的实例加权饱和求和：`value(item) × instanceWeight` 累加，
    /// 乘法/加法任一溢出饱和到 Int.max 并置位（issue #66 fail-closed）。
    private static func weightedCappedSum(
        _ items: [VillageItemState],
        value: (VillageItemState) -> Int
    ) -> (value: Int, saturated: Bool) {
        var saturated = false
        let total = items.reduce(0) { acc, item in
            let (scaled, mulOverflow) = value(item).multipliedReportingOverflow(by: item.instanceWeight)
            let (sum, addOverflow) = acc.addingReportingOverflow(scaled)
            if mulOverflow || addOverflow {
                saturated = true
                return Int.max
            }
            return sum
        }
        return (total, saturated)
    }
}
```

注意：
- `instanceWeight`/`countOverflowed` 是 internal，同模块（COCHelperCore）内可直接访问 ✓。
- `VillageItemState` 的 `status == .unverified` 已在 main 确认存在 ✓。
- `CatalogCompatibility` 定义于 `GameCatalog.swift:423`（同模块）；`isUnverified`/`isUsable` 是现成 public 计算属性，直接使用，**不要重复声明 extension**。
- `VillageDetailProjection.instanceCountAndOverflow` 是 internal static（VillageDetailProjection.swift:238），同模块直接调用——覆盖率/未知权重复用现成实现，不重复造轮子。
- `isKnown` 规则复制而非调用 `VillageDetailProjection.isKnown`（它是 private）✓。

---

## 任务间依赖与顺序

Task 1（domain+计算）→ Task 2（property）→ Task 3（UI）→ Task 4（Reflexion）。每任务独立提交；Task 2/3/4 依赖 Task 1 的类型已存在。

## 不做（边界，issue #70 非目标 + 阶段 1 范围）

- 不做实例数量宇宙数据管线（阶段 2，Tools/game_catalog）——stage/global 分母为已观测 known 实例的等级和，明确不是村庄全宇宙。
- 不做 `.available`（目录有快照无）投影产出——覆盖率命名为"观测数据完整性"。
- 不改 `VillageCategoryCompletion`/`isFullyMaxed`（筛选 chip 契约，#53/#66）。
- 不改 `UpgradeOverviewProjection`（issue 要求 6 的"消费同一指标投影"在阶段 1 体现为：UI 三指标全部来自同一个 `VillageProgressProjection.metrics` 入口；升级总览列表不展示三指标，YAGNI）。
- 不新增资源库存/工人队列/自动规划。
