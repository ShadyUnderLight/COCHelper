# Issue #110 — partial 快照下「观测数据完整性」不得显示无 scope 的裸 100%

基线：`origin/main@63c125d`。Issue #110 是 #96 的指标语义 follow-up：`snapshotCoverage` 与升级总览聚合未携带 coverage scope。

## 1. 设计分析（SDD）

### 问题确认（已读代码核实）

- `snapshotCoverage` 构造（`VillageProgressMetrics.swift`）`denominatorIsComplete: true` 且不传 `coverageDiagnostic` → partial 快照 + 全 known 时 reasons 空 → `.ready` 裸 100%。
- `aggregateCoverage()` 返回裸 `(known, observed)?`，且内部调 `metrics(...)` 不传 coverage（默认 `.unavailable`）→ 聚合丢失全部 scope 信息。
- 详情页 stage/global 已正确消费 coverage（#96），`metricRow` 的 degradedReason 展示机制现成。

### 3 候选投票（聚合 coverage 合并语义，3 个独立 subagent）

| 候选 | 语义 | 结论 |
|---|---|---|
| A. 任一 unavailable → 整体 unavailable | fail-closed 最严 | **否决**：`TrackerBase.allCases = [home, builder]`，BB 的 `progressCoverage` 恒 `.unavailable`（决策 5）→ 任何已导入村庄都自带 unavailable 对 → 聚合恒 unavailable，fail-useless |
| B. partial 下限 + 诊断补充 | 任一非 complete → partial（合并缺失）；unavailable 计数进诊断 | **采用**（2/2 有效票） |
| C. 严格降级 + unavailableCount/partialCount 字段 | UI 表达力最强 | **否决**：生产下计数是恒量（0 与 N），过度设计 |

修正（评审子代理提出，已核实）：**scope 合并只对 home 基地对进行**，BB 对只贡献数值、不参与 scope 判定（决策 5 注释与 `progressCoverage` 计算逻辑核实一致）。

## 2. 类型契约（CoT）

```swift
/// 升级总览「观测数据完整性」卡的聚合结果（Issue #110）。
/// 数值 = 全部已导入村庄 × 全部基地的 snapshotCoverage 累加（BB 数值照旧计入）；
/// coverage = 仅合并 home 基地的 progressCoverage（决策 5：BB 恒 .unavailable，
/// 不参与 scope 判定——否则任何已导入村庄都自带 unavailable 对，聚合恒降级）。
public struct AggregateCoverage: Hashable, Sendable {
    public let numerator: Int
    public let denominator: Int
    public let coverage: ProgressUniverseCoverage
    public let diagnostics: [String]
}
```

### 合并规则（`mergedCoverage(of:)`，Core 纯函数，可单独 property 测试）

1. 存在任一 `.partial` 对 → `.partial`，missingSections / unmodeledCategories 取并集（missing 先 subtract unmodeled 去重）
2. 无 `.partial` 但 `.complete` 与 `.unavailable` 混合 → `.partial`（明细空，诊断由 unavailableHomeCount 计数生成）——unavailable 村庄不得被静默成 `.complete`（Reflexion 663fb99 修复，property 反向属性锁定）
3. 无任何 partial/unavailable 且存在 `.complete` → `.complete`（无诊断）
4. 全 `.unavailable` 或空列表 → `.unavailable`（无差集，纯已观测口径；调用方 `observed == 0` → nil 路径兜底）

### 诊断（partial 专属，复用 detail 页 `coverageDiagnostic(for:)` 措辞风格）

- missing 非空 → 「部分村庄快照缺少类别数据（中文类别名 sorted），无法确认完整村庄进度。」
- unmodeled 非空 → 「目录未对 X 的实例数量建模，无法确认完整村庄进度。」
- unavailable 对计数 > 0 → 「N 个村庄覆盖状态不可用，无法确认完整村庄进度。」

## 3. 改动文件

| 文件 | 改动 |
|---|---|
| `Sources/COCHelperCore/VillageProgressMetrics.swift` | ① snapshotCoverage 构造补传 `coverageDiagnostic`；② `aggregateCoverage()` 返回 `AggregateCoverage?`，收集 home 对 coverage 并合并；③ 新增 `AggregateCoverage` 类型 + `mergedCoverage(of:)` + 聚合诊断生成 |
| `Sources/COCHelperCore/VillageCatalogProjection.swift` | `ProgressUniverseCoverage.helpText` 提取（三分支措辞单一来源，详情页与聚合卡共用防漂移） |
| `Sources/COCHelper/VillageDetailView.swift` | `metricsBar` 标题按 coverage 分支：complete → 「观测数据完整性」，否则 → 「已观测数据关联率」；消费共享 `helpText` |
| `Sources/COCHelper/ContentView.swift` | `TrackerMetricsView.aggregateCoverage` 消费 `AggregateCoverage`；tint 按 coverage 三分支（blue/orange/orange）+ 标题同详情页口径；`.help()` tooltip 展示 scope 措辞 + 诊断 |
| `Tests/COCHelperCoreTests/VillageProgressMetricsTests.swift` | 翻转 L460 断言 + 新增回归（见下） |

不动：三指标公式、实例权重、coverageDen 口径、fail-closed（饱和/溢出/observed==0 → nil）。

## 4. TDD 测试清单（RED 先行）

1. 翻转 `testIncompleteDenominatorForcesPartial`：partial + 全 known → snapshotCoverage `.partial` + 诊断含缺失类别
2. 新增 `testCompleteCoverageKeepsSnapshotCoverageReady`：complete + 全 known → `.ready`（验收 2）
3. 新增 `testPartialSnapshotCoverageRatioStill100WithDiagnostic`：partial + numerator==denominator → `.partial`、ratio 100%、诊断非空（验收 3）
4. 新增 `testAggregateCoverageBBPairDoesNotPoisonScope`：单村庄（home partial + BB unavailable）→ 聚合 coverage 仍 `.partial`（BB 不污染）
5. 新增 `testAggregateCoverageAllUnavailableWhenNoHomeUniverse`：全 unavailable 对 → coverage `.unavailable`
6. 新增 `testAggregateCoverageCompleteWhenAllComplete`：全 complete → `.complete` 无诊断
7. 新增 `testAggregateCoverageMergesMissingSectionsAndUnmodeled`：两村庄不同 missing → 并集；missing∩unmodeled 去重
8. 新增 property 测试：`mergedCoverage` 交换律 / 结合律 / 幂等 / 全 complete 恒等（项目 SeededGenerator LCG 惯例）
9. 现有 fail-closed 测试保持通过（饱和 → nil）

## 5. Reflexion 自查清单（完成于终审）

- [x] `swift test` 全量通过（1013/1013：基线 999 + 新增 14）
- [x] `git diff --check` 干净（含跨 commit 检查）
- [x] 验收 1-6 逐条对照（双独立交叉审核员 APPROVE）
- [x] 生产目录恒 partial 前提下聚合卡行为验证（恒 partial + 诊断，不 fail-useless）
- [x] 数值口径与修复前逐位一致（回归）
- [x] Reflexion 发现混合 complete+unavailable 村庄 bug → 修复（663fb99）+ 反向属性锁定
- [x] 评审 important 修复：property 测试复用 SeededGenerator（75c1c5a）、聚合卡标题同详情页口径（终审 I1）
