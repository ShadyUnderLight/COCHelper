# 03 Upgrade Overview（hot）

操作：保持升级总览热缓存，重复上下分页回放。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 10.366453s | 10.349946s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost overview/projection | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

结论：没有从该 AX 回放证明性能改善。

post Time Profiler 诊断样本的 raw top 为 objc_msgSend 59、specialized find1<A>(_:key:filter:) 53、EnvironmentPropertyKey metadata 39；样本受 Accessibility 回放污染，不能归因。
