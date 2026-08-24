# 02 Village Detail 切换/筛选（cold）

## Evidence metadata

- baseline exact SHA: d3b57e8164f81e292a023b052e455085565c3dbb；post exact SHA: 98a2d1a582f4d2dcb461e9d6e0b47d1ab41d4864
- environment/fixture: 见同目录 README 的固定环境；匿名村庄 fixture，包含 home/builder 状态、搜索“超级”和状态筛选控件。
- scenario state: cold 首次进入详情页后执行 home ↔ builder、搜索、状态筛选；历史/手动面板未形成完整配对。
- workload status: partial；末尾分页/完整展开收起和 canonical 每次切换后连续滚动 10 秒未完成。
- raw trace status: baseline/post Animation Hitches trace 已导出 TOC；交互路径部分完成，hitches 表各 0 行。

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
