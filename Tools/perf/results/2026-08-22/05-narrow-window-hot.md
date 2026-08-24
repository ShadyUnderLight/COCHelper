# 05 窄窗口阶梯滚动（hot）

## Evidence metadata

- baseline exact SHA: d3b57e8164f81e292a023b052e455085565c3dbb；post exact SHA: 98a2d1a582f4d2dcb461e9d6e0b47d1ab41d4864
- environment/fixture: 见同目录 README 的固定环境；与 cold 使用同一匿名 fixture 和约 814x820 窄窗口。
- scenario state: hot 从同一进程的 cold 窄窗口回放结束后开始，重复上下分页。
- workload status: partial；未执行 canonical 横向阶梯滚动、长中文名称换行和人工连续滚动 10 秒。
- raw trace status: baseline/post Animation Hitches trace 均可导出 TOC；hitches 表各 0 行。

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
