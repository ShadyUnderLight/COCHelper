# 02 Village Detail 切换与筛选（cold）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：匿名 home/builder/mixed fixture，默认窗口约 871x820。
- scenario state：尝试进入 builder 后进行页面级真实拖动。
- workload status：`partial`；搜索、状态筛选、历史和 manual 面板完整配对未完成。
- raw trace status：TOC、hitches 和 frame-lifetime 可导出。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 10.590860s | 10.608569s |
| `hitches` rows | 125 | 0 |
| `hitches-frame-lifetimes` rows | 1508 | 1911 |
| `os-signpost-interval` rows | 87 | 0 |
| Time Profiler / custom signpost / memory | unknown | unknown |

这些计数不能作为前后性能结论，因为本轮没有完成协议规定的全部切换状态。
