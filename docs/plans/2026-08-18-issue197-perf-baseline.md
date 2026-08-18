# Issue #197：建立滚动卡顿基线、真实快照样本与回归门禁（实施计划）

## 审查结论（2026-08-18）
- 分类：基准测量 + 回归门禁（benchmark / test-gap / instrumentation infra），非 bug 修复。
- 结论：现在做。前提：基于 origin/main@5a55348（issue 锁定基线）新建分支实现；Instruments 采集为人工步骤，本 Issue 交付可复现脚手架（fixtures / 场景脚本 / signpost / 基线格式 / 复测命令）。
- 代码证据：基线 main 上确认存在高风险路径（VillageDetailView TimelineView 60s 全量投影、普通 ScrollView+VStack、body 内同步 NSImage(contentsOf:)、ContentView overviewRecords + overviewState 双投影）。无任何既有性能基线基础设施。

## 交付物
1. **匿名本地 fixtures**（Tests/COCHelperCoreTests/Fixtures/perf_*）
   - 账号快照：主村 / 建筑工人基地 / 混合（含 timer-ended、缺失 section → partial、目录未收录 → unknown）
   - 部落战争日志多页缓存（3 页，游标链）
   - 部落都城突袭周末多页缓存（3 页，游标链）
   - manifest：commit SHA、catalog fingerprint、macOS、arch、toolchain、窗口尺寸、数据规模
2. **场景脚本**（Tools/perf/perf_scenarios.md）：5 场景 × 冷/热两次操作步骤
3. **基线格式 + 复测命令**（Tools/perf/baseline_format.md）
4. **统一 signpost**（Sources/COCHelperCore/PerformanceSignpost.swift）覆盖：
   VillageCatalogProjection.project / BuildingGroupProjection.project /
   CraftTableProjection.project / UpgradeOverviewProjection.overviewRecords /
   UpgradeOverviewProjection.overviewState / VillageItemState.preferredAssetURLs(version:)
   - 只记录耗时、计数、数据规模、cache hit/miss；不记录账号原文、token、URL 敏感参数、完整唯一 ID。
5. **单元测试**：fixture 解码契约 + 匿名契约 + 计数契约；signpost event 名称契约。
   - 不设 wall-clock 阈值测试（issue 非目标）。

## 非目标（红线）
- 不引入图片缓存 / LazyVStack / 投影缓存实现（#198/#199/#200 负责）。
- 不用 XCTest 固定 wall-clock 阈值替代 Instruments 证据。
- 不提交用户真实快照、token、cookie、原始账号 tag。
- 不把「测试通过/窗口能打开」表述成「滚动性能已修复」。
- 不改变任何用户可见语义（signpost 仅埋点）。

## 验收标准映射
- [ ] 主线 Release App 能按 fixture 重复打开并执行全部场景 → 人工（Instruments + 真实窗口）；本 Issue 交付场景脚本与 fixture 路径。
- [ ] 每个场景都有操作步骤、数据规模、环境、commit SHA 和原始指标摘要 → Tools/perf/ 文档 + manifest + baseline_format.md。
- [ ] 至少识别每个场景的前三个主线程热点；未证明根因标记未知 → 人工 Instruments 步骤，文档给出记录模板。
- [ ] 建立后续 #198/#199/#200 共用的基线格式和复测命令 → Tools/perf/baseline_format.md + signpost 埋点。
- [ ] 采样产物不含真实账号数据/token/cookie/完整敏感 ID → fixtures 匿名契约测试 + signpost 只传整数/布尔。
- [ ] 性能基线本身不改变用户可见语义；Swift 测试、Release build、git diff --check 通过 → 全量验证。

## 实现顺序
1. docs（plan / scenarios / baseline_format）
2. PerfFixtureTests（RED）→ fixtures + manifest（GREEN）
3. PerformanceSignpostTests（RED）→ PerformanceSignpost + 投影包装（GREEN）
4. 全量 swift test / release build / build_app.sh / diff-check
5. commit + PR

## 数据规模目标（perf fixtures）
- 主村账号：~100 建筑条目（含城墙 cnt、同建筑多等级、~10 进行中 timer、2 timer-ended）、~40 陷阱、~30 部队、法术/英雄/宠物/装备、helpers/guardians/decos/obstacles。
- 建筑工人基地：~60 条目。
- war log：3 页 × ~10 条/页（游标链，末页 after nil）。
- raid：3 页 × ~6 赛季/页（游标链，末页 after nil）。
