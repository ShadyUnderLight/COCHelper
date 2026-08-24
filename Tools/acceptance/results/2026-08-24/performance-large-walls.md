# Issue #226：1000+ 城墙 Release 性能验收记录

状态：**待人工 Release App 验收**

## 固定信息

- commit: `256c065`（PR 分支 HEAD，基于 `origin/main`）
- fixture: `perf_account_snapshot_large_walls.json`
- tag: `#PERF-LARGE-WALLS`（匿名）
- 城墙段数: 1005（逐段 `cnt: 1`）
- macOS: 待填写
- Release build: `scripts/build_app.sh` 产出 `.build/COCHelper.app`

## 场景结果（人工填写）

| # | 场景 | 卡顿 | 内存异常 | UI 状态漂移 | 备注 |
|---|---|---|---|---|---|
| 1 | Village Detail 滚动 | 待测 | 待测 | 待测 | |
| 2 | Snapshot History 滚动 | 待测 | 待测 | 待测 | |
| 3 | 展开大变化 row | 待测 | 待测 | 待测 | |
| 4 | category filter 切换 | 待测 | 待测 | 待测 | |
| 5 | today/7/30 切换 | 待测 | 待测 | 待测 | |
| 6 | 连续展开/折叠 | 待测 | 待测 | 待测 | |

## 操作步骤

见 `Tools/acceptance/large_walls_perf_scenario.md`。

## 结论

- 自动化 fixture 契约已通过；Release UI 交互性能**尚未在本 PR 中记录人工结论**。
- 若人工验收无问题，将上表「待测」改为「无」并勾选通过。
