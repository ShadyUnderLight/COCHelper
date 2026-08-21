# 04 Account Data（cold）

操作：首次进入账号数据页，回放账号摘要编辑区的上下分页。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | unknown（xctrace 收尾失败） | 8.360041s |
| Animation Hitches rows | unknown | 0 |
| 最长 hitch | unknown | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost/分页指标 | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

结论：baseline cold 没有有效 trace；场景 4 cold 不能做前后比较。
