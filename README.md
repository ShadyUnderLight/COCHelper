# COC 助手：升级追踪器

一个原生 SwiftUI macOS 本地升级追踪器。它读取游戏内复制的账号 JSON，汇总所有村庄正在升级的记录，并按预计完成时间展示项目身份、等级和剩余时间。

## 当前已实现

- “升级总览”列表：跨所有村庄按预计完成时间显示项目、所属村庄与基地、当前等级 → 下一等级、进度和数量。
- 点击侧边栏的具体村庄可进入该村庄的独立升级列表；点击“升级总览”返回跨村庄汇总。
- 只展示快照中已经存在且带有进行中倒计时的升级事项，不展示可升级目录。
- 同一账号快照里的家乡村庄 / 建筑大师基地、重复记录、数量和嵌套模块都会保留。
- 粘贴游戏内复制的原始账号 JSON：解析计时器、等级、重复记录、嵌套模块、加速状态和未知字段诊断。
- 根据快照时间扣除导入时的年龄，并在本地继续显示进行中倒计时；计时结束后提示重新导入确认等级。
- 内置中文名称目录；未知 ID 仍保留 `#dataID` 以便核对。
- 内置版本化静态升级目录（`GameCatalog/18.400.13`，683 项 / 5479 条逐级记录）：提供中文名称、等级上限、每级完整时长与图标/外观资源引用；目录缺失或版本不匹配时给出诊断，不崩溃、不编造时长。
- 随目录人工维护 `seasonal_phases.json`：阶段日期只采用 Supercell 官方公告；当前收录 2026-04-01 至 2026-07-30 的 Crafted Defenses 阶段，旧快照可显示“已结束，仅历史数据”，未获官方精确日期的阶段保持“未配置”。
- 村庄投影层（`VillageCatalogProjection`）：把账号快照与静态目录 join，按等级聚合重复建筑/墙，进行中记录同时携带目录完整时长与实时剩余时间；`upgrading / complete / maxed / unknown / unavailable` 状态机 + 缺失原因。
- 多村庄档案：每个账号独立保存 JSON 快照；按账号标签 `tag` 重复导入时自动更新对应档案。
- 村庄详情页「粘贴并更新」快捷导入：读取剪贴板 JSON 直接预览并按当前村庄更新，免去“账号数据”页的完整流程（详见下文「快捷导入」一节）。
- 官方玩家信息（可选）：对已导入且带有效账号标签的村庄，一键或批量从 Clash of Clans 官方 API 拉取玩家资料（大本营、奖杯、部落、单位等级等），作为独立来源展示在村庄详情。
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

当前版本以本地记录为主，不生成未来升级规划。账号 JSON 通过游戏内复制后粘贴到“账号数据”页面；导入确认后会按账号标签自动归档到村庄档案。解析器保留原始文本，展示的计时器/冷却值按 `timestamp` 扣除快照年龄；没有时间戳时保留原始值并提示诊断。原始 JSON 没有单独的目标等级字段，正在升级记录里的下一等级仅按当前等级 +1 推断，完成后应重新导入确认。联网只发生在用户主动点击官方数据刷新时（见下文“官方玩家数据”一节），且官方数据作为独立来源展示，不影响本地记录。

## 快捷导入：村庄详情页「粘贴并更新」（Issue #61）

村庄详情页提供「粘贴并更新」按钮：读取系统剪贴板 → 解析账号 JSON 并展示预览 → 确认后按**当前村庄**更新本地快照，免去“账号数据 → 粘贴 → 解析 → 确认”的完整流程。

### 路由与拦截规则

- 导入目标固定为当前详情页村庄（按显式村庄 ID），与剪贴板 JSON 的账号 tag 无关；Tag 只用于跨档案冲突检测。
- 剪贴板 JSON 的账号 Tag（忽略大小写、首尾空白与可选 `#` 前缀）属于**其他**档案时阻止导入，并提示到“账号数据”页手动导入——避免快捷路径把 A 的账号数据误写进同 Tag 的另一档案 B。
- 目标村庄未导入过快照时建立新快照；JSON 未提供账号 Tag 时仍按当前村庄应用。
- Tag 语义与账号数据页一致：JSON Tag 与目标村庄当前 Tag 相同时保留官方 API 数据，Tag 变化或缺失时重置官方数据。

### 与账号数据页的关系

账号数据页是完整导入流程（解析诊断、选择/创建目标档案），快捷导入是详情页的快捷入口（目标固定为当前村庄）；两者写入同一快照存储，并遵循同一 Tag 契约（同 Tag 更新、Tag 变化/缺失重置官方数据）。

## 下一阶段建议

1. 随游戏版本更新名称目录，并为不同 APK 版本保留可审计的目录快照。
2. 如果后续 JSON 提供明确的目标等级或队列字段，再补充原始字段映射，不从数组顺序猜测。
3. 为升级追踪器增加导入历史和按类别筛选，但继续保持快照来源边界。

## Tools：APK 静态升级目录（issue #13）

`Tools/game_catalog/` 从 APK 生成版本化的静态升级目录（`catalog.json` + `manifest.json` + 空 `icons/`），
落库于 `Sources/COCHelperCore/GameCatalog/<版本>/`（SwiftPM 用 `.copy` 保留版本目录结构）。生成与校验均零第三方运行时依赖
（Python stdlib），测试用 pytest + hypothesis。

生成（输出目录必须为空，非空报错不自动清理）。**两步生成链**：主目录生成后必须再跑
精制台目录生成器——它幂等登记 `craft_table_catalog.json` 到 manifest（缺失登记时
validator 与 App 运行时都会 fail-closed，精制台不可用）：

```bash
python3 Tools/generate_game_catalog.py \
  --apk /Users/lmz/Downloads/base.apk.1 \
  --game-version 18.400.13 \
  --output Sources/COCHelperCore/GameCatalog/18.400.13
python3 Tools/generate_craft_table_catalog.py \
  --apk /Users/lmz/Downloads/base.apk.1 \
  --game-version 18.400.13 \
  --output Sources/COCHelperCore/GameCatalog/18.400.13/craft_table_catalog.json
```

校验与全量测试：

```bash
python3 Tools/validate_game_catalog.py --catalog Sources/COCHelperCore/GameCatalog/18.400.13
python3 -m pytest Tools/tests -q
```

**渲染 spike（issue #27，前置调研）**：`Tools/render_spike.py` 验证 SC2 V6 视觉资产
（`.sc`/`.sctx`）的可解析性与渲染可行性，输出 verdict 报告；需要
`ctypes` + libzstd（`/opt/homebrew/lib/libzstd.dylib`），与生成管线（纯 stdlib）分离：

```bash
python3 Tools/render_spike.py --apk /Users/lmz/Downloads/base.apk.1 --output /tmp/coc-spike-out
```

spike 结论：export 名与引用链可解析（`ui.sc` exports=3024），但渲染 PNG 存在双重阻塞
（export 全部指向 MovieClip + 纹理全部 ASTC/KTX 压缩）——**渲染路径已解锁
（Issue #30 / PR #32）**：`Tools/render_generator.py` 渲染固定样本 PNG 并回写
`catalog.json` 的 `renderedPath`：

```bash
python3 Tools/render_generator.py --apk /Users/lmz/Downloads/base.apk.1 \
  --catalog Sources/COCHelperCore/GameCatalog/18.400.13   # 渲染 + 回写 catalog.json
python3 Tools/render_generator.py --apk <apk> --catalog <dir> --samples-only  # 只渲染不回写
python3 Tools/render_generator.py --apk <apk> --catalog <dir>   # 全量渲染 catalog 全部引用（Issue #25）
```

**Issue #25 全量渲染完成**：`render_generator.py` 默认模式收集 catalog 全部
icon/levelVisual 引用（item 级 + level 级，R2.4 去重，1269 个唯一键）并渲染回写
`renderedPath`；18.400.13 目录当前含 **1246 张 PNG**（成功 1246 / 失败 23：
export_not_found 10 + render_failed 13，均写稳定 missingReason 不产空 PNG），
`manifest.json` `generatedFiles` 登记全部 path/size/sha256。4 个固定样本
（`icons/ui/icon_unit_barbarian.png`、`icons/ui/icon_spell_rage.png`、
`icons/buildings/fireplace_lvl1.png`、`icons/buildings/blacksmith_lvl1.png`）作为
回归基线仍在样本集中。渲染模块依赖例外同 spike：`sc2.py` 的 zstd body 解压需
`ctypes` + libzstd；`astc.py`/`ktx.py`/`render.py` 纯 stdlib（契约 R9.2/R9.3）。
`renderedPath` 输出契约见 `docs/rendered-path-contract.md`，路径选型决策见
`docs/render-path-decision.md`，spike 报告见 `docs/spike-2026-08-05-render.md`。

- **`--game-version` 语义**：APK 内不含版本字符串，必须显式传入（如 `18.400.13`）；不传时默认从
  `assets/build.tag` 推断（`18_400_7` → `18.400.7`）。生成器写盘前自检，失败不落盘；输出确定性
  （无时间戳，重复生成字节一致）。
- **缺表 fail loud**：APK 缺任何注册表或 `upgrade_data.csv` 时生成直接失败（不产出部分/空目录）；
  输出目录非空也拒绝（不自动清理）。
- **行语义**：建筑/陷阱表行 N = "升级到 N 级"；单位/法术/英雄/宠物/守卫表行 N = "从 N 升到
  N+1"，升级属性映射到下一等级（最低等级 = 初始，`durationSeconds` null +
  `min_level_initial_no_upgrade`）。等级号保留源表原始值（战斗直升机 15..35、超级野蛮人 5..13）。
  时间列空值 = 0，不做 forward-fill（只有标识列继承）。
- **边界**：渲染路径已解锁（Issue #30 / PR #32）——4 个固定样本 PNG 已入库并回写
  `renderedPath`（未全量渲染的引用保持 `renderedPath` null + `icons_not_rendered`）；不编造缺失时长
  （用 `missingReason` 枚举标记：`time_missing`/`time_invalid`/`upgrade_data_missing`/`no_time_source`，
  `'0'` 是真实值不是缺失）；**不改** `Tools/generate_account_name_catalog.py`；dataID 段与名称目录
  对齐（heroes/pets/equipment/guardians 集成测试对拍，heroes 按 VillageType 分流 heroes/heroes2，
  legacy 把全部英雄冗余写入两段）。
- **capital 与 Swift 合同**：部落都城条目使用 `capital_buildings`/`capital_traps`/`capital_characters`/
  `capital_spells` section 和 `capitalBuildings`/`capitalTraps`/`capitalTroops`/`capitalSpells`
  category，`base` 为 null + `capital_has_no_base`。**当前 Swift `TrackerCategory` 尚无这些
  rawValue**（`from(section:)` 对 `capital_*` 返回 nil）——这是 #14 消费端的扩展点，本 Issue
  不改 Swift。
- **校验器**：`validate_game_catalog.py` 除结构/语义不变量外，还重算 `generatedFiles` 中
  catalog.json 的 sha256/size 并检查 `icons/` 目录存在（篡改检出）。
- **限时阶段表**：`seasonal_phases.json` 是独立的人工维护增强数据，不从 APK 名称推断日期。
  日期采用 Swift `JSONDecoder` 默认 `.deferredToDate`（2001-01-01 00:00:00 UTC 起秒数）；
  官方仅给出日期而未给出时刻时，按 UTC 日边界编码，公告末日按包含语义转成次日 00:00 的
  `until`（模型区间恒为 `from <= now < until`）。每条阶段保留官方 `sourceURL` 供审计。
- **集成测试**：真实 APK 集成测试默认用 `/Users/lmz/Downloads/base.apk.1`；其他机器可通过环境变量
  `COC_APK_PATH` 指定，未设置且路径不存在时自动 skip。
- **已知问题（SwiftPM 资源）**：SPM `.process("Resources")` 会把资源目录**拍平**到 bundle 根部
  （`GameCatalog/18.400.13/catalog.json` → bundle 根 `catalog.json`），且多个版本目录存在同名文件
  时构建报 `multiple resources named 'catalog.json'`。当前仅一个版本目录可正常打包；将来落第二个
  版本时需先解决（如按版本重命名文件名），消费端 #14 按文件名经 `Bundle.module` 读取。
  `icons/` 以 `.gitkeep` 占位跟踪。


## API 连接（阶段一：连通性 smoke）

本地版本支持可选接入 Clash of Clans 官方 API，用于验证凭证、IP 白名单与网络连通性。当前只提供 `/v1/locations` 探测，不解析玩家数据，不投影到 UI。

### 凭证准备

1. 打开官方开发者门户 https://developer.clashofclans.com/ 注册并登录。
2. "My Account" 页面创建 API key，绑定运行本应用的机器的 **Allowed IP addresses**（家庭宽带为公网出口 IP；VPN/代理会改变出口 IP，需同步更新）。
3. 复制生成的 JWT 字符串作为 token。

### token 存储（二选一）

- **环境变量（临时验证）**：`COC_TOKEN=<你的token> swift run smoke-api`。注意：token 会留在 shell history 与进程环境中，临时验证后建议清理；长期使用推荐下面的 Keychain 方式。
- **Keychain（推荐）**：token 存入 macOS Keychain（service `com.coc-helper.coapi`，account `developer-token`）。运行下面的配置脚本，在终端隐藏输入 token，写入 Keychain 后自动执行 smoke：

  ```bash
  zsh scripts/configure_coc_api.sh
  ```

  使用项目脚本即可；它通过 Swift Keychain API 写入完整 JWT，避免系统命令交互式密码输入的长度限制。

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

- 官方数据以独立来源（界面显示“官方 API 数据”，内部标识为 `official-api`）展示在村庄详情，与本地导入 JSON（`imported`）并存，互不覆盖；本地快照、导入计时、加速状态和升级追踪器记录在任何情况下不会被官方数据修改。
- 每次成功抓取记录 `fetchedAt`；超过 24 小时未刷新时界面显示“已过期（stale）”，不会伪装成实时数据。
- 单位/兵种等级直接显示官方名称与等级，不做名称到本地 dataID 的映射（映射必须显式且版本化，首期不引入）。

### 刷新语义

- 只处理带有效账号标签（`#` + 大写字母/数字）的村庄；缺少标签或格式无效的村庄显示“已跳过”（跳过不会清空该村庄上次成功抓取的官方数据）。
- 批量刷新中相同 tag 只请求一次，结果复用到所有同 tag 村庄；请求顺序执行，配合客户端 429 退避，不会无限并发。村庄较多且遇限流时批量刷新耗时可能较长（单个 tag 最多重试 2 次），期间刷新按钮保持禁用。
- 首次请求失败：村庄仍可正常打开，显示失败原因；后续请求失败：保留上次成功快照（last-good）并显示上次成功抓取时间。
- 401/403/404/429/5xx、超时、响应解析失败都不会删除本地导入数据。
- 不自动轮询；是否刷新由用户主动触发。

### Token 设置

在“官方玩家数据”卡片点击“设置 API Token”，粘贴开发者门户生成的 JWT。Token 只写入 macOS Keychain，绝不写入 UserDefaults、村庄 JSON、日志或测试 fixture；也可以用命令行 `security add-generic-password -s com.coc-helper.coapi -a developer-token -w` 写入。

### 已知边界

- 官方响应中的未识别顶层字段会记录在共享部落状态中（审计用途），不会导致解码失败；已支持建筑大师基地奖杯、都城奖杯、部落都城联赛及最新入会要求字段。
- 本阶段不调用部落详情、部落对战、部落对战联赛（CWL）、部落都城等端点（阶段三）；不从 API 推导建筑、资源库存或升级队列。

## 部落数据（阶段三：共享数据层）

在“账号数据”页的“部落数据”卡片中，可以刷新当前村庄所属部落的档案（名称、等级、成员数、类型、部落对战记录概览、入会要求、建筑大师基地奖杯、都城奖杯、部落都城联赛、都城大本营等级与徽章）。

### 共享数据层语义

- 部落数据按部落标签 `clanTag` 存储为**共享数据**：同一部落下的多个村庄看到同一份档案与来源时间，不会把部落字段复制进每个村庄的本地 JSON。
- 当前部落归属派生自最近成功玩家快照的 `clan.tag`；玩家换部落或离开部落后，新快照刷新即更新归属，旧部落数据保留但不会显示为当前部落。
- 批量刷新中相同部落只请求一次（按标签去重、顺序执行），村庄数量增长不会线性放大部落请求。
- 无部落 / 空部落显示明确的 no-clan 状态；部落抓取失败保留上次成功数据（last-good），部落失败不会清除玩家官方快照或本地导入数据。
- 来源标签界面显示为“官方 API 数据”或“缓存的官方 API 数据”，内部标识分别为 `official-api` 与 `cached-official-api`。
- 部落解析器升级后，旧缓存仍可读但会提示刷新；主动刷新成功后才会填充新增字段。
- 首期不解析部落成员列表（`memberList` 显式 deferred），不逐成员请求玩家端点；部落徽章只加载官方 https 图片地址。

### 已知边界

- 阶段三当前只包含部落档案；当前部落对战（currentwar）、部落对战日志（warlog）与部落都城突袭周末（capitalraidseasons）在后续阶段接入，部落数据的 `isWarLogPublic` 字段为后续部落对战日志的显式不可用状态预留。

## 当前部落对战（阶段三 stage 3b：按需刷新）

在“账号数据”页的“当前部落对战”卡片中，可以按需查看当前村庄所属部落的对战状态（备战中/部落对战进行中/已结束）与双方摘要比分（攻击次数、星数、摧毁率、对战规模）。

### 按需与共享语义

- **按需刷新**：点击“查看当前部落对战”按钮才请求 `currentwar`；不做批量联动、不在启动时全量拉取。
- 部落对战数据与部落档案是**独立共享层**（独立端点、独立新鲜度、独立存储 key `coc-helper.clan-wars.v1`）：同一部落多个村庄共享一份，不复制进村庄档案。
- **`notInWar`（当前无部落对战）是成功响应**：显示“当前没有进行中的部落对战”空状态，不是失败；`warEnded`（部落对战已结束）显示结果。
- 部落对战抓取失败保留上次成功数据（last-good）；失败不会清除部落档案、玩家快照或本地导入数据。
- 来源标签与部落卡片一致：界面显示“官方 API 数据”或“缓存的官方 API 数据”，内部标识为 `official-api` / `cached-official-api`。
- 双方成员进攻记录（成员标签、名称、大本营等级、地图位置、攻击次数、总星数、摧毁率——成员进攻为官方 `attacks` 数组，星数/摧毁率按次聚合）以展开式明细展示（默认折叠，每表上限 30 行）；部落对战时间字段保留官方格式字符串，暂不本地化解析。

### 已知边界

- 部落对战日志（warlog）与部落都城突袭周末（capitalraidseasons）在 stage 3c 接入，同样按需刷新。

## 部落对战日志与部落都城（阶段三 stage 3c：分页，按需）

在“账号数据”页的“部落对战日志”与“突袭周末”卡片中，可以按需查看历史部落对战（胜负、星数、摧毁率）与突袭周末（都城金币、奖励、攻击统计），支持“加载更多”分页。

### 分页与状态语义

- **按需刷新**：点击“查看”按钮才请求；分页游标（`after`）向后翻页，末页或无新游标时自动停止（游标停滞视为末页，防无限循环）；重复条目在合并时去重。
- **部落对战日志不公开是显式状态**：部落档案 `isWarLogPublic=false` 时直接显示“部落对战日志不公开”且不发起请求；请求返回 403 时显示失败原因（档案过期兜底）。不伪造“没有历史部落对战”。
- 与部落档案/当前部落对战一样是独立共享层（独立 key `coc-helper.clan-war-logs.v1` / `coc-helper.clan-capitals.v1`），同部落多村庄共享一份。
- 分页端点共用客户端（`/warlog`、`/capitalraidseasons`），游标与 `limit` 通过 query 参数传输（官方默认分页大小，不写死限流数值）。
- 失败保留上次成功数据（last-good）；部落对战日志条目成员明细与突袭周末成员突袭表现（`members`）/攻防日志（`attackLog`/`defenseLog`）以展开式明细展示（默认折叠，每段上限 30 行）。

### 架构（stage 3c 泛化）

- 状态/存储/刷新逻辑泛化为 `OfficialEndpointState<T>` / `OfficialStateStore<T>` / `EndpointRefresher`，部落档案、当前部落对战、部落对战日志、突袭周末四个端点共用；旧类型保留 typealias（持久化格式与旧版本完全兼容）。

## 非官方声明与合规边界

本应用是**非官方**的《部落冲突》（Clash of Clans）社区工具，与 Supercell 无关。

- 数据来源：仅通过 Supercell 官方 API（developer.clashofclans.com）读取公开数据；不执行任何自动化游戏操作（不自动攻击、不自动升级、不模拟点击）。
- 禁止自动化与公开分发：本应用仅用于个人本地使用，不提供任何自动化游戏行为的接口；不得将本应用或其数据用于公共托管、批量数据抓取、转售或任何形式的公开分发。
- 所有游戏内容与素材版权归 Supercell Oy 所有；按 [Supercell Fan Content Policy](https://supercell.com/en/fan-content-policy/) 使用。
- 仓库内随附的渲染 PNG（`GameCatalog/*/icons/`）仅为应用 Bundle 内部资源（SwiftPM `.copy("GameCatalog")` 打包），随私有分发使用、不单独分发；若仓库转为 public 或对外分发应用，须重新评估（契约 R12.3）。
- 官方 API 限流与条款：应用遵守官方 API 的使用条款与速率限制（客户端内置 429 退避），不绕过认证、不伪造请求。
