# 05 窄窗口建筑组卡横向拖动（hot）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：沿用 cold 的匿名页面；实际窗口仍约 871x820。
- scenario state：热缓存后重复真实横向指针拖动。
- workload status：`partial`；未达到约 800pt，未证明长中文名称换行和内部阶梯的完整配对；工具窗口为 20 秒。
- raw trace status：TOC、hitches 和 frame-lifetime 可导出。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 20.578520s | 20.569068s |
| `hitches` rows | 0 | 0 |
| `hitches-frame-lifetimes` rows | 3667 | 1874 |
| `os-signpost-interval` rows | 0 | 0 |
| Time Profiler / custom signpost / memory | unknown | unknown |
