# 04 partial/proxy AX replay：Account Data 外层列表

## 回放条件

- 匿名账号快照、官方玩家空态、部落、war log/raid 多页 seed 已加载。
- 进入 Account Data，进行主列表 top/bottom 往返；分页加载没有单独触发，因此不等价于 #209 场景 4。

## 覆盖边界

- 实际覆盖：进入 Account Data、外层列表 `AXScrollToBottom/AXScrollToTop` ×3。
- 未覆盖：war/raid 分页触发、分页后滚动、独立触发源和分页内存观测。

## 观测指标

| 指标 | baseline `d3b57e8` | post `7043c178` | 证据/边界 |
|---|---:|---:|---|
| Animation Hitch | 50 | 81 | `hitches` 表；post 为 `7043c178`，自动化回放 |
| 最长 hitch | 16.67 ms | 33.33 ms | 同上 |
| `VillageItemState.preferredAssetURLs` | 7 次，最大 0.047 ms，平均 0.036 ms | 未观测 | `os-signpost` |
| `NSImage.contentsOf` | 5 次，最大 1.737 ms，平均 1.127 ms | 未观测 | `os-signpost` |
| war/raid 分页加载 | unknown | unknown | 未单独触发 |
| Allocations/VM Tracker | unknown | unknown | 本轮未采集 |

## 结论

两侧 hitch 数量和图片 signpost 不足以说明分页、缓存或账号卡片性能变化；分页和内存指标保持 `unknown`。
