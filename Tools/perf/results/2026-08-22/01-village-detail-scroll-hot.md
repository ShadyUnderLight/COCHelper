# 01 Village Detail 全部滚动（hot）

操作：cold 回放结束后保持详情页和匿名 fixture，执行上下分页回放。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 10.341096s | 10.349403s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost 投影/图片指标 | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

结论：没有从当前回放证明前后差异；不可把 AX 回放的空 hitch 表当作用户感知结论。

post Time Profiler 诊断样本的 raw top 为 objc_msgSend 45、deduplicated_symbol 36、specialized find1<A>(_:key:filter:) 35；样本受 Accessibility 回放污染，不能归因。
