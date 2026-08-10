# Issue #111 — 建模并展示 warLeague（CWL 联赛），避免已知字段静默丢失

日期：2026-08-11
基线：`origin/main@32628b6`
状态：设计完成，待 TDD 实现

## 1. 问题定义（SDD）

`OfficialClanSnapshot`（`Sources/COCHelperCore/ClanModels.swift`）的 `knownKeys` 包含
`"warLeague"`（L104），但模型无属性、decode 不解析、encode 不写回：

1. `warLeague` 不会进入 `unrecognizedKeys`（审计被掩盖）；
2. decode 后数据不可访问（静默丢失）；
3. round-trip / 持久化后永久丢失；
4. UI（`ClanCardView` / `ContentView` 添加预览）只展示"部落都城联赛"
   （capitalLeague），用户看不到部落当前 CWL 联赛。

fixture `official_clan_full.json` L29 含 `"warLeague": { "id": 48000010, "name": "Crystal League III" }`。
注意：fixture 的 league 字段除 warLeague 外**不可信**（capitalLeague 85000006 被写成
"Titan League I"，真实是 Silver League I），因此 ID 映射不以 fixture 为准，单独外部验证（见 §3）。

## 2. 类型契约

```swift
// OfficialClanSnapshot（ClanModels.swift）
public let warLeague: ClanLeague?          // 官方 raw key "warLeague"，对象形状 {id, name}
// decode:  container.decodeIfPresent(ClanLeague.self, forKey: "warLeague")
// encode:  container.encodeIfPresent(warLeague, forKey: "warLeague")
// init:    新增参数 warLeague: ClanLeague? = nil（默认值，保持现有调用方兼容）

// LeagueTierContext（LeagueTierCatalog.swift）
case war                                    // CWL 联赛，ID 段 48000000-48000022

// ClanDisplayFormat（COCHelperApp）
public static func warLeagueLabel(_ league: ClanLeague?) -> String?
// 查 .war context；未知 ID → "未本地化联赛（ID: x, name）"（复用 tierNameFallback）

// parserVersion：clan-snapshot-0.3 → clan-snapshot-0.4（解析范围变化，先例 #20 B1 策略）
```

不变式：
- 缺失 / `null` / 旧缓存（无该键）→ `warLeague == nil`，解码不失败；
- `warLeague` 仍留在 `knownKeys`（现在语义为"已建模"）；`memberList` 仍为真正 deferred；
- UI 文案"部落联赛"与"部落都城联赛"严格区分，不得互相回显。

## 3. CWL 联赛 ID 数据验证（CoT 证据链）

catalog（`league_tier_catalog.json`）目前只有 home/builderBase/capital/leagueTier 四个
context，**无 CWL（480000xx）数据**。需新增 `war` context。ID → 英文名经两个独立
GitHub 数据源交叉验证：

| 数据源 | 覆盖 | 结论 |
|---|---|---|
| clashperk/clashperk `src/util/constants.ts` L498-520 | 48000000-48000022（23 项） | 完整：Unranked、青铜III→冠军I、**Titan III/II/I、Legend（2026 新增）** |
| ClashKingInc/ClashKingBot `assets/war_leagues.json` | 48000000-48000018（19 项） | 子集，重叠部分与 clashperk 完全一致 |

- 48000010 = Crystal League III（与官方 fixture 一致，fixture 的 warLeague 由此可信）。
- 48000019-48000022 = Titan III/II/I、Legend 与 issue 引用的 Supercell
  "The Sound of Clash Update" 公告（新增 CWL Titan/Legend 联赛）吻合。
- 中文名采用与 home context（29000000-29000022，官方简中术语）**平行映射**：
  同一联赛体系（铜杯联赛3…传奇杯联赛），CWL 与主村联赛 ID 结构同构
  （48000010=Crystal League III ↔ 29000010=水晶杯联赛3）。

### 3 候选投票（本地化实现方式）

| 候选 | 描述 | 评估 |
|---|---|---|
| **A（推荐）** | catalog 新增 `war` context（48000000-48000022 平行中文名） | 符合 #71 catalog 单一来源方向；数据双源验证；未知 ID 走既有 fallback |
| B | 不建表，直接 fallback 官方英文 name | 零编造风险但用户看到英文，放弃本地化 |
| C | 代码手写字典 | 违背 #71 catalog 方向，字典易漂移 |

**投票结果：A**（fallback 机制同时保留，未知 ID 仍显示官方 name 可审计）。

## 4. 验收标准（issue 原文映射）

- [x] 完整 fixture 解码后 `snapshot.warLeague?.id/name` == 官方响应值
- [x] round-trip 后仍存在；缺失 / null / 旧缓存保持兼容
- [x] 部落卡片在有值时显示独立"部落联赛"，不与"部落都城联赛"混淆
- [x] CWL 已知 ID（含 2026 新联赛）确定性中文、未知 ID 安全回退
- [x] `unrecognizedKeys` 测试证明：warLeague 已建模；memberList 仍不产生噪音

## 5. 改动文件清单

| 文件 | 改动 |
|---|---|
| `Sources/COCHelperCore/ClanModels.swift` | warLeague 属性 + init + decode + encode |
| `Sources/COCHelperCore/LeagueTierCatalog.swift` | `LeagueTierContext` 加 `.war` + 注释 |
| `Sources/COCHelperCore/GameCatalog/18.400.13/league_tier_catalog.json` | 新增 `war` context（23 项） |
| `Sources/COCHelperCore/OfficialEndpointState.swift` | parserVersion 0.3 → 0.4 + 注释 |
| `Sources/COCHelperApp/ClanDisplayFormat.swift` | `warLeagueLabel` + `LeagueKind.war` |
| `Sources/COCHelper/ClanCardView.swift` | GridRow 加"部落联赛" |
| `Sources/COCHelper/ContentView.swift` | 添加预览加"部落联赛"行 |
| `Tests/COCHelperCoreTests/ClanDecodeTests.swift` | fixture 断言 + round-trip + 缺失/null + parserVersion |
| `Tests/COCHelperCoreTests/LeagueTierCatalogTests.swift` | war context 断言 + fuzz 扩展 |
| `Tests/COCHelperCoreTests/ClanDisplayFormatTests.swift` | warLeagueLabel 已知/未知/nil + property |
| `Tests/COCHelperCoreTests/GenericEndpointStateTests.swift` | parserVersion 断言 0.4 |
| `Tests/COCHelperCoreTests/AppModelClanResolveTests.swift` | parserVersion 断言 0.4 |

## 6. Property-based 测试计划

- `ClanDisplayFormatTests`：固定 seed 生成器（SplitMix64Generator 先例），
  任意 Int ID + 可选 name fuzz `warLeagueLabel`：
  - 输出要么属于 catalog war context 中文集，要么为 `未本地化联赛（ID: x[, name]）` 格式；
  - 永不包含"都城"字样（与 capital 语义隔离）；
  - 永不为空串；nil 输入 → nil。
- `LeagueTierCatalogTests`：`testFuzzLookupsKnownHitUnknownNil` 用
  `LeagueTierContext.allCases`，加入 `.war` 后自动覆盖（保持现有模式）。
- `ClanDecodeTests`：round-trip 变体矩阵（完整 / 缺失 / null / 未知字段并存）。

## 7. 验证命令

```bash
swift build && swift test
git diff --check
python3 -m pytest -q Tools/tests   # 回归（catalog 生成脚本无改动，预期不变）
```

## 8. 边界（不要做）

- 不做 issue 建议 4 的 `deferredKnownKeys` 拆分（独立 refactor）；
- 不动其他 context 的 catalog 数据；
- 不引入新依赖（property 测试用项目现有生成器模式）；
- 不改 ClanWarModels / OfficialPlayerSnapshot。
