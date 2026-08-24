# 05 窄窗口建筑组卡横向拖动（cold）

## Evidence metadata

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- environment/fixture：匿名 Village Detail；实际窗口仍约 871x820，resize 未成功。
- scenario state：建筑组列表区域发送真实横向指针拖动，尝试覆盖组卡内容。
- workload status：`partial`；不是约 800pt 窄窗口，未证明建筑组卡内部阶梯和长中文换行完整覆盖；工具窗口为 20 秒。
- raw trace status：TOC、hitches 和 frame-lifetime 可导出。

| 指标 | baseline | post |
|---|---:|---:|
| Trace duration | 20.612656s | 20.576385s |
| `hitches` rows | 0 | 0 |
| `hitches-frame-lifetimes` rows | 3821 | 1511 |
| Longest detected hitch | unknown | unknown |
| `os-signpost-interval` rows | 0 | 4 |
| Time Profiler / custom signpost / memory | unknown | unknown |

真实横向拖动不等于已满足窄窗口 canonical workload；尺寸和内部滚动目标仍是验收缺口。
