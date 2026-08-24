# 04 Account Data 与战争/突袭数据（cold）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：匿名账号和 `#PERFCLAN` 缓存，默认窗口约 871x820。
- scenario state：首次进入 Account Data 后进行页面级真实上下拖动。
- workload status：`partial`；war log/capital raid 多页滚动未混入本 trace，分页见 triggers.md。
- raw trace status：baseline cold 使用 20 秒工具窗口；post cold 使用 10 秒；TOC 和 frame-lifetime 可导出。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 20.585725s | 10.588109s |
| `hitches` rows | 0 | 0 |
| `hitches-frame-lifetimes` rows | 2457 | 1225 |
| `os-signpost-interval` rows | 0 | 0 |
| Time Profiler / custom signpost / memory | unknown | unknown |
