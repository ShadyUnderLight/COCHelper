# 01 Village Detail 全部滚动（cold）

## Evidence metadata

- baseline exact SHA: d3b57e8164f81e292a023b052e455085565c3dbb；post exact SHA: 98a2d1a582f4d2dcb461e9d6e0b47d1ab41d4864
- environment/fixture: 见同目录 README 的固定环境；匿名 #ANONYMIZED，home/全部/分类名称。
- scenario state: cold 为进程启动后的首次进入详情页；本文件只记录首次进入段。
- workload status: partial；本 checkpoint 使用 Accessibility 分页，不是 canonical 连续滚轮/拖动 10 秒。
- raw trace status: baseline/post Animation Hitches trace 均可导出 TOC；hitches 表各 0 行；原始 trace 只保存在本机临时目录。

操作：Release App 首次进入 #ANONYMIZED Village Detail，默认 home/全部/分类名称，再执行上下分页回放。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 10.333815s | 10.353092s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost 投影/图片指标 | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

结论：本次自动化回放没有观察到 hitch 表行，但不构成性能改善结论；完整边界见 replay_protocol.md。

补充：post 另有 10.280848s Time Profiler 诊断样本（不是本 cold trace 的配对样本），raw top 为 objc_msgSend 45、deduplicated_symbol 36、specialized find1<A>(_:key:filter:) 35；样本受 Accessibility 回放污染，不能归因。
