# Issue #209 Release 回放证据（2026-08-22）

状态：**partial，不能作为关闭 #209 的最终验收**。

本目录记录同一匿名 fixture 在锁定基线和当前主线上的 Release App 回放。回放使用 Accessibility 分页动作驱动列表，未使用人工连续滚轮或拖动，因此只能作为可审计的诊断证据，不能宣称用户感知的滚动性能收益。

## 固定环境

- baseline：d3b57e8164f81e292a023b052e455085565c3dbb
- post：98a2d1a582f4d2dcb461e9d6e0b47d1ab41d4864
- catalog fingerprint：sha256:a024fe5be9c3edff5f1f7e4f5ceeb0c013d3714b98a17678a7a7dd7d7dd225ab
- macOS：26.6.2 (25G83) / arm64 / Apple Swift 6.3.3
- 默认窗口：约 1172x820；窄窗口：约 814x820
- fixture：匿名 #ANONYMIZED、#PERF-MIXED、#PERF-BUILDER、#PERFCLAN；UI 实际显示 2 个已导入村庄，#PERF-BUILDER 保留为等待导入占位
- fixture manifest 声明的数组规模：home 516、builder 467、mixed 521、variant 516；war log 10/10/10；capital raid 6/6/5

## Animation Hitches 结果

单元格格式为「trace duration / 导出的 hitches-frame-lifetimes 行数」。空表不代表其它指标为零；本轮统一标记为 unknown 的 OSSignpost 和内存指标见下文。

| 场景 | baseline cold | post cold | baseline hot | post hot |
|---|---:|---:|---:|---:|
| 01 Village Detail 全部滚动 | 10.333815s / 0 | 10.353092s / 0 | 10.341096s / 0 | 10.349403s / 0 |
| 02 Village Detail 切换/筛选 | 10.339222s / 0（部分回放） | 10.343382s / 0（部分回放） | 10.356124s / 0 | 10.350237s / 0 |
| 03 Upgrade Overview | 10.353947s / 0 | 10.342255s / 0 | 10.366453s / 0 | 10.349946s / 0 |
| 04 Account Data | unknown（trace 收尾失败） | 8.360041s / 0 | 8.348515s / 0 | 8.329135s / 0 |
| 05 窄窗口 | 8.373565s / 0 | 8.356216s / 0 | 8.368044s / 0 | 8.353113s / 0 |

这里的 0 只表示导出的 hitch 表没有行；xctrace 同时报告了 logging archive 错误，所以不能从这批回放推导“没有卡顿”或“性能已改善”。

## 其它指标覆盖

- Time Profiler：post 的场景 01、03、05 和 baseline 的窄窗口回放有可导出样本；前三 raw frame 主要包含 Accessibility/SwiftUI 和工具驱动调用，不能归因到业务根因。
- OSSignpost：有效 trace 的 os-signpost-interval 导出没有可核对行，投影/候选探测/图片解码调用数和耗时为 unknown。
- Allocations / VM Tracker：未形成有效样本；Allocations 触发了系统管理员授权提示，未输入凭据。
- 峰值内存、短时分配、停止后回收、60s tick、导入变化、manual action、war/raid 分页：unknown，本轮未混入滚动数字。
- 物理连续滚轮/拖动、场景 2 完整展开/收起配对和场景 4 分页加载：未完成，不能勾选为最终验收。

逐场景记录：

- 01-village-detail-scroll-cold.md / 01-village-detail-scroll-hot.md
- 02-village-detail-switch-cold.md / 02-village-detail-switch-hot.md
- 03-upgrade-overview-cold.md / 03-upgrade-overview-hot.md
- 04-account-data-cold.md / 04-account-data-hot.md
- 05-narrow-window-cold.md / 05-narrow-window-hot.md

采样协议和失败边界见 replay_protocol.md。原始 .trace 仅保存在本机临时目录，不提交仓库。
