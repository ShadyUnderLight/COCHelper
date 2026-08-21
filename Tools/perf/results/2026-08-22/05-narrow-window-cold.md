# 05 窄窗口阶梯滚动（cold）

操作：窗口实际缩至约 814x820，进入匿名 Village Detail 后执行上下分页回放。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 8.373565s | 8.356216s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost 投影/图片指标 | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

Time Profiler raw top frames（baseline）：objc_msgSend 9、<deduplicated_symbol> 9、SwiftUI DisplayList 相关 std::__1::function 8；这些样本受 Accessibility 回放污染，不能归因。
