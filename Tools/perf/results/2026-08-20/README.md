# Issue #209 Release 自动化回放检查点

状态：`observed-automated-replay`，不是最终验收结论。

## 固定信息

- baseline：`d3b57e8164f81e292a023b052e455085565c3dbb`（#200 合并后的主线）
- post（本次 checkpoint 实际测量）：`7043c178cab9868a09b2102f4c478689edeef7a3`
- PR base（已 rebase 的最新 `origin/main`）：`f310e5ed133424ac3caf6c8ba9569d672c0f5f60`
- macOS：26.6.2 (25G83)，arm64
- Swift：Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
- catalog fingerprint：`sha256:a024fe5be9c3edff5f1f7e4f5ceeb0c013d3714b98a17678a7a7dd7d7dd225ab`
- fixture：匿名 `home/builder/mixed/variant`、3 页 war log、3 页 capital raid
- 数据隔离：临时 `CFFIXED_USER_HOME`；没有读取或覆盖真实账号数据

## 采样方法

- 两个 commit 都构建了 Release App；Debug App 只用于加载匿名 seed。
- 使用 Instruments `Animation Hitches` 模板和 `os_signpost` instrument，单场景约 8 秒；
  该 checkpoint 的 post 版本固定为上面的 `7043c178`，不代表 PR base 的新测量。
- 使用 Accessibility `AXScrollToBottom` / `AXScrollToTop` 往返 3 次作为确定性回放。
- hitch 数量和时长来自 `hitches` 表；资源 signpost 数量和区间来自目标进程的 `os-signpost` 表。
- 原始 `.trace` 未提交仓库，导出的结果只保留计数、时长和数据规模。

## 场景索引

| 场景 | baseline | post | 结果 |
|---|---:|---:|---|
| Village Detail 全部分类 | 52 hitch | 208 hitch | [01-village-detail-scroll.md](01-village-detail-scroll.md) |
| Village Detail 基地切换 | 57 hitch | 73 hitch | [02-village-detail-switch.md](02-village-detail-switch.md) |
| Upgrade Overview | 0 hitch | 18 hitch | [03-upgrade-overview.md](03-upgrade-overview.md) |
| Account Data | 50 hitch | 81 hitch | [04-account-data.md](04-account-data.md) |
| 窄窗口 | 0 hitch | 25 hitch | [05-narrow-window.md](05-narrow-window.md) |

## 不能据此宣称的内容

- 这不是人工连续滚动，因此不能直接作为用户感知帧率结论。
- 本轮没有完成冷启动/热缓存的独立配对采样。
- 本轮没有提交 Allocations/VM Tracker 峰值内存和回收结果。
- Accessibility 驱动会出现在 Time Profiler 主线程样本中，因此前三热点不作为应用根因证据。
- 60 秒 tick、导入变化、manual action、war/raid 分页加载没有独立采样。
- 任何性能改善或回归结论保持 `unknown`，需要后续人工 Release trace 完成后再更新 #209。
