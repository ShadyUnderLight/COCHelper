# 性能基线格式与复测命令（Issue #197，供 #198/#199/#200 共用）

## 环境记录（每次采样必填）
- 基线 commit SHA（本 Issue = `origin/main@5a553481c67466cf92627caf27d1f18371a1fef8`）
- catalog manifest fingerprint：`Sources/COCHelperCore/GameCatalog/18.400.13/manifest.json` 的 `catalog.json` sha256
- macOS 版本 / 硬件架构 / Swift toolchain / 窗口尺寸 / 数据规模（fixture 名 + 条目数）

## 指标字段（每场景 × 冷/热）
| 字段 | 说明 |
|---|---|
| 窗口刷新频率 / Animation Hitch 次数与最长 hitch | Instruments Animation Hitches |
| 16.7ms 60Hz 帧预算下的主线程阻塞区间 | Time Profiler，主线程 |
| 每次滚动 / Timeline tick 的 projection 调用次数和耗时 | signpost：VillageCatalogProjection.project / BuildingGroupProjection.project / CraftTableProjection.project / UpgradeOverviewProjection.overviewRecords / overviewState |
| 图片候选探测次数、成功解码次数、失败候选次数和解码内存峰值 | signpost：VillageItemState.preferredAssetURLs(version:) + Allocations/VM Tracker（NSImage/CGImage/临时数组） |
| 峰值内存、短时分配量和滚动停止后的回收情况 | Allocations / VM Tracker |

## signpost 埋点契约
- 统一命名空间：`OSLog(subsystem: "com.local.coc-helper", category: "perf.projection")`
- 事件名（稳定，见 PerformanceSignpost.swift）：
  - `VillageCatalogProjection.project`
  - `BuildingGroupProjection.project`
  - `CraftTableProjection.project`
  - `UpgradeOverviewProjection.overviewRecords`
  - `UpgradeOverviewProjection.overviewState`
  - `VillageItemState.preferredAssetURLs`
- 负载只含整数（scale/count）与布尔（cache hit/miss），不得记录账号原文、token、URL 敏感参数、完整唯一 ID。

## 复测命令
```bash
# Release App（Instruments 可附加）
scripts/build_app.sh
open .build/COCHelper.app

# 测试门禁（不设 wall-clock 阈值）
swift test
git diff --check

# Instruments（人工）
# 1. Animation Hitches：滚动 10 秒场景
# 2. Time Profiler：主线程热点，每场景取前 3
# 3. Allocations/VM Tracker：图片解码内存与回收
# 4. 若启用 OSSignpost：Profile → os_signpost 区间（投影调用次数/耗时）
```

## 基线报告存放
- 每场景记录文件建议：`Tools/perf/results/2026-08-18/<场景>-<冷|热>.md`
- 内容：操作步骤、数据规模、环境、commit SHA、原始指标摘要、前三个主线程热点（未证明根因标记未知）。

## 后续 Issue 复测
- #198 / #199 / #200 完成后，用同一 fixture 与场景重跑，保留前后对比（同格式）。
