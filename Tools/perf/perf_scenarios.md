# 滚动性能场景脚本（Issue #197）

基线：`origin/main@5a553481c67466cf92627caf27d1f18371a1fef8`。
每个场景执行**冷启动**与**热缓存**两次，分别记录指标（见 baseline_format.md）。

## fixture 路径
- 账号快照：`Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_home.json`、
  `perf_account_snapshot_builder.json`、`perf_account_snapshot_mixed.json`、`perf_account_snapshot_variant.json`
- 战争日志 / 突袭周末多页缓存：`perf_war_log_page_01..03.json`、`perf_capital_raid_page_01..03.json`
- 数据规模与环境：`perf_fixtures_manifest.json`

## 加载方式（两步流程，Release app 无 seed 入口）
- **Step 1（Debug app 加载 seed）**：只有 debug 构建含「性能样本」菜单（release 构建被 `#if DEBUG` 排除）。用 debug 构建组装 Debug app（bundle id 与 release 相同，共用 Application Support 数据），打开后菜单「性能样本」→ 加载性能样本（隐藏）（⌘⇧P），自动导入 3 村庄 + manual active/completed + conflict + war/raid 多页缓存。命令见 `baseline_format.md` 复测命令。
- **Step 2（Release app 测量）**：`scripts/build_app.sh` 组装 Release app 并打开（Instruments 可附加），此时读到的正是 Step 1 写入的 seed 数据。
- 备选（手动 UI 粘贴）：无村庄数据时也可在任意构建粘贴 `perf_account_snapshot_home.json` 导入，但 manual/conflict/war-raid 多页状态需按场景说明手动建立（seed 路径自动完成）。

## 场景 1：Village Detail 全部分类、默认排序
1. 按「加载方式」完成 seed（Debug app）→ Release app 打开村庄 A（#ANONYMIZED）详情页。
2. 打开该村庄详情页，base = 主村、筛选 = 全部、排序默认。
3. 连续上下滚动 10 秒（覆盖全部建筑组卡与列表行）。
4. 记录：hitch 次数/最长 hitch、主线程阻塞区间、projection 调用次数/耗时、图片候选/解码/失败/内存峰值。
5. 冷启动 = 首次进入；热缓存 = 滚动停止后再次滚动 10 秒。

## 场景 2：Village Detail 切换基地、筛选、展开/收起
1. 同场景 1 seed 加载，进入详情页。
2. 切换基地（主村 ↔ 建筑工人基地，村庄 B #PERF-BUILDER / 村庄 C #PERF-MIXED）。
3. 切换搜索/状态筛选；展开/收起快照历史与手动队列面板。
4. 每次切换后滚动 10 秒，记录 tick 与投影调用变化。

## 场景 3：Upgrade Overview 多村庄、manual 状态、各面板
1. seed 已建立 3 村庄（A/B/C）+ manual active/completed（≥5 项），在总览页打开。
2. 滚动 active / pending / recently completed / attention 各面板各 10 秒。

## 场景 4：Account Data 账号摘要、官方玩家、部落、战争、战争日志、突袭周末
1. 账号数据页滚动全部卡片 10 秒（含官方玩家卡、部落卡、战争卡、战争日志卡、突袭周末卡）。
2. 战争日志 / 突袭周末多页：用真实账号 token 或已缓存的多页数据（fixture 为匿名形态参考）加载 ≥2 页，滚动分页列表。
3. 记录分页加载后的滚动 hitch 与图片解码内存。

## 场景 5：窄窗口横向阶梯滚动与长中文名称
1. 窗口缩到 ~800pt 宽（windowResizability(.contentSize) 允许）。
2. 打开建筑组卡（横向阶梯滚动），连续滚动 10 秒；覆盖长中文名称行。
3. 记录窄窗口布局下阶梯滚动与文字换行的主线程阻塞区间。

## 记录要求
- 每个场景区分冷启动 / 首次进入 / 热缓存 / API·导入状态变化 / 60s tick，不得混成一个数字。
- 采样产物不得包含真实账号数据、token、cookie 或完整敏感 ID。
