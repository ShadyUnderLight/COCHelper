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

## 最新自动化回放检查点

2026-08-20 已基于 `d3b57e8164f81e292a023b052e455085565c3dbb` 与
`7043c178cab9868a09b2102f4c478689edeef7a3` 分别构建 Release App，并在隔离的
`CFFIXED_USER_HOME` 中使用匿名 fixture 做了 partial/proxy AX replay。结果见
`Tools/perf/results/2026-08-20/`。

这批结果不是 #209 五个固定 workload 的同场景回放，也不是最终 Release 验收门：
实际操作与未覆盖项见 `Tools/perf/results/2026-08-20/replay_protocol.md`。
本轮使用 Accessibility 的 `AXScrollToTop/AXScrollToBottom` 做外层列表的确定性
往返，未覆盖人工连续滚轮/拖动、场景 2 的筛选/展开收起、场景 3 的各面板、场景 4
的 war/raid 分页或场景 5 的横向阶梯滚动，也没有把 Allocations/VM Tracker 和
Time Profiler 前三热点作为已证明数据。之后 `origin/main` 已推进到
`f310e5ed133424ac3caf6c8ba9569d672c0f5f60`；本 PR 已 rebase 到该最新 base，
但没有把这批旧 checkpoint 冒充成 `f310e5e` 的新测量。未完成项必须保持 unknown，
不能勾选上面的最终验收清单。

## 2026-08-22 Release 回放

Tools/perf/results/2026-08-22/ 记录了 d3b57e8 与 2026-08-22 采样时主线上的
post checkpoint 98a2d1a 的匿名
Release 回放矩阵。该批数据补齐了大部分 Animation Hitches trace 的
duration 和导出行数，但仍使用 Accessibility 分页动作，且 OSSignpost、
Allocations、60s tick、导入/manual/pagination 的独立证据为 unknown。
因此本 README 的最终验收清单继续保持未勾选；详见
2026-08-22/README.md 与 2026-08-22/replay_protocol.md。
