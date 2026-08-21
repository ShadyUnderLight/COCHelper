# 05 窄窗口阶梯滚动（hot）

操作：保持约 814x820 窄窗口和热缓存，重复上下分页回放。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 8.368044s | 8.353113s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost 投影/图片指标 | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

Time Profiler raw top frames（post）：specialized find1<A>(_:key:filter:) 12、objc_msgSend 10、SwiftUI EnvironmentPropertyKey metadata 7；这些样本受 Accessibility 回放污染，不能归因。
