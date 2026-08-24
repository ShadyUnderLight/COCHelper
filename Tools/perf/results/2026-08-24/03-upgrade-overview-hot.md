# 03 Upgrade Overview 多面板（hot）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：沿用 cold 的匿名 fixture、页面和窗口。
- scenario state：热缓存后重复页面级真实上下拖动。
- workload status：`partial`；baseline trace 使用 20 秒工具窗口，且未完成四面板配对；post 为 10 秒但仍未逐面板覆盖。
- raw trace status：TOC、hitches 和 frame-lifetime 可导出。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 20.579648s | 10.581393s |
| `hitches` rows | 0 | 0 |
| `hitches-frame-lifetimes` rows | 2661 | 1963 |
| `os-signpost-interval` rows | 0 | 0 |
| Time Profiler / custom signpost / memory | unknown | unknown |
