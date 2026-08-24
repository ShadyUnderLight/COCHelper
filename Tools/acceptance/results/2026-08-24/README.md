# Issue #226 验收证据索引（2026-08-24）

基线：`origin/main@256c065`（#234/#235/#236 已合并）  
工具链 HEAD：`83fd27c`（lastSeenAt/latestCheckedAt 持久化 + paired fail-closed 单 row 语义）

## 自动化门禁

| 项目 | 状态 | 证据 |
|---|---|---|
| `AppModelSnapshotHistoryTests` | 通过 | [automated-gate.md](automated-gate.md)（commit `83fd27c`，working tree clean 已验证） |
| `swift test --parallel --num-workers 1` | 通过 | 同上 |
| Release build + `scripts/build_app.sh` | 通过 | 同上 |
| `git diff --check` | 通过 | 同上（排除 `Tools/acceptance/results`） |
| production code 改动 | **0 行** | 仅验收脚手架 + fixture（`Sources/COCHelperApp/PerfFixtures` dead duplicate 已删） |
| `gate.sh` clean-worktree 门禁 | 通过 | `automated-gate.md` 头部记录 `working tree: clean`，证据可追溯到含 runner/fixture/gate 的 clean commit |

## 真实村庄连续导入（需本地 JSON，交错 + 共同 restart）

| 项目 | 状态 | 说明 |
|---|---|---|
| A1→B1 → **共同 restart** → A2→B2（交错） | **待本地数据** | `runner` 现为 `A1/B1 → restart → A2/B2` 交错生命周期，验证两村同时存在时 restart 隔离 |
| A2/B2 duplicate（严格 +1） | **待本地数据** | 重复导入 `entries 不变 / duplicateMetadata +1 / duplicateImportCount 严格 +1` |
| A/B 串档 + lineage 隔离 | **待本地数据** | runner 输出 `real-village-acceptance.json`，含 `after-restart` 两边 projection + 最终 `totalSnapshotCount 2/2` |

> 无可信 coverage 协议的真实 JSON 应预期 `insufficientCoverage/数据不足`，不是失败。

## Release 性能（1000+ 城墙，paired）

| 项目 | 状态 | 证据 |
|---|---|---|
| fixture 契约（1005 段城墙，paired 同 lineage） | 通过 | `PerfFixtureTests.testPerfAccountSnapshotLargeWallsHas1000PlusSegments` + 手工验证 `before/after` 同 tag `#LARGEWALL01` 大量 Wall 位移 |
| Release App 人工滚动/展开（含大变化 row） | **待人工** | 见 [performance-large-walls.md](performance-large-walls.md)（**两步粘贴 before→after** 同村同 tag 产生确定性大变化 row；单次粘贴仅 baseline 无法复现场景 3） |

fixture：`perf_account_snapshot_large_walls_before.json` + `perf_account_snapshot_large_walls_after.json`（各 1005 段，`#LARGEWALL01` 合法，同 lineage，`lvl` 偏移 6 确保大量变化；`large_walls.json` 保留兼容旧单测）

## 下一步（review 前）

1. 维护者将真实村庄 JSON 放入 `Tools/acceptance/local/`（不提交）。
2. 运行 `Tools/acceptance/gate.sh` 生成 `real-village-acceptance.json`。
3. 按 `large_walls_perf_scenario.md` 在 Release App 完成人工性能核对并更新 `performance-large-walls.md`。
