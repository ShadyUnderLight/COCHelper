# 03 Upgrade Overview（hot）

## Evidence metadata

- baseline exact SHA: d3b57e8164f81e292a023b052e455085565c3dbb；post exact SHA: 98a2d1a582f4d2dcb461e9d6e0b47d1ab41d4864
- environment/fixture: 见同目录 README 的固定环境；与 cold 使用同一匿名 fixture 和同一已导入村庄状态。
- scenario state: hot 从同一进程的 cold 列表回放结束后开始；只重复 active/pending 汇总列表。
- workload status: partial；recently completed/attention 面板和 canonical 每面板 10 秒未执行。
- raw trace status: baseline/post Animation Hitches trace 均可导出 TOC；hitches 表各 0 行。

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
