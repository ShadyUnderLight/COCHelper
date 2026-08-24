# 02 Village Detail 切换与筛选（hot）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：沿用 cold 的匿名 fixture 和页面状态。
- scenario state：builder 页面热缓存后重复真实拖动。
- workload status：`partial`；未完成搜索/状态/展开收起的同条件动作序列。
- raw trace status：TOC、hitches 和 frame-lifetime 可导出。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 10.602059s | 10.582009s |
| `hitches` rows | 112 | 0 |
| `hitches-frame-lifetimes` rows | 1892 | 1853 |
| Longest detected hitch | 33.33ms | unknown |
| `os-signpost-interval` rows | 0 | 0 |
| Time Profiler / custom signpost / memory | unknown | unknown |
