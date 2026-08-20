# 05 窄窗口：详情列表回放

## 回放条件

- Village Detail 建筑大师基地，窗口缩至约 800px 截图宽度后回放。
- 进行 3 次 Accessibility 主列表 top/bottom 往返；未单独驱动建筑组卡内部横向滚动。

## 观测指标

| 指标 | baseline `d3b57e8` | post `7043c178` | 证据/边界 |
|---|---:|---:|---|
| Animation Hitch | 0 | 25 | `hitches` 表；post 为 `7043c178`，不是人工连续滚动 |
| 最长 hitch | 未观测 | 8.33 ms | 同上 |
| `VillageItemState.preferredAssetURLs` | 未观测 | 115 次，最大 0.046 ms，平均 0.014 ms | `os-signpost` |
| 横向阶梯滚动 | unknown | unknown | 本轮未单独驱动 |
| Allocations/VM Tracker | unknown | unknown | 本轮未采集 |

## 结论

这批数据只能证明窄窗口自动化回放产生了可导出的 trace，不能证明横向阶梯滚动或中文换行的性能变化。
