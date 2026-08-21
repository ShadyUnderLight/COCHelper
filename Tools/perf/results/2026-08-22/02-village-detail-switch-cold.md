# 02 Village Detail 切换/筛选（cold）

操作：首次回放 home/builder 切换、搜索“超级”、状态筛选和详情列表滚动。末尾分页动作未完整执行，标记为 partial。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 10.339222s | 10.343382s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost 投影/图片指标 | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

结论：这是部分交互回放，不满足最终场景 2 验收。
