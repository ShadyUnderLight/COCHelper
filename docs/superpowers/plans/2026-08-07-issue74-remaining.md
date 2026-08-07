# Issue #74 剩余部分实施设计（deprecated 消费层 + 最小 74a）

日期：2026-08-07
分支：codex/issue-74-remaining
依据：Issue #74 评审定稿 + 上一轮总结（74b 已合入 #83；剩余 = deprecated 消费层 + 最小 74a；seasonal 被阶段日期数据源阻塞）

## 1. 范围

- **A. deprecated 消费层**：`CatalogItem.missingReason`（#83 已加字段）透传到投影层与 UI——37 个 `deprecated_in_source` item 区分「历史记录存在」与「当前可用」（Issue #74 验收：seasonal/deprecated 条目能区分）。
- **B. 最小 74a 兼容性状态**：`loadBundled` 读取 manifest + 显式兼容性模型（`unverified/verified/mismatch/unavailable`）+ UI「与玩家版本未验证」展示。**不做** verified/mismatch 的玩家 build 数据源接入（官方 API 无此字段，阻塞点保持不变）。
- **不做**：seasonal 生命周期（阶段日期数据源未定：APK 只有 specialAbility 名无日期）；#70/#73 消费方。

## 2. 现状证据（已核实）

| 层 | 现状 | 位置 |
|---|---|---|
| Manifest | `CatalogManifest` 模型存在但 `loadBundled` 不读取（#83 后仍如此） | GameCatalog.swift |
| 兼容性 | `project(expectedGameVersion: String? = GameCatalog.defaultBundledVersion)` 默认自我比较；`catalogIsUsable` 阻断完成度 | VillageCatalogProjection.swift L296/303、BuildingGroupProjection.swift L105/116 |
| deprecated | `CatalogItem.missingReason` 已解码（#83），但投影层 `VillageItemState` 无透传字段（其 `missingReason` 是 join 语义：目录未收录/不可用），UI 无消费 | VillageCatalogProjection.swift L83 |
| UI 版本展示 | ContentView L656 对比 `catalog.gameVersion != GameCatalog.defaultBundledVersion`（自我比较）；LevelDetailSheet「目录 v18.400.13」 | ContentView / LevelDetailSheet |

## 3. 设计决策（CoT）

### 3.1 兼容性状态模型（投票点）

```swift
public enum CatalogCompatibility: Hashable, Sendable {
    /// 无玩家 build 输入：目录可用但未验证（UI 明确「未验证」，不得伪装「已匹配」）。
    case unverified(gameVersion: String)
    /// 玩家 build == catalog.gameVersion。
    case verified(gameVersion: String)
    /// 玩家 build != catalog.gameVersion：catalogIsUsable 必须 false（完成度 fail-closed）。
    case mismatch(catalogVersion: String, expectedVersion: String)
    /// 目录不可用（catalog == nil）。
    case unavailable
}
```

关键决策：
1. **默认参数 `expectedGameVersion` 从 `defaultBundledVersion` 改为 nil**——删除自我比较：默认路径产出 `.unverified`（诚实），只有显式传入玩家 build 才可能 `.verified`/`.mismatch`。
2. **`catalogIsUsable` 语义不变**（unverified 时 true）：玩家 build 数据源不存在，若 unverified → false 会让全 App 完成度失效。评审定稿要求的是「展示层不伪装已验证」，非「未验证即不可用」。
3. `VillageCatalogProjection` 新增 `compatibility: CatalogCompatibility` 字段（与 `catalogIsUsable` 分离：前者展示、后者阻断）。

### 3.2 deprecated 透传

```swift
// VillageItemState 新字段（与 join 语义的 missingReason 分离，doc 注明）
public let catalogItemMissingReason: String?  // CatalogItem.missingReason 原样透传（如 deprecated_in_source）
```

UI 消费（最小）：LevelDetailSheet missingNote 区域 + UpgradeDisplayRow 状态徽标/副标题显示「已废弃（源目录标记）」——**不改变状态机**（deprecated item 的 status 仍按现有规则，仅展示标记；状态机改动影响大且无游戏语义证据支持新状态）。

### 3.3 manifest 加载

`GameCatalog.loadBundled` 同时读同目录 manifest.json；`GameCatalog` 新增 `manifest: CatalogManifest?`（解码失败 → nil，不阻塞目录加载——与 loadBundled 现有「解码失败返回 nil」风格一致，但目录本身仍返回：manifest 是增强信息，非必需）。UI/诊断可用 buildTag/sourceFingerprint/counts。

## 4. 3 候选方案（投票）

### 方案 A（推荐）：投影层兼容性枚举 + 默认参数改 nil
如 3.1。诚实、显式、与 catalogIsUsable 解耦。
- 优点：单一状态源；UI 只消费枚举；默认路径诚实（unverified）
- 缺点：`expectedGameVersion` 默认值改动影响面（需全量回归，现有测试大多不传该参数 → 走 nil → unverified，catalogIsUsable 仍 true，行为等价）

### 方案 B：不改默认参数，仅加「已验证」标注
保留自我比较，但把匹配结果标记为 unverified 直到显式传入。
- 优点：改动最小（不动默认参数）
- 缺点：保留虚假比较路径（传 defaultBundledVersion 时仍是自我比较）；两套语义并存，测试与调用方易混淆

### 方案 C：不建枚举，诊断文案层区分
只在 UI 文案改「未验证」，不加类型。
- 优点：无新类型
- 缺点：状态逻辑散落 UI；无法被测试锚定；mismatch 时 UI 无法区分「未验证 vs 不匹配」

投票输出：3 agent 各评一方案。

## 5. TDD 测试计划

### Swift
1. `GameCatalogTests`：`loadBundled().manifest` 非 nil（bundled manifest 存在）；manifest 解码（buildTag/counts.timed 等）；manifest 缺失/损坏 → 目录仍加载、manifest nil
2. `VillageCatalogProjectionTests`：
   - 默认（nil）→ `.unverified(gameVersion:)`；显式相同 → `.verified`；显式不同 → `.mismatch`；catalog nil → `.unavailable`
   - 显式不同时 `catalogIsUsable == false`（回归）；默认时 `catalogIsUsable == true`（回归）
   - `catalogItemMissingReason` 透传：deprecated item → "deprecated_in_source"；普通 item → nil；聚合后保留（property-based：SeededRNG 随机 items 聚合，断言透传不变量）
3. `BuildingGroupProjectionTests`：兼容性相关回归（project 默认参数变更后 catalogIsUsable 行为）

### Python
无改动（生成器/validator 已完成）。

## 6. 风险与边界

- `expectedGameVersion` 默认参数改动：全量 `grep expectedGameVersion` 确认调用点；现有测试不传参 → nil → unverified + catalogIsUsable true（行为等价）；显式传 "99.0.0" 的测试 → mismatch + false（不变）
- ContentView L656 的自我比较提示：改为消费 `compatibility`（默认 unverified → 显示「未验证」，不再显示「不匹配」）
- deprecated UI 文案为展示层（状态机不动）
- 不做 seasonal；PR 描述注明数据源阻塞

## 7. 投票结果与定稿（2026-08-07）

**方案 A 2:1 胜出**（B 有条件支持但"未传入 vs 恰好传默认值"不可判定；C 反对——状态散落 UI 不可测）。

定稿修正（投票评审采纳）：
1. **测试 helper 默认参数同步改 nil**（VillageCatalogProjectionTests.project helper L198 与 BuildingGroupProjectionTests 同款——否则默认路径测试拿到 .verified 与生产 .unverified 不一致）
2. **BuildingGroupProjection.project 默认参数一并改 nil**（L105，避免半栈残留自我比较）
3. **领域助手 `CatalogCompatibility.resolve(catalog:expectedGameVersion:)`** 静态函数（投影/UI 共用，防 UI 手搓三态判定）

UI 定稿：
- `VillageCatalogProjection.project`：unverified 时加 **info 级**诊断「静态目录版本 X；与玩家版本未验证」（mismatch 保持 warning、catalog nil 保持 warning）
- `VillageDetailView` 版本行（L238）：compatibility == .unverified 时加「· 未验证」后缀
- `ContentView.CatalogStatusNote`：改消费 resolve 结果——unavailable/mismatch → warning 保持；**unverified 不渲染**（常态非异常，避免总览常驻噪音；未验证信息由详情页承担）

## 8. 实现状态（2026-08-07 完成）

- ✅ 投票：方案 A 2:1（B 判定不可证明；C 状态散落 UI）；修正 3 条全采纳（测试 helper 默认 nil、BuildingGroupProjection 同步、resolve 领域助手）
- ✅ 数据层：`CatalogCompatibility`（unverified/verified/mismatch/unavailable）+ `resolve`；`GameCatalog.manifest`（loadBundled 读 manifest，失败不阻塞）；`VillageCatalogProjection.compatibility` + unverified info 诊断；`expectedGameVersion` 默认改 nil（两处投影入口 + 测试 helper）
- ✅ deprecated：`VillageItemState.catalogItemMissingReason` 透传（3 构造点必填）+ UI 两处（LevelDetailSheet missingNote、UpgradeDisplayRow subtitle「已废弃」）
- ✅ UI：VillageDetailView 版本行「· 未验证」；ContentView CatalogStatusNote 改消费 resolve（mismatch/unavailable warning，unverified 不渲染）
- ✅ 测试：+8（manifest 1、兼容性 5、deprecated 透传 1、property 聚合 50 轮 1）；既有 staleCatalog 测试 4 处显式传期望版本（helper 默认改 nil 的连锁修复）
- ✅ 验证：pytest 573 + swift test 742 全绿，0 警告
- ⚠️ 踩坑：测试追加到文件末尾会落在 class 外（XCTest 不收集）——须插入 class 收尾前；helper 默认参数改动会连锁破坏「用自定义版本目录构造 mismatch」的既有测试（须显式传参而非依赖默认值）
- ⚠️ 未做：seasonal 生命周期（阶段日期数据源阻塞：APK 只有 specialAbility 名无日期）——PR 描述注明
