# Issue #35：官方 API 数据接入村庄详情页

日期：2026-08-06 · 分支：`issue-35-village-detail-api`

## 背景（评审结论摘要）

数据层已就绪（`AppModel` 竞态防护、部落四层按 clan tag 共享、按需刷新、卡片状态机文案完整）。
本质工作是视图层重组 + 卡片状态读取显式化：

- 5 张卡片（`OfficialPlayerCardView`/`ClanCardView`/`ClanWarCardView`/`WarLogCardView`/`CapitalRaidCardView`）
  目前全部读 `model.currentVillage*`（基于 `selectedVillageID`），而 `VillageDetailView` 持有显式 `villageID`。
- Issue 验收标准要求「页面必须始终以当前 villageID 为数据来源」，刷新期间切村庄不得串村。
- 数据层写回已有 `expectedTag` 校验 + `refreshClan(villageID:)` 传发起村庄防竞态；缺口在**读取**与**部落刷新入口**的显式化。

## 目标

1. `AppModel` 新增按 `villageID` 查询与按 `villageID` 刷新的显式接口（现有 `current*` 保留为兼容转发）。
2. 5 张卡片接收显式 `villageID` 参数，读状态与刷新全部走 by-ID 接口。
3. `VillageDetailView` 在 header 之后接入官方 API 区域（玩家卡平铺 + 部落区默认折叠）。
4. `AccountDataView` 保留卡片，传 `model.selectedVillageID`（复用组件 = 单状态，不形成两套刷新入口）。
5. 测试：by-ID 路由隔离 + 刷新切村写回 + property-based 一致性。

## 类型契约（Task 1 产出，public）

```swift
// AppModel（Sources/COCHelperApp/AppModel.swift）

// 读取：按村庄 ID（对不存在 ID 一律返回 nil，不崩溃）
public func officialState(for villageID: UUID) -> OfficialAPIState?
public func officialClanTag(for villageID: UUID) -> String?      // 派生自 lastGood.clan.tag
public func clanStatusUnknown(for villageID: UUID) -> Bool       // lastGood == nil

// 读取：按 clan tag（部落四层共享字典）
public func clanState(for clanTag: String) -> ClanAPIState?
public func clanWarState(for clanTag: String) -> ClanWarAPIState?
public func warLogState(for clanTag: String) -> ClanWarLogAPIState?
public func capitalState(for clanTag: String) -> ClanCapitalAPIState?
public func isWarLogKnownNotPublic(for clanTag: String) -> Bool
public func warLogHasMore(for clanTag: String) -> Bool
public func capitalHasMore(for clanTag: String) -> Bool

// 刷新：按村庄 ID（内部复用现有 Task 逻辑与防重入 flag）
public func refreshOfficialPlayer(villageID: UUID)
public func refreshClan(villageID: UUID)          // 现有 internal 版 public 化
public func refreshClanWar(villageID: UUID)
public func refreshWarLog(villageID: UUID, force: Bool = false)
public func loadMoreWarLog(villageID: UUID)
public func refreshCapitalRaid(villageID: UUID)
public func loadMoreCapitalRaid(villageID: UUID)
```

现有 `current*` 属性/方法保留（内部转发到 by-ID 实现，语义不变，现有测试不动）。

## 任务分解

### Task 1：AppModel by-ID 接口（TDD + property-based）

文件：`Sources/COCHelperApp/AppModel.swift`、`Tests/COCHelperCoreTests/AppModelTests.swift`

TDD 顺序：
1. 先写测试：by-ID 读取路由隔离（A/B 村庄各自状态不串）、
   `refreshOfficialPlayer(villageID:)` 刷新期间切村庄仍写回发起村庄、
   by-tag 部落查询去重共享、`officialClanTag(for:)`/`clanStatusUnknown(for:)` 派生语义
   （lastGood nil → unknown true；clan tag 无效 → nil；换部落 → 只反映最近成功快照）。
2. property-based（项目无第三方依赖，XCTest 手写小型随机生成）：
   - 一致性：任意随机村庄列表 + 随机存在的 ID，`officialState(for: id)` 与数组中对应村庄状态恒等；
     随机不存在 ID → nil。
   - 派生一致性：随机 `OfficialAPIState`（随机 status/lastGood/clan），
     `clanStatusUnknown == (lastGood == nil)` 恒成立；
     `officialClanTag != nil ⟹ lastGood != nil` 恒成立。
3. 实现 + Reflexion 自查。

### Task 2：卡片显式 villageID + AccountDataView 传参

文件：5 张卡片（`Sources/COCHelper/*CardView.swift`）、`Sources/COCHelper/ContentView.swift`

- 每张卡片加 `let villageID: UUID`（调用方传参，不可为空字符串/无 ID 默认值）。
- 替换读状态：`model.currentVillageOfficialState` → `model.officialState(for: villageID)`；
  `currentClanState` → 先 `officialClanTag(for: villageID)` 再 `clanState(for:)`，其余 war/log/capital 同理。
- 刷新按钮：`refreshOfficialPlayer()` → `refreshOfficialPlayer(villageID: villageID)`；
  `refreshCurrentClan()` → `refreshClan(villageID:)`；`refreshCurrentClanWar()` → `refreshClanWar(villageID:)`；
  `refreshCurrentWarLog()/loadMoreCurrentWarLog()` → `refreshWarLog(villageID:)/loadMoreWarLog(villageID:)`；
  `refreshCurrentCapitalRaid()/loadMoreCurrentCapitalRaid()` → `refreshCapitalRaid(villageID:)/loadMoreCapitalRaid(villageID:)`。
- `AccountDataView`（ContentView.swift:562-604）保持卡片顺序，传 `model.selectedVillageID`。
- 视图层无测试基建：以 `swift build` 编译通过 + 语义走查为准（Self-review 逐行核对每处替换）。

### Task 3：VillageDetailView 官方 API 区域

文件：`Sources/COCHelper/VillageDetailView.swift`

- 在 `detailContent` 的 `header` 之后、`basePicker` 之前插入官方 API 区域：
  - `OfficialPlayerCardView(villageID: villageID)` 平铺（首屏可见，主诉求）。
  - 部落区（Clan/War/WarLog/Capital 4 卡）包在 `DisclosureGroup("部落信息（official-api）")` 中，默认折叠。
- 无自动请求：不新增任何 onAppear/task 触发刷新。
- 布局：沿用现有 `.padding(28)` 与 Panel 风格。

### Task 4：全量验证 + 收尾

命令：`swift test` → `swift build -c release` → `./scripts/build_app.sh` → `git diff --check`。
最终 code review（整实现）→ finishing-a-development-branch → PR。

## 验证命令

```bash
swift test
swift build -c release
./scripts/build_app.sh
git diff --check
```

## 非目标（勿做）

- 不改 API schema / 不新增字段；不自动轮询；不进页面自动请求 war/log/capital；
  不碰 #34 图标渲染；不扩展 N+1 成员请求；不重构 `OfficialStateStore`/分页逻辑；不动 Keychain。
