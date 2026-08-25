# Issue #226：1000+ 城墙 Release 性能场景

本场景使用 **fixture-equivalent** 脱敏数据，不替代两个真实村庄的导入验收。

## Fixture

- 单快照（兼容旧测试）：`Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls.json`（tag `#PERF-LARGE-WALLS`，hyphen 非法，仅作单快照 benchmark；history 场景请用 paired）
- **Paired（推荐，history 可展开 row，可稳定执行场景 3）**：
  - `perf_account_snapshot_large_walls_before.json`（1005 段，`lvl = 1` 全量，tag `#LARGEWALL01` 合法，同 lineage baseline）
  - `perf_account_snapshot_large_walls_after.json`（1005 段，`lvl = 12` 全量，同 tag `#LARGEWALL01`，保证同 lineage continued，raw histogram 偏移 1005）
  - 均由 `python3 Tools/acceptance/generate_large_walls_fixture.py` 生成（单文件 + paired 同步）；`lvl` 全量极值保证 raw workload 1005（旧 offset 6 仅 3 段残余，已修正）
- Tag 说明：`#LARGEWALL01` 为合法 synthetic tag（`OfficialPlayerTagValidator.isValid`），避免 hyphen 导致 `unknown` lineage；`#PERF-LARGE-WALLS` 保留仅为兼容旧单文件测试，不应用于 history 场景
- 规模：1005 段城墙（`data: 1000008`，逐段 `cnt: 1`）— **“大量”指 1005 段 raw Wall 输入规模经过完整 import → canonicalization → history → histogram Diff → projection 路径，形成一个非 duplicate、可展开、fail-closed 的 `unknown/insufficientCoverage` history row（无 verified coverage 时 Diff 仅产生 1 个 `unknownChange`，`oldQuantity 1005 → newQuantity 1005，impact 1`），而非 1005 个 confirmed change rows**；这已满足 #226 “使用至少 1000 段 Wall 的数据，在 Release App 滚动/展开”的性能目标

## 加载方式

### 账号数据页粘贴（唯一推荐，不需改 App seed）— 需两步以产生可展开的大变化 row

1. `scripts/build_app.sh` 构建 Release App。
2. 打开 Release App → 账号数据页。
3. 粘贴 `perf_account_snapshot_large_walls_before.json` 全文并导入（baseline，1005 墙）。
4. 再次粘贴 `perf_account_snapshot_large_walls_after.json` 全文并导入（同村同 tag，触发大量 Wall `lvl` 变化的 history Diff）。
5. 通过 `acceptance-runner` 或调试输出验证第二条 history 已为“非 baseline”且含确定性的大量 Wall 变化（Diff 输出 1 个 `unknown/insufficientCoverage` change，而非 1005 个 confirmed rows）。

> 注意：`AppModel.loadPerformanceSample()` / Debug perf seed 当前仅加载 home/builder/mixed/variant 及 war/raid 多页 fixture，**不会**加载 `perf_account_snapshot_large_walls.json`。不要使用 Debug seed 作为本 1000+ 城墙场景的加载路径，否则测不到目标数据却误以为完成 #226 性能门禁。

## 操作清单（Release App）

每个场景连续操作 ≥10 秒，记录是否出现明显主线程卡顿、重复 projection 构建、内存异常增长、scroll/disclosure 状态漂移。

| # | 场景 | 操作 |
|---|---|---|
| 1 | Village Detail 滚动 | 城墙分类或全部建筑列表上下滚动 |
| 2 | 导入性能 | 连续导入 before/after 快照，观察主线程响应 |
| 3 | Diff 计算性能 | 触发大量 Wall histogram Diff，观察计算耗时 |
| 4 | 统计窗口 | today → 7 天 → 30 天切换（如仍有 UI 展示） |
| 5 | 连续导入 | 同一快照多次导入，观察 duplicate 路径性能 |
| 6 | 重启恢复 | 导入后重启 App，观察 history 加载性能 |

## 记录要求

- 窗口尺寸、macOS 版本、commit SHA、测试日期。
- 卡顿：主观明显卡顿 / 轻微 / 无。
- 可选 Instruments：Animation Hitches 次数、Time Profiler 前三热点（见 `Tools/perf/baseline_format.md`）。
- 不提交 raw trace 或敏感 JSON。

## 通过标准

- 无明显主线程卡顿或 UI 状态漂移。
- 若发现性能问题，记录 profile 摘要并**另开**性能 issue；不在 #226 顺手做优化。
