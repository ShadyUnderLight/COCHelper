# Issue #226：1000+ 城墙 Release 性能场景

本场景使用 **fixture-equivalent** 脱敏数据，不替代两个真实村庄的导入验收。

## Fixture

- 单快照（兼容旧测试）：`Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls.json`（tag `#PERF-LARGE-WALLS`，hyphen 非法，仅作单快照 benchmark；history 场景请用 paired）
- **Paired（推荐，history 大变化 row）**：
  - `perf_account_snapshot_large_walls_before.json`（1005 段，`lvl = (i %12)+1`，tag `#LARGEWALL01` 合法）
  - `perf_account_snapshot_large_walls_after.json`（1005 段，`lvl = ((i+6)%12)+1`，同 tag `#LARGEWALL01`，保证同 lineage continued，大量 Wall 等级位移）
  - 均由 `python3 Tools/acceptance/generate_large_walls_fixture.py` 生成（单文件 + paired 同步）
- Tag 说明：`#LARGEWALL01` 为合法 synthetic tag（`OfficialPlayerTagValidator.isValid`），避免 hyphen 导致 `unknown` lineage；`#PERF-LARGE-WALLS` 保留仅为兼容旧单文件测试，不应用于 history Diff 验收
- 规模：1005 段城墙（`data: 1000008`，逐段 `cnt: 1`）

## 加载方式

### 账号数据页粘贴（唯一推荐，不需改 App seed）— 需两步以产生可展开的大变化 row

1. `scripts/build_app.sh` 构建 Release App。
2. 打开 Release App → 账号数据页。
3. 粘贴 `perf_account_snapshot_large_walls_before.json` 全文并导入（baseline，1005 墙）。
4. 再次粘贴 `perf_account_snapshot_large_walls_after.json` 全文并导入（同村同 tag，触发大量 Wall `lvl` 变化的 history Diff）。
5. 进入对应村庄详情页与 Snapshot History，此时第二条 history 已为“非 baseline”且含确定性的大量 Wall 变化，可展开验证场景 3。

> 注意：`AppModel.loadPerformanceSample()` / Debug perf seed 当前仅加载 home/builder/mixed/variant 及 war/raid 多页 fixture，**不会**加载 `perf_account_snapshot_large_walls.json`。不要使用 Debug seed 作为本 1000+ 城墙场景的加载路径，否则测不到目标数据却误以为完成 #226 性能门禁。

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
