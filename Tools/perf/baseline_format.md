# 性能基线格式与复测命令（Issue #197/#209，供 #198/#199/#200 共用）

## 环境记录（每次采样必填）
- 基线 commit SHA（本 Issue = `origin/main@d3b57e8164f81e292a023b052e455085565c3dbb`，Issue #209 锁定；
  #197 初版基线 `5a553481c67466cf92627caf27d1f18371a1fef8` 仅作脚手架历史记录）
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
  - `VillageItemState.preferredAssetURLs`（候选 URL 探测）
  - `NSImage.contentsOf`（滚动路径同步图片解码，app target 埋点）
- 负载只含整数（scale/count）与布尔（cache hit/miss / succeeded/ok）：
  - 投影/候选探测用 `cache=%d`、`count=%d`；
  - 图片解码用 `ok=%d`（`PerformanceSignpost.end` 的 `succeeded` 负载，表达解码成功/失败，本路径无缓存概念）。
  不得记录账号原文、token、URL 敏感参数、完整唯一 ID。

## 复测命令（两步：Debug 加载 seed → Release 测量）
```bash
# Step 1：Debug App 加载性能样本（唯一含 seed 入口的构建；release 无菜单）
swift build
mkdir -p .build/COCHelper.debug.app/Contents/MacOS .build/COCHelper.debug.app/Contents/Resources
cp .build/arm64-apple-macosx/debug/COCHelper .build/COCHelper.debug.app/Contents/MacOS/COCHelper
cp Resources/Info.plist .build/COCHelper.debug.app/Contents/Info.plist
cp Resources/COCHelperAppIcon.icns .build/COCHelper.debug.app/Contents/Resources/COCHelperAppIcon.icns
cp -R .build/arm64-apple-macosx/debug/COCHelper_COCHelperCore.bundle .build/COCHelper.debug.app/
cp -R .build/arm64-apple-macosx/debug/COCHelper_COCHelperApp.bundle .build/COCHelper.debug.app/
open .build/COCHelper.debug.app
# 菜单「性能样本」→ 加载性能样本（隐藏）（⌘⇧P）→ 自动导入 3 村庄 +
# manual active/completed + conflict + war/raid 多页缓存（无村庄/部落数据时生效）

# Step 2：Release App 测量（Instruments 可附加，读 Step 1 写入的 seed 数据）
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
> Debug 与 Release 的 bundle id 相同（com.local.coc-helper），共用 Application Support 数据，
> 因此 Step 1 写入的 seed 数据可被 Step 2 的 Release app 读取。若用户已有真实村庄/部落数据，
> seed 会拒绝加载（不覆盖用户数据），此时直接测量用户自己的数据即可。

## 基线报告存放
- 每场景记录文件建议：`Tools/perf/results/2026-08-18/<场景>-<冷|热>.md`
- 内容：操作步骤、数据规模、环境、commit SHA、原始指标摘要、前三个主线程热点（未证明根因标记未知）。

## 后续 Issue 复测
- #198 / #199 / #200 完成后，用同一 fixture 与场景重跑，保留前后对比（同格式）。
