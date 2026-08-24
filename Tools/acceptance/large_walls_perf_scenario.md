# Issue #226：1000+ 城墙 Release 性能场景

本场景使用 **fixture-equivalent** 脱敏数据，不替代两个真实村庄的导入验收。

## Fixture

- 文件：`Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls.json`
- Tag：`#PERF-LARGE-WALLS`（匿名，非真实账号）
- 规模：1005 段城墙（`data: 1000008`，逐段 `cnt: 1`）
- 生成：`python3 Tools/acceptance/generate_large_walls_fixture.py`

## 加载方式

### 方式 A：账号数据页粘贴（推荐，不需改 App seed）

1. `scripts/build_app.sh` 构建 Release App。
2. 打开 Release App → 账号数据页。
3. 粘贴 `perf_account_snapshot_large_walls.json` 全文并导入。
4. 进入对应村庄详情页与 Snapshot History。

### 方式 B：Debug seed + Release 测量（仅空数据环境）

若 Application Support 无现有村庄，可用 Debug App 的 perf seed 流程（见 `Tools/perf/baseline_format.md`），但 **不得** 将 perf seed 的多村庄状态当作 #226 真实村庄验收。

## 操作清单（Release App）

每个场景连续操作 ≥10 秒，记录是否出现明显主线程卡顿、重复 projection 构建、内存异常增长、scroll/disclosure 状态漂移。

| # | 场景 | 操作 |
|---|---|---|
| 1 | Village Detail 滚动 | 城墙分类或全部建筑列表上下滚动 |
| 2 | Snapshot History 滚动 | 历史时间线列表滚动 |
| 3 | 展开大变化 row | 展开含大量 Wall/建筑变化的 row |
| 4 | category filter | 切换 all/building/wall/hero 等 |
| 5 | 统计窗口 | today → 7 天 → 30 天切换 |
| 6 | 连续展开/折叠 | 同一 row 多次 disclosure 切换 |

## 记录要求

- 窗口尺寸、macOS 版本、commit SHA、测试日期。
- 卡顿：主观明显卡顿 / 轻微 / 无。
- 可选 Instruments：Animation Hitches 次数、Time Profiler 前三热点（见 `Tools/perf/baseline_format.md`）。
- 不提交 raw trace 或敏感 JSON。

## 通过标准

- 无明显主线程卡顿或 UI 状态漂移。
- 若发现性能问题，记录 profile 摘要并**另开**性能 issue；不在 #226 顺手做优化。
