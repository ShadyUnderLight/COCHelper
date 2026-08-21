# 03 Upgrade Overview（cold）

操作：首次进入升级总览，回放 active/pending 汇总列表上下分页。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 10.353947s | 10.342255s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost overview/projection | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

结论：没有从该 AX 回放证明性能改善；各面板独立触发源仍未知。

post 另有 10.310387s Time Profiler 诊断样本（不是本 cold trace 的配对样本），raw top 为 objc_msgSend 59、specialized find1<A>(_:key:filter:) 53、EnvironmentPropertyKey metadata 39；样本受 Accessibility 回放污染，不能归因。
