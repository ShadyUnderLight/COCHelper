# 04 Account Data（cold）

## Evidence metadata

- baseline exact SHA: d3b57e8164f81e292a023b052e455085565c3dbb；post exact SHA: 98a2d1a582f4d2dcb461e9d6e0b47d1ab41d4864
- environment/fixture: 见同目录 README 的固定环境；匿名账号摘要、war log/capital raid fixture 已加载到隔离环境，但本 trace 未触发分页。
- scenario state: cold 为进程启动后的首次进入 Account Data；只回放账号摘要编辑区上下分页。
- workload status: partial；war log/capital raid 多页和 canonical 分页加载未执行；baseline trace 收尾失败。
- raw trace status: post trace 可导出 TOC、hitches 表 0 行；baseline trace 无有效 TOC，保持 unknown。

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
