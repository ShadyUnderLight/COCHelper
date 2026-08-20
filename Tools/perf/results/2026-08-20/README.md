# Issue #209 partial/proxy AX replay checkpoint

状态：`observed-partial-proxy-ax-replay`，不是 #209 固定 workload，也不是最终验收结论。

## 固定信息

- baseline：`d3b57e8164f81e292a023b052e455085565c3dbb`（#200 合并后的主线）
- post（本次 checkpoint 实际测量）：`7043c178cab9868a09b2102f4c478689edeef7a3`
- PR base（已 rebase 的最新 `origin/main`）：`f310e5ed133424ac3caf6c8ba9569d672c0f5f60`
- macOS：26.6.2 (25G83)，arm64
- Swift：Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
- catalog fingerprint：`sha256:a024fe5be9c3edff5f1f7e4f5ceeb0c013d3714b98a17678a7a7dd7d7dd225ab`
- fixture：匿名 `home/builder/mixed/variant`、3 页 war log、3 页 capital raid
- 数据隔离：临时 `CFFIXED_USER_HOME`；没有读取或覆盖真实账号数据
- baseline fixture manifest SHA-256：`ed7100e4cd9f18fd3ba0df3b18a205baab84041bb4eb13af7dd7e2c1c6d1b33d`
- post fixture manifest SHA-256：`08f9da290bacf23095ad8d686dff1de28146735b912bca71fbe56c6cec5a0acb`
- baseline/post fixture blob index SHA-256：`acbc0c9e28bbead274eac0d88c5962e0091631544af7c71c61966c7763c70461`

## Fixture dataScale

以下是 `perf_fixtures_manifest.json` 的完整 dataScale；baseline/post 的 blob index
相同，manifest SHA 差异来自协议元数据而不是 fixture JSON 数量变化。

| fixture | items |
|---|---:|
| `perf_account_snapshot_home` | 516 |
| `perf_account_snapshot_builder` | 467 |
| `perf_account_snapshot_mixed` | 521 |
| `perf_account_snapshot_variant` | 516 |
| `perf_war_log_page_01` | 10 |
| `perf_war_log_page_02` | 10 |
| `perf_war_log_page_03` | 10 |
| `perf_capital_raid_page_01` | 6 |
| `perf_capital_raid_page_02` | 6 |
| `perf_capital_raid_page_03` | 5 |

## Display and window record

- 默认窗口：`1180x820`。
- 窄窗口：历史记录只有约 `800px` 截图宽度，未保留精确窗口 bounds；场景 05
  因此只能作为 proxy observation，不能作为窄窗口固定基线。
- 采样主机显示配置：内置主屏当前模式 `3456x2234 @ 120Hz`；外接 `Q27B3`
  为 `2560x1440 @ 75Hz`。历史 trace 未保留窗口所在显示器绑定，不能把两者混成
  单一刷新率门禁。

## 采样方法与可复现性边界

- 两个 commit 都构建了 Release App；Debug App 只用于加载匿名 seed。
- 使用 Instruments `Animation Hitches` 模板和 `os_signpost` instrument，配置
  `--time-limit 8s`；历史 raw trace 删除后没有保留每个 trace 的 `trace-toc`
  实际 duration，因此这里不把 8 秒配置值冒充实际 duration。
- 使用 Accessibility `AXScrollToBottom` / `AXScrollToTop` 往返 3 次作为 proxy replay；
  历史记录没有保留每个 AX action 的 wall-clock 间隔，不能声称 bit-for-bit 重放。
- 完整的实际覆盖、遗漏项和新的可重跑 action protocol 见
  [`replay_protocol.md`](replay_protocol.md)。该 protocol 要求下一次采样同时保存
  `trace-toc` 的 `<duration>`、窗口 bounds 和显示刷新率。
- hitch 数量和时长来自 `hitches` 表；资源 signpost 数量和区间来自目标进程的 `os-signpost` 表。
- 原始 `.trace` 未提交仓库，导出的结果只保留计数、时长和数据规模。

## Checkpoint workload 索引（不是 #209 固定场景索引）

| proxy checkpoint | 实际操作 | 明确未覆盖 | 结果 |
|---|---|---|---|
| 01 Village Detail outer-list AX replay | 进入匿名村庄 A；外层列表 top/bottom ×3 | 人工连续滚动、冷/热拆分、详情内横向滚动 | [01-village-detail-scroll.md](01-village-detail-scroll.md) |
| 02 Village switch + outer-list AX replay | 进入村庄 A，切换基地/村庄后外层列表 top/bottom ×3 | 搜索/状态筛选、历史/手动队列展开收起 | [02-village-detail-switch.md](02-village-detail-switch.md) |
| 03 Upgrade Overview outer-list AX replay | 进入总览，外层列表 top/bottom ×3 | active/pending/completed/attention 各面板独立滚动 | [03-upgrade-overview.md](03-upgrade-overview.md) |
| 04 Account Data outer-list AX replay | 进入账号数据，外层列表 top/bottom ×3 | war/raid 分页加载与分页后滚动 | [04-account-data.md](04-account-data.md) |
| 05 Narrow-window outer-list AX replay | 详情页约 800px 窄窗口，外层列表 top/bottom ×3 | 精确窗口 bounds、建筑组卡横向阶梯滚动 | [05-narrow-window.md](05-narrow-window.md) |

## 不能据此宣称的内容

- 这不是人工连续滚动，因此不能直接作为用户感知帧率结论。
- 本轮没有完成冷启动/热缓存的独立配对采样。
- 本轮没有提交 Allocations/VM Tracker 峰值内存和回收结果。
- Accessibility 驱动会出现在 Time Profiler 主线程样本中，因此前三热点不作为应用根因证据。
- 60 秒 tick、导入变化、manual action、war/raid 分页加载没有独立采样。
- 任何性能改善或回归结论保持 `unknown`，需要后续人工 Release trace 完成后再更新 #209。
