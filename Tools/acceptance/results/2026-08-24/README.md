# Issue #226 验收证据索引（2026-08-24）

基线：`origin/main@256c065`（#234/#235/#236 已合并）

## 自动化门禁

| 项目 | 状态 | 证据 |
|---|---|---|
| `AppModelSnapshotHistoryTests` | 通过 | [automated-gate.md](automated-gate.md) |
| `swift test --parallel --num-workers 1` | 通过 | 同上 |
| Release build + `scripts/build_app.sh` | 通过 | 同上 |
| `git diff --check` | 通过 | 同上 |
| production code 改动 | **0 行** | 仅验收脚手架 + fixture |

## 真实村庄连续导入（需本地 JSON）

| 项目 | 状态 | 说明 |
|---|---|---|
| A1→A2 账号数据页 + 重启 + duplicate | **待本地数据** | 将 JSON 放入 `Tools/acceptance/local/` 后运行 `acceptance-runner` |
| B1→B2 详情页快捷导入 + 重启 + duplicate | **待本地数据** | 同上 |
| A/B 串档检查 | **待本地数据** | runner 输出 `real-village-acceptance.json` |

> 无可信 coverage 协议的真实 JSON 应预期 `insufficientCoverage/数据不足`，不是失败。

## Release 性能（1000+ 城墙）

| 项目 | 状态 | 证据 |
|---|---|---|
| fixture 契约（1005 段城墙） | 通过 | `PerfFixtureTests.testPerfAccountSnapshotLargeWallsHas1000PlusSegments` |
| Release App 人工滚动/展开 | **待人工** | 见 [performance-large-walls.md](performance-large-walls.md) |

fixture：`perf_account_snapshot_large_walls.json`（`#PERF-LARGE-WALLS`，fixture-equivalent）

## 下一步（review 前）

1. 维护者将真实村庄 JSON 放入 `Tools/acceptance/local/`（不提交）。
2. 运行 `Tools/acceptance/gate.sh` 生成 `real-village-acceptance.json`。
3. 按 `large_walls_perf_scenario.md` 在 Release App 完成人工性能核对并更新 `performance-large-walls.md`。
