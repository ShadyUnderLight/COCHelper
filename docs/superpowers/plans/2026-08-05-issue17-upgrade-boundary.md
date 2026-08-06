# Issue #17 升级状态边界契约 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为「基于真实 JSON 的可观测升级状态与队列不可用边界」（Issue #17）补上结构化队列不可用契约类型与验证性测试，锁定"不伪造队列信息"的审计边界。

**Architecture:** 新增一个纯函数契约类型（`QueueTimelineResolver` + `QueueTimelineUnavailable` + `QueueTimelineResolution`），永远返回结构化不可用状态（真实账号 JSON 实测零队列字段）；其余验收点（分区/嵌套/推断标记/needsReimport 等）已在 #14-#16/#24 实现并有测试，本轮只补 3 组验证性测试（数组重排稳定性、boost 非归属、fixture 队列/helper 审计）。

**Tech Stack:** Swift / SwiftPM / XCTest（property 风格用项目既有 `SeededRNG` 固定种子）

**决策记录（SDD 3 候选投票，2026-08-05）：**
- 候选 A（仅测试+文档）：否决——测试是重言式（`RawAccountItem` 只解码已知键，结构上不可能含队列字段，断言恒绿），验收 #4 无可测试闭环。
- 候选 B（独立契约类型）：**通过**（采纳 minor 修改：显式 public init + 静态常量 `missingQueueFields`）。
- 候选 C（VillageItemState 派生属性）：否决——`VillageItemState`（`Sources/COCHelperCore/VillageCatalogProjection.swift:19-101`）不持有快照时间/目录版本，关联值恒 nil 且失真。
- 采纳 B + C 评审员建议：契约挂独立纯函数（不污染纯投影值）；`UpgradeDisplayRecord` 不加字段（YAGNI）。
- follow-up（不纳入本轮）：`RawAccountItem` item 级未知键被静默丢弃（顶层有 `unknownTopLevelKeys` 诊断、item 级没有），未来 JSON 出现队列字段时的可观测入口——另开 Issue。

---

### Task 1: QueueTimeline 契约类型（TDD）

**Files:**
- Create: `Sources/COCHelperCore/QueueTimeline.swift`
- Create: `Tests/COCHelperCoreTests/QueueTimelineResolverTests.swift`

- [ ] **Step 1: 写失败测试（RED）**

创建 `Tests/COCHelperCoreTests/QueueTimelineResolverTests.swift`：

```swift
import XCTest
@testable import COCHelperCore

/// Issue #17：队列时间线边界契约测试。
///
/// 真实账号 JSON（anonymized_account_snapshot.json）实测不存在任何队列字段
/// （queueID/queueKind/assignedItemID/targetLevel/startedAt/totalDurationSeconds 均 0 处），
/// 因此契约必须恒返回结构化 unavailable，禁止编造队列信息。
final class QueueTimelineResolverTests: XCTestCase {
    private func loadFixtureSnapshot() throws -> AccountSnapshot {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "anonymized_account_snapshot", withExtension: "json")
        )
        return try AccountSnapshotImporter.parse(
            String(data: Data(contentsOf: url), encoding: .utf8) ?? "",
            now: Date(timeIntervalSince1970: 1_785_736_933) // == fixture timestamp：age = 0
        )
    }

    private func makeVillage(snapshot: AccountSnapshot) -> VillageProfile {
        VillageProfile(
            name: "测试村庄",
            accountSnapshot: snapshot
        )
    }

    /// 真实 fixture 的升级项 → 结构化 unavailable，缺失字段精确、原因含项目名、溯源透传。
    func testRealFixtureUpgradingItemReturnsStructuredUnavailable() throws {
        let snapshot = try loadFixtureSnapshot()
        let village = makeVillage(snapshot: snapshot)
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: GameCatalog.loadBundled(),
            base: .home,
            now: Date(timeIntervalSince1970: 1_785_736_933)
        )
        let upgrading = try XCTUnwrap(projection.items.first { $0.isUpgrading })

        let resolution = QueueTimelineResolver.resolve(
            for: upgrading,
            snapshotCapturedAt: snapshot.capturedAt,
            catalogVersion: projection.catalogVersion
        )

        guard case .unavailable(let state) = resolution else {
            return XCTFail("队列时间线必须为 unavailable（JSON 无队列字段）")
        }
        XCTAssertEqual(state.missingFields, QueueTimelineUnavailable.missingQueueFields)
        XCTAssertEqual(state.missingFields, [
            "queueID", "queueKind", "assignedItemID",
            "targetLevel", "startedAt", "totalDurationSeconds",
        ])
        XCTAssertTrue(state.reason.contains(upgrading.name), "原因应包含请求的项目名")
        XCTAssertTrue(state.reason.contains("队列"), "原因应明确说明队列信息缺失")
        XCTAssertEqual(state.snapshotCapturedAt, snapshot.capturedAt)
        XCTAssertEqual(state.catalogVersion, "18.400.13")
    }

    /// 非升级项同样不可用：与升级状态无关，任何项目都无队列信息。
    func testNonUpgradingItemAlsoUnavailable() throws {
        let snapshot = try loadFixtureSnapshot()
        let village = makeVillage(snapshot: snapshot)
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: GameCatalog.loadBundled(),
            base: .home,
            now: Date(timeIntervalSince1970: 1_785_736_933)
        )
        let idle = try XCTUnwrap(projection.items.first { !$0.isUpgrading })

        let resolution = QueueTimelineResolver.resolve(
            for: idle,
            snapshotCapturedAt: nil,
            catalogVersion: nil
        )
        guard case .unavailable = resolution else {
            return XCTFail("非升级项同样不可用")
        }
    }

    /// 溯源缺失时如实透传 nil，不伪造快照时间/目录版本。
    func testNilProvenancePassesThrough() throws {
        let snapshot = try loadFixtureSnapshot()
        let village = makeVillage(snapshot: snapshot)
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: nil,
            base: .home,
            now: Date(timeIntervalSince1970: 1_785_736_933)
        )
        let item = try XCTUnwrap(projection.items.first)

        let resolution = QueueTimelineResolver.resolve(
            for: item,
            snapshotCapturedAt: nil,
            catalogVersion: nil
        )
        guard case .unavailable(let state) = resolution else {
            return XCTFail("应为 unavailable")
        }
        XCTAssertNil(state.snapshotCapturedAt)
        XCTAssertNil(state.catalogVersion)
    }

    /// Codable 契约：编码→解码 round-trip 保持载荷不变（诊断可持久化）。
    func testResolutionCodableRoundTrip() throws {
        let original = QueueTimelineResolution.unavailable(QueueTimelineUnavailable(
            reason: "测试原因",
            missingFields: QueueTimelineUnavailable.missingQueueFields,
            snapshotCapturedAt: Date(timeIntervalSince1970: 1_785_736_333),
            catalogVersion: "18.400.13"
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueueTimelineResolution.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// 缺失字段清单是契约：与 issue 记载的不可得字段一致，改动即破坏契约。
    func testMissingFieldsAreExactContract() {
        XCTAssertEqual(QueueTimelineUnavailable.missingQueueFields, [
            "queueID", "queueKind", "assignedItemID",
            "targetLevel", "startedAt", "totalDurationSeconds",
        ])
    }
}
```

- [ ] **Step 2: 运行确认 RED**

Run: `swift test --filter QueueTimelineResolverTests`
Expected: 编译失败（`QueueTimelineResolver` 不存在）→ 测试不通过（RED 成立）

- [ ] **Step 3: 写最小实现**

创建 `Sources/COCHelperCore/QueueTimeline.swift`：

```swift
import Foundation

/// Issue #17：队列时间线边界契约。
///
/// 真实账号 JSON（anonymized_account_snapshot.json 实测）不提供队列身份
/// （queueID/queueKind/assignedItemID）、目标等级（targetLevel）或排程
/// （startedAt/totalDurationSeconds）。本类型是「请求精确队列时间线」的唯一
/// 契约入口：当前一律返回结构化不可用状态，禁止编造队列信息；未来 JSON
/// 出现明确队列字段时另开 Issue 扩展 `QueueTimelineResolution`。
public struct QueueTimelineUnavailable: Codable, Hashable, Sendable {
    /// 已知的队列相关字段；当前解码器不读取，fixture 实测 0 处。
    public static let missingQueueFields: [String] = [
        "queueID", "queueKind", "assignedItemID",
        "targetLevel", "startedAt", "totalDurationSeconds",
    ]

    /// 不可用原因（含请求项目名，便于定位）。
    public let reason: String
    /// 缺失的队列字段清单（`missingQueueFields`）。
    public let missingFields: [String]
    /// 快照捕获时间；快照无 timestamp 时 nil（如实透传，不伪造）。
    public let snapshotCapturedAt: Date?
    /// 静态目录版本；目录不可用时 nil。
    public let catalogVersion: String?

    public init(
        reason: String,
        missingFields: [String],
        snapshotCapturedAt: Date?,
        catalogVersion: String?
    ) {
        self.reason = reason
        self.missingFields = missingFields
        self.snapshotCapturedAt = snapshotCapturedAt
        self.catalogVersion = catalogVersion
    }
}

/// 队列时间线请求结果。当前只有 `.unavailable`；未来队列字段出现时再扩展。
public enum QueueTimelineResolution: Codable, Hashable, Sendable {
    /// 当前账号 JSON 不提供队列身份/目标等级，无法生成精确队列时间线。
    case unavailable(QueueTimelineUnavailable)
}

/// 纯函数契约：请求某条升级记录的精确队列时间线。
///
/// `snapshotCapturedAt` 来源：`VillageProfile.accountSnapshot?.capturedAt`；
/// `catalogVersion` 来源：`VillageCatalogProjection.catalogVersion`（或
/// `UpgradeDisplayRecord.catalogVersion`）。
public enum QueueTimelineResolver {
    /// 当前解码器不提供任何队列字段，恒返回 `.unavailable`（禁止编造）。
    public static func resolve(
        for item: VillageItemState,
        snapshotCapturedAt: Date?,
        catalogVersion: String?
    ) -> QueueTimelineResolution {
        .unavailable(QueueTimelineUnavailable(
            reason: "当前账号 JSON 不提供队列身份/目标等级（\(item.name)），无法生成精确队列时间线。",
            missingFields: QueueTimelineUnavailable.missingQueueFields,
            snapshotCapturedAt: snapshotCapturedAt,
            catalogVersion: catalogVersion
        ))
    }
}
```

- [ ] **Step 4: 运行确认 GREEN**

Run: `swift test --filter QueueTimelineResolverTests`
Expected: 5 个测试全部 PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperCore/QueueTimeline.swift Tests/COCHelperCoreTests/QueueTimelineResolverTests.swift
git commit -m "feat: 队列时间线边界契约——结构化不可用状态 (Issue #17)"
```

---

### Task 2: 数组重排 property 测试 + boost 非归属测试

**Files:**
- Modify: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`

**背景**：`makeVillage` helper（约 L71-90）目前写死 `boosts: [:]`，需加带默认值的 `boosts` 参数（现有调用不变）。文件内已有 `SeededRNG`（L5-15）、`loadRealFixture()`（L116-125）、`project(...)`（L127-142）。

- [ ] **Step 1: 改 makeVillage helper 支持 boosts**

把 `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift` 中 `makeVillage` 签名改为：

```swift
    private func makeVillage(
        tag: String? = "#TEST",
        objectSections: [String: [AccountItem]] = [:],
        boosts: [String: Int64] = [:]
    ) -> VillageProfile {
        VillageProfile(
            name: "测试村庄",
            accountSnapshot: AccountSnapshot(
                tag: tag,
                capturedAt: nil,
                importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                ageSeconds: nil,
                originalText: "",
                objectSections: objectSections,
                numericSections: [:],
                boosts: boosts,
                unknownTopLevelKeys: [],
                diagnostics: []
            )
        )
    }
```

- [ ] **Step 2: 追加深度重排 helper 与两个测试（文件末尾、属性测试区之前或之后均可）**

```swift
    // MARK: - Issue #17: 数组重排稳定性与 boost 非归属

    /// 深度重排：每个 section 数组及其嵌套 types/modules 数组分别打乱（固定种子）。
    private func deeplyShuffled(
        _ sections: [String: [AccountItem]],
        using rng: inout SeededRNG
    ) -> [String: [AccountItem]] {
        sections.mapValues { items in
            items.shuffled(using: &rng).map { item in
                AccountItem(
                    id: item.id,
                    section: item.section,
                    dataID: item.dataID,
                    level: item.level,
                    count: item.count,
                    timerSeconds: item.timerSeconds,
                    remainingSeconds: item.remainingSeconds,
                    helperTimerSeconds: item.helperTimerSeconds,
                    remainingHelperSeconds: item.remainingHelperSeconds,
                    helperCooldownSeconds: item.helperCooldownSeconds,
                    remainingHelperCooldownSeconds: item.remainingHelperCooldownSeconds,
                    helperRecurrent: item.helperRecurrent,
                    gearUp: item.gearUp,
                    weapon: item.weapon,
                    types: item.types.shuffled(using: &rng),
                    modules: item.modules.shuffled(using: &rng)
                )
            }
        }
    }

    /// 投影事实行：身份与事实字段（不含 id——id 含数组索引，重排后允许漂移）。
    private func factLines(_ items: [VillageItemState]) -> [String] {
        items.map { item in
            [
                item.section, String(item.dataID),
                item.currentLevel.map(String.init) ?? "nil",
                item.isNested ? "nested" : "flat",
                item.count.map(String.init) ?? "nil",
                item.timerSeconds.map(String.init) ?? "nil",
                item.remainingSeconds.map(String.init) ?? "nil",
                item.status.rawValue,
                item.nextLevel.map(String.init) ?? "nil",
                item.name,
                item.maxLevel.map(String.init) ?? "nil",
                item.nextLevelDurationSeconds.map(String.init) ?? "nil",
            ].joined(separator: "|")
        }.sorted()
    }

    /// RED 验证：数组重排会改变含索引的 id——先断言 id 集变化（证明重排生效），
    /// 再断言事实集不变。JSON 数组重排不得改变项目身份与事实（issue 验收 #6）。
    func testArrayReorderDoesNotChangeItemFacts() throws {
        let sections = try loadRealFixture()
        let village = makeVillage(objectSections: sections)
        let catalog = GameCatalog.loadBundled()

        var rng = SeededRNG(seed: 17)
        let shuffledSections = deeplyShuffled(sections, using: &rng)
        let reversedSections = sections.mapValues { Array($0.reversed()) }

        let originalHome = project(village: village, catalog: catalog, base: .home)
        let originalBuilder = project(village: village, catalog: catalog, base: .builder)

        for variant in [("shuffled", shuffledSections), ("reversed", reversedSections)] {
            let variantVillage = makeVillage(objectSections: variant.1)
            let variantHome = project(village: variantVillage, catalog: catalog, base: .home)
            let variantBuilder = project(village: variantVillage, catalog: catalog, base: .builder)

            // 1. 重排确实生效：含索引的原始 id 集合必须变化（否则测试自身无鉴别力）。
            let originalIDs = Set(originalHome.items.map(\.id))
            let variantIDs = Set(variantHome.items.map(\.id))
            XCTAssertNotEqual(originalIDs, variantIDs, "\(variant.0) 后 id 应漂移（id 含数组索引）")

            // 2. 事实不变：按 (section,dataID,level,isNested) 身份的事实完全一致。
            XCTAssertEqual(factLines(originalHome.items), factLines(variantHome.items),
                           "\(variant.0) 后主村事实改变")
            XCTAssertEqual(factLines(originalBuilder.items), factLines(variantBuilder.items),
                           "\(variant.0) 后建筑工人基地事实改变")
        }
    }

    /// 全局 boost（clocktower_cooldown 等）只留在快照顶层，不得归属到任何项目
    /// （issue 验收 #5）。用远超真实计时的特殊值避免碰撞。
    func testBoostValuesNeverAttributedToProjectItems() throws {
        let boostValue: Int64 = 987_654_321
        let village = makeVillage(
            objectSections: [
                "buildings": [
                    makeItem(section: "buildings", dataID: 1_000_013, level: 17,
                             timerSeconds: 369_441, remainingSeconds: 1000, path: "0"),
                    makeItem(section: "buildings", dataID: 1_000_032, level: 12, path: "1"),
                ],
            ],
            boosts: ["clocktower_cooldown": boostValue]
        )
        let home = project(village: village, catalog: syntheticCatalog, base: .home)

        // boost 保留在快照顶层（独立来源）。
        XCTAssertEqual(village.accountSnapshot?.boosts["clocktower_cooldown"], boostValue)

        // 任何投影项目的计时/剩余字段都不得携带 boost 值。
        XCTAssertFalse(home.items.isEmpty)
        for item in home.items {
            XCTAssertNotEqual(item.timerSeconds, boostValue,
                              "\(item.name) 的计时不得来自全局 boost")
            XCTAssertNotEqual(item.remainingSeconds, boostValue,
                              "\(item.name) 的剩余时间不得来自全局 boost")
        }
    }
```

- [ ] **Step 3: 运行确认 GREEN**

Run: `swift test --filter VillageCatalogProjectionTests`
Expected: 全部 PASS（既有 30+ 测试 + 新增 2 个；本任务是验证既有行为的回归测试，立即绿为预期）

**验证测试有效性（watch it fail 等价）**：测试内部含自证断言 `XCTAssertNotEqual(originalIDs, variantIDs)`（id 必须漂移）——若该断言失败说明重排未生效、测试空转；若通过且事实断言也通过，说明测试同时具备"重排生效"与"事实不变"双重鉴别力，无需额外临时破坏代码。

- [ ] **Step 4: 提交**

```bash
git add Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "test: 数组重排不改变项目事实 + 全局 boost 不归属项目 (Issue #17)"
```

---

### Task 3: fixture 队列/helper 审计测试

**Files:**
- Modify: `Tests/COCHelperCoreTests/AccountSnapshotTests.swift`

- [ ] **Step 1: 追加审计测试（在 `testAnonymizedCopiedAccountFixtureMatchesReportedShape` 之后）**

```swift
    /// Issue #17 审计：真实 fixture 不存在任何队列字段或 helper_timer，
    /// 且带 timer 的项目记录可精确枚举（10 条，含主村/建筑工人基地与嵌套路径）。
    /// fixture 更新时同步更新下方清单——清单变化即「可观测范围」变化，须人工确认。
    func testRealFixtureQueueAndHelperAudit() throws {
        let text = try fixtureText()
        let snapshot = try AccountSnapshotImporter.parse(
            text,
            now: Date(timeIntervalSince1970: 1_785_736_933) // == fixture timestamp：age = 0
        )

        // 1. 原始 JSON 无任何队列字段（fixture 实测 0 处；解码器也不读取）。
        for key in QueueTimelineUnavailable.missingQueueFields {
            XCTAssertFalse(text.contains(key), "fixture 不应包含队列字段 \(key)")
        }

        // 2. 无 helper_timer：helpers 只有 helper_cooldown，不得被当作队列计时。
        XCTAssertTrue(snapshot.allObjectItems.allSatisfy { $0.helperTimerSeconds == nil },
                      "fixture 不应包含任何 helper_timer")
        let helpers = try XCTUnwrap(snapshot.objectSections["helpers"])
        XCTAssertEqual(helpers.count, 4)
        XCTAssertEqual(helpers.filter { $0.helperCooldownSeconds != nil }.count, 3,
                       "helpers 应为 3/4 项带 helper_cooldown")

        // 3. 带 timer 的项目记录精确枚举（issue 记录的 11 条含本样本口径差异：
        //    仓库 fixture 实测 10 条 timer；以 fixture 为准）。
        let timers = snapshot.allObjectItems
            .filter { $0.timerSeconds != nil }
            .map { "\($0.section):\($0.dataID):lvl\($0.level ?? -1):\($0.timerSeconds!)" }
            .sorted()
        XCTAssertEqual(timers, [
            "buildings:1000013:lvl17:369441",
            "buildings:1000013:lvl17:414387",
            "buildings:1000032:lvl12:357878",
            "buildings:1000032:lvl12:422074",
            "buildings:1000072:lvl3:338486",
            "buildings2:1000050:lvl7:264940",
            "buildings2:1000050:lvl9:371059",
            "pets:73000017:lvl7:241213",
            "traps:12000020:lvl3:412087",
            "units:4000123:lvl5:381417",
        ])
        XCTAssertEqual(timers.count, 10)
        XCTAssertEqual(snapshot.activeItemCount, 10)
    }
```

- [ ] **Step 2: 运行确认 GREEN**

Run: `swift test --filter AccountSnapshotTests`
Expected: 全部 PASS（新增 1 个测试立即绿为预期——验证既有行为）

- [ ] **Step 3: 提交**

```bash
git add Tests/COCHelperCoreTests/AccountSnapshotTests.swift
git commit -m "test: 真实 fixture 队列/helper_timer 审计——未出现字段保持不可用 (Issue #17)"
```

---

### Task 4: 全量验证与自查（Reflexion）

- [ ] **Step 1: 全量测试**

Run: `swift test`
Expected: 全部 PASS（366 + 8 = 374 个左右；既有 366 不回归）

- [ ] **Step 2: 指定过滤命令（issue 验收命令）**

```bash
swift test --filter AccountSnapshotTests
swift test --filter UpgradeOverviewProjectionTests
```

- [ ] **Step 3: app 构建**

Run: `./scripts/build_app.sh`
Expected: 构建成功（.build/COCHelper.app 产出）

- [ ] **Step 4: Reflexion 自查清单**

- [ ] 契约不伪造数据：`resolve` 恒返回 `.unavailable`，无队列字段编造
- [ ] 未改动任何现有行为逻辑（解码器/投影/UI 零改动，只有 1 个新源文件 + 测试）
- [ ] 测试有效性自证：重排测试含「id 必须漂移」断言（防测试空转）；契约测试断言精确字段清单
- [ ] 未提交密钥/敏感信息；fixture 保持匿名
- [ ] 与 issue 非目标一致：未改解码、未加队列字段、未做排程

**验证命令汇总：**
```bash
swift test --filter QueueTimelineResolverTests
swift test --filter VillageCatalogProjectionTests
swift test --filter AccountSnapshotTests
swift test
./scripts/build_app.sh
```
