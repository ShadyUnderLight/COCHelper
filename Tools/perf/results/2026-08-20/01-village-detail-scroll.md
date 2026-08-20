# 01 partial/proxy AX replay：Village Detail 外层列表

## 回放条件

- Release App，村庄 A（`#ANONYMIZED`），家乡村庄，全部分类，默认排序。
- 3 次 Accessibility 主列表 top/bottom 往返；这是 proxy workload，不是 #209 固定场景的同场景回放。
- 默认窗口设置为 1180x820；本轮未把窗口几何作为可比指标导出。

## 覆盖边界

- 实际覆盖：进入匿名村庄 A、外层列表 `AXScrollToBottom/AXScrollToTop` ×3。
- 未覆盖：人工连续滚动、冷/热拆分、详情内建筑组卡横向滚动、独立触发源。

## 观测指标

| 指标 | baseline `d3b57e8` | post `7043c178` | 证据/边界 |
|---|---:|---:|---|
| Animation Hitch | 52 | 208 | `hitches` 表；post 为 `7043c178`，自动化回放，不能直接解释为用户帧率改善 |
| 最长 hitch | 33.33 ms | 75.00 ms | 同上 |
| `VillageItemState.preferredAssetURLs` | 未观测 | 223 次，最大 0.063 ms，平均 0.012 ms | `os-signpost` |
| Projection signpost | 未观测 | 未观测 | 该回放未触发可配对的 projection 区间 |
| Allocations/VM Tracker | unknown | unknown | 本轮未采集 |
| 主线程前三热点 | unknown | unknown | AX 驱动会污染样本，未作根因结论 |

## 结论

自动化回放中观测到 hitch 数量不同，但不足以证明 #210/#212 的用户可感知收益或根因变化。保留 `unknown`。
