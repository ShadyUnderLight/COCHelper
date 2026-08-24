# Issue #226：1000+ 城墙 Release 性能验收记录

状态：**待人工 Release App 验收**

## 固定信息

- commit: `3a25e98`（含 A1/B1 → 共同 restart → A2/B2 交错、duplicate 严格 +1、B restart 对称校验、paired large-wall 修复，基于 `origin/main@256c065`）
- fixture（paired，history 大变化 row）：
  - `perf_account_snapshot_large_walls_before.json`（1005 段，`#LARGEWALL01` 合法，同 lineage baseline）
  - `perf_account_snapshot_large_walls_after.json`（1005 段，同 tag 同 lineage，`lvl` 偏移 6，确保大量 Wall 等级变化）
  - 单文件 `perf_account_snapshot_large_walls.json`（`#PERF-LARGE-WALLS` hyphen 保留仅为兼容旧测试，不用于 history 场景）
- tag: `#LARGEWALL01`（合法 synthetic，`OfficialPlayerTagValidator.isValid`）
- 城墙段数: 1005 / 1005（逐段 `cnt: 1`，等级分布位移）
- 生成：`python3 Tools/acceptance/generate_large_walls_fixture.py`（写 Tests Fixtures，含 single + paired）
- macOS: 待填写
- Release build: `scripts/build_app.sh` 产出 `.build/COCHelper.app`
- 加载方式：**账号数据页两步粘贴**（先 before 再 after，同村同 tag，产生可展开的大变化 row；见 `large_walls_perf_scenario.md`）— 单次粘贴仅 baseline，无法稳定复现场景 3

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
