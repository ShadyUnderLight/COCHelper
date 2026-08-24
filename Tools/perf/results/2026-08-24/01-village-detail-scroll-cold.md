# 01 Village Detail 全部滚动（cold）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：见 README；匿名 fixture，默认窗口约 871x820。
- scenario state：首次进入匿名 Village Detail，尝试覆盖主内容上下真实指针拖动。
- workload status：`partial`；未证明完整 10 秒连续用户滚动和所有建筑组卡覆盖。
- raw trace status：两版本 TOC、hitches 和 frame-lifetime 可导出；OSSignpost 仅记录系统 interval。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 10.646984s | 10.581561s |
| `hitches` rows | 0 | 0 |
| `hitches-frame-lifetimes` rows | 1873 | 1866 |
| `os-signpost-interval` rows | 4 | 0 |
| Time Profiler / custom signpost / memory | unknown | unknown |

空 hitches 表不解释为无卡顿或性能改善。
