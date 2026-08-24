# 05 窄窗口阶梯滚动（cold）

## Evidence metadata

- baseline exact SHA: d3b57e8164f81e292a023b052e455085565c3dbb；post exact SHA: 98a2d1a582f4d2dcb461e9d6e0b47d1ab41d4864
- environment/fixture: 见同目录 README 的固定环境；匿名 #ANONYMIZED，窗口实际约 814x820。
- scenario state: cold 为窄窗口首次进入 Village Detail，home/全部/分类名称。
- workload status: partial；本 checkpoint 使用 Accessibility top/bottom，不是 canonical 横向阶梯滚动和长中文名称人工滚动 10 秒。
- raw trace status: baseline/post Animation Hitches trace 均可导出 TOC；hitches 表各 0 行。

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
