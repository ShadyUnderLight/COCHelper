# Issue #49 实施计划：玩家村庄信息页重设计（昵称优先、信息分组、去重复）

日期：2026-08-06
分支：feat/issue49-village-identity（基于 main，worktree: `.worktrees/feat-issue49-village-identity`）
规格来源：Issue #49 + 评审（notes/2026-08-06-issue49-review.md）

## 范围（非目标，照 issue 原文）

- 不改官方 API schema / 不加请求；不自动刷新
- 不删 `troops`/`heroes`/`spells`/`heroEquipment` 字段与解码持久化
- 不重新实现部落/战争/都城卡；不动 #45 组卡 / #47 图标
- 不改 `UpgradeDisplayRecord.villageName` 等本地升级数据语义
- 不把卡片改回读 `selectedVillageID`（保持显式 villageID 路由）

## 类型契约（Task 1，controller 已定稿）

```swift
// Sources/COCHelperCore/VillageDisplayIdentity.swift
public enum VillageIdentitySource: Equatable, Hashable, Sendable {
    case officialName   // 官方昵称（lastGood.name 非空白）
    case localName      // VillageProfile.name 回退
    case tagFallback    // Tag 回退
    case unnamed        // "未命名村庄"
}

public struct VillageDisplayIdentity: Equatable, Hashable, Sendable {
    public let primaryName: String
    public let tag: String?            // 展示用 tag：officialState.playerTag ?? village.tag
    public let localAlias: String?     // 官方昵称存在且本地名不同、非占位"未命名村庄"时提供
    public let source: VillageIdentitySource
    public let officialStatus: OfficialAPIDisplayStatus  // state?.displayStatus ?? .never
    public let officialFetchedAt: Date?
}

public enum VillageDisplayIdentityProjection {
    public static func project(
        village: VillageProfile,
        officialState: OfficialAPIState?,
        at now: Date = Date()
    ) -> VillageDisplayIdentity
}
```

名称优先级（照 issue 契约）：`lastGood.name`（trim 非空）→ `village.name` → `village.tag` → "未命名村庄"。
stale/failed 但 `lastGood != nil` → 仍显示昵称，`source == .officialName`，`officialStatus` 透传 stale/failed。
`lastGood == nil` → 走本地回退，不伪造官方昵称。Tag 变化清理已由 `applyImportedSnapshot` 保证（本任务不碰）。

## 任务分解

### Task 1：Core 身份投影 + 测试（TDD，含 property-based）
- 新增 `Sources/COCHelperCore/VillageDisplayIdentity.swift`（上述契约）
- 新增 `Tests/COCHelperCoreTests/VillageDisplayIdentityTests.swift`：
  - 确定性用例：昵称优先 / 本地回退 / Tag 回退 / 空白昵称 / 未命名
  - stale+lastGood 保留昵称 / failed+lastGood / lastGood==nil 回退
  - 多村庄隔离（两个 village + 各自 state，互相不串）
  - 本地别名条件（官方名==本地名时不显示 alias；"未命名村庄"不显示 alias）
  - property-based：随机名称/状态组合下 `primaryName` 非空、优先级链单调（复用 CoAPIPropertyTests 的确定性 seed 模式）
- 提交

### Task 2：侧边栏 + 升级总览头（ContentView.swift）
- `VillageSidebarRow`：第一行 `identity.primaryName`（回退状态用 secondary 样式 + 小徽标"待获取昵称"等），第二行 tag + 大本营等级/状态，升级数徽标保留右侧
- `TrackerHeaderView`（村庄模式）：标题行用投影（primaryName 主标题、tag + 来源/更新时间第二行）；无村庄（全部村庄）模式保持现状
- 只读 `village.officialAPIState`，不引入 AppModel 依赖；提交

### Task 3：村庄详情页头部（VillageDetailView.swift）
- `header` 换投影：primaryName 大标题、tag + 官方来源/更新时间第二行、快照时间保留；`localAlias` 以"本地别名：xxx"展示
- `completionBar`/`basePicker`/`categoryFilterBar`/`itemRow` 数据语义不动；提交

### Task 4：官方玩家卡片重构（OfficialPlayerCardView.swift）
- 删除 `unitsSummary` 调用与函数（snapshot 字段不动）
- 卡片 header 降级为低权重来源标签（"official-api" + 状态），不再 headline 平级
- `snapshotSummary` 去重复：不再显示 name+tag 大标题（昵称只在页面头部出现一次）
- 固定三列 Grid 改分组布局：进度（大本营/武器/建筑大师基地/经验）/ 战绩（奖杯/最佳/建筑大师奖杯/战争星数/攻防胜场）/ 部落与联赛（部落/角色/联赛/大师联赛/战争偏好）+ 折叠"更多玩家信息"（捐兵/受捐/都城金币贡献/传奇统计），用 `LazyVGrid(.adaptive)` 或分组 section，宽窗口不留大片空白
- 保留刷新按钮/状态行/Token 设置/villageID 路由/未识别键提示；提交

### Task 5：全量验证（controller 执行）
- `swift test` → `swift build -c release` → `./scripts/build_app.sh` → `git diff --check`

## 验收（照 issue）
- 侧边栏/主页首标题 = 官方昵称；无官方数据时回退文案清晰、不伪造昵称
- 切换村庄 A/B 名称/状态来自各自 villageID；账号 Tag 变化后旧昵称不残留（现有契约）
- 概览卡无兵种/英雄/法术/装备长文本；快照字段仍可解码持久化
- 无第二套刷新入口；不自动请求
