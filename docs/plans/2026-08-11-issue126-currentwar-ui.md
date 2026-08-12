# Issue #126 CurrentWar UI 重做 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `ClanWarCardView` 从 API 响应转储重做为可执行的对战指挥界面：消费 #125 展示投影、取消 `prefix(30)` 截断、提供双方比分卡/筛选 chips/排序切换/我方对手切换/稳定列成员表。

**Architecture:** 两层。Core 层（`ClanWarDisplayProjection`）追加可测的筛选桶、计数、排序变体与防守列投影纯函数；UI 层（`COCHelper` target）只消费投影，不自行解释 `nil`/配额/排序。SwiftUI 视图不直接测试（项目无 UI 测试 target），全部可测逻辑落在 Core，用单元测试 + 手写确定性 property-based 测试覆盖。

**Tech Stack:** Swift 6.0 / SwiftPM / SwiftUI（macOS 14）/ XCTest（无第三方依赖）

**基线:** `origin/main@157a4a0`（含 #125 投影 PR #131）。工作分支 `feat/issue-126-currentwar-ui`（worktree `.worktrees/issue-126-currentwar-ui`）。

---

## 设计决策记录（SDD 阶段，3 候选投票结论）

三个独立设计评审 subagent 并行评估「成员筛选 chips 归属模型」候选（A 直接映射 displayGroup / B 待处理包含 awaitingWar / C 阶段动态文案并入未出手），结果：A 赞成（0 blocker，2 non-blocker 建议）、B 反对（chip 重叠破坏验收 Σ 不变式）、C 赞成（带必改条件：备战期"待处理"也要中性化）。定稿采用 **方案 A + 吸收三评审共同建议**：

| 决策 | 结论 | 依据 |
|------|------|------|
| 基座 chips 归属 | 未出手 = `.notAttacked`；剩余1次 = `.remaining && remainingAttacks == 1`；剩余多次 = `.remaining && remainingAttacks >= 2`；已完成 = `.complete`；数据未确认 = `.unknown ∪ .quotaUnknown ∪ .overQuota` | 7 组 displayGroup 是行的划分 → Σ 不变式恒成立；未知/quotaUnknown/overQuota 均不进未出手 |
| 待处理 chip | 派生聚合：待处理 = 未出手 ∪ 剩余1次 ∪ 剩余多次（**不含 awaitingWar**） | 备战期 0 次攻击是正常状态非告警（issue 明文）；不引入重叠计数 |
| awaitingWar 处理 | 不进任何告警 chip；`chipCounts` 单独输出 `awaitingWar` 中性计数，备战期 UI 显示"等待开战 N"（secondary 色） | 吸收评审 A 的 S2 建议：备战期成员不"无处可去"，又不虚增告警 |
| 计数函数位置 | Core 新增 `chipCounts(rows:phase:)` 纯函数，验收"各筛选项数量之和与投影状态一致"可直接测试 | 吸收评审 A 的 S1 建议：计数逻辑不散落 view 层 |
| 排序变体位置 | Core 新增 `sortedRows(_:attacksPerMember:order:)`，`ClanWarSortOrder = actionPriority/mapPosition/name`；现有 `sortedRows(_:attacksPerMember:)` 保留并 delegate | 可测性 + 不破坏 #125 既有 905 行测试 |
| 防守列 | 投影 `ClanWarMemberRow` 新增 `defenseAttacks: Int?`（= raw `opponentAttacks?.count`），仅显示"防 N"；深度防守表现归 #127 | #126 列头要求含"防守"，最小数据；不扩大 scope 到 #127 |
| 已知边界（记录，不改） | `phase == .unknown(raw:)` 时 zero → `.notAttacked` 计入未出手（继承自 #125 Core `displayGroup` 行为） | 未知 phase 已有顶部数据提示兜底；改 Core 语义超出本 issue |

**验收不变式（property-based 测试核心）**：Σ(notAttacked + remainingOnce + remainingMany + complete + unknownData) + awaitingWar == rows.count；pending == notAttacked + remainingOnce + remainingMany；未知不计入未出手。

---

## 文件结构

| 文件 | 责任 | 操作 |
|------|------|------|
| `Sources/COCHelperCore/ClanWarDisplayProjection.swift` | 追加筛选桶/计数/排序变体/防守列投影（追加 MARK section，不改既有 API 语义） | Modify |
| `Tests/COCHelperCoreTests/ClanWarDisplayProjectionFilterTests.swift` | 筛选/计数/排序变体单元测试 + property-based 测试（新文件，手写确定性生成器） | Create |
| `Sources/COCHelper/ClanWarCardView.swift` | 重构：消费投影、状态徽标、比分卡、组装成员区；保留 header/statusLine/refreshButton/notInWar/unrecognizedKeys/两入口 | Modify |
| `Sources/COCHelper/ClanWarMemberSection.swift` | 成员区：我方/对手切换、筛选 chips、排序切换、LazyVStack 成员表、行展开、表头 | Create |
| `Sources/COCHelper/ClanWarScoreCardView.swift` | 双方比分卡（自适应：宽左右/窄上下），星数差/摧毁率差仅双字段存在时计算 | Create |
| `docs/plans/2026-08-11-issue126-currentwar-ui.md` | 本计划 | Create |

不改：`ClanWarModels.swift`（raw 解码）、`ClanWarRefresher.swift`、持久化/UserDefaults/parserVersion、`ContentView.swift`、`TrackedClanDetailView.swift`。

---

## Task 1: Core 投影扩展——筛选桶、计数、排序变体、防守列

**Files:**
- Modify: `Sources/COCHelperCore/ClanWarDisplayProjection.swift`
- Create: `Tests/COCHelperCoreTests/ClanWarDisplayProjectionFilterTests.swift`

### 类型契约（SDD）

追加到 `ClanWarDisplayProjection.swift` 文件末尾（新 MARK section）：

```swift
// MARK: - 成员筛选桶与排序变体（Issue #126）

/// 成员筛选桶（UI chips 的纯数据映射）。
///
/// 契约（Issue #126，SDD 3 候选投票定稿方案 A）：
/// - 基座五桶互斥且覆盖除 awaitingWar 外的全部 displayGroup：
///   notAttacked / remainingOnce / remainingMany / complete / unknownData；
/// - `pending` 是派生聚合桶：== notAttacked ∪ remaining（不含 awaitingWar——
///   备战期 0 次攻击是正常状态，不算"未出手告警"）；
/// - `.unknown`（attacks == nil）只能进 unknownData，绝不进未出手；
/// - awaitingWar（preparation + zero）不进任何告警桶，计数单独由
///   `ClanWarFilterCounts.awaitingWar` 输出（UI 显示"等待开战 N"，中性色）。
public enum ClanWarMemberFilter: Hashable, Sendable, CaseIterable {
    case all
    case pending
    case notAttacked
    case remainingOnce
    case remainingMany
    case complete
    case unknownData
}

/// 成员排序顺序（Issue #126：默认行动优先，提供地图位置/名称切换）。
public enum ClanWarSortOrder: Hashable, Sendable, CaseIterable {
    /// 行动优先（= #125 `sortedRows` 语义）：未出手 → 剩余 → 已完成 → 数据未知组。
    case actionPriority
    /// 地图位置升序（nil 排最后），平局按名称再按 sourceIndex。
    case mapPosition
    /// 名称升序（nil 排最后，String 比较序），平局按 mapPosition 再按 sourceIndex。
    case name
}

/// 筛选桶计数（Σ 守恒不变式的可测输出）。
public struct ClanWarFilterCounts: Hashable, Sendable {
    public let pending: Int
    public let notAttacked: Int
    public let remainingOnce: Int
    public let remainingMany: Int
    public let complete: Int
    public let unknownData: Int
    /// 备战期且明确 0 次攻击（中性计数，不进告警桶）。
    public let awaitingWar: Int

    public init(pending: Int, notAttacked: Int, remainingOnce: Int,
                remainingMany: Int, complete: Int, unknownData: Int, awaitingWar: Int) {
        self.pending = pending
        self.notAttacked = notAttacked
        self.remainingOnce = remainingOnce
        self.remainingMany = remainingMany
        self.complete = complete
        self.unknownData = unknownData
        self.awaitingWar = awaitingWar
    }
}

extension ClanWarDisplayProjection {
    /// 行是否匹配筛选桶。`all` 恒 true；其余基于 displayGroup + remainingAttacks。
    public static func matches(_ row: ClanWarMemberRow, filter: ClanWarMemberFilter,
                               phase: ClanWarPhase) -> Bool

    /// 过滤行（保持输入顺序不变，仅过滤）。`all` 返回原数组。
    public static func filteredRows(_ rows: [ClanWarMemberRow], filter: ClanWarMemberFilter,
                                    phase: ClanWarPhase) -> [ClanWarMemberRow]

    /// 各筛选桶计数（含 awaitingWar 中性计数）。
    ///
    /// 不变式：notAttacked + remainingOnce + remainingMany + complete + unknownData
    /// + awaitingWar == rows.count；pending == notAttacked + remainingOnce + remainingMany。
    public static func chipCounts(rows: [ClanWarMemberRow], phase: ClanWarPhase) -> ClanWarFilterCounts

    /// 按指定顺序排序（`order` 变体；`actionPriority` 与 #125 `sortedRows` 全序一致）。
    /// 三种顺序均以 sourceIndex 为最终平局键 → 全序确定。
    public static func sortedRows(_ members: [ClanWarMember], attacksPerMember: Int?,
                                  order: ClanWarSortOrder) -> [ClanWarMemberRow]
}

extension ClanWarMemberRow {
    /// 防守列数据：对方攻击本成员的次数（= raw `opponentAttacks?.count`）；
    /// nil = 官方未返回防守数据。深度防守表现归 Issue #127。
    public var defenseAttacks: Int? { _defenseAttacks }
    // 实现时用存储属性或 computed 内部字段（见 Task 1 Code 步）
}
```

### Task 1 实施步骤

- [ ] **Step 1: 写失败测试**（`Tests/COCHelperCoreTests/ClanWarDisplayProjectionFilterTests.swift`，新建）

测试辅助沿用 #125 测试模式（`attack(order:stars:destruction:)` / `member(...)` / `participant(...)` / `snapshot(...)` 构造器）。测试文件含：

1. `testMatchesAllAlwaysTrue`
2. `testMatchesNotAttackedExcludesAwaitingWar`：preparation + zero → `.awaitingWar`，matches(.notAttacked) == false、matches(.pending) == false；inWar + zero → `.notAttacked`，matches(.notAttacked) == true、matches(.pending) == true
3. `testMatchesRemainingOnceVsMany`：partial + remainingAttacks 1 → once；2 → many；两种都进 pending
4. `testMatchesUnknownDataBuckets`：unknown / quotaUnknown / overQuota 三态都 matches(.unknownData)；unknown 不 matches(.notAttacked)（未知不计入未出手）
5. `testMatchesComplete`：complete 只 matches(.complete) 和 .all
6. `testFilteredRowsPreservesOrderAndAllReturnsIdentity`
7. `testChipCountsSumInvariant`：固定 7 行 fixture（覆盖全部 7 组 displayGroup），断言 Σ 基座 + awaitingWar == 7、pending == 未出手 + once + many
8. `testChipCountsAwaitingWarOnlyInPreparation`：warEnded + zero → notAttacked 计数（非 awaitingWar）
9. `testSortedRowsMapPositionOrder`：mapPosition 升序、nil 最后、平局按 sourceIndex
10. `testSortedRowsNameOrder`：name 升序（String 序）、nil 最后、平局按 mapPosition/sourceIndex；名称缺失仍确定性
11. `testSortedRowsActionPriorityMatchesLegacy`：`sortedRows(members, attacksPerMember:)` 与 `sortedRows(members, attacksPerMember:, order: .actionPriority)` 结果相同
12. `testDefenseAttacksProjected`：`participant(_:attacksPerMember:)` 输出的 `ClanWarMemberRow.defenseAttacks` == raw `opponentAttacks?.count`；nil 防守 → nil
13. `testFortyMembersAllProjected`：40 成员 fixture（含 30+ 下标）经 `project` 后 `clan.members?.count == 40`，无截断路径（第 31 行存在且行字段完整）
14. **property-based**（手写确定性生成器，模式同 `AppModelQuickImportTests` 的 LCG，seed 固定）：
    - `testPropertyFilterCountsSumConserved`：随机 rows（随机 attacks 形态/配额/phase，N=200 轮）断言 Σ 基座 + awaitingWar == rows.count、pending == 三桶之和
    - `testPropertyUnknownNeverCountedAsNotAttacked`：同轮次断言 unknown 行只进 unknownData
    - `testPropertySortingDeterministic`：三种 order 下排序结果 == 再次排序结果（幂等/全序），且含 nil mapPosition/name 时仍确定性
    - `testPropertyFilteredRowsMatchesMatches`：filteredRows(.x) 的元素集合 == rows.filter { matches($0, .x, phase) } 集合

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ClanWarDisplayProjectionFilterTests`
Expected: FAIL（编译错误：`ClanWarMemberFilter` 未定义——符合"测试先于实现"）

- [ ] **Step 3: 最小实现**（追加到 `ClanWarDisplayProjection.swift` 末尾）

```swift
// MARK: - 成员筛选桶与排序变体（Issue #126）

public enum ClanWarMemberFilter: Hashable, Sendable, CaseIterable {
    case all, pending, notAttacked, remainingOnce, remainingMany, complete, unknownData
}

public enum ClanWarSortOrder: Hashable, Sendable, CaseIterable {
    case actionPriority, mapPosition, name
}

public struct ClanWarFilterCounts: Hashable, Sendable { /* 见契约 */ }

extension ClanWarMemberRow {
    /// 防守列：对方攻击本成员次数（nil = 未返回）。内部存储由投影映射填充。
    public private(set) var defenseAttacks: Int?
    // ⚠️ 若修改存储属性会与既有 memberwise init 冲突 → 改为：投影映射时
    //    通过新的内部 init 设置；或者采用计算属性 + 关联结构。实现时选
    //    最小侵入方案：给 ClanWarMemberRow 增加 init 参数并保留既有 init。
}
```

实现要点（必须遵循，违反即返工）：
- `matches`：`case .all: return true`；其余 switch `displayGroup(phase:action:)`，remainingOnce/Many 再查 `row.action.remainingAttacks`
- `chipCounts`：单遍扫描 rows，按 displayGroup 计数；`pending` 计算为派生值
- `sortedRows(_,_,order:)`：三种 order 各自 comparator；**一律以 `sourceIndex` 为最终平局键**（全序）；`actionPriority` 复用现有 sortRank 语义（提取私有函数，避免重复实现）；现有 `sortedRows(_:attacksPerMember:)` 改为 `return sortedRows(members, attacksPerMember: attacksPerMember, order: .actionPriority)`（行为不变）
- 防守列：`participant(_:attacksPerMember:)` 的成员映射处追加 `defenseAttacks: member.opponentAttacks?.count`；`ClanWarMemberRow` 增加存储属性 + 新 init 参数（既有 init 调用处同步）；**不改 raw `ClanWarModels.swift`**

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ClanWarDisplayProjectionFilterTests`，再 Run: `swift test`（全量，确认 #125 既有测试不回归）
Expected: 新测试全 PASS；全量 1100+ 测试 0 失败

- [ ] **Step 5: 自查（Reflexion）并提交**

自查清单：① 三种排序全序有测试；② 未知不入未出手有测试；③ 40 人无截断有测试；④ 既有 `sortedRows` 行为未变（有对照测试）；⑤ 未改 raw 模型/持久化/parserVersion。

```bash
git add Sources/COCHelperCore/ClanWarDisplayProjection.swift Tests/COCHelperCoreTests/ClanWarDisplayProjectionFilterTests.swift
git commit -m "feat(core): currentwar 成员筛选桶、排序变体与防守列投影 (Issue #126)"
```

---

## Task 2: UI——ClanWarCardView 重构（消费投影）

**Files:**
- Modify: `Sources/COCHelper/ClanWarCardView.swift`
- Create: `Sources/COCHelper/ClanWarScoreCardView.swift`
- Create: `Sources/COCHelper/ClanWarMemberSection.swift`

### 设计契约（CoT 要点）

**状态徽标**（`ClanWarPhase` → 文案/颜色）：
- `.preparation` → "备战中" / orange
- `.inWar` → "部落对战进行中" / red
- `.warEnded` → "部落对战已结束" / secondary
- `.notInWar` → 成功空状态 Label（绿色 checkmark，非失败）
- `.unknown(raw:)` → "未知部落对战状态" / secondary，raw 值显示在数据诊断（保留可审计性）

**比分卡**（`ClanWarScoreCardView`）：
- 输入：`label: String`（我方/对方）、`row: ClanWarParticipantProjection`、`quota: ClanWarQuota`
- 自适应：`ViewThatFits(in: .horizontal)`，第一候选 `HStack(比分卡A, 比分卡B)`，fallback `VStack`；两卡内容抽成内部 `ScoreCard` 组件避免重复
- 每卡：名称（nil → "我方"/"对方"）、部落等级（`ClanDisplayFormat.clanLevelLabel`）、星数、官方摧毁率（`ClanCombatSummary.displayDestructionPercent`）；**attacks/stars/destruction 原样透传（含 nil），缺失不渲染该段**
- 已用攻击/总配额：`quota.totalAttacks` 非 nil 且 `row.official.attacks` 非 nil → "已用攻击 X / Y"；否则"攻击配额未知"
- 星数差/摧毁率差：仅两边官方字段都存在时计算（`abs` 差），任一缺失不显示差值

**成员区**（`ClanWarMemberSection`）：
- 输入：`title`、`projection: ClanWarParticipantProjection`、`phase: ClanWarPhase`、`quota`（展示剩余用）
- 我方/对手：外部 Picker（`ClanWarCardView` 持有 `@State selectedSide`，`.clan/.opponent`）
- chips 行：`ScrollView(.horizontal)` + 胶囊 Button（复用 header 的 capsule 样式）；chips = 全部/待处理/未出手/剩余1次/剩余多次/已完成/数据未确认 + （awaitingWar > 0 时）"等待开战 N"中性 chip；每个显示 `label + count`；选中态 `Color.cocAccent`，待处理用警示色（`Color.orange` 或 `.red`，仅非备战期），数据未确认用中性色
- 排序切换：`Picker`（segmented）：行动优先/地图位置/名称
- 成员表：**LazyVStack** + 表头行（位置/成员/大本营/攻击进度/星数/防守/状态）；**无 `prefix(30)`**；`ForEach(rows, id: \.sourceIndex)`（单方内唯一）；列对齐用固定宽度 frame（位置 28 / 大本营 56 / 攻击进度 64 / 星数 48 / 防守 40）+ 成员列 `lineLimit(1)` flexible；窄窗口成员列可截断（truncationMode tail），**不得让右侧列被挤出**
- 行内容：位置、名称（nil → "未知成员"）、大本营（nil → "—"）、攻击进度（`attackCount` + 剩余）、星数（`stars.knownStars` + missing 提示 "⭐N +?N"）、防守（`defenseAttacks` → "防 N"，nil → "—"）、状态（displayGroup 文案：等待开战/未出手/剩余N次/已完成/超出配额/配额未知/数据未知；颜色只表状态：待处理警示、完成成功、未知中性）
- 行展开：`@State expandedIndex: Int?`（DisclosureGroup 会破坏列对齐 → 用 Button + `if expanded` 明细块）；明细 = `lines` 逐次（order、⭐ 文本、摧毁率）；**`lines` 为 nil/空时不显示箭头**
- VoiceOver：星数用文本 `"⭐N"` + `.accessibilityLabel("N 颗星")`；状态 chip 有明确文案

**ClanWarCardView 主视图**：
- `statusContent` 保留现状结构（statusUnknown / 无部落 / never 懒加载 / 有 state）
- 有 `state.lastGood` 时：`let projection = ClanWarDisplayProjection.project(snapshot)`；`warSummary` 改为消费投影：
  - `.notInWar` → 成功空状态
  - 其余 → 状态徽标 + `refreshStatus` 提示（stale/failed 已有 statusLine 覆盖）+ 规则（`BattleModifierText.localizedText`）+ 对战规模（`quota.teamSize`）+ 比分卡 + 成员区（我方/对手 Picker）+ 开始/结束时间（`startTime ?? warStartTime` / `endTime`）+ unrecognizedKeys 提示保留
- **保留不动**：`header`、`statusLine`、`refreshButton`、`isManualEntry`/`clanTag` 路由、两个入口签名、失败保留 last-good
- `ClanWarScoreCardView` 与 `ClanWarMemberSection` 放在同一 Panel 内（不换视觉系统：`Panel`/`Color.cocPanel`/`Color.cocElevated`/`Color.cocAccent`）

### 实施步骤

- [ ] **Step 1: 创建 `ClanWarScoreCardView.swift`**（纯布局，无 Core 逻辑）
- [ ] **Step 2: 创建 `ClanWarMemberSection.swift`**（消费 `filteredRows`/`chipCounts`/`sortedRows(order:)`，UI 内不出现任何 `attacks == nil` 判定之外的原始语义解释；所有计数来自 `chipCounts`）
- [ ] **Step 3: 重构 `ClanWarCardView.swift`**（删除 `scoreRow`/`participantRow`/`memberDisclosure`/`memberRow`/`memberLabel`/`attackLineRow`，替换为投影消费；`percent` 静态函数保留供摧毁率文本）
- [ ] **Step 4: 构建验证**

Run: `swift build`
Expected: 编译通过，0 error

- [ ] **Step 5: 自查（Reflexion）并提交**

自查清单：① 无 `prefix` 截断残留；② 无直接消费 raw `ClanWarMember` 的 UI 代码（全部走投影）；③ 两入口（villageID/clanTag）编译路径都在；④ 未引入新视觉系统；⑤ 中文文案与既有风格一致。

```bash
git add Sources/COCHelper/ClanWarCardView.swift Sources/COCHelper/ClanWarScoreCardView.swift Sources/COCHelper/ClanWarMemberSection.swift
git commit -m "feat(ui): currentwar 卡片重做，取消 30 人截断并接入展示投影 (Issue #126)"
```

---

## Task 3: 全量验证 + 真实窗口验收清单 + PR

- [ ] **Step 1: 全量测试 + 构建**

Run: `swift build && swift test`
Expected: 0 error、0 failure（1100+ 测试）

- [ ] **Step 2: 验收清单核对**（真实窗口由用户在 Xcode 中验证，PR body 列出）

- 40 人对战 fixture 全部成员可见（无"还有 N 名成员"文案）
- preparation / inWar / warEnded / notInWar 四状态
- 我方/对手切换、全部/待处理筛选、排序切换
- 长中文名、英文名、阿拉伯文名、缺失名称、缺失 mapPosition
- 窄窗口/宽窗口/滚动/展开收起攻击详情
- 失败保留缓存、stale 提示、刷新按钮
- 不出现截断成员、重叠文本、右侧指标被挤出

- [ ] **Step 3: 推送并创建 PR**

```bash
git push -u origin feat/issue-126-currentwar-ui
gh pr create --title "feat(ui): currentwar 卡片重做，取消 30 人截断（Issue #126）" --body "<Summary + Test Plan，附验收清单>"
```

---

## 风险和边界（本计划遵守）

- 不做 #127（攻击详情扩展/防守表现/北京时间）——防守列仅显示"防 N"次数；
  **数据诊断已在本次实现**（可展开诊断区：mismatches 覆盖诊断/攻击数/星数、unknownAttackDataCount、unrecognizedKeys）
- 不做 #124（warlog）；不改 raw snapshot 字节/UserDefaults key/parserVersion
- 不改 `ClanWarModels.swift` 解码；不改 `ClanWarRefresher.swift`
- 不引入新视觉系统；不改两个入口的调用签名
- 已知边界：`phase == .unknown(raw:)` + zero 计入未出手（继承 #125 Core 行为，不改）
- 已知边界：展开态身份 = `tag ?? name ?? "#\(sourceIndex)"`——缺 tag 且重名成员会同时展开
  （官方 API 契约成员必有 tag，实际不可达；tag/name 双缺时按位置兜底，刷新重排后可能错位）
