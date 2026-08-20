# 2026-08-20 partial/proxy AX replay protocol

本文件描述这批 checkpoint 的实际 workload 和下一次可重跑方式。它不是完整的
#209 验收脚本；任何使用 `Animation Hitch` 数字做前后比较的复测，都必须把
`trace-toc` duration、窗口 bounds、刷新率和 fixture metadata 一起保存。

## Common setup

1. 在目标 commit 上运行 `swift build`，组装 Debug App。
2. 在空的隔离用户目录中打开 Debug App，通过菜单「性能样本」→「加载性能样本（隐藏）」
   加载匿名 fixtures；Release App 使用相同 bundle identifier 读取 seed。
3. 记录：
   - commit SHA；
   - `Tests/COCHelperCoreTests/Fixtures/perf_fixtures_manifest.json` SHA-256；
   - `Sources/COCHelperApp/PerfFixtures/` 的 path/blob index SHA-256；
   - manifest 中的完整 `dataScale`；
   - `CGMainDisplayID()` 当前 mode 的 pixel size/refresh rate；
   - App window 的精确 bounds；窄窗口不能只写“约 800px”。
4. 以 `Animation Hitches` + `os_signpost` 录制；实际命令使用固定
   `--time-limit 8s`，结束后立即导出 TOC，保存 `<summary>/<duration>`，再删除 raw trace。

示例命令（`APP_PID`、`TRACE`、`TOC` 必须替换为本次运行值）：

```bash
xcrun xctrace record \
  --template 'Animation Hitches' \
  --instrument os_signpost \
  --attach "$APP_PID" \
  --time-limit 8s \
  --output "$TRACE" \
  --no-prompt
xcrun xctrace export --input "$TRACE" --toc --output "$TOC"
```

历史 checkpoint 的 raw trace 已删除，因此其实际 TOC duration 和每个 action 的
wall-clock 间隔不可回填；旧数字只保留为一次性 `observed` 证据，不是可复用门禁。

## Actual proxy actions in this checkpoint

AX element index 每次必须从最新 `sky.get_app_state(..., disableDiff:true)` 重新解析，
下面的序列是语义动作，不是跨 UI 状态复用的固定 index：

| checkpoint | action sequence | omitted from #209 fixed workload |
|---|---|---|
| 01 | 进入匿名村庄 A；找到主内容 `list`；`AXScrollToBottom` → `AXScrollToTop` ×3 | 人工连续滚动、冷/热分离、详情内横向滚动 |
| 02 | 进入村庄 A；切换基地/村庄；主内容 `list` top/bottom ×3 | 搜索/状态筛选、历史与手动队列展开收起 |
| 03 | 进入 Upgrade Overview；主内容 `list` top/bottom ×3 | 各 overview 面板分别滚动 |
| 04 | 进入 Account Data；主内容 `list` top/bottom ×3 | war/raid 分页触发、分页后滚动 |
| 05 | 进入详情；调整到约 800px 窄窗口；主内容 `list` top/bottom ×3 | 精确 bounds、建筑组卡横向阶梯滚动 |

`sky` 侧的每个动作使用默认等待；历史运行没有记录该等待的实际毫秒数。下一次
要形成可审计 checkpoint，应在 action 之间显式记录时间戳，并在结果 Markdown 中
同时列出 `start/end/duration`。
