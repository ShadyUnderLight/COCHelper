# 独立触发源证据

## 60s tick

- 被测版本：post `aa48c8b2b89de00ec84386148fbc09812cac8f3c`
- 条件：Account/Overview 页面静止，不执行滚动；Time Profiler limit 65s。
- TOC：duration `108.558302s`，end-reason `Time limit reached`。
- `time-profile`：314 rows。
- 判断：trace 可导出，但没有能单独标识 Timeline tick 回调的应用 signpost；不能把任意 profile row 归因于 60s tick，状态为 `partial/unknown`。

## 导入变化

- 条件：隔离 HOME 中将匿名 `perf_account_snapshot_variant.json` 写入导入输入框，尝试执行“解析文本”。
- trace：post Time Profiler，duration `10.597896s`，`time-profile` 0 rows。
- 判断：没有可归因 profile 样本，也没有形成可审计的导入后首次滚动对照；状态为 `unknown`。

## manual action

- 条件检查：进入匿名 Village Detail 后，Accessibility 树没有可启动的“开始升级”按钮；可见动作均因快照数量、覆盖状态或当前状态门禁不可用。
- 判断：没有安全的 manual start/complete 操作可执行；未把 disabled button 当作 manual action evidence，状态为 `unknown`。

## war log pagination

- 条件：进入匿名部落详情，点击“查看更多（再显示 10 条）”。
- UI 证据：操作前按钮 element index 为 51，操作后变为 71，页面追加一页 10 条记录。
- 独立 trace：post Time Profiler，分页完成后静止 10 秒，duration `10.589005s`，`time-profile` 6 rows。
- 判断：分页追加动作已验证，但没有形成加载期间 hitch/解码内存证据；状态为 `partial`。

## Allocations / VM Tracker

- attach 模式：管理员授权后 10 秒窗口仍报告 `Failed to attach to target`；TOC duration `18.678129s`，无 `allocations`/`vm-tracker` 数据表。
- launch 模式：管理员授权后 10 秒窗口仍报告 `Failed to attach to target`；TOC duration `16.327258s`，同样无目标内存数据表。
- 判断：权限本身已通过，但当前手工打包 Release App 与 Allocations 模板未形成有效样本；峰值内存、分配和回收状态为 `unknown`。
