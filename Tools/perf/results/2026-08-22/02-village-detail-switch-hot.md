# 02 Village Detail 切换/筛选（hot）

## Evidence metadata

- baseline exact SHA: d3b57e8164f81e292a023b052e455085565c3dbb；post exact SHA: 98a2d1a582f4d2dcb461e9d6e0b47d1ab41d4864
- environment/fixture: 见同目录 README 的固定环境；匿名村庄 fixture，home/builder、搜索“超级”、状态筛选。
- scenario state: hot 从同一进程的 cold 交互结束后开始，重复筛选路径。
- workload status: partial；未完成完整历史/手动面板展开收起、每次切换后的 canonical 连续滚动。
- raw trace status: baseline/post Animation Hitches trace 均可导出 TOC；hitches 表各 0 行。

操作：保持匿名详情页热状态，重复 home/builder、搜索和状态筛选回放。

| 指标 | baseline d3b57e8 | post 98a2d1a |
|---|---:|---:|
| Trace duration | 10.356124s | 10.350237s |
| Animation Hitches rows | 0 | 0 |
| 最长 hitch | 0（无导出行） | 0（无导出行） |
| Time Profiler >16.7ms 区间 | unknown | unknown |
| OSSignpost 投影/图片指标 | unknown | unknown |
| Allocations/VM Tracker | unknown | unknown |

结论：筛选动作可回放，但完整展开/收起和人工滚轮仍未完成。
