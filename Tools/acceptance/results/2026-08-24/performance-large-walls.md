# Issue #226：1000+ 城墙 Release 性能验收记录

状态：**待人工 Release App 验收**

## 固定信息

- commit: `83fd27c`（lastSeenAt/latestCheckedAt 跨 final restart + paired 1005 raw workload 单 row fail-closed，基于 `origin/main@256c065`）
- fixture（paired，1005 段 raw workload + fail-closed Diff 路径）：
  - `perf_account_snapshot_large_walls_before.json`（1005 段全 `Lv1`，`#LARGEWALL01` 合法，同 lineage baseline）
  - `perf_account_snapshot_large_walls_after.json`（1005 段全 `Lv12`，同 tag 同 lineage，raw histogram 偏移 1005；无 verified coverage 时 Diff 仅产生 1 个 `unknownChange`（`oldQuantity 1005 → newQuantity 1005，impact 1`）的 `insufficientCoverage` 结果，而非 1005 个 confirmed changes）
  - 单文件 `perf_account_snapshot_large_walls.json`（`#PERF-LARGE-WALLS` hyphen 保留仅为兼容旧测试，不用于 history 场景）
- tag: `#LARGEWALL01`（合法 synthetic，`OfficialPlayerTagValidator.isValid`）
- 城墙段数: 1005 / 1005（全量极值，Diff 单 change 验证 1005 输入规模）
- 生成：`python3 Tools/acceptance/generate_large_walls_fixture.py`（写 Tests Fixtures，含 single + paired，before=Lv1/after=Lv12）
- macOS: 待填写
- Release build: `scripts/build_app.sh` 产出 `.build/COCHelper.app`
- 加载方式：**账号数据页两步粘贴**（先 before 再 after，同村同 tag，产生非 duplicate `unknownChange` Diff；见 `large_walls_perf_scenario.md`）— 单次粘贴仅 baseline，无法稳定复现场景 3

> 注：#259 已移除用户可见的 Snapshot History 时间线 UI（含可展开 row、category filter）。性能验证改为导入/Diff 计算/重启恢复路径，由 `acceptance-runner` 做 headless 校验。

## 场景结果（人工填写）

| # | 场景 | 卡顿 | 内存异常 | UI 状态漂移 | 备注 |
|---|---|---|---|---|---|
| 1 | Village Detail 滚动 | 待测 | 待测 | 待测 | |
| 2 | 导入性能（before/after） | 待测 | 待测 | 待测 | |
| 3 | Diff 计算（大量 Wall） | 待测 | 待测 | 待测 | |
| 4 | today/7/30 切换 | 待测 | 待测 | 待测 | |
| 5 | 重启恢复 | 待测 | 待测 | 待测 | |

## 操作步骤

见 `Tools/acceptance/large_walls_perf_scenario.md`。

## 结论

- 自动化 fixture 契约已通过；Release UI 交互性能**尚未在本 PR 中记录人工结论**。
- 若人工验收无问题，将上表「待测」改为「无」并勾选通过。
