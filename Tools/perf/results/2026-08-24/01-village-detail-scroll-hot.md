# 01 Village Detail 全部滚动（hot）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：与 cold 相同，默认窗口约 871x820。
- scenario state：沿用同一进程和页面状态重复真实指针上下拖动。
- workload status：`partial`；未形成完整 canonical 用户动作序列。
- raw trace status：TOC、hitches 和 frame-lifetime 可导出。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 10.627812s | 10.575600s |
| `hitches` rows | 0 | 1 |
| `hitches-frame-lifetimes` rows | 973 | 1908 |
| Longest detected hitch | unknown | 8.33ms |
| `os-signpost-interval` rows | 0 | 14 |
| Time Profiler / custom signpost / memory | unknown | custom前三热点见 README / memory unknown |

单个 hitches 行不直接等价于用户感知回归；动作和原始采样条件仍需最终 canonical rerun。
