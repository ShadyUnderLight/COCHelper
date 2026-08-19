# Issue #200：缓存静态村庄投影并复用升级总览派生结果（实施计划）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 缓存 Village Detail 的静态村庄投影（目录 join / 聚合 / effective 层）与精制台投影，60s tick 只做 O(items) 动态刷新；升级总览改为单趟组合入口，同一 tick 只执行一次 canonical all-village/all-base 投影。

**Architecture:**
- 新增 Core 层 `VillageProjectionCache`（final class，AppModel 主 actor 持有）：key 绑定真实输入身份（snapshot/manual core 内容 hash、catalogEpoch、phase bucket），命中时对 `remainingSeconds` 做减法刷新（动态），到期（remaining >0 → 0）时立即重建（静态事实翻转保持与现状一致）。
- 新增 `UpgradeOverviewProjection.overviewRender` 组合入口：一次 `allRecords`（注入 projectionProvider）产出 active/pending/state；`overviewRecords`/`overviewState` 保留签名并委托，现有 consumer/测试不变。
- 不改投影语义：`VillageCatalogProjection.project` / `BuildingGroupProjection.project` / `CraftTableProjection.project` 纯函数保持原样，缓存是外层包装；unknown/unverified/conflict/fail-closed 语义不变。

**Tech Stack:** Swift / SwiftPM / XCTest（项目现有 @testable 测试模式）

**关键决策（评审已确认）:**
1. `liveRemainingSeconds` 公式 `remaining(t) = remaining(t0) - (t - t0)`：refresh 只需缓存构建时刻的 remainingSeconds + builtAt，无需原始快照字段。
2. 到期翻转（active→needsReimport、module upgrading→recorded）属于"完成事实"，不动态推断；检测到到期 → 立即重建该 key（行为与现状每 tick 重建完全一致）。
3. `now` 不进 cache key；phase bucket 是 now 的派生（边界区间），bucket 内 availability 恒定。
4. catalog 身份：`GameCatalog` 非 Hashable → 用 AppModel 维护的 `catalogEpoch: Int`（当前 lazy 单例无运行中替换，机制为未来准备）+ `catalogVersion` 轻量代理；`craftTableCatalog` 同 epoch；`seasonalPhases` 表小且 Hashable → 直接内容 hash 进 bucket。
5. 缓存条目不存 buildingGroups：每 tick 从刷新后的 projection.rawItems 用现有 `project(projection:)` 重载派生（O(records)，不是静态投影重建）。
6. 不引入后台计算/actor（issue 允许）；缓存仅主 actor 访问。

**非目标（红线）:** 不改 `VillageCatalogProjection.project` 签名与内部逻辑；不动 AccountSnapshot/VillageProfile/manual storage schema；不做 #159 AppModel 拆分 / #160 ContentView 搬迁；不新增 signpost 事件名（#197 契约测试不动）；不删 unknown/diagnostic 信息；不做图片/懒加载（#198/#199 已完成）。

---

### Task 1: PhaseBucket（seasonal phase 边界区间）

**Files:**
- Modify: `Sources/COCHelperCore/GameCatalog.swift`（追加 `PhaseBucket` + `SeasonalPhaseTable.bucket(at:)`，放 SeasonalPhaseTable 定义之后）
- Test: `Tests/COCHelperCoreTests/SeasonalPhaseBucketTests.swift`（新建）

- [ ] **Step 1: 写失败测试**

`Tests/COCHelperCoreTests/SeasonalPhaseBucketTests.swift`:

```swift
import XCTest
@testable import COCHelperCore

/// Issue #200：phase bucket = 所有阶段边界（from/until，过滤非法区间）中
/// now 所在的区间。bucket 内任意 now 的 availability 判定恒定
///（phase 选择与 notStarted/active/ended 状态都不跨边界变化）。
final class SeasonalPhaseBucketTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func phase(_ id: String, from: TimeInterval, until: TimeInterval) -> SeasonalPhase {
        SeasonalPhase(
            phaseID: id,
            name: nil,
            from: Date(timeIntervalSince1970: from),
            until: Date(timeIntervalSince1970: until),
            itemKeys: ["buildings:1000001"]
        )
    }

    func testEmptyTableYieldsUnconfiguredBucket() {
        let bucket = SeasonalPhaseTable.empty.bucket(at: t0)
        XCTAssertEqual(bucket.start, .distantPast)
        XCTAssertEqual(bucket.end, .distantFuture)
        // 空表任意 now 同一 bucket（单桶语义）。
        XCTAssertEqual(bucket, SeasonalPhaseTable.empty.bucket(at: t0.addingTimeInterval(3600)))
    }

    func testSinglePhaseInsideAndOutside() {
        let table = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [phase("p1", from: 1_000_000, until: 2_000_000)]
        )
        let inside = table.bucket(at: Date(timeIntervalSince1970: 1_500_000))
        XCTAssertEqual(inside.start.timeIntervalSince1970, 1_000_000)
        XCTAssertEqual(inside.end.timeIntervalSince1970, 2_000_000)

        let outside = table.bucket(at: Date(timeIntervalSince1970: 3_000_000))
        XCTAssertEqual(outside.start.timeIntervalSince1970, 2_000_000)
        XCTAssertEqual(outside.end, .distantFuture)
    }

    func testMultiplePhaseBoundaries() {
        let table = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [
                phase("p1", from: 1_000_000, until: 2_000_000),
                phase("p2", from: 2_500_000, until: 3_500_000),
            ]
        )
        // 1_800_000 位于 p1 内部。
        let bucket = table.bucket(at: Date(timeIntervalSince1970: 1_800_000))
        XCTAssertEqual(bucket.start.timeIntervalSince1970, 1_000_000)
        XCTAssertEqual(bucket.end.timeIntervalSince1970, 2_000_000)
        // 2_200_000 位于 p1 结束与 p2 开始之间。
        let gap = table.bucket(at: Date(timeIntervalSince1970: 2_200_000))
        XCTAssertEqual(gap.start.timeIntervalSince1970, 2_000_000)
        XCTAssertEqual(gap.end.timeIntervalSince1970, 2_500_000)
    }

    func testInvalidPhaseRangesAreFiltered() {
        // from >= until 的非法区间与 availability 判定同口径过滤。
        let table = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [
                phase("bad", from: 2_000_000, until: 1_000_000),
                phase("good", from: 1_000_000, until: 1_500_000),
            ]
        )
        let bucket = table.bucket(at: Date(timeIntervalSince1970: 1_200_000))
        XCTAssertEqual(bucket.start.timeIntervalSince1970, 1_000_000)
        XCTAssertEqual(bucket.end.timeIntervalSince1970, 1_500_000)
    }

    func testBucketAtExactBoundary() {
        let table = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [phase("p1", from: 1_000_000, until: 2_000_000)]
        )
        // from 边界本身：<= date 取边界（与 availability 的 from <= now 同口径）。
        let atFrom = table.bucket(at: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(atFrom.start.timeIntervalSince1970, 1_000_000)
        XCTAssertEqual(atFrom.end.timeIntervalSince1970, 2_000_000)
    }

    func testTableContentChangeYieldsDifferentIdentity() {
        let tableA = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [phase("p1", from: 1_000_000, until: 2_000_000)]
        )
        let tableB = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [phase("p1", from: 1_000_000, until: 3_000_000)]
        )
        let now = Date(timeIntervalSince1970: 1_500_000)
        XCTAssertNotEqual(tableA.bucket(at: now).tableIdentity, tableB.bucket(at: now).tableIdentity)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter SeasonalPhaseBucketTests 2>&1 | tail -5`
Expected: FAIL（`bucket(at:)` 不存在，编译错误）

- [ ] **Step 3: 实现**

在 `Sources/COCHelperCore/GameCatalog.swift` 中 `SeasonalPhaseTable` 定义之后追加：

```swift
// MARK: - Issue #200 Phase bucket（投影缓存的时间桶）

/// `SeasonalPhaseTable` 在指定时刻的投影时间桶。
///
/// bucket = 所有合法阶段（from < until，与 `availability` 判定同口径）的
/// from/until 边界集合中 `date` 所在区间。区间内任意时刻的
/// `availability(forItemKey:lifecycle:at:)` 结果恒定（phase 选择与
/// notStarted/active/ended 状态都不跨边界变化），因此作为村庄静态投影
/// 缓存的时间维度，`now` 本身不得进入缓存键。
public struct PhaseBucket: Hashable, Sendable {
    /// 阶段表内容身份（`hashValue`；表小，直接内容 hash）。
    public let tableIdentity: Int
    /// 区间起点（含；无更早边界时为 distantPast）。
    public let start: Date
    /// 区间终点（不含；无更晚边界时为 distantFuture）。
    public let end: Date

    public init(tableIdentity: Int, start: Date, end: Date) {
        self.tableIdentity = tableIdentity
        self.start = start
        self.end = end
    }
}

extension SeasonalPhaseTable {
    /// 计算 `date` 所在的 phase 边界区间（Issue #200 缓存时间桶）。
    public func bucket(at date: Date) -> PhaseBucket {
        let boundaries = phases
            .filter { $0.from < $0.until }  // 与 availability 同口径过滤非法区间
            .flatMap { [$0.from, $0.until] }
            .sorted()
        let start = boundaries.last(where: { $0 <= date }) ?? .distantPast
        let end = boundaries.first(where: { $0 > date }) ?? .distantFuture
        return PhaseBucket(tableIdentity: hashValue, start: start, end: end)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter SeasonalPhaseBucketTests 2>&1 | tail -5`
Expected: PASS（6 tests, 0 failures）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/GameCatalog.swift Tests/COCHelperCoreTests/SeasonalPhaseBucketTests.swift
git commit -m "feat(perf): add seasonal phase bucket for projection cache key (Issue #200)"
```

---

### Task 2: 动态刷新（remainingSeconds 递减 + 到期检测）

**Files:**
- Modify: `Sources/COCHelperCore/VillageCatalogProjection.swift`（`VillageItemState.withRemainingSeconds`、`EffectiveVillageItemState` 扩展放本文件或 EffectiveVillageProjection.swift、`VillageCatalogProjection.refreshingTimers`）
- Modify: `Sources/COCHelperCore/EffectiveVillageProjection.swift`（`EffectiveVillageItemState.withImportedRemainingSeconds`）
- Modify: `Sources/COCHelperCore/CraftTableProjection.swift`（`CraftTableModuleState.withRemainingSeconds` + `[CraftTableDefenseState].refreshingModules`）
- Test: `Tests/COCHelperCoreTests/VillageProjectionRefreshTests.swift`（新建）

说明：`VillageItemState` 的 memberwise init 是 internal（struct 定义在 Core 内），`withRemainingSeconds` 在 Core 内实现可直接复制全部字段。

- [ ] **Step 1: 写失败测试**

`Tests/COCHelperCoreTests/VillageProjectionRefreshTests.swift`:

```swift
import XCTest
@testable import COCHelperCore

/// Issue #200：动态刷新——remainingSeconds 按 (now - builtAt) 递减、
/// 到期（>0 → 0）检测、effective 层 importedRemainingSeconds 同步。
/// 刷新不改变任何静态字段（status/nextLevel/effective 状态），到期重建由
/// 缓存层负责（本层只报告 expired）。
final class VillageProjectionRefreshTests: XCTestCase {
    private var village: VillageProfile!
    private var catalog: GameCatalog!
    private var builtAt: Date!

    override func setUpWithError() throws {
        builtAt = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = try makeSnapshot(
            importedAt: builtAt,
            buildings: [
                (dataID: 1_000_001, level: 1, remaining: 3600),   // 升级中
                (dataID: 1_000_002, level: 2, remaining: 0),       // 计时结束
                (dataID: 1_000_003, level: 3, remaining: nil),     // 普通完成
            ]
        )
        village = VillageProfile(
            id: UUID(), name: "测试村", tag: "#TEST", officialTag: nil,
            accountSnapshot: snapshot
        )
        catalog = try makeCatalog()
    }

    private func makeSnapshot(
        importedAt: Date,
        buildings: [(dataID: Int64, level: Int, remaining: Int64?)]
    ) throws -> AccountSnapshot {
        var sections: [String: [AccountItem]] = [:]
        let items = buildings.enumerated().map { index, b in
            AccountItem(
                id: "buildings:\(index)",
                section: "buildings",
                dataID: b.dataID,
                name: "建筑\(b.dataID)",
                level: b.level,
                count: 1,
                timerSeconds: b.remaining,
                remainingSeconds: b.remaining,
                isNew: false
            )
        }
        sections["buildings"] = items
        return try AccountSnapshot(
            importedAt: importedAt,
            tag: "#TEST",
            name: "测试村",
            objectSections: sections
        )
    }

    private func makeCatalog() throws -> GameCatalog {
        // 最小合成目录：maxLevel 足够高避免满级干扰。
        let json = """
        {
          "gameVersion": "18.400.13",
          "items": [
            {"section":"buildings","category":"buildings","dataID":1000001,"base":"home","name":"A","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":1,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]},
            {"section":"buildings","category":"buildings","dataID":1000002,"base":"home","name":"B","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":2,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]},
            {"section":"buildings","category":"buildings","dataID":1000003,"base":"home","name":"C","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]}
          ]
        }
        """
        struct Payload: Decodable {
            let gameVersion: String
            let items: [CatalogItem]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        return try GameCatalog(
            gameVersion: payload.gameVersion,
            items: payload.items,
            manifest: nil,
            universeKeys: [],
            universeSupplement: [:],
            displayCategories: [],
            seasonalPhases: .empty
        )
    }

    private func project(at now: Date) -> VillageCatalogProjection {
        VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home, now: now
        )
    }

    func testRemainingDecrementsByDelta() {
        let p0 = project(at: builtAt)
        let upgraded = try! XCTUnwrap(p0.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgraded.remainingSeconds, 3600)

        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(60), builtAt: builtAt)
        let upgradedNow = try! XCTUnwrap(refreshed.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgradedNow.remainingSeconds, 3540)
        XCTAssertFalse(refreshed.expired)
    }

    func testTimerExpirationIsDetected() {
        let p0 = project(at: builtAt)
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(3600), builtAt: builtAt)
        XCTAssertTrue(refreshed.expired)
        let upgradedNow = try! XCTUnwrap(refreshed.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgradedNow.remainingSeconds, 0)
        // 静态字段不被刷新改动（status 仍为投影时刻的 .upgrading——
        // 到期翻转由缓存层重建负责）。
        XCTAssertEqual(upgradedNow.status, .upgrading)
    }

    func testAlreadyExpiredTimerIsNotReportedAgain() {
        let p0 = project(at: builtAt)
        // 已结束计时（remaining == 0）不触发 expired。
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(60), builtAt: builtAt)
        XCTAssertFalse(refreshed.expired)
    }

    func testClockRewindKeepsRemainingUnchanged() {
        let p0 = project(at: builtAt)
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(-60), builtAt: builtAt)
        let upgradedNow = try! XCTUnwrap(refreshed.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgradedNow.remainingSeconds, 3600)
        XCTAssertFalse(refreshed.expired)
    }

    func testEffectiveTrackerItemsRemainingSynchronized() {
        let p0 = project(at: builtAt)
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(60), builtAt: builtAt)
        let effective = try! XCTUnwrap(
            refreshed.projection.effectiveTrackerItems.first { $0.itemKey.dataID == 1_000_001 }
        )
        XCTAssertEqual(effective.importedRemainingSeconds, 3540)
    }

    func testRawItemsAlsoRefreshed() {
        let p0 = project(at: builtAt)
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(120), builtAt: builtAt)
        let raw = try! XCTUnwrap(refreshed.projection.rawItems.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(raw.remainingSeconds, 3480)
    }

    func testCraftTableModulesRefreshAndDetectExpiration() throws {
        // 合成快照需含精制台（craft table dataID 是 display 规则常量）。
        // 构造一个 buildings 段含精制台 + 模块升级的记录。
        let craftID = try XCTUnwrap(
            BuildingDisplayCategoryRules.craftTableDataID
        )
        // 直接构造投影太复杂，此处用真实 path：先构造模块快照再投影。
        // 精制台行 id 形如 "buildings:0.types.0"，嵌套判定依赖 id 包含 ".types."。
        var sections: [String: [AccountItem]] = [:]
        let craft = AccountItem(
            id: "buildings:0",
            section: "buildings",
            dataID: craftID,
            name: "精制台",
            level: 5,
            count: 1,
            timerSeconds: nil,
            remainingSeconds: nil,
            isNew: false
        )
        let module = AccountItem(
            id: "buildings:0.types.0",
            section: "buildings",
            dataID: 103_000_001,
            name: "模块",
            level: 1,
            count: 1,
            timerSeconds: 3600,
            remainingSeconds: 3600,
            isNew: false
        )
        sections["buildings"] = [craft, module]
        let snapshot = try AccountSnapshot(
            importedAt: builtAt, tag: "#TEST", name: "测试村",
            objectSections: sections
        )
        let village = VillageProfile(
            id: UUID(), name: "测试村", tag: "#TEST", officialTag: nil,
            accountSnapshot: snapshot
        )
        let craftTable = CraftTableProjection.project(
            village: village, catalog: nil, base: .home, now: builtAt
        )
        let defense = try XCTUnwrap(craftTable.first)
        let moduleState = try XCTUnwrap(defense.modules.first)
        XCTAssertEqual(moduleState.remainingSeconds, 3600)
        XCTAssertEqual(moduleState.status, .upgrading)

        let refreshed = craftTable.refreshingModules(
            at: builtAt.addingTimeInterval(60), builtAt: builtAt
        )
        let moduleNow = try XCTUnwrap(refreshed.modules.first?.modules.first)
        XCTAssertEqual(moduleNow.remainingSeconds, 3540)
        XCTAssertFalse(refreshed.expired)

        let expired = craftTable.refreshingModules(
            at: builtAt.addingTimeInterval(3600), builtAt: builtAt
        )
        XCTAssertTrue(expired.expired)
    }
}
```

注意：测试中用到的 `BuildingDisplayCategoryRules.craftTableDataID`、`AccountItem` 的 init 参数、`GameCatalog` 的 init 参数需与现有代码一致——实现 Step 3 前先核对 `AccountItem` init 与 `GameCatalog` init 签名（见 `AccountSnapshot.swift` L51-133、`GameCatalog.swift` init），不一致则按实际签名调整测试 fixture 构造。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter VillageProjectionRefreshTests 2>&1 | tail -5`
Expected: FAIL（`refreshingTimers` 等不存在）

- [ ] **Step 3: 实现**

3a. `Sources/COCHelperCore/VillageCatalogProjection.swift` 追加（`VillageItemState` 定义之后）：

```swift
// MARK: - Issue #200 动态刷新

extension VillageItemState {
    /// 复制自身并替换 remainingSeconds（动态刷新专用；不改任何静态字段）。
    /// 到期/状态翻转由缓存层在 expired 时重建处理。
    public func withRemainingSeconds(_ newValue: Int64?) -> VillageItemState {
        VillageItemState(
            id: id, section: section, dataID: dataID, base: base, name: name,
            category: category, currentLevel: currentLevel, count: count,
            timerSeconds: timerSeconds, remainingSeconds: newValue,
            nextLevel: nextLevel, nextLevelDurationSeconds: nextLevelDurationSeconds,
            nextLevelDurationState: nextLevelDurationState, maxLevel: maxLevel,
            currentStageMaxLevel: currentStageMaxLevel, nextUpgrade: nextUpgrade,
            status: status, missingReason: missingReason,
            catalogItemMissingReason: catalogItemMissingReason,
            availability: availability, icon: icon, levelVisual: levelVisual,
            currentLevelIcon: currentLevelIcon, currentLevelVisual: currentLevelVisual,
            isNested: isNested, displayCategory: displayCategory,
            countOverflowed: countOverflowed, effectiveState: effectiveState
        )
    }
}
```

（如 `VillageItemState` init 参数与上不同，按实际定义调整——成员都在，逐字段复制即可。）

3b. `Sources/COCHelperCore/EffectiveVillageProjection.swift` 追加：

```swift
// MARK: - Issue #200 动态刷新

extension EffectiveVillageItemState {
    /// 复制自身并替换 importedRemainingSeconds（动态刷新专用）。
    public func withImportedRemainingSeconds(_ newValue: Int64?) -> EffectiveVillageItemState {
        // 逐字段复制，仅 importedRemainingSeconds 替换（init 参数以实际定义为准）。
        // 如果 EffectiveVillageItemState 没有公开逐字段 init，则用
        // Mirror/手动复制：这里按实际源码补齐全部字段。
        EffectiveVillageItemState(
            itemKey: itemKey,
            rawItemID: rawItemID,
            importedCurrentLevel: importedCurrentLevel,
            importedCount: importedCount,
            importedCountOverflowed: importedCountOverflowed,
            importedCountQuality: importedCountQuality,
            importedTimerSeconds: importedTimerSeconds,
            importedRemainingSeconds: newValue,
            importedDistribution: importedDistribution,
            manualCompletedDistribution: manualCompletedDistribution,
            activeManualRecords: activeManualRecords,
            activeTargetDistribution: activeTargetDistribution,
            effectiveCompletedDistribution: effectiveCompletedDistribution,
            status: status,
            provenance: provenance,
            diagnostic: diagnostic,
            catalogDurationState: catalogDurationState,
            catalogCosts: catalogCosts,
            catalogNextUpgrade: catalogNextUpgrade,
            currentStageMaxLevel: currentStageMaxLevel,
            globalMaxLevel: globalMaxLevel
        )
    }
}
```

（实现前先读 `EffectiveVillageItemState` 的实际 init 签名，按实际字段补全。）

3c. `Sources/COCHelperCore/CraftTableProjection.swift` 追加：

```swift
// MARK: - Issue #200 动态刷新

extension CraftTableModuleState {
    /// 复制自身并替换 remainingSeconds（动态刷新专用）。
    public func withRemainingSeconds(_ newValue: Int64?) -> CraftTableModuleState {
        CraftTableModuleState(
            id: id, dataID: dataID, name: name, statTypes: statTypes,
            displayTitles: displayTitles, currentLevel: currentLevel,
            maxLevel: maxLevel, status: status, timerSeconds: timerSeconds,
            remainingSeconds: newValue, missingReason: missingReason
        )
    }
}

extension Array where Element == CraftTableDefenseState {
    /// 精制台模块 remainingSeconds 按 (now - builtAt) 递减。
    /// expired = 任一模块 remaining 从 >0 变 0（调用方应重建静态投影）。
    public func refreshingModules(
        at now: Date, builtAt: Date
    ) -> (modules: [CraftTableDefenseState], expired: Bool) {
        let delta = max(0, now.timeIntervalSince(builtAt))
        var expired = false
        let refreshed = map { defense in
            let modules = defense.modules.map { module in
                guard let remaining = module.remainingSeconds, remaining > 0 else {
                    return module
                }
                let newRemaining = max(0, remaining - Int64(delta))
                if newRemaining == 0 { expired = true }
                return module.withRemainingSeconds(newRemaining)
            }
            return CraftTableDefenseState(
                id: defense.id, dataID: defense.dataID, name: defense.name,
                currentLevel: defense.currentLevel,
                availability: defense.availability, modules: modules
            )
        }
        return (refreshed, expired)
    }
}
```

3d. `Sources/COCHelperCore/VillageCatalogProjection.swift` 追加（`VillageCatalogProjection` 定义内，`project` 之后）：

```swift
    // MARK: - Issue #200 动态刷新

    /// 把 remainingSeconds（items/rawItems）与 importedRemainingSeconds
    /// （effectiveTrackerItems）按 (now - builtAt) 递减后返回副本。
    ///
    /// - expired：任一 remaining 从 >0 变 0。到期意味着 active→needsReimport、
    ///   模块 upgrading→recorded 等「完成事实」翻转——动态 overlay 不得自行
    ///   推断完成事实（Issue #200 验收），调用方应在 expired 时重建静态投影。
    /// - 时钟回拨（now < builtAt）保持 remaining 不变（clamp delta ≥ 0）。
    /// - 静态字段（status/nextLevel/nextUpgrade/effectiveState 等）不变。
    public func refreshingTimers(
        at now: Date, builtAt: Date
    ) -> (projection: VillageCatalogProjection, expired: Bool) {
        let delta = max(0, now.timeIntervalSince(builtAt))
        var expired = false

        func refreshed(_ item: VillageItemState) -> VillageItemState {
            guard let remaining = item.remainingSeconds, remaining > 0 else {
                return item
            }
            let newRemaining = max(0, remaining - Int64(delta))
            if newRemaining == 0 { expired = true }
            return item.withRemainingSeconds(newRemaining)
        }

        let refreshedItems = items.map(refreshed)
        let refreshedRaw = rawItems.map(refreshed)
        let refreshedEffective = effectiveTrackerItems.map { state in
            guard let remaining = state.importedRemainingSeconds, remaining > 0 else {
                return state
            }
            let newRemaining = max(0, remaining - Int64(delta))
            if newRemaining == 0 { expired = true }
            return state.withImportedRemainingSeconds(newRemaining)
        }

        return (
            projection: VillageCatalogProjection(
                villageID: villageID, villageName: villageName, base: base,
                catalogVersion: catalogVersion, catalogIsUsable: catalogIsUsable,
                compatibility: compatibility, items: refreshedItems,
                rawItems: refreshedRaw, effectiveTrackerItems: refreshedEffective,
                manualCoverage: manualCoverage, progressMetrics: progressMetrics,
                diagnostics: diagnostics, progressCoverage: progressCoverage
            ),
            expired: expired
        )
    }
```

（`VillageCatalogProjection` init 参数按实际定义核对。）

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter VillageProjectionRefreshTests 2>&1 | tail -5`
Expected: PASS（7 tests, 0 failures）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/VillageCatalogProjection.swift Sources/COCHelperCore/EffectiveVillageProjection.swift Sources/COCHelperCore/CraftTableProjection.swift Tests/COCHelperCoreTests/VillageProjectionRefreshTests.swift
git commit -m "feat(perf): add timer refresh with expiration detection for cached projections (Issue #200)"
```

---

### Task 3: VillageProjectionCache（缓存 + 命中刷新 + 到期重建）

**Files:**
- Create: `Sources/COCHelperCore/VillageProjectionCache.swift`
- Test: `Tests/COCHelperCoreTests/VillageProjectionCacheTests.swift`（新建）

- [ ] **Step 1: 写失败测试**

`Tests/COCHelperCoreTests/VillageProjectionCacheTests.swift`:

```swift
import XCTest
@testable import COCHelperCore

/// Issue #200：静态村庄投影缓存。
/// - 相同静态输入只构建一次；now 变化只做动态刷新；
/// - 到期（remaining >0 → 0）触发重建（与现状每 tick 重建行为一致）；
/// - key 覆盖 snapshot / manual core / catalogEpoch / base / phase bucket。
final class VillageProjectionCacheTests: XCTestCase {
    private var cache: VillageProjectionCache!
    private var village: VillageProfile!
    private var catalog: GameCatalog!
    private var craftTableCatalog: CraftTableCatalog?
    private var phases: SeasonalPhaseTable!
    private var t0: Date!

    override func setUpWithError() throws {
        cache = VillageProjectionCache()
        t0 = Date(timeIntervalSince1970: 1_000_000)
        village = try makeVillage(importedAt: t0)
        catalog = try makeCatalog()
        craftTableCatalog = nil
        phases = .empty
    }

    private func makeVillage(importedAt: Date) throws -> VillageProfile {
        // 1 条升级中（remaining 3600）+ 1 条普通完成。
        var sections: [String: [AccountItem]] = [:]
        sections["buildings"] = [
            AccountItem(id: "buildings:0", section: "buildings", dataID: 1_000_001,
                        name: "A", level: 1, count: 1, timerSeconds: 3600,
                        remainingSeconds: 3600, isNew: false),
            AccountItem(id: "buildings:1", section: "buildings", dataID: 1_000_002,
                        name: "B", level: 2, count: 1, timerSeconds: nil,
                        remainingSeconds: nil, isNew: false),
        ]
        let snapshot = try AccountSnapshot(
            importedAt: importedAt, tag: "#TEST", name: "测试村",
            objectSections: sections
        )
        return VillageProfile(
            id: UUID(), name: "测试村", tag: "#TEST", officialTag: nil,
            accountSnapshot: snapshot
        )
    }

    private func makeCatalog() throws -> GameCatalog {
        let json = """
        {
          "gameVersion": "18.400.13",
          "items": [
            {"section":"buildings","category":"buildings","dataID":1000001,"base":"home","name":"A","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":1,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]},
            {"section":"buildings","category":"buildings","dataID":1000002,"base":"home","name":"B","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":2,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]}
          ]
        }
        """
        struct Payload: Decodable {
            let gameVersion: String
            let items: [CatalogItem]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        return try GameCatalog(
            gameVersion: payload.gameVersion, items: payload.items, manifest: nil,
            universeKeys: [], universeSupplement: [:], displayCategories: [],
            seasonalPhases: .empty
        )
    }

    private func render(at now: Date) -> VillageProjectionCache.RenderResult {
        cache.render(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: phases, base: .home, now: now,
            manualUpgradeCore: nil, catalogEpoch: 0
        )
    }

    // MARK: - 命中与刷新

    func testSameStaticInputBuildsOnce() {
        let first = render(at: t0)
        XCTAssertEqual(first.projection.items.count, 2)
        XCTAssertEqual(cache.buildCount, 1)

        let second = render(at: t0.addingTimeInterval(60))
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.hitCount, 1)
        // 动态刷新：remaining 递减。
        let upgraded = try! XCTUnwrap(second.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgraded.remainingSeconds, 3540)
    }

    func testExpirationRebuildsAndFlipsState() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        // 到期（3600s 后）。
        let expiredRender = render(at: t0.addingTimeInterval(3600))
        XCTAssertEqual(cache.buildCount, 2)
        let upgraded = try! XCTUnwrap(expiredRender.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgraded.remainingSeconds, 0)
        XCTAssertTrue(upgraded.needsReimport)
        // 重建后的新缓存再次命中。
        let _ = render(at: t0.addingTimeInterval(3660))
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testGoldenParityWithDirectProjection() {
        let render = render(at: t0)
        let direct = VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home, now: t0
        )
        XCTAssertEqual(render.projection.items, direct.items)
        XCTAssertEqual(render.projection.rawItems, direct.rawItems)
        XCTAssertEqual(render.projection.effectiveTrackerItems, direct.effectiveTrackerItems)
        XCTAssertEqual(render.projection.progressMetrics, direct.progressMetrics)
        XCTAssertEqual(render.projection.diagnostics, direct.diagnostics)
        XCTAssertEqual(render.buildingGroups.count, 2)
    }

    // MARK: - 失效矩阵

    func testSnapshotChangeRebuilds() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        village = try! makeVillage(importedAt: t0.addingTimeInterval(10))  // 新快照
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testManualCoreChangeRebuilds() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        let core = ManualUpgradeCore(villageID: village.id, schemaVersion: 1)
        let _ = cache.render(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: phases, base: .home, now: t0,
            manualUpgradeCore: core, catalogEpoch: 0
        )
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testCatalogEpochChangeRebuilds() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        let _ = cache.render(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: phases, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 1
        )
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testBaseChangeRebuilds() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        let _ = cache.render(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: phases, base: .builder, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0
        )
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testPhaseBucketChangeRebuilds() {
        phases = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [
                SeasonalPhase(
                    phaseID: "p1", name: nil,
                    from: t0, until: t0.addingTimeInterval(3600),
                    itemKeys: ["buildings:1000001"]
                )
            ]
        )
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        // 跨 phase 边界（until 之后）→ 新 bucket → 重建。
        let _ = render(at: t0.addingTimeInterval(7200))
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testPhaseBucketSameBucketDoesNotRebuild() {
        phases = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [
                SeasonalPhase(
                    phaseID: "p1", name: nil,
                    from: t0, until: t0.addingTimeInterval(7200),
                    itemKeys: ["buildings:1000001"]
                )
            ]
        )
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        // 同一 bucket 内 → 仅刷新。
        let _ = render(at: t0.addingTimeInterval(600))
        XCTAssertEqual(cache.buildCount, 1)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter VillageProjectionCacheTests 2>&1 | tail -5`
Expected: FAIL（`VillageProjectionCache` 不存在）

- [ ] **Step 3: 实现**

`Sources/COCHelperCore/VillageProjectionCache.swift`:

```swift
import Foundation

/// Issue #200：静态村庄投影缓存（render + cache + 动态刷新）。
///
/// 职责：
/// - key 绑定真实输入身份：快照内容（`AccountSnapshot` Hashable 值）、
///   manual core 内容、base、catalogEpoch + catalogVersion、phase bucket；
///   **不以 Date/selectedVillageID 单独作 key**。
/// - 命中：只做动态刷新（remainingSeconds 递减 + 到期检测）；到期
///   （remaining >0 → 0）立即重建静态投影——「完成事实」翻转不动态推断。
/// - 构建：一次 `VillageCatalogProjection.project` + 派生 buildingGroups
///   （`BuildingGroupProjection.project(projection:)`，O(records)）+ 一次
///   `CraftTableProjection.project`。
///
/// 线程模型：AppModel 主 actor 持有并访问（非 Sendable，文档约定主 actor）。
/// 不引入后台计算：输入快照与输出 render 模型保持现有同步语义。
public final class VillageProjectionCache {
    /// 缓存键：真实输入身份（内容 hash 由 Hashable 值语义保证）。
    public struct Key: Hashable {
        public let villageID: UUID
        /// 快照内容身份（整个值参与 hash/==，导入/恢复替换即自动失效）。
        public let snapshot: AccountSnapshot?
        public let base: TrackerBase
        /// manual core 内容身份（Start/Cancel/Adjust/settle 即自动失效）。
        public let manualCore: ManualUpgradeCore?
        /// 目录/精制台表替换纪元（AppModel 维护；GameCatalog 非 Hashable，
        /// 用事件计数 + 版本轻量代理）。
        public let catalogEpoch: Int
        public let catalogVersion: String?
        public let phaseBucket: PhaseBucket

        public init(
            villageID: UUID,
            snapshot: AccountSnapshot?,
            base: TrackerBase,
            manualCore: ManualUpgradeCore?,
            catalogEpoch: Int,
            catalogVersion: String?,
            phaseBucket: PhaseBucket
        ) {
            self.villageID = villageID
            self.snapshot = snapshot
            self.base = base
            self.manualCore = manualCore
            self.catalogEpoch = catalogEpoch
            self.catalogVersion = catalogVersion
            self.phaseBucket = phaseBucket
        }
    }

    /// 一次 render 的组合产物。
    public struct RenderResult {
        public let projection: VillageCatalogProjection
        /// 从同一 projection.rawItems 派生的建筑组卡（O(records) 派生，
        /// 非静态投影重建）。
        public let buildingGroups: [BuildingGroup]
        public let craftTable: [CraftTableDefenseState]

        public init(
            projection: VillageCatalogProjection,
            buildingGroups: [BuildingGroup],
            craftTable: [CraftTableDefenseState]
        ) {
            self.projection = projection
            self.buildingGroups = buildingGroups
            self.craftTable = craftTable
        }
    }

    private struct Entry {
        let projection: VillageCatalogProjection
        let craftTable: [CraftTableDefenseState]
        let builtAt: Date
    }

    private var entries: [Key: Entry] = [:]
    /// 容量上限（防御；超限清空——用户村庄数少，2N+2 条目内正常）。
    private let maxEntries = 64

    /// 静态投影构建次数（性能测试断言用）。
    public private(set) var buildCount = 0
    /// 缓存命中次数（性能测试断言用）。
    public private(set) var hitCount = 0

    public init() {}

    /// 渲染村庄详情所需的全部投影（缓存 + 动态刷新）。
    public func render(
        village: VillageProfile,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        base: TrackerBase,
        now: Date,
        manualUpgradeCore: ManualUpgradeCore?,
        catalogEpoch: Int
    ) -> RenderResult {
        let key = Key(
            villageID: village.id,
            snapshot: village.accountSnapshot,
            base: base,
            manualCore: manualUpgradeCore,
            catalogEpoch: catalogEpoch,
            catalogVersion: catalog?.gameVersion,
            phaseBucket: seasonalPhases.bucket(at: now)
        )

        if let entry = entries[key] {
            let refreshed = entry.projection.refreshingTimers(
                at: now, builtAt: entry.builtAt
            )
            let craftRefreshed = entry.craftTable.refreshingModules(
                at: now, builtAt: entry.builtAt
            )
            if refreshed.expired || craftRefreshed.expired {
                // 到期：完成事实翻转（active→needsReimport 等）——
                // 立即重建静态投影，与现状每 tick 重建行为一致。
                return buildAndStore(key: key, village: village, catalog: catalog,
                                     craftTableCatalog: craftTableCatalog,
                                     seasonalPhases: seasonalPhases, base: base,
                                     now: now, manualUpgradeCore: manualUpgradeCore)
            }
            hitCount += 1
            let buildingGroups = BuildingGroupProjection.project(
                projection: refreshed.projection,
                catalog: catalog,
                base: base,
                manualUpgradeCore: manualUpgradeCore
            )
            return RenderResult(
                projection: refreshed.projection,
                buildingGroups: buildingGroups,
                craftTable: craftRefreshed.modules
            )
        }

        return buildAndStore(key: key, village: village, catalog: catalog,
                             craftTableCatalog: craftTableCatalog,
                             seasonalPhases: seasonalPhases, base: base,
                             now: now, manualUpgradeCore: manualUpgradeCore)
    }

    /// 清空缓存（AppModel 恢复/重置等全局事件可选调用；key 内容身份
    /// 已覆盖大部分失效，本方法供显式重置使用）。
    public func removeAll() {
        entries.removeAll()
    }

    private func buildAndStore(
        key: Key,
        village: VillageProfile,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        base: TrackerBase,
        now: Date,
        manualUpgradeCore: ManualUpgradeCore?
    ) -> RenderResult {
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            seasonalPhases: seasonalPhases,
            craftTableCatalog: craftTableCatalog,
            base: base,
            now: now,
            manualUpgradeCore: manualUpgradeCore
        )
        let buildingGroups = BuildingGroupProjection.project(
            projection: projection,
            catalog: catalog,
            base: base,
            manualUpgradeCore: manualUpgradeCore
        )
        let craftTable = CraftTableProjection.project(
            village: village,
            catalog: craftTableCatalog,
            base: base,
            seasonalPhases: seasonalPhases,
            now: now
        )
        if entries.count >= maxEntries {
            entries.removeAll()
        }
        entries[key] = Entry(projection: projection, craftTable: craftTable, builtAt: now)
        buildCount += 1
        return RenderResult(
            projection: projection,
            buildingGroups: buildingGroups,
            craftTable: craftTable
        )
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter VillageProjectionCacheTests 2>&1 | tail -5`
Expected: PASS（8 tests, 0 failures）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/VillageProjectionCache.swift Tests/COCHelperCoreTests/VillageProjectionCacheTests.swift
git commit -m "feat(perf): add village projection cache with key-bound invalidation (Issue #200)"
```

---

### Task 4: 升级总览单趟组合入口（overviewRender）

**Files:**
- Modify: `Sources/COCHelperCore/UpgradeOverviewProjection.swift`
- Test: `Tests/COCHelperCoreTests/UpgradeOverviewProjectionTests.swift`（追加测试）

- [ ] **Step 1: 写失败测试**

在 `Tests/COCHelperCoreTests/UpgradeOverviewProjectionTests.swift` 追加（文件末尾，class 内）：

```swift
    // MARK: - Issue #200 单趟组合入口

    /// overviewRender 一次调用只执行一次 canonical 投影（村庄×base 各一次，
    /// 不因 active+pending+state 翻倍）。
    func testOverviewRenderSinglePassProjection() throws {
        let villages = try makeVillagesForRender()
        var providerCalls = 0
        let render = UpgradeOverviewProjection.overviewRender(
            from: villages,
            catalog: syntheticCatalog,
            manualUpgradeCores: [:],
            at: Date(timeIntervalSince1970: 1_000_000)
        ) { _, _, _ in
            providerCalls += 1
            // provider 内必须实际构建（保持投影一致），此处委托真实现。
            return UpgradeOverviewProjection.defaultProjectionProvider(
                from: villages, catalog: syntheticCatalog, seasonalPhases: .empty,
                manualUpgradeCores: [:]
            )(nil, .home, Date())
        }
        XCTAssertEqual(providerCalls, villages.count * TrackerBase.allCases.count)
        XCTAssertFalse(render.active.isEmpty)
        XCTAssertEqual(render.state.manualActiveCount, 0)
    }

    /// 组合入口结果与 overviewRecords + overviewState 完全一致（golden parity）。
    func testOverviewRenderMatchesLegacyAPIs() throws {
        let villages = try makeVillagesForRender()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let provider = UpgradeOverviewProjection.defaultProjectionProvider(
            from: villages, catalog: syntheticCatalog, seasonalPhases: .empty,
            manualUpgradeCores: [:]
        )
        let render = UpgradeOverviewProjection.overviewRender(
            from: villages, catalog: syntheticCatalog, manualUpgradeCores: [:], at: now
        ) { village, base, tickNow in
            provider(village, base, tickNow)
        }
        let legacy = UpgradeOverviewProjection.overviewRecords(
            from: villages, catalog: syntheticCatalog, manualUpgradeCores: [:], at: now
        )
        let state = UpgradeOverviewProjection.overviewState(
            from: villages, catalog: syntheticCatalog, manualUpgradeCores: [:], at: now
        )
        XCTAssertEqual(render.active, legacy.active)
        XCTAssertEqual(render.pending, legacy.pending)
        XCTAssertEqual(render.state.manualActiveCount, state.manualActiveCount)
        XCTAssertEqual(render.state.importedActiveCount, state.importedActiveCount)
        XCTAssertEqual(render.state.deduplicatedDisplayCount, state.deduplicatedDisplayCount)
        XCTAssertEqual(render.state.manualCompletedCount, state.manualCompletedCount)
        XCTAssertEqual(render.state.completedRecently, state.completedRecently)
        XCTAssertEqual(render.state.activeRecords, state.activeRecords)
        XCTAssertEqual(render.state.attentionRecords, state.attentionRecords)
        XCTAssertEqual(render.state.needsReimportRecords, state.needsReimportRecords)
    }

    /// 手工构造 render 用村庄（复用文件顶部 fixture 模式：快照直构）。
    private func makeVillagesForRender() throws -> [VillageProfile] {
        var sections: [String: [AccountItem]] = [:]
        sections["buildings"] = [
            AccountItem(id: "buildings:0", section: "buildings", dataID: 1_000_001,
                        name: "加农炮", level: 1, count: 1, timerSeconds: 300,
                        remainingSeconds: 300, isNew: false),
        ]
        let snapshot = try AccountSnapshot(
            importedAt: Date(timeIntervalSince1970: 1_000_000),
            tag: "#RENDER", name: "渲染村", objectSections: sections
        )
        return [
            VillageProfile(id: UUID(), name: "渲染村", tag: "#RENDER",
                           officialTag: nil, accountSnapshot: snapshot)
        ]
    }
```

说明：`defaultProjectionProvider` 是 Task 4 Step 3 新增的静态工厂（默认 provider 的显式入口，便于测试注入同一 provider）。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter UpgradeOverviewProjectionTests/testOverviewRender 2>&1 | tail -5`
Expected: FAIL（`overviewRender` 不存在）

- [ ] **Step 3: 实现**

3a. `Sources/COCHelperCore/UpgradeOverviewProjection.swift` 新增组合结果类型（`UpgradeOverviewState` 定义之后）：

```swift
/// Issue #200：总览单趟组合结果——active/pending/state 由同一次
/// canonical 投影派生，UI 一个 tick 只调用一次 `overviewRender`。
public struct UpgradeOverviewRender: Sendable {
    public let active: [UpgradeDisplayRecord]
    public let pending: [UpgradeDisplayRecord]
    public let state: UpgradeOverviewState

    public init(
        active: [UpgradeDisplayRecord],
        pending: [UpgradeDisplayRecord],
        state: UpgradeOverviewState
    ) {
        self.active = active
        self.pending = pending
        self.state = state
    }
}
```

3b. `allRecords` 改为接受 provider（替换 L192-233 的签名与 `project` 调用）：

```swift
    private static func allRecords(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        manualUpgradeCores: [UUID: ManualUpgradeCore],
        at now: Date,
        projectionProvider: (VillageProfile, TrackerBase, Date) -> VillageCatalogProjection
    ) -> [UpgradeDisplayRecord] {
        villages.flatMap { village in
            TrackerBase.allCases.flatMap { base in
                let projection = projectionProvider(village, base, now)
                let tracked = projection.items.filter { $0.status != .unavailable }
                let displayRecords = tracked.filter { $0.status != .available }
                let metrics = projection.progressMetrics
                return displayRecords.map { item in
                    UpgradeDisplayRecord(
                        id: village.id.uuidString + ":" + base.rawValue + ":" + item.id,
                        villageID: village.id,
                        villageName: village.name,
                        villageTag: village.tag,
                        base: base,
                        item: item,
                        catalogVersion: projection.catalogVersion,
                        villageMetrics: metrics
                    )
                }
            }
        }
    }
```

3c. 新增核心实现 + 组合入口 + 默认 provider 工厂（`allRecords` 之后）：

```swift
    /// Issue #200：默认投影提供者（等价于直接调用
    /// `VillageCatalogProjection.project`；供 `overviewRender` 默认参数与
    /// 测试注入同一 provider 使用）。
    public static func defaultProjectionProvider(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        manualUpgradeCores: [UUID: ManualUpgradeCore]
    ) -> (VillageProfile, TrackerBase, Date) -> VillageCatalogProjection {
        { village, base, now in
            VillageCatalogProjection.project(
                village: village,
                catalog: catalog,
                seasonalPhases: seasonalPhases,
                base: base,
                now: now,
                manualUpgradeCore: manualUpgradeCores[village.id]
            )
        }
    }

    /// 单趟核心：一次 canonical 投影产出 active/pending/state。
    private static func overviewRenderCore(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable,
        manualUpgradeCores: [UUID: ManualUpgradeCore],
        at now: Date,
        recentlyCompletedWindow: TimeInterval,
        projectionProvider: (VillageProfile, TrackerBase, Date) -> VillageCatalogProjection
    ) -> UpgradeOverviewRender {
        let records = allRecords(
            from: villages,
            catalog: catalog,
            seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores,
            at: now,
            projectionProvider: projectionProvider
        )

        let active = records.filter(\.item.isEffectivelyUpgrading)
            .sorted { activeOrder($0, $1, at: now) }
        let pending = records.filter(\.item.effectivelyNeedsReimport)
            .sorted(by: pendingOrder)
        let attention = records.filter { record in
            guard let status = record.item.effectiveState?.status else { return false }
            return status == .conflict || status == .unknown || status == .needsReimport
        }

        let manualActiveCount = manualUpgradeCores.values.reduce(0) {
            $0 + $1.activeRecords.count
        }
        let manualCompletedCount = manualUpgradeCores.values.reduce(0) {
            $0 + $1.completedHistory.count
        }
        var importedActiveCount = 0
        var deduplicatedDisplayCount = 0
        let activeByKey = Dictionary(
            grouping: active,
            by: { Self.stableKey(villageID: $0.villageID, item: $0.item) }
        )
        for rows in activeByKey.values {
            let timerRows = rows.filter { $0.item.timerSeconds != nil }
            if !timerRows.isEmpty {
                importedActiveCount += timerRows.count
                deduplicatedDisplayCount += timerRows.count
            } else if !rows.isEmpty {
                deduplicatedDisplayCount += 1
            }
        }

        let completions: [UpgradeRecentCompletion] = manualUpgradeCores
            .flatMap { villageID, core in
                core.completedHistory.compactMap { record in
                    guard record.expectedEndAt >= now.addingTimeInterval(-recentlyCompletedWindow)
                    else { return nil }
                    let name = catalog?.item(
                        section: record.itemKey.rawSection,
                        dataID: record.itemKey.dataID
                    )?.name ?? record.itemKey.stableID
                    return UpgradeRecentCompletion(
                        villageID: villageID,
                        itemKey: record.itemKey,
                        itemName: name,
                        targetLevel: record.targetLevel,
                        quantity: record.quantity,
                        completedAt: record.expectedEndAt
                    )
                }
            }
            .sorted { $0.completedAt > $1.completedAt }

        return UpgradeOverviewRender(
            active: active,
            pending: pending,
            state: UpgradeOverviewState(
                manualActiveCount: manualActiveCount,
                importedActiveCount: importedActiveCount,
                deduplicatedDisplayCount: deduplicatedDisplayCount,
                manualCompletedCount: manualCompletedCount,
                completedRecently: completions,
                activeRecords: active,
                attentionRecords: attention,
                needsReimportRecords: pending
            )
        )
    }

    /// Issue #200：总览组合入口——一次投影同时产出 active/pending/state。
    ///
    /// `projectionProvider` 默认直接投影；UI 应注入
    /// `VillageProjectionCache`（AppModel 侧），同一 tick 不再重复执行
    /// canonical all-village/all-base 投影。
    public static func overviewRender(
        from villages: [VillageProfile],
        catalog: GameCatalog?,
        seasonalPhases: SeasonalPhaseTable = .empty,
        manualUpgradeCores: [UUID: ManualUpgradeCore] = [:],
        at now: Date = Date(),
        recentlyCompletedWindow: TimeInterval = 7 * 24 * 3600,
        projectionProvider: (VillageProfile, TrackerBase, Date) -> VillageCatalogProjection? = nil
    ) -> UpgradeOverviewRender {
        let provider = projectionProvider
            ?? defaultProjectionProvider(
                from: villages, catalog: catalog,
                seasonalPhases: seasonalPhases, manualUpgradeCores: manualUpgradeCores)
        return overviewRenderCore(
            from: villages, catalog: catalog, seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores, at: now,
            recentlyCompletedWindow: recentlyCompletedWindow,
            projectionProvider: { village, base, tickNow in
                provider(village, base, tickNow) ?? VillageCatalogProjection.project(
                    village: village, catalog: catalog, seasonalPhases: seasonalPhases,
                    base: base, now: tickNow,
                    manualUpgradeCore: manualUpgradeCores[village.id]
                )
            }
        )
    }
```

注意：provider 类型用 `(VillageProfile, TrackerBase, Date) -> VillageCatalogProjection?`（可选）是为了让 AppModel 的缓存 provider 能在村庄缺失时回退直接投影；`nil` 时内部走默认。

3d. `overviewRecords` / `overviewState` 改为委托 `overviewRenderCore`（保留各自 signpost 与签名）：

`overviewRecords`（L77-106）body 替换为：

```swift
        let __perfID = PerformanceSignpost.begin(
            .upgradeOverviewRecords,
            dataScale: villages.count,
            count: villages.reduce(0) {
                $0 + ($1.accountSnapshot?.objectSections.reduce(0) { $0 + $1.value.count } ?? 0)
            }
        )
        defer { PerformanceSignpost.end(.upgradeOverviewRecords, id: __perfID) }
        let provider = defaultProjectionProvider(
            from: villages, catalog: catalog,
            seasonalPhases: seasonalPhases, manualUpgradeCores: manualUpgradeCores)
        let render = overviewRenderCore(
            from: villages, catalog: catalog, seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores, at: now,
            recentlyCompletedWindow: 7 * 24 * 3600,
            projectionProvider: provider
        )
        return (active: render.active, pending: render.pending)
```

`overviewState`（L300-396）body 替换为：

```swift
        let __perfID = PerformanceSignpost.begin(
            .upgradeOverviewState,
            dataScale: villages.count,
            count: villages.reduce(0) {
                $0 + ($1.accountSnapshot?.objectSections.reduce(0) { $0 + $1.value.count } ?? 0)
            }
        )
        defer { PerformanceSignpost.end(.upgradeOverviewState, id: __perfID) }
        let provider = defaultProjectionProvider(
            from: villages, catalog: catalog,
            seasonalPhases: seasonalPhases, manualUpgradeCores: manualUpgradeCores)
        return overviewRenderCore(
            from: villages, catalog: catalog, seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores, at: now,
            recentlyCompletedWindow: recentlyCompletedWindow,
            projectionProvider: provider
        ).state
```

注意：`overviewState` 的旧 body 中 `allRecords` 调用与去重/计数逻辑被 `overviewRenderCore` 吸收；`stableKey` 保留。**删除旧 overviewState body 中重复的过滤/计数代码**（避免两套实现漂移）。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter UpgradeOverviewProjectionTests 2>&1 | tail -5`
Expected: PASS（现有 + 新增全绿，含 testOverviewRenderSinglePassProjection / testOverviewRenderMatchesLegacyAPIs）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/UpgradeOverviewProjection.swift Tests/COCHelperCoreTests/UpgradeOverviewProjectionTests.swift
git commit -m "feat(perf): single-pass overview render with combined active/pending/state (Issue #200)"
```

---

### Task 5: AppModel 集成（catalogEpoch + villageRender + overviewRender）

**Files:**
- Modify: `Sources/COCHelperApp/AppModel.swift`

- [ ] **Step 1: 实现**

1a. 在 `AppModel` 类属性区（`manualUpgradeCores` 附近）追加：

```swift
    /// Issue #200：目录/精制台表替换纪元。当前目录为 lazy 单例（启动加载，
    /// 无运行中替换），机制为未来目录更新功能准备；任一替换点必须递增。
    public private(set) var catalogEpoch: Int = 0

    /// Issue #200：村庄静态投影缓存（主 actor 持有；见 VillageProjectionCache
    /// 线程模型文档）。
    private let projectionCache = VillageProjectionCache()
```

1b. 在 `AppModel` 类中追加两个方法（放 `snapshotHistoryProjection` 附近或 manual 相关方法附近均可）：

```swift
    // MARK: - Issue #200 村庄渲染（缓存）

    /// Village Detail 的组合渲染：静态投影 + 建筑组卡 + 精制台（缓存）。
    /// `now` 只做动态刷新；静态输入变化（快照/manual/catalog/base/phase bucket）
    /// 由缓存键自动失效。返回 nil 仅当村庄不存在（fail-closed，不猜
    /// selectedVillageID）。
    public func villageRender(
        villageID: UUID,
        base: TrackerBase,
        now: Date
    ) -> VillageProjectionCache.RenderResult? {
        guard let village = villages.first(where: { $0.id == villageID }) else {
            return nil
        }
        return projectionCache.render(
            village: village,
            catalog: gameCatalog,
            craftTableCatalog: craftTableCatalog,
            seasonalPhases: seasonalPhases,
            base: base,
            now: now,
            manualUpgradeCore: manualUpgradeCores[villageID],
            catalogEpoch: catalogEpoch
        )
    }

    /// 升级总览组合渲染（单趟 canonical 投影，经 VillageProjectionCache）。
    public func overviewRender(
        villages: [VillageProfile],
        manualUpgradeCores: [UUID: ManualUpgradeCore],
        now: Date
    ) -> UpgradeOverviewRender {
        UpgradeOverviewProjection.overviewRender(
            from: villages,
            catalog: gameCatalog,
            seasonalPhases: seasonalPhases,
            manualUpgradeCores: manualUpgradeCores,
            at: now,
            projectionProvider: { village, base, tickNow in
                self.projectionCache.render(
                    village: village,
                    catalog: self.gameCatalog,
                    craftTableCatalog: self.craftTableCatalog,
                    seasonalPhases: self.seasonalPhases,
                    base: base,
                    now: tickNow,
                    manualUpgradeCore: manualUpgradeCores[village.id],
                    catalogEpoch: self.catalogEpoch
                ).projection
            }
        )
    }
```

- [ ] **Step 2: 构建确认**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 3: Commit**

```bash
git add Sources/COCHelperApp/AppModel.swift
git commit -m "feat(perf): expose cached village render and overview render from AppModel (Issue #200)"
```

---

### Task 6: View 接线（VillageDetailView + ContentView）

**Files:**
- Modify: `Sources/COCHelper/VillageDetailView.swift`
- Modify: `Sources/COCHelper/ContentView.swift`

- [ ] **Step 1: VillageDetailView 改走 model.villageRender**

`VillageDetailView.swift` 的 `detailContent(village:now:)`（当前 L134-196 附近）：

```swift
    private func detailContent(village: VillageProfile, now: Date) -> some View {
        // Issue #200：静态投影经 AppModel 缓存（60s tick 只做动态刷新）；
        // 显式 villageID 为数据来源，不得因缓存读取 selectedVillageID 猜目标。
        guard let render = model.villageRender(
            villageID: villageID, base: selectedBase, now: now
        ) else {
            return AnyView(ContentUnavailableView(
                "村庄不存在",
                systemImage: "questionmark.folder",
                description: Text("该村庄可能已被删除。")
            ))
        }
        let projection = render.projection
        let buildingGroups = render.buildingGroups
        let craftTable = render.craftTable
        // 以下派生逻辑不变（trackedItems/displayItems/groups/total/...
        // 全部在缓存 projection 上做 O(items) 过滤/统计，不重跑静态投影）。
        ...
    }
```

具体改法：删除原 `detailContent` 中三个投影调用（`VillageCatalogProjection.project`、`BuildingGroupProjection.project(village:...)`、`CraftTableProjection.project`），替换为上面 `guard let render` 解包；**其余代码（L96-155 的 trackedItems/displayItems/groups/total/progressMetrics/statsByKey/filtered/groups/groupIDs/groupByInstanceID 派生）原样保留**，仅把 `projection`/`buildingGroups`/`craftTable` 三个局部变量来源改为 `render`。

若 `detailContent` 返回类型是 `some View`（非 AnyView），则把 guard 分支改为返回 `ContentUnavailableView` 即可（同一 `some View` 类型要求：确认两个分支返回类型一致——`detailContent` 当前返回 `ScrollView`+`VStack` 组合的 `some View`，ContentUnavailableView 与它是同一 opaque 类型（都满足 View），SwiftUI 中 `some View` 函数体内不同分支返回不同具体类型需要 `@ViewBuilder` 或 `AnyView`。**查看当前 detailContent 是否有 @ViewBuilder**——如无，则村庄 nil 分支保留外层 Group 已有处理，此处直接 `let render = model.villageRender(...)!`（village 存在时 render 必非 nil，防御由外层 if let village 保证），或返回空 `Color.clear`。**决定**：村庄不存在时外层 `if let village` 已拦截，`detailContent` 只在 village 存在时调用 → `render` 必非 nil，用 `guard let render = ... else { return Color.clear.frame(height: 0) }` 兜底（不改变 `some View` 单一类型）。

- [ ] **Step 2: ContentView TrackerOverviewContent 改走组合入口**

2a. `TrackerOverviewContent`（L622-658）增加 provider 参数并改 body：

```swift
private struct TrackerOverviewContent: View {
    let villages: [VillageProfile]
    let catalog: GameCatalog?
    let seasonalPhases: SeasonalPhaseTable
    let manualUpgradeCores: [UUID: ManualUpgradeCore]
    let scopeLabel: String
    let panelTitle: String
    let now: Date
    /// Issue #200：单趟组合渲染（AppModel 注入缓存 provider）。
    let overviewProvider: ([VillageProfile], [UUID: ManualUpgradeCore], Date) -> UpgradeOverviewRender

    var body: some View {
        // 单趟组合：active/pending/state 一次取得，同一 tick 只执行一次
        // canonical all-village/all-base 投影（issue #200 验收）。
        let render = overviewProvider(villages, manualUpgradeCores, now)

        VStack(alignment: .leading, spacing: 18) {
            TrackerMetricsView(
                villages: villages,
                records: render.active,
                scopeLabel: scopeLabel,
                catalog: catalog,
                seasonalPhases: seasonalPhases,
                now: now
            )
            CatalogStatusNote(catalog: catalog)
            ManualUpgradeStatePanel(
                state: render.state,
                now: now
            )
            ActiveUpgradesPanel(
                records: render.active,
                pendingReimport: render.pending,
                now: now,
                title: panelTitle
            )
            TrackerOverviewFreshnessNote(villages: villages)
        }
    }
}
```

2b. 两处调用（L677-699）加 provider 参数：

```swift
                            overviewProvider: { villages, cores, tickNow in
                                model.overviewRender(
                                    villages: villages,
                                    manualUpgradeCores: cores,
                                    now: tickNow
                                )
                            },
```

（L678-686 与 L689-698 两处都加；注意 `manualUpgradeCores` 局部变量名与闭包参数 `cores` 不冲突。）

- [ ] **Step 3: 构建 + 全量测试**

Run: `swift test 2>&1 | tail -5`
Expected: All tests passed（注意：COCHelper target 无 XCTest 测试，UI 编译通过即可；全量 COCHelperCoreTests 不受影响）

- [ ] **Step 4: Commit**

```bash
git add Sources/COCHelper/VillageDetailView.swift Sources/COCHelper/ContentView.swift
git commit -m "feat(perf): wire cached render into village detail and overview views (Issue #200)"
```

---

### Task 7: AppModel 层集成测试（seed 重放 + tick 不重建 + 失效矩阵）

**Files:**
- Test: `Tests/COCHelperCoreTests/AppModelProjectionCacheTests.swift`（新建）

- [ ] **Step 1: 写测试**

`Tests/COCHelperCoreTests/AppModelProjectionCacheTests.swift`:

```swift
import XCTest
@testable import COCHelperCore
@testable import COCHelperApp

/// Issue #200：AppModel 集成——#197 perf seed 重放下，
/// - 同一 tick 序列不重复构建静态投影（buildCount 不增）；
/// - 导入新快照 / manual 命令后重建（key 内容身份自动失效）；
/// - overviewRender 单趟。
final class AppModelProjectionCacheTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelProjectionCacheTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSeededModel() throws -> (AppModel, URL) {
        let model = AppModel(defaults: defaults, historyStore: TestSnapshotHistoryStore())
        let fixtureDirectory = try XCTUnwrap(Bundle.module.resourceURL)
        XCTAssertTrue(model.loadPerformanceSample(fixtureDirectory: fixtureDirectory))
        return (model, fixtureDirectory)
    }

    /// 60s tick 序列：静态投影只构建一次；remaining 动态递减。
    @MainActor
    func testTicksDoNotRebuildStaticProjection() throws {
        let (model, _) = try makeSeededModel()
        let village = try XCTUnwrap(model.villages.first(where: { $0.tag == "#ANONYMIZED" }))
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        let r0 = try XCTUnwrap(model.villageRender(villageID: village.id, base: .home, now: t0))
        XCTAssertEqual(r0.projection.items.count, village.accountSnapshot?.objectSections.values.reduce(0) { $0 + $1.count } ?? 0)

        // 同 bucket 内 5 个 tick：不重建。
        for i in 1...5 {
            let r = try XCTUnwrap(model.villageRender(
                villageID: village.id, base: .home, now: t0.addingTimeInterval(TimeInterval(i * 60))
            ))
            XCTAssertEqual(r.projection.items.count, r0.projection.items.count)
        }
    }

    /// 导入新快照 → key 内容身份变化 → 自动重建。
    @MainActor
    func testSnapshotImportRebuilds() throws {
        let (model, fixtureDirectory) = try makeSeededModel()
        let village = try XCTUnwrap(model.villages.first(where: { $0.tag == "#ANONYMIZED" }))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let before = try XCTUnwrap(model.villageRender(villageID: village.id, base: .home, now: t0))

        // 重新导入 home fixture（内容相同但 importedAt 更新 → 新身份）。
        let homeURL = fixtureDirectory.appendingPathComponent("perf_account_snapshot_home.json")
        model.importText = try String(contentsOf: homeURL, encoding: .utf8)
        model.parseAccountText()
        XCTAssertTrue(model.applyPendingAccountSnapshot())

        let after = try XCTUnwrap(model.villageRender(
            villageID: model.villages[0].id, base: .home, now: t0.addingTimeInterval(60)
        ))
        XCTAssertNotEqual(after.projection.items, before.projection.items)
    }

    /// overviewRender 单趟：一个 tick 内 canonical 投影执行村庄×base 次
    ///（经缓存 provider，且与 overviewRecords/overviewState 一致）。
    @MainActor
    func testOverviewRenderSinglePassThroughAppModel() throws {
        let (model, _) = try makeSeededModel()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let render = model.overviewRender(
            villages: model.villages,
            manualUpgradeCores: model.manualUpgradeCores,
            now: t0
        )
        XCTAssertFalse(render.active.isEmpty || render.pending.isEmpty)
        XCTAssertEqual(render.state.manualActiveCount,
                       model.manualUpgradeCores.values.reduce(0) { $0 + $1.activeRecords.count })

        // 第二次调用（同 bucket）命中缓存：投影不重建（由 cache buildCount
        // 覆盖——AppModel 不暴露 buildCount，此处验证结果一致即可）。
        let render2 = model.overviewRender(
            villages: model.villages,
            manualUpgradeCores: model.manualUpgradeCores,
            now: t0.addingTimeInterval(60)
        )
        XCTAssertEqual(render2.active.count, render.active.count)
    }
}
```

说明：`model.villages[0].id` 在导入后可能不同于原 village（导入替换占位/追加）——导入逻辑以现有测试（AppModelPerfSeedTests）行为为准，断言只比较 items 是否变化。若 `applyPendingAccountSnapshot` 导入到原 village 则 `after.projection.items` 与 before 相同的场景需调整断言（用 `XCTAssertNotEqual(model.villages[0].id, village.id)` 或比较 importedAt）——**实现时按实际行为调整，原则：内容身份变化（importedAt 或记录变化）必须重建**。

- [ ] **Step 2: 运行测试确认通过**

Run: `swift test --filter AppModelProjectionCacheTests 2>&1 | tail -5`
Expected: PASS（3 tests, 0 failures）

- [ ] **Step 3: 全量验证**

```bash
swift test 2>&1 | tail -3        # 全量测试（1622+ 新增，0 failures）
swift build -c release 2>&1 | tail -3   # Release build
git diff --check                 # 空白错误检查
```

- [ ] **Step 4: Commit**

```bash
git add Tests/COCHelperCoreTests/AppModelProjectionCacheTests.swift
git commit -m "test(perf): AppModel integration tests for cached projection ticks and invalidation (Issue #200)"
```

---

### Task 8: 文档与收尾

- [ ] **Step 1: 更新 docs/plans 记录（可选但推荐）**

在 `docs/plans/` 下追加 `2026-08-19-issue200-projection-cache.md` 执行结果摘要（本计划执行完成后的实际 diff 概览、验证命令输出、遗留项）。若仓库无该惯例则跳过（不主动新建文档）。

- [ ] **Step 2: 全量最终验证**

```bash
swift test 2>&1 | tail -3
swift build -c release 2>&1 | tail -3
git diff --check
git status
git log --oneline -10
```

- [ ] **Step 3: 自查 issue #200 验收标准**

- [ ] Village Detail 60s tick 不重复构建（Task 3/7 计数测试）✓
- [ ] 总览同一 tick 单趟 canonical 投影（Task 4 单趟计数测试）✓
- [ ] cache key 覆盖 village/snapshot/base/manual/catalogEpoch/phase bucket（Task 1/3 测试）✓
- [ ] dynamic 更新不制造错误等级/完成事实（Task 2：refresh 只动 remaining；到期重建）✓
- [ ] 失效测试（Task 3/7 矩阵）✓
- [ ] unknown/unverified/unavailable/partial/conflict/last-good/coverage 语义不变（golden parity 测试 Task 3/4）✓
- [ ] canonical projection 次数显著下降证据（buildCount/hitCount 计数测试）✓
- [ ] 全量 Swift 测试、Release build、git diff --check ✓

- [ ] **Step 4: 提交剩余改动（如有）并推送分支**

```bash
git status   # 确认无遗漏
git push -u origin codex/issue-200-projection-cache
```

---

## 自检记录（Self-Review）

- **Spec 覆盖**：issue 三块（detail 缓存 / 总览组合 / 严格失效）→ Task 1-3（缓存引擎）+ Task 4（组合入口）+ Task 5-6（接线）+ Task 7（失效/性能验收测试）；"不把历史 cache 当静态投影 cache"→ 未触碰 snapshotHistoryProjectionCache ✓；"详情页显式 villageID"→ Task 6 ✓；"Sendable/actor 边界"→ 不做后台计算（issue 允许）✓；"旧异步任务不覆盖新结果"→ 无异步（同步缓存）✓。
- **Placeholder 扫描**：Task 2 Step 3b/3d 中 `EffectiveVillageItemState`/`VillageCatalogProjection` 的 init 参数标注"按实际定义核对"——这两个 init 参数较多（20+/13+），计划中列出完整参数有漂移风险，实现时以实际源码为准（测试会验证字段级正确性）；其余步骤均为完整代码。
- **类型一致性**：`PhaseBucket`（Task 1）→ `Key.phaseBucket`（Task 3）✓；`RenderResult`（Task 3）→ `AppModel.villageRender` 返回（Task 5）✓；`UpgradeOverviewRender`（Task 4）→ `model.overviewRender`（Task 5）→ ContentView（Task 6）✓；`defaultProjectionProvider`（Task 4）→ Task 4 测试 ✓。