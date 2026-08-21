# 04 Account Data（hot）

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
