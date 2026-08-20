# 03 partial/proxy AX replay：Upgrade Overview 外层列表

## 回放条件

- 3 个匿名 seed 村庄和 manual 状态已加载，进入 Upgrade Overview。
- 进行 3 次 Accessibility 主列表 top/bottom 往返；不等价于各 overview 面板分别滚动。

## 覆盖边界

- 实际覆盖：进入 Upgrade Overview、外层列表 `AXScrollToBottom/AXScrollToTop` ×3。
- 未覆盖：active/pending/recently-completed/attention 面板的独立滚动和独立触发源。

## 观测指标

| 指标 | baseline `d3b57e8` | post `7043c178` | 证据/边界 |
|---|---:|---:|---|
| Animation Hitch | 0 | 18 | `hitches` 表；post 为 `7043c178`，不是人工连续滚动 |
| 最长 hitch | 未观测 | 8.34 ms | 同上 |
| `VillageItemState.preferredAssetURLs` | 未观测 | 15 次，最大 0.051 ms，平均 0.031 ms | `os-signpost` |
| `NSImage.contentsOf` | 未观测 | 2 次，最大 0.942 ms，平均 0.806 ms | `os-signpost` |
| `UpgradeOverviewProjection.*` | 未观测 | 未观测 | 回放未触发可配对区间 |
| Allocations/VM Tracker | unknown | unknown | 本轮未采集 |

## 结论

post 回放出现 hitch 而 baseline 未出现，说明不能把本轮结果表述为性能改善；两者均需同一人工冷/热流程复测，当前结论为 `unknown`。
