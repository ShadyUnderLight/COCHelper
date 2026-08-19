# Issue #209 性能基线结果（2026-08-19）

基线：`origin/main@d3b57e8164f81e292a023b052e455085565c3dbb`。5 个固定场景 × 冷/热，共 10 份采样文档（`Tools/perf/results/2026-08-19/`）。

## 采样状态清单

| 场景 | 冷启动/首次进入 | 热缓存再次滚动 |
|---|---|---|
| 01 Village Detail 全部分类滚动 | ☐ | ☐ |
| 02 Village Detail 切换基地/筛选/展开收起 | ☐ | ☐ |
| 03 Upgrade Overview 各面板 | ☐ | ☐ |
| 04 Account Data（含 war/raid 多页） | ☐ | ☐ |
| 05 窄窗口横向阶梯滚动 | ☐ | ☐ |

> 每份文档的「原始指标摘要」含 60s tick / 导入变化 / manual action / 分页加载独立行——
> 这些触发源必须单独采样，不得与滚动混成一个数字（#209 要求，见 perf_scenarios.md「记录要求」）。

## 说明
- 模板字段结构见 `Tools/perf/baseline_format.md`；场景操作见 `Tools/perf/perf_scenarios.md`；冷/热操作步骤已按采样拆分到各文档。
- 采样完成后：每份文档回链 #196/#209；后续 #210/#211/#212 合并后用同一 fixture/窗口/场景复测，结果追加到本目录并保持前后对比。
- 采样产物不得包含真实账号数据、token、cookie 或完整敏感 ID。
