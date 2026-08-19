# Upgrade Overview：多村庄、manual 状态、各面板滚动（冷启动/首次进入）

> Issue #209 基线采样文档。本文件为模板：静态信息已填，**指标字段待 Instruments 采样后填写**，
> 采样完成后删除「待采样」标注并回链 #196/#209。

## 操作步骤
1. seed 已建立 3 村庄（A/B/C）+ manual active/completed（≥5 项），在总览页打开。
2. 滚动 active / pending / recently completed / attention 各面板各 10 秒（本文档对应 冷启动/首次进入）。

## fixture 与数据规模
- seed 路径：Debug app「性能样本」菜单（⌘⇧P）加载，3 村庄 + manual active/completed + conflict + war/raid 多页缓存
- perf_account_snapshot_home: 516 / builder: 467 / mixed: 521 / variant: 516（顶层数组元素合计）
- perf_war_log_page_01..03: 10 / 10 / 10 条；perf_capital_raid_page_01..03: 6 / 6 / 5 条
- 未加载任何真实账号数据（fixtures 已匿名）

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

## 前 3 个主线程热点（待采样）
1. 待采样
2. 待采样
3. 待采样

## 前后对比
- 基线期（无前序对比）：本文件为 #209 首轮基线，供 #210/#211/#212 复测对比。
- 未证明的根因一律标记为「未知」，不得用推测替代。

## 复测命令
```bash
# Step 1：Debug app 加载性能样本（⌘⇧P）→ Step 2：Release app 测量
scripts/build_app.sh && open .build/COCHelper.app
# Instruments：Animation Hitches / Time Profiler / Allocations，滚动 10 秒
```
