# 04 Account Data 与战争/突袭数据（hot）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：沿用 cold 的匿名账号、部落缓存和页面状态。
- scenario state：热缓存后重复页面级真实上下拖动；分页另行记录。
- workload status：`partial`；baseline 使用 20 秒工具窗口，post trace 没有 frame-lifetime 行，不能解释为 0。
- raw trace status：两版本 TOC 可导出；post frame 数据无效/为空。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 20.585336s | 10.620133s |
| `hitches` rows | 294 | 0 |
| `hitches-frame-lifetimes` rows | 1936 | 0（unknown，不是零帧） |
| `os-signpost-interval` rows | 10 | 0 |
| Time Profiler / custom signpost / memory | unknown | unknown |
