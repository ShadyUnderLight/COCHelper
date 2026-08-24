# Issue #209 回放协议与边界

## 构建与隔离

1. 在 /private/tmp/cochelper-base-d3 detached worktree 构建 d3b57e8 Release App。
2. 用唯一 bundle ID 和临时 HOME/CFFIXED_USER_HOME 加载 Debug 性能样本，再用相同 bundle ID 的 Release App 测量。
3. post checkpoint 使用本 worktree 的 Release App，采样时主线 commit 为 98a2d1a；之后 main 已继续推进，本目录不把该 checkpoint 改写成新 main。
4. 两个版本都只加载匿名 fixture；没有读取真实账号 JSON、token、cookie 或完整敏感 ID。

## 2026-08-22 AX checkpoint commands（历史实际命令）

Animation Hitches：

    xcrun xctrace record --template 'Animation Hitches' --instrument os_signpost --attach "$PID" --time-limit 8s --output "$TRACE" --no-prompt

Time Profiler：

    xcrun xctrace record --template 'Time Profiler' --attach "$PID" --time-limit 8s --output "$TRACE" --no-prompt

以上 8 秒命令是本目录已经记录的数据实际使用的命令；不要把历史 trace 解释成 10 秒采样。

## Final canonical rerun commands

正式 rerun 的 workload 和 Instruments 采样窗口都固定为 10 秒：

    TRACE_SECONDS=10s
    xcrun xctrace record --template 'Animation Hitches' --instrument os_signpost --attach "$PID" --time-limit "$TRACE_SECONDS" --output "$TRACE" --no-prompt
    xcrun xctrace record --template 'Time Profiler' --attach "$PID" --time-limit "$TRACE_SECONDS" --output "$TRACE" --no-prompt

每个 trace 先用 xcrun xctrace export --toc 验证 duration/end-reason，再导出 hitches-frame-lifetimes、os-signpost-interval 或 time-profile。xctrace 过程会报告 Fatal logging system error: The log archive is corrupt or incomplete and cannot be read，但只要 trace 目录存在且 TOC/目标表可导出，就保留为可部分审查证据；不能把退出码当成业务指标。

## 回放动作

- 默认窗口场景使用 Accessibility 列表的上下分页动作；场景 2 另外切换 home/builder、搜索和状态筛选。
- 窄窗口通过 UI resize 实际缩到约 814x820，再用 Accessibility top/bottom 动作回放。
- 每次 cold/hot 单独 attach，trace 不跨场景复用。
- 这不是物理滚轮或拖动，不能替代最终 Release 验收。

## Final canonical rerun freeze

以下协议用于后续真正的 #209 final rerun；本目录的 AX replay 不宣称已经执行了它。

- cold：同一 commit 下新启动 Release App，使用同一新建临时 HOME 和同一匿名 seed；在该进程首次进入目标页面前 attach trace。不得先访问目标页面或执行热身滚动。
- hot：沿用 cold 的同一进程、同一 fixture、同一窗口和同一页面状态；cold workload 停止并空闲 5 秒后重复同一动作序列，不重新导入、不重启。
- 每个 workload 的正式采样窗口固定为 10 秒；setup、导航、fixture seed 和窗口 resize 不计入这 10 秒。baseline/post 使用相同动作次数和相同起止状态。
- Scenario 01：Village Detail home/全部/默认排序，连续上下滚动 10 秒。
- Scenario 02：home ↔ builder、搜索/状态筛选、历史与 manual 面板展开/收起；每个状态切换后按固定顺序连续滚动 10 秒。
- Scenario 03：Upgrade Overview 的 active、pending、recently completed、attention 面板各滚动 10 秒。
- Scenario 04：Account Data 摘要、官方玩家、部落、战争、war log 和 capital raid；war/raid 多页加载后的滚动单独开 trace。
- Scenario 05：窗口约 800pt 宽，执行建筑组卡横向阶梯滚动，覆盖长中文名称换行，持续 10 秒。
- 60s tick、导入变化、manual action、分页加载分别单独开 trace，不与上述滚动窗口合并。

## 未完成项

- baseline 场景 04 cold trace 在 xctrace 收尾阶段没有生成可导出 TOC，已记为 unknown。
- OSSignpost 空表无法区分“没有事件”和“日志数据流丢失”，因此不填 0。
- Allocations/VM Tracker 需要系统管理员授权；本轮未输入管理员凭据，也不把内存结果写成 0。
- 60s tick、导入、manual action、分页加载尚未建立独立 trace。
