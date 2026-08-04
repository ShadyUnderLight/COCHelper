# COC 助手：升级追踪器

一个原生 SwiftUI macOS 本地升级 tracker。它读取游戏内复制的账号 JSON，汇总所有村庄正在升级的记录，并按预计完成时间展示项目身份、等级和剩余时间。

## 当前已实现

- “升级总览”列表：跨所有村庄按预计完成时间显示项目、所属村庄与基地、当前等级 → 下一等级、进度和数量。
- 点击侧边栏的具体村庄可进入该村庄的独立升级列表；点击“升级总览”返回跨村庄汇总。
- 只展示快照中已经存在且带有进行中倒计时的升级事项，不展示可升级目录。
- 同一账号快照里的主村 / 建筑工人基地、重复记录、数量和嵌套模块都会保留。
- 粘贴游戏内复制的原始账号 JSON：解析计时器、等级、重复记录、嵌套模块、加速状态和未知字段诊断。
- 根据快照时间扣除导入时的年龄，并在本地继续显示进行中倒计时；计时结束后提示重新导入确认等级。
- 内置中文名称目录；未知 ID 仍保留 `#dataID` 以便核对。
- 多村庄档案：每个账号独立保存 JSON 快照；按账号 `tag` 重复导入时自动更新对应档案。
- 官方玩家信息（可选）：对已导入且带有效 tag 的村庄，一键或批量从 Clash of Clans 官方 API 拉取玩家资料（大本营、奖杯、部落、单位等级等），作为独立来源展示在村庄详情。
- 深色 macOS 界面和本地 `UserDefaults` 存储。

## 运行

```bash
swift test
swift run COCHelper
```

生成可双击打开的本地 app：

```bash
./scripts/build_app.sh
open .build/COCHelper.app
```

也可以直接在 Xcode 中打开 `Package.swift`，选择 `COCHelper` scheme 运行。

## 重要边界

当前版本以本地记录为主，不生成未来升级规划。账号 JSON 通过游戏内复制后粘贴到“账号数据”页面；导入确认后会按 tag 自动归档到村庄档案。解析器保留原始文本，展示的计时器/冷却值按 `timestamp` 扣除快照年龄；没有时间戳时保留原始值并提示诊断。原始 JSON 没有单独的目标等级字段，正在升级记录里的下一等级仅按当前等级 +1 推断，完成后应重新导入确认。联网只发生在用户主动点击官方数据刷新时（见下文“官方玩家数据”一节），且官方数据作为独立来源展示，不影响本地记录。

## 下一阶段建议

1. 随游戏版本更新名称目录，并为不同 APK 版本保留可审计的目录快照。
2. 如果后续 JSON 提供明确的目标等级或队列字段，再补充原始字段映射，不从数组顺序猜测。
3. 为 tracker 增加导入历史和按类别筛选，但继续保持快照来源边界。

## API 连接（阶段一：连通性 smoke）

本地版本支持可选接入 Clash of Clans 官方 API，用于验证凭证、IP 白名单与网络连通性。当前只提供 `/v1/locations` 探测，不解析玩家数据，不投影到 UI。

### 凭证准备

1. 打开官方开发者门户 https://developer.clashofclans.com/ 注册并登录。
2. "My Account" 页面创建 API key，绑定运行本应用的机器的 **Allowed IP addresses**（家庭宽带为公网出口 IP；VPN/代理会改变出口 IP，需同步更新）。
3. 复制生成的 JWT 字符串作为 token。

### token 存储（二选一）

- **环境变量（临时验证）**：`COC_TOKEN=<你的token> swift run smoke-api`。注意：token 会留在 shell history 与进程环境中，临时验证后建议清理；长期使用推荐下面的 Keychain 方式。
- **Keychain（推荐）**：token 存入 macOS Keychain（service `com.coc-helper.coapi`，account `developer-token`）。可通过运行 `swift run smoke-api` 配合工具写入，或使用 `security add-generic-password -s com.coc-helper.coapi -a developer-token -w`。

**安全边界**：token 绝不写入源码、UserDefaults、村庄 JSON、日志或测试 fixture；本仓库任何文件都不应出现真实凭证。

### 连通性验证

```bash
swift run smoke-api
```

输出与退出码：

| 结果 | 含义 | 退出码 |
|---|---|---|
| `SUCCESS: 连通性验证通过，locations=N` | API 可达且授权通过 | 0 |
| `FAILED: 未配置凭证` | 未设置 COC_TOKEN 且 Keychain 无 token | 2 |
| `FAILED: 授权失败 reason=...` | 401/403：token 无效或 IP 不在白名单（reason 含 `invalidIp` 时检查 Allowed IP） | 1 |
| `FAILED: 请求被限流（429）` | 超过官方速率限制 | 1 |
| `FAILED: 端点不存在（404）` | 路径/版本错误 | 1 |
| `FAILED: 服务器错误（5xx）` | 官方服务异常 | 1 |
| `FAILED: 网络失败 ...` | 超时/断网/响应解析失败 | 1 |

错误映射（HTTP → 本地错误）：401 → unauthorized；403 → accessDenied(reason)；404 → notFound；429 → rateLimited（自动限次退避重试）；5xx → serverError；超时/断网 → timeout/network；2xx 但 JSON 解析失败 → malformedResponse。

## 官方玩家数据（阶段二：手动/批量刷新）

在“账号数据”页的“官方玩家数据”卡片中，可以手动刷新当前村庄的官方玩家资料；侧边栏“官方 API”区提供“刷新全部官方数据”。

### 来源与时间

- 官方数据以独立来源（来源标签 `official-api`）展示在村庄详情，与本地导入 JSON（`imported`）并存，互不覆盖；本地快照、导入计时、加速状态和 tracker 记录在任何情况下不会被官方数据修改。
- 每次成功抓取记录 `fetchedAt`；超过 24 小时未刷新时界面显示“已过期（stale）”，不会伪装成实时数据。
- 单位/兵种等级直接显示官方名称与等级，不做名称到本地 dataID 的映射（映射必须显式且版本化，首期不引入）。

### 刷新语义

- 只处理带有效 tag（`#` + 大写字母/数字）的村庄；缺 tag 或格式无效的村庄显示“已跳过”（跳过不会清空该村庄上次成功抓取的官方数据）。
- 批量刷新中相同 tag 只请求一次，结果复用到所有同 tag 村庄；请求顺序执行，配合客户端 429 退避，不会无限并发。村庄较多且遇限流时批量刷新耗时可能较长（单个 tag 最多重试 2 次），期间刷新按钮保持禁用。
- 首次请求失败：村庄仍可正常打开，显示失败原因；后续请求失败：保留上次成功快照（last-good）并显示上次成功抓取时间。
- 401/403/404/429/5xx、超时、响应解析失败都不会删除本地导入数据。
- 不自动轮询；是否刷新由用户主动触发。

### Token 设置

在“官方玩家数据”卡片点击“设置 API Token”，粘贴开发者门户生成的 JWT。Token 只写入 macOS Keychain，绝不写入 UserDefaults、村庄 JSON、日志或测试 fixture；也可以用命令行 `security add-generic-password -s com.coc-helper.coapi -a developer-token -w` 写入。

### 已知边界

- 官方响应中的未识别字段会记录在村庄数据中（审计用途），不会导致解码失败。
- 本阶段不调用部落详情、战争、CWL、部落资本等端点（阶段三）；不从 API 推导建筑、资源库存或升级队列。

## 部落数据（阶段三：共享数据层）

在“账号数据”页的“部落数据”卡片中，可以刷新当前村庄所属部落的档案（名称、等级、成员数、类型、战争记录概览、部落资本大厅等级与徽章）。

### 共享数据层语义

- 部落数据按 `clan tag` 存储为**共享数据**：同一部落下的多个村庄看到同一份档案与来源时间，不会把部落字段复制进每个村庄的本地 JSON。
- 当前部落归属派生自最近成功玩家快照的 `clan.tag`；玩家换部落或离开部落后，新快照刷新即更新归属，旧部落数据保留但不会显示为当前部落。
- 批量刷新中相同部落只请求一次（按 tag 去重、顺序执行），村庄数量增长不会线性放大部落请求。
- 无部落 / 空部落显示明确的 no-clan 状态；部落抓取失败保留上次成功数据（last-good），部落失败不会清除玩家官方快照或本地导入数据。
- 来源标签区分 `official-api`（最近成功）与 `cached-official-api`（失败但保留 last-good）。
- 首期不解析部落成员列表（`memberList` 显式 deferred），不逐成员请求玩家端点；部落徽章只加载官方 https 图片地址。

### 已知边界

- 阶段三当前只包含部落档案；当前战争（currentwar）、战争日志（warlog）与部落资本赛季（capitalraidseasons）在后续阶段接入，部落数据的 `isWarLogPublic` 字段为后续战争日志的显式不可用状态预留。
