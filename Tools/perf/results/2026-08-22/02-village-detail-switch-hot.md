# 02 Village Detail 切换/筛选（hot）

操作：保持匿名详情页热状态，重复 home/builder、搜索和状态筛选回放。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 10.356124s | 10.350237s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost 投影/图片指标 | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

结论：筛选动作可回放，但完整展开/收起和人工滚轮仍未完成。
