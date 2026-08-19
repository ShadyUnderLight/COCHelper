# Upgrade Overview：多村庄、manual 状态、各面板滚动（冷启动/首次进入）

> Issue #209 基线采样文档。静态信息已填，**指标字段待 Instruments 采样后填写**，
> 采样完成后删除「待采样」标注并回链 #196/#209。

## 操作步骤
1. seed 已建立 3 村庄（A/B/C）+ manual active/completed（≥5 项），冷启动后打开总览页（首次进入）。
2. 滚动 active / pending / recently completed / attention 各面板各 10 秒。
3. 记录各面板 hitch 与投影调用（首次进入段）；热缓存段见 `03-upgrade-overview-hot.md`，不得混入同一采样。

## fixture 与数据规模
- seed 路径：Debug app「性能样本」菜单（⌘⇧P）加载，3 村庄 + manual active/completed + conflict + war/raid 多页缓存
- perf_account_snapshot_home: 516 / builder: 467 / mixed: 521 / variant: 516（顶层数组元素合计）
- perf_war_log_page_01..03: 10 / 10 / 10 条；perf_capital_raid_page_01..03: 6 / 6 / 5 条
- 未加载任何真实账号数据（fixtures 已匿名；若本机已有真实村庄/部落数据，seed 拒绝加载，此时本文件「未加载真实数据」陈述不成立，须在采样备注中说明）

## 环境和 commit SHA
- 被测 commit SHA：`origin/main@d3b57e8164f81e292a023b052e455085565c3dbb`（Issue #209 锁定基线）
- catalog manifest fingerprint：`sha256:a024fe5be9c3edff5f1f7e4f5ceeb0c013d3714b98a17678a7a7dd7d7dd225ab`（`Sources/COCHelperCore/GameCatalog/18.400.13/manifest.json`）
- macOS 26.6.1 (25G76) / arm64 / Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
- 窗口尺寸：1180x820（默认）；窄窗口场景 ~800pt

## 原始指标摘要（待 Instruments 采样）
| 指标 | 数值 | 备注 |
|---|---|---|
| Animation Hitch 次数 | 待采样 | Instruments Animation Hitches，滚动 10 秒 |
| 最长 hitch | 待采样 | ms |
| 主线程 >16.7ms 阻塞区间 | 待采样 | Time Profiler 主线程 |
| VillageCatalogProjection 调用/耗时 | 待采样 | OSSignpost |
| BuildingGroupProjection 调用/耗时 | 待采样 | OSSignpost |
| CraftTableProjection 调用/耗时 | 待采样 | OSSignpost |
| UpgradeOverviewProjection 调用/耗时 | 待采样 | OSSignpost |
| 图片候选探测 / 成功解码 / 失败候选 | 待采样 | OSSignpost + Allocations |
| 峰值内存 / 短时分配 / 停止后回收 | 待采样 | Allocations / VM Tracker |
| 可见行数 / row 构建数 / 重复构建数 | 待采样 | 若可观测 |
| 60s tick 触发后的阻塞区间（独立记录） | 待采样 | 不得与滚动混计为一个数字 |
| 导入/账号数据变化后的行为（独立记录） | 待采样 | 触发源单独采样 |
| manual action 后的行为（独立记录） | 待采样 | 触发源单独采样 |
| 分页加载后的滚动 hitch 与解码内存（独立记录） | 待采样 | 场景 4 必填；其他场景如有分页同样记录 |

## 触发源独立采样（与滚动分开记录）
每次触发源变更后单独开一次 trace，不得与滚动混进同一次记录：
- 60s tick：停在当前页不操作，等 Timeline 60 秒 tick 触发，记录该 tick 的投影调用/主线程阻塞；
- 导入变化：导入/替换一个账号快照后，立即记录重建与首次滚动；热缓存段用同一 fixture 重复导入一次；
- manual action：新建/完成一个 manual 升级后，记录投影与列表行重建；
- 分页加载：war log / capital raid 滚动到页尾触发下一页加载，单独记录加载期间的 hitch 与解码内存（场景 4 必填，其他场景如有分页同样记录）。

## 前 3 个主线程热点（待采样）
1. 待采样
2. 待采样
3. 待采样

## 前后对比
- 基线期（无前序对比）：本文件为 #209 首轮基线，供 #210/#211/#212 复测对比。
- 未证明的根因一律标记为「未知」，不得用推测替代。

## 复测命令
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
# 菜单「性能样本」→ 加载性能样本（隐藏）（⌘⇧P）；若已有真实村庄/部落数据 seed 会拒绝加载

# Step 2：Release App 测量（Instruments 可附加，读 Step 1 写入的 seed 数据）
scripts/build_app.sh
open .build/COCHelper.app

# 门禁（不设 wall-clock 阈值）
swift test
git diff --check

# Instruments（人工，按本文档指标表逐项采集）
# 1. Animation Hitches：滚动 10 秒场景
# 2. Time Profiler：主线程热点，取前 3
# 3. Allocations / VM Tracker：图片解码内存与回收
# 4. OSSignpost：Profile → os_signpost 区间（投影调用次数/耗时；事件名见 Tools/perf/baseline_format.md）
# 5. 60s tick / 导入 / manual action / 分页加载：单独采样，不与滚动混计
```
