# Issue #209 Release 性能复测证据（2026-08-24）

状态：**partial，不能关闭 #209**。

本目录记录 baseline 与 post 在同一台 Mac、同一匿名 fixture 上的 Release 回放结果。五个场景都产生了可导出的 Animation Hitches trace，但 workload、窗口尺寸、OSSignpost 语义和 Allocations 证据仍有明确边界；本目录不把 trace 存入仓库，也不把空表解释成“没有卡顿”。

## 被测对象与环境

- baseline exact SHA：`d3b57e8164f81e292a023b052e455085565c3dbb`
- post exact SHA：`aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- catalog manifest fingerprint：`sha256:e431aea86ea22dae356bc9619375a88a147bde20c3e2ae8464089ea8f49a79ca`
- macOS：26.6.2 (25G83) / arm64
- Swift：Apple Swift 6.3.3
- fixture：匿名 `#ANONYMIZED`、`#PERF-MIXED`、`#PERF-BUILDER`、`#PERFCLAN`
- fixture manifest：home 516、builder 467、mixed 521、variant 516；war log 10/10/10；capital raid 6/6/5
- App：两个版本均使用独立 bundle ID、临时 `HOME/CFFIXED_USER_HOME/TMPDIR`；未读取真实账号 JSON、token、cookie 或完整敏感 ID
- 实测默认窗口：`871x820`；Scenario 05 的 resize 操作未成功改变边界，因此不能称为约 800pt canonical 窄窗口

## Animation Hitches 导出摘要

单元格格式为「实际 trace duration / `hitches` 表行数 / `hitches-frame-lifetimes` 行数 / `os-signpost-interval` 行数」。这些是导出表计数，不是跨场景性能结论；尤其空的 `hitches` 表不等于没有卡顿。

| 场景 | baseline cold | post cold | baseline hot | post hot |
|---|---:|---:|---:|---:|
| 01 Village Detail | 10.646984s / 0 / 1873 / 4 | 10.581561s / 0 / 1866 / 0 | 10.627812s / 0 / 973 / 0 | 10.575600s / 1 / 1908 / 14 |
| 02 切换/筛选 | 10.590860s / 125 / 1508 / 87 | 10.608569s / 0 / 1911 / 0 | 10.602059s / 112 / 1892 / 0 | 10.582009s / 0 / 1853 / 0 |
| 03 Upgrade Overview | 10.645011s / 0 / 1382 / 0 | 10.589851s / 0 / 1945 / 0 | 20.579648s / 0 / 2661 / 0 | 10.581393s / 0 / 1963 / 0 |
| 04 Account Data | 20.585725s / 0 / 2457 / 0 | 10.588109s / 0 / 1225 / 0 | 20.585336s / 294 / 1936 / 10 | 10.620133s / 0 / 0 / 0 |
| 05 窄窗口/横向拖动 | 20.612656s / 0 / 3821 / 0 | 20.576385s / 0 / 1511 / 4 | 20.578520s / 0 / 3667 / 0 | 20.569068s / 0 / 1874 / 0 |

Scenario 03 baseline hot、Scenario 04 baseline cold/hot、Scenario 05 两个版本使用了 20 秒工具窗口以保证物理拖动有机会发生；它们不是冻结协议要求的 10 秒正式样本。Scenario 04 post hot 的 trace 有 TOC，但没有 frame-lifetime 行，按 unknown 处理。

## Time Profiler / OSSignpost / 内存边界

- 可归因的代表性主线程样本：post Scenario 01 hot 的 `time-profile` 有 132 个 Main Thread rows；原始顶层栈前三为 `swift_retain` 14、`_platform_memmove` 12、`swift_release` 12。该样本包含 SwiftUI/工具驱动，仅作为原始热点记录，不能单独证明业务根因。
- 其它 trace 的 time-profile 行数和线程覆盖不一致；没有形成五场景均可比的前三主线程热点表，因此未勾选最终热点门禁。
- `os-signpost-interval` 中可见的是系统/框架 signpost；没有足够证据把它们映射为 `PerformanceSignpost` 的投影、图片候选或解码指标。应用自定义 signpost 保持 `unknown`。
- Allocations attach 与 launch 两种方式均跑满窗口但报告 `Failed to attach to target`；TOC 中没有 `allocations`/`vm-tracker` 数据表。峰值内存、短时分配和停止后回收保持 `unknown`。

## 独立触发源

详见 [triggers.md](triggers.md)。当前证据为：

- 60s tick：post 静止 65 秒 trace，TOC duration 108.558302 秒、end-reason 为 time limit、time-profile 314 rows；没有能单独标识 tick 回调的应用 signpost，因此仍为 partial/unknown。
- 导入变化：匿名 variant 文本已写入输入框并尝试解析；10.597896 秒 trace 的 time-profile 为 0 rows，未形成可归因证据。
- manual action：fixture 中没有可启动的“开始升级”按钮，动作投影因数量/覆盖/状态门禁不可启动，未伪造点击。
- 分页：war log 的“查看更多（再显示 10 条）”已实际触发，按钮索引从 51 变为 71；分页完成后的独立 10.589005 秒 trace 有 6 个 time-profile rows。capital raid 未单独完成。

## #209 验收状态

- [x] baseline/post exact SHA 与匿名隔离环境记录
- [x] 五个场景 cold/hot 均有实际 trace 尝试和逐场景文件
- [x] 部分真实指针拖动已完成，且与 Accessibility checkpoint 区分
- [x] 失败边界、空表和工具错误保留为 unknown/partial
- [ ] 五场景全部按 canonical workload 严格配对
- [ ] Scenario 05 约 800pt 窗口、建筑组卡内部横向阶梯和长中文换行
- [ ] OSSignpost 应用自定义事件与前三主线程热点完整可比
- [ ] Allocations/VM Tracker 有效样本
- [ ] tick、导入、manual、war/raid pagination 全部有可归因独立证据

因此本 PR 只能作为 final replay diagnostic evidence，必须使用 `Refs: #209`，不能使用 `Closes: #209`。

原始 `.trace` 仅保存在本机 `/var/folders/.../T/` 临时目录，不提交仓库。
