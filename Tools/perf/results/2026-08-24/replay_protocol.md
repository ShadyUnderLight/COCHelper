# Issue #209 Final replay protocol

## 固定命令

正式 canonical 采样窗口固定为 10 秒，Animation Hitches 与 Time Profiler 使用同一个变量：

```bash
TRACE_SECONDS=10s
xcrun xctrace record --template 'Animation Hitches' --instrument os_signpost \
  --attach "$PID" --time-limit "$TRACE_SECONDS" --output "$TRACE" --no-prompt
xcrun xctrace record --template 'Time Profiler' \
  --attach "$PID" --time-limit "$TRACE_SECONDS" --output "$TRACE" --no-prompt
```

每个 trace 必须先用 `xcrun xctrace export --toc` 核验 duration/end-reason，再导出 `hitches`、`hitches-frame-lifetimes`、`os-signpost-interval` 或 `time-profile`。xctrace 的退出码和 logging archive 错误都不能直接当作业务指标。

## Canonical cold/hot 定义

- cold：同一 commit 下新启动 Release App，使用新临时 HOME 和匿名 seed；首次进入目标页面前 attach。
- hot：沿用 cold 的同一进程、fixture、窗口和页面状态；cold workload 后空闲 5 秒，不重新导入、不重启。
- setup、导航、fixture seed、窗口 resize 不计入正式 10 秒 workload。
- baseline/post 必须使用相同动作序列和相同起止状态。

## 场景动作

1. Village Detail home/全部/默认排序，连续上下滚动 10 秒。
2. home ↔ builder、搜索/状态筛选、历史与 manual 面板展开/收起；每个状态切换后按固定顺序滚动 10 秒。
3. Upgrade Overview 的 active、pending、recently completed、attention 面板各滚动 10 秒。
4. Account Data 摘要、官方玩家、部落、战争、war log 和 capital raid；分页加载单独开 trace。
5. 窗口约 800pt 宽，建筑组卡内部横向阶梯滚动，覆盖长中文名称换行 10 秒。

## 本轮实际偏差

- 真实指针拖动通过 Computer Use 完成；它不是 AX top/bottom checkpoint，但部分场景只完成了页面级上下/横向拖动，未完成完整 canonical 状态序列。
- Scenario 05 resize 未命中 macOS resize handle，实测仍为 871x820；因此不宣称窄窗口验收完成。
- 为避免物理拖动在 UI 工具切换时丢失，部分 baseline/post trace 使用了 20 秒窗口；这些 trace 只保留为 partial diagnostic evidence。
- Scenario 04 post hot 具备 TOC 但没有 frame-lifetime 行；不得解释为 0。
- Allocations/VM Tracker attach 和 launch 都没有形成有效数据表。

## 本轮实际 partial pointer sequence

以下是实际执行过的工具动作，不是对 canonical 用户操作的追述：

- Scenario 01：主内容重复 `drag (520,640) → (520,180)`，等待约 500ms，再 `drag (520,180) → (520,640)`，等待约 500ms；10 秒 post helper 重复 5 轮。baseline helper 使用同一垂直轨迹但等待和轮数存在差异。
- Scenario 02：先尝试切换到 builder（post 使用 sidebar builder 坐标约 `(72,140)`），随后执行 Scenario 01 的垂直拖动；搜索、状态筛选、历史/manual 展开收起没有形成完整配对。
- Scenario 03：先尝试进入 Upgrade Overview（post 使用 sidebar 坐标约 `(72,289)`），随后执行 Scenario 01 的垂直拖动；没有分别锁定四个面板各 10 秒。
- Scenario 04：先尝试进入 Account Data（post 使用 sidebar 坐标约 `(72,347)`），随后执行 Scenario 01 的垂直拖动；war/raid 分页不在该滚动 trace 内。
- Scenario 05：建筑组内容区域重复 `drag (650,520) → (240,520)`，等待约 650ms，再反向拖动，等待约 650ms；20 秒 helper 重复 7 轮。resize 未命中，实际窗口仍为 871x820。

这些动作序列及其导出表的 durable 副本见 [trace_manifest.md](trace_manifest.md)；不能据此把本轮结果提升为 canonical before/after benchmark。

## 独立触发

60s tick、导入变化、manual action、war log/capital raid pagination 必须各自独立开 trace，不与滚动 workload 合并。当前执行结果见 [triggers.md](triggers.md)，未完成项保持 unknown。
