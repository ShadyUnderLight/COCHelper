# Issue #209 回放协议与边界

## 构建与隔离

1. 在 /private/tmp/cochelper-base-d3 detached worktree 构建 d3b57e8 Release App。
2. 用唯一 bundle ID 和临时 HOME/CFFIXED_USER_HOME 加载 Debug 性能样本，再用相同 bundle ID 的 Release App 测量。
3. 当前主线使用本 worktree 的 Release App，commit 为 98a2d1a。
4. 两个版本都只加载匿名 fixture；没有读取真实账号 JSON、token、cookie 或完整敏感 ID。

## Trace 命令

Animation Hitches：

    xcrun xctrace record --template 'Animation Hitches' --instrument os_signpost --attach "$PID" --time-limit 8s --output "$TRACE" --no-prompt

Time Profiler：

    xcrun xctrace record --template 'Time Profiler' --attach "$PID" --time-limit 8s --output "$TRACE" --no-prompt

每个 trace 先用 xcrun xctrace export --toc 验证 duration/end-reason，再导出 hitches-frame-lifetimes、os-signpost-interval 或 time-profile。xctrace 过程会报告 Fatal logging system error: The log archive is corrupt or incomplete and cannot be read，但只要 trace 目录存在且 TOC/目标表可导出，就保留为可部分审查证据；不能把退出码当成业务指标。

## 回放动作

- 默认窗口场景使用 Accessibility 列表的上下分页动作；场景 2 另外切换 home/builder、搜索和状态筛选。
- 窄窗口通过 UI resize 实际缩到约 814x820，再用 Accessibility top/bottom 动作回放。
- 每次 cold/hot 单独 attach，trace 不跨场景复用。
- 这不是物理滚轮或拖动，不能替代最终 Release 验收。

## 未完成项

- baseline 场景 04 cold trace 在 xctrace 收尾阶段没有生成可导出 TOC，已记为 unknown。
- OSSignpost 空表无法区分“没有事件”和“日志数据流丢失”，因此不填 0。
- Allocations/VM Tracker 需要系统管理员授权；本轮未输入管理员凭据，也不把内存结果写成 0。
- 60s tick、导入、manual action、分页加载尚未建立独立 trace。
