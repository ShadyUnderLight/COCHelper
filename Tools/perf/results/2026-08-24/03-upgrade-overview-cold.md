# 03 Upgrade Overview 多面板（cold）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：匿名 fixture，默认窗口约 871x820。
- scenario state：首次进入 Upgrade Overview 后进行真实上下拖动。
- workload status：`partial`；active/pending/recently completed/attention 未逐面板各采样 10 秒。
- raw trace status：TOC、hitches 和 frame-lifetime 可导出。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 10.645011s | 10.589851s |
| `hitches` rows | 0 | 0 |
| `hitches-frame-lifetimes` rows | 1382 | 1945 |
| `os-signpost-interval` rows | 0 | 0 |
| Time Profiler / custom signpost / memory | unknown | unknown |
