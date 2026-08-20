# 02 partial/proxy AX replay：Village 切换与外层列表

## 回放条件

- 先进入村庄 A，再切换建筑大师基地；随后进行 3 次 Accessibility 主列表 top/bottom 往返。
- 筛选和展开面板没有在本次 proxy replay 中运行；因此不等价于 #209 场景 2。

## 覆盖边界

- 实际覆盖：进入村庄 A、切换基地/村庄、外层列表 `AXScrollToBottom/AXScrollToTop` ×3。
- 未覆盖：搜索/状态筛选、历史面板展开收起、手动队列面板展开收起、独立触发源。

## 观测指标

| 指标 | baseline `d3b57e8` | post `7043c178` | 证据/边界 |
|---|---:|---:|---|
| Animation Hitch | 57 | 73 | `hitches` 表；post 为 `7043c178`，自动化回放 |
| 最长 hitch | 33.33 ms | 25.00 ms | 同上 |
| `VillageItemState.preferredAssetURLs` | 未观测 | 77 次，最大 0.046 ms，平均 0.015 ms | `os-signpost` |
| `NSImage.contentsOf` | 未观测 | 16 次，最大 3.850 ms，平均 1.586 ms | `os-signpost` |
| Projection signpost | 未观测 | 未观测 | 未触发可配对区间 |
| Allocations/VM Tracker | unknown | unknown | 本轮未采集 |

## 结论

观测值不能替代同条件人工冷/热采样；不据此宣称基地切换或 row/cache 改动已解决滚动问题。
