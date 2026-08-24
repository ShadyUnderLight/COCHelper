# 04 Account Data（hot）

## Evidence metadata

- baseline exact SHA: d3b57e8164f81e292a023b052e455085565c3dbb；post exact SHA: 98a2d1a582f4d2dcb461e9d6e0b47d1ab41d4864
- environment/fixture: 见同目录 README 的固定环境；与 cold 使用同一匿名账号/war/raid fixture。
- scenario state: hot 从同一进程的账号摘要回放结束后开始；只回放摘要区上下分页。
- workload status: partial；war log/capital raid 多页、图片内存和分页触发源未执行。
- raw trace status: baseline/post Animation Hitches trace 均可导出 TOC；hitches 表各 0 行。

操作：保持账号数据页热状态，回放摘要区上下分页；war log/capital raid 分页触发未单独执行。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 8.348515s | 8.329135s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost/分页指标 | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

结论：没有分页、图片内存或 trigger-source 证据，不能宣称场景 4 已完成。
