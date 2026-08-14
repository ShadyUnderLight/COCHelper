# Issue #145 本地队列元数据与容量设置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为本地手动升级记录提供可解释的队列元数据（queueKind）与用户配置的容量（capacity），Start 满容量时禁用并提示「本地容量已满」，且严格区分 local manual queue / imported observed timer / actual game queue。

**Architecture:** Core 层新增纯模型（LocalQueueKind / LocalQueueCapacityConfig / LocalQueueOccupancy，无持久化职责）；`ManualTrackerVillageState` 增加 `queueCapacityConfigs` 字段（decodeIfPresent 向后兼容，不 bump schema）；AppModel 命令层做容量校验（core 明确不承担 capacity 职责）；UI 在 Start sheet 提供 queueKind 选择与占用摘要，VillageDetailView 提供容量配置入口。

**Tech Stack:** Swift / SwiftUI / Swift Package Manager（XCTest）

**基线:** origin/main@ad06c7c（1459 tests 全过）。Worktree: `.worktrees/issue-145-queue-capacity`，分支 `feat/issue-145-queue-capacity`。

---

### Task 1: Core 纯模型 — LocalQueueKind / LocalQueueCapacityConfig / LocalQueueOccupancy

**Files:**
- Create: `Sources/COCHelperCore/LocalQueueCapacity.swift`
- Test: `Tests/COCHelperCoreTests/LocalQueueCapacityTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import COCHelperCore

/// Issue #145：本地队列类别 / 容量配置 / 占用摘要的纯模型契约。
final class LocalQueueCapacityTests: XCTestCase {
    private let villageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: - LocalQueueKind

    func testQueueKindKnownCategories() {
        XCTAssertTrue(LocalQueueKind.builder.isKnown)
        XCTAssertTrue(LocalQueueKind.laboratory.isKnown)
        XCTAssertTrue(LocalQueueKind.hero.isKnown)
        XCTAssertTrue(LocalQueueKind.equipment.isKnown)
        XCTAssertEqual(LocalQueueKind.knownKinds, [.builder, .laboratory, .hero, .equipment])
        XCTAssertEqual(LocalQueueKind.builder.displayName, "建筑工人")
    }

    func testQueueKindUnknownRawValueIsNotKnown() {
        let kind = LocalQueueKind(rawValue: "forge")
        XCTAssertFalse(kind.isKnown)
        XCTAssertEqual(kind.rawValue, "forge")
        XCTAssertEqual(kind.description, "forge")
    }

    func testQueueKindCodableUsesRawString() throws {
        let data = try JSONEncoder().encode(LocalQueueKind.builder)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"builder\"")
        let decoded = try JSONDecoder().decode(LocalQueueKind.self, from: data)
        XCTAssertEqual(decoded, .builder)
    }

    func testQueueKindRawValueMatchesRecordFreeString() {
        // ManualUpgradeRecord.queueKind 是自由字符串（#139），必须按 rawValue 匹配。
        XCTAssertEqual(LocalQueueKind.builder.rawValue, "builder")
        XCTAssertEqual(LocalQueueKind.laboratory.rawValue, "laboratory")
        XCTAssertEqual(LocalQueueKind.hero.rawValue, "hero")
        XCTAssertEqual(LocalQueueKind.equipment.rawValue, "equipment")
    }

    // MARK: - LocalQueueCapacityConfig

    func testCapacityConfigAcceptsZeroAndPositive() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let zero = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .builder, capacity: 0, updatedAt: now
        )
        XCTAssertEqual(zero.capacity, 0)
        let five = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .builder, capacity: 5, updatedAt: now
        )
        XCTAssertEqual(five.capacity, 5)
    }

    func testCapacityConfigRejectsNegative() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertThrowsError(
            try LocalQueueCapacityConfig(
                villageID: villageID, queueKind: .builder, capacity: -1, updatedAt: now
            )
        ) { error in
            XCTAssertEqual(error as? LocalQueueCapacityConfigError, .invalidCapacity(-1))
        }
    }

    func testCapacityConfigRejectsTooLarge() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertThrowsError(
            try LocalQueueCapacityConfig(
                villageID: villageID,
                queueKind: .builder,
                capacity: LocalQueueCapacityConfig.maximumCapacity + 1,
                updatedAt: now
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalQueueCapacityConfigError,
                .invalidCapacity(LocalQueueCapacityConfig.maximumCapacity + 1)
            )
        }
    }

    func testCapacityConfigRejectsInvalidTimestamp() {
        XCTAssertThrowsError(
            try LocalQueueCapacityConfig(
                villageID: villageID,
                queueKind: .builder,
                capacity: 5,
                updatedAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        ) { error in
            XCTAssertEqual(error as? LocalQueueCapacityConfigError, .invalidTimestamp)
        }
    }

    func testCapacityConfigDefaultsToUserConfigured() throws {
        let config = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .builder, capacity: 5,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(config.source, .userConfigured)
    }

    func testCapacityConfigCodableRoundTrip() throws {
        let config = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .laboratory, capacity: 2,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(LocalQueueCapacityConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.source, .userConfigured)
        XCTAssertEqual(decoded.updatedAt, config.updatedAt)
    }

    // MARK: - LocalQueueOccupancy

    private func record(
        queueKind: String?,
        status: ManualUpgradeRecordStatus = .active
    ) throws -> ManualUpgradeRecord {
        try ManualUpgradeRecord(
            recordID: UUID(),
            itemKey: TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002),
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: Date(timeIntervalSince1970: 1_000),
            expectedEndAt: Date(timeIntervalSince1970: 3_600),
            durationSeconds: 2_600,
            durationKind: .timed,
            frozenCosts: nil,
            catalogProvenance: ManualCatalogProvenance(gameVersion: "18.400.13"),
            baselineReference: ManualBaselineReference(revision: "rev"),
            queueKind: queueKind,
            status: status
        )
    }

    private func config(capacity: Int, kind: LocalQueueKind = .builder) throws -> LocalQueueCapacityConfig {
        try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: kind, capacity: capacity,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    func testOccupancyWithoutConfig() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [try record(queueKind: "builder")],
            capacityConfig: nil
        )
        XCTAssertEqual(occupancy.activeManualCount, 1)
        XCTAssertNil(occupancy.capacity)
        XCTAssertFalse(occupancy.isCapacityConfigured)
        XCTAssertFalse(occupancy.isFull)
        XCTAssertNil(occupancy.availableSlots)
    }

    func testOccupancyCountsOnlyMatchingQueueKind() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [
                try record(queueKind: "builder"),
                try record(queueKind: "builder"),
                try record(queueKind: "laboratory"),
                try record(queueKind: nil),
            ],
            capacityConfig: try config(capacity: 2)
        )
        XCTAssertEqual(occupancy.activeManualCount, 2)
        XCTAssertEqual(occupancy.capacity, 2)
        XCTAssertTrue(occupancy.isCapacityConfigured)
        XCTAssertTrue(occupancy.isFull)
        XCTAssertEqual(occupancy.availableSlots, 0)
    }

    func testOccupancyBelowCapacity() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [try record(queueKind: "builder")],
            capacityConfig: try config(capacity: 5)
        )
        XCTAssertFalse(occupancy.isFull)
        XCTAssertEqual(occupancy.availableSlots, 4)
    }

    func testOccupancyZeroCapacityIsAlwaysFull() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [],
            capacityConfig: try config(capacity: 0)
        )
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertTrue(occupancy.isFull, "capacity 0 时不允许任何本地 active")
        XCTAssertEqual(occupancy.availableSlots, 0)
    }

    func testOccupancyIgnoresNonActiveRecords() throws {
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [
                try record(queueKind: "builder", status: .completed),
                try record(queueKind: "builder", status: .cancelled),
            ],
            capacityConfig: try config(capacity: 1)
        )
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertFalse(occupancy.isFull)
    }

    func testOccupancyUnknownKindMatchesRawValue() throws {
        let kind = LocalQueueKind(rawValue: "forge")
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: kind,
            activeRecords: [try record(queueKind: "forge")],
            capacityConfig: try config(capacity: 1, kind: kind)
        )
        XCTAssertTrue(occupancy.isFull)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LocalQueueCapacityTests 2>&1 | tail -5`
Expected: FAIL（`LocalQueueKind` 未定义，编译错误）

- [ ] **Step 3: Write minimal implementation**

Create `Sources/COCHelperCore/LocalQueueCapacity.swift`:

```swift
import Foundation

/// Issue #145：本地队列类别。
///
/// `ManualUpgradeRecord.queueKind` 是自由字符串（#139 引入，仅透传存储）。
/// 本类型提供已知类别与未知类别的包装，按 `rawValue` 与 record 字段完全兼容。
/// 这是本地工作流标签，不是游戏官方队列类别；不推断 builder/lab/hero/
/// equipment 的官方容量和分配规则。
public struct LocalQueueKind: Codable, Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let builder = LocalQueueKind(rawValue: "builder")
    public static let laboratory = LocalQueueKind(rawValue: "laboratory")
    public static let hero = LocalQueueKind(rawValue: "hero")
    public static let equipment = LocalQueueKind(rawValue: "equipment")

    /// 已知类别清单（UI 选择器顺序）。
    public static let knownKinds: [LocalQueueKind] = [.builder, .laboratory, .hero, .equipment]

    public var isKnown: Bool {
        Self.knownKinds.contains(self)
    }

    /// 中文展示名；未知类别如实显示原始字符串。
    public var displayName: String {
        switch rawValue {
        case "builder": "建筑工人"
        case "laboratory": "实验室"
        case "hero": "英雄"
        case "equipment": "装备"
        default: rawValue
        }
    }

    public var description: String { rawValue }

    // 单值 Codable：JSON 直接是字符串，与 record.queueKind 同构。
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 容量配置来源。当前只有用户配置；未来出现其他来源（如官方数据）再扩展。
public enum LocalQueueCapacitySource: String, Codable, Hashable, Sendable {
    /// 用户在本机明确设置的本地工作流容量，不是游戏官方事实。
    case userConfigured
}

/// Issue #145：用户配置的本地队列容量（source = userConfigured）。
public struct LocalQueueCapacityConfig: Codable, Hashable, Sendable {
    /// 容量上限（防御性：超过视为非法输入，避免无意义的大数）。
    public static let maximumCapacity = 10_000

    public let villageID: UUID
    public let queueKind: LocalQueueKind
    /// 本地手动记录同时进行的最大数量；0 合法（不允许任何本地 active）。
    public let capacity: Int
    public let updatedAt: Date
    public let source: LocalQueueCapacitySource

    public init(
        villageID: UUID,
        queueKind: LocalQueueKind,
        capacity: Int,
        updatedAt: Date,
        source: LocalQueueCapacitySource = .userConfigured
    ) throws {
        guard capacity >= 0, capacity <= Self.maximumCapacity else {
            throw LocalQueueCapacityConfigError.invalidCapacity(capacity)
        }
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LocalQueueCapacityConfigError.invalidTimestamp
        }
        self.villageID = villageID
        self.queueKind = queueKind
        self.capacity = capacity
        self.updatedAt = updatedAt
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            villageID: try container.decode(UUID.self, forKey: .villageID),
            queueKind: try container.decode(LocalQueueKind.self, forKey: .queueKind),
            capacity: try container.decode(Int.self, forKey: .capacity),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            source: try container.decodeIfPresent(
                LocalQueueCapacitySource.self, forKey: .source
            ) ?? .userConfigured
        )
    }

    private enum CodingKeys: String, CodingKey {
        case villageID
        case queueKind
        case capacity
        case updatedAt
        case source
    }
}

public enum LocalQueueCapacityConfigError: Error, Equatable, Sendable {
    case invalidCapacity(Int)
    case invalidTimestamp
}

/// Issue #145：某个本地队列的占用摘要（纯投影，不写任何状态）。
public struct LocalQueueOccupancy: Codable, Hashable, Sendable {
    public let queueKind: LocalQueueKind
    /// 本地手动 active 记录数（只统计 `status == .active` 且 queueKind 匹配）。
    public let activeManualCount: Int
    /// 用户配置的容量；nil = 未配置（不做容量校验）。
    public let capacity: Int?

    public init(queueKind: LocalQueueKind, activeManualCount: Int, capacity: Int?) {
        self.queueKind = queueKind
        self.activeManualCount = activeManualCount
        self.capacity = capacity
    }

    public var isCapacityConfigured: Bool { capacity != nil }

    /// 本地容量已满（仅当配置了容量时判定）。
    public var isFull: Bool {
        guard let capacity else { return false }
        return activeManualCount >= capacity
    }

    /// 剩余可启动数量；未配置容量时 nil。
    public var availableSlots: Int? {
        guard let capacity else { return nil }
        return max(0, capacity - activeManualCount)
    }
}

/// Issue #145：本地队列占用投影入口（纯函数）。
public enum LocalQueueOccupancyResolver {
    /// `capacityConfig` 的 villageID 与调用方村庄一致由调用方保证。
    public static func occupancy(
        queueKind: LocalQueueKind,
        activeRecords: [ManualUpgradeRecord],
        capacityConfig: LocalQueueCapacityConfig?
    ) -> LocalQueueOccupancy {
        let count = activeRecords
            .filter { $0.queueKind == queueKind.rawValue }
            .count
        return LocalQueueOccupancy(
            queueKind: queueKind,
            activeManualCount: count,
            capacity: capacityConfig?.capacity
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LocalQueueCapacityTests 2>&1 | tail -5`
Expected: PASS（13 tests）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/LocalQueueCapacity.swift Tests/COCHelperCoreTests/LocalQueueCapacityTests.swift
git commit -m "feat(core): 本地队列类别/容量配置/占用摘要纯模型 (Issue #145)"
```

---

### Task 2: Store 持久化 — ManualTrackerVillageState 增加 queueCapacityConfigs

**Files:**
- Modify: `Sources/COCHelperCore/ManualTrackerStore.swift`
- Test: `Tests/COCHelperCoreTests/ManualTrackerStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/COCHelperCoreTests/ManualTrackerStoreTests.swift`:

```swift
// MARK: - Issue #145 队列容量配置持久化

private func capacityConfig(
    villageID: UUID,
    kind: LocalQueueKind,
    capacity: Int = 2,
    updatedAt: Date = Date(timeIntervalSince1970: 1_000)
) throws -> LocalQueueCapacityConfig {
    try LocalQueueCapacityConfig(
        villageID: villageID, queueKind: kind, capacity: capacity, updatedAt: updatedAt
    )
}

func testVillageStateCapacityConfigsRoundTrip() throws {
    let villageID = UUID()
    let config = try capacityConfig(villageID: villageID, kind: .builder)
    let state = try ManualTrackerVillageState(
        villageID: villageID,
        queueCapacityConfigs: [config]
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(ManualTrackerVillageState.self, from: data)
    XCTAssertEqual(decoded.queueCapacityConfigs, [config])
    XCTAssertEqual(decoded.queueCapacityConfigs.first?.source, .userConfigured)
}

func testVillageStateRejectsCrossVillageCapacityConfig() {
    let config = try! capacityConfig(villageID: UUID(), kind: .builder)
    XCTAssertThrowsError(
        try ManualTrackerVillageState(villageID: UUID(), queueCapacityConfigs: [config])
    ) { error in
        XCTAssertEqual(
            error as? ManualTrackerStoreError,
            .invalidEnvelope("队列容量配置的村庄与所属村庄不一致。")
        )
    }
}

func testVillageStateRejectsDuplicateQueueKindCapacityConfig() throws {
    let villageID = UUID()
    XCTAssertThrowsError(
        try ManualTrackerVillageState(
            villageID: villageID,
            queueCapacityConfigs: [
                try capacityConfig(villageID: villageID, kind: .builder),
                try capacityConfig(villageID: villageID, kind: .builder, capacity: 3),
            ]
        )
    ) { error in
        XCTAssertEqual(
            error as? ManualTrackerStoreError,
            .invalidEnvelope("存在重复的队列类别容量配置。")
        )
    }
}

func testVillageStateDecodesLegacyDataWithoutCapacityConfigs() throws {
    // 旧版 JSON 没有 queueCapacityConfigs 字段：decode 必须回退为空数组，
    // 不能报错（向后兼容，不 bump schemaVersion）。
    let villageID = UUID()
    let json = """
    {"villageID":"\(villageID.uuidString)","schemaVersion":1,"baselineReference":null,\
    "core":{"itemStates":[],"records":[]},"stateUpdatedAt":1000}
    """
    let state = try JSONDecoder().decode(
        ManualTrackerVillageState.self, from: Data(json.utf8)
    )
    XCTAssertTrue(state.queueCapacityConfigs.isEmpty)
}

func testEnvelopePersistsCapacityConfigsAcrossSaveLoad() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Issue145Store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileStore = FileManualTrackerStore(
        fileURL: directory.appendingPathComponent("manual-tracker-v1.json")
    )

    let villageID = UUID()
    let config = try capacityConfig(villageID: villageID, kind: .laboratory, capacity: 1)
    var envelope = try ManualTrackerEnvelope(
        villages: [
            try ManualTrackerVillageState(villageID: villageID, queueCapacityConfigs: [config]),
        ],
        migrationMarker: ManualTrackerMigrationMarker(completedAt: Date(timeIntervalSince1970: 1_000))
    )
    try fileStore.save(envelope)

    let loaded = try XCTUnwrap(try fileStore.load())
    let state = try XCTUnwrap(loaded.state(for: villageID))
    XCTAssertEqual(state.queueCapacityConfigs, [config])
    XCTAssertEqual(state.queueCapacityConfigs.first?.source, .userConfigured)
    XCTAssertEqual(state.queueCapacityConfigs.first?.updatedAt, config.updatedAt)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ManualTrackerStoreTests 2>&1 | tail -5`
Expected: FAIL（`queueCapacityConfigs` 不存在，编译错误）

- [ ] **Step 3: Implement persistence**

Modify `Sources/COCHelperCore/ManualTrackerStore.swift`:

1. `ManualTrackerVillageState` 增加存储属性（第 75 行 `reconciliationHistory` 之后）:

```swift
    /// Issue #145：用户配置的本地队列容量（source = userConfigured）。
    /// 只约束未来 local manual start，不修改历史 record 或 imported 快照。
    public var queueCapacityConfigs: [LocalQueueCapacityConfig]
```

2. 主 init 增加参数与校验（在 reconciliationHistory 校验之后、`self.villageID = ...` 之前）:

```swift
        guard queueCapacityConfigs.count <= 64 else {
            throw ManualTrackerStoreError.invalidEnvelope("队列容量配置数量超过上限。")
        }
        for config in queueCapacityConfigs {
            guard config.villageID == villageID else {
                throw ManualTrackerStoreError.invalidEnvelope(
                    "队列容量配置的村庄与所属村庄不一致。"
                )
            }
            guard config.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ManualTrackerStoreError.invalidEnvelope("队列容量配置时间无效。")
            }
        }
        guard Set(queueCapacityConfigs.map(\.queueKind.rawValue)).count
                == queueCapacityConfigs.count else {
            throw ManualTrackerStoreError.invalidEnvelope("存在重复的队列类别容量配置。")
        }
```

3. 主 init 签名加参数 `queueCapacityConfigs: [LocalQueueCapacityConfig] = []`，并在 `self.reconciliationHistory = reconciliationHistory` 之后赋值:

```swift
        self.queueCapacityConfigs = queueCapacityConfigs
```

4. `init(from:)` 中传给主 init:

```swift
            queueCapacityConfigs: try container.decodeIfPresent(
                [LocalQueueCapacityConfig].self,
                forKey: .queueCapacityConfigs
            ) ?? []
```

5. CodingKeys 增加:

```swift
        case queueCapacityConfigs
```

6. 空村庄便利 init 增加参数 `queueCapacityConfigs: [LocalQueueCapacityConfig] = []` 并透传。

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ManualTrackerStoreTests 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/ManualTrackerStore.swift Tests/COCHelperCoreTests/ManualTrackerStoreTests.swift
git commit -m "feat(store): 村庄状态持久化本地队列容量配置 (Issue #145)"
```

---

### Task 3: AppModel 容量配置命令与投影

**Files:**
- Modify: `Sources/COCHelperApp/AppModel.swift`
- Test: `Tests/COCHelperCoreTests/AppModelManualUpgradeCommandTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/COCHelperCoreTests/AppModelManualUpgradeCommandTests.swift`:

```swift
// MARK: - Issue #145 队列容量配置

@MainActor
func testSetQueueCapacityPersistsAndProjects() throws {
    let (model, villageID, _) = try makeModel()
    XCTAssertNil(
        model.queueOccupancy(for: villageID, queueKind: .builder).capacity,
        "初始未配置容量"
    )
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 3)
    let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
    XCTAssertEqual(occupancy.capacity, 3)
    XCTAssertEqual(occupancy.activeManualCount, 0)
    XCTAssertFalse(occupancy.isFull)
    // 其他类别不受影响
    XCTAssertNil(model.queueOccupancy(for: villageID, queueKind: .hero).capacity)
}

@MainActor
func testClearQueueCapacityRemovesConfig() throws {
    let (model, villageID, _) = try makeModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 3)
    try model.clearQueueCapacity(for: villageID, queueKind: .builder)
    XCTAssertNil(model.queueOccupancy(for: villageID, queueKind: .builder).capacity)
}

@MainActor
func testQueueCapacityConfigSurvivesUnrelatedCoreUpdate() throws {
    let (model, villageID, action) = try makeModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)
    _ = try model.startManualUpgrade(
        for: villageID, action: action, startedAt: Date()
    )
    let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
    XCTAssertEqual(occupancy.capacity, 5, "core 命令不得丢失容量配置")
    XCTAssertEqual(occupancy.activeManualCount, 1)
}

@MainActor
func testQueueCapacityConfigSurvivesSettlement() throws {
    let (model, villageID, action) = try makeModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)
    _ = try model.startManualUpgrade(
        for: villageID, action: action, startedAt: Date(timeIntervalSince1970: 1_000)
    )
    let settled = model.settleManualUpgrades(at: Date(timeIntervalSince1970: 10_000))
    XCTAssertEqual(settled, 1)
    let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
    XCTAssertEqual(occupancy.capacity, 5, "settle 不得丢失容量配置")
    XCTAssertEqual(occupancy.activeManualCount, 0, "已 settle 的 record 不再占用")
}

@MainActor
func testQueueCapacityConfigPersistsAcrossRestart() throws {
    let (model, villageID, _) = try makeModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 2)

    let defaults = UserDefaults(suiteName: suiteName)!
    let restored = AppModel(
        defaults: defaults,
        historyStore: TestSnapshotHistoryStore(),
        manualTrackerStore: store,
        currentVillagePersistence: TestCurrentVillagePersistence(data: nil),
        transactionJournalURL: storeURL.deletingLastPathComponent()
            .appendingPathComponent("test-transaction.json")
    )
    // 重启后 store 文件仍在（同一 FileManualTrackerStore），config 必须保留。
    let occupancy = restored.queueOccupancy(for: villageID, queueKind: .builder)
    XCTAssertEqual(occupancy.capacity, 2, "重启后 userConfigured 容量必须保留")
    XCTAssertEqual(occupancy.activeManualCount, 0)
}

@MainActor
func testSetQueueCapacityRejectsNegativeCapacity() throws {
    let (model, villageID, _) = try makeModel()
    XCTAssertThrowsError(
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: -1)
    ) { error in
        guard case ManualUpgradeCommandError.queueCapacityInvalid = error else {
            return XCTFail("期望 queueCapacityInvalid，得到 \(error)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppModelManualUpgradeCommandTests 2>&1 | tail -5`
Expected: FAIL（`setQueueCapacity` / `queueOccupancy` / `queueCapacityInvalid` 不存在，编译错误）

- [ ] **Step 3: Implement AppModel commands**

Modify `Sources/COCHelperApp/AppModel.swift`:

1. `ManualUpgradeCommandError` 增加 case（第 128 行 `coreRejected` 之后）:

```swift
    case queueCapacityInvalid
```

errorDescription 增加:

```swift
        case .queueCapacityInvalid:
            "队列容量配置无效（必须为 0 到 10000 的整数）。"
```

2. `updateManualUpgradeCore`（第 592-601 行）构造 VillageState 处增加:

```swift
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: now,
            lastSettleAt: previousState?.lastSettleAt,
            lastImportAt: previousState?.lastImportAt,
            diagnostics: previousState?.diagnostics ?? [],
            reconciliationHistory: previousState?.reconciliationHistory ?? [],
            queueCapacityConfigs: previousState?.queueCapacityConfigs ?? []
        )
```

3. `settleManualUpgrades`（第 641-649 行）同样增加:

```swift
                let state = try ManualTrackerVillageState(
                    villageID: village.id,
                    core: core,
                    stateUpdatedAt: now,
                    lastSettleAt: now,
                    lastImportAt: previousState.lastImportAt,
                    diagnostics: previousState.diagnostics,
                    reconciliationHistory: previousState.reconciliationHistory,
                    queueCapacityConfigs: previousState.queueCapacityConfigs
                )
```

4. 在 `settleManualUpgrades` 之后新增三个方法（MARK: - Issue #145 队列容量）:

```swift
    // MARK: - Issue #145 队列容量配置

    /// 设置/更新某个队列类别的本地容量（userConfigured）。
    /// 只影响未来 local manual start 的容量校验，不修改历史 record。
    @discardableResult
    public func setQueueCapacity(
        for villageID: UUID,
        queueKind: LocalQueueKind,
        capacity: Int,
        now: Date = Date()
    ) throws -> LocalQueueCapacityConfig {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualTrackerStoreError.unavailable("目标村庄不存在。")
        }
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualTrackerStoreError.unavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualTrackerStoreError.invalidEnvelope("更新时间无效。")
        }
        let config: LocalQueueCapacityConfig
        do {
            config = try LocalQueueCapacityConfig(
                villageID: villageID,
                queueKind: queueKind,
                capacity: capacity,
                updatedAt: now
            )
        } catch LocalQueueCapacityConfigError.invalidCapacity {
            throw ManualUpgradeCommandError.queueCapacityInvalid
        } catch LocalQueueCapacityConfigError.invalidTimestamp {
            throw ManualUpgradeCommandError.invalidTime
        }

        var candidate = currentEnvelope
        let previousState = candidate.state(for: villageID)
        let core = previousState?.core ?? try ManualUpgradeCore()
        var configs = previousState?.queueCapacityConfigs
            .filter { $0.queueKind != queueKind } ?? []
        configs.append(config)
        configs.sort { $0.queueKind.rawValue < $1.queueKind.rawValue }
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: now,
            lastSettleAt: previousState?.lastSettleAt,
            lastImportAt: previousState?.lastImportAt,
            diagnostics: previousState?.diagnostics ?? [],
            reconciliationHistory: previousState?.reconciliationHistory ?? [],
            queueCapacityConfigs: configs
        )
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            markManualTrackerUnavailable(error)
            throw error
        }
        installManualTrackerEnvelope(candidate)
        return config
    }

    /// 清除某个队列类别的本地容量配置（回到未配置状态）。
    public func clearQueueCapacity(
        for villageID: UUID,
        queueKind: LocalQueueKind,
        now: Date = Date()
    ) throws {
        guard villages.contains(where: { $0.id == villageID }) else {
            throw ManualTrackerStoreError.unavailable("目标村庄不存在。")
        }
        guard let currentEnvelope = manualTrackerEnvelope,
              manualTrackerStatus != .unavailable,
              manualTrackerStatus != .migrationRequired else {
            throw ManualTrackerStoreError.unavailable(
                manualTrackerError ?? "手动升级存储尚未可用。"
            )
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ManualTrackerStoreError.invalidEnvelope("更新时间无效。")
        }
        guard let previousState = currentEnvelope.state(for: villageID),
              previousState.queueCapacityConfigs.contains(where: {
                  $0.queueKind == queueKind
              }) else { return }

        var candidate = currentEnvelope
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: previousState.core,
            stateUpdatedAt: now,
            lastSettleAt: previousState.lastSettleAt,
            lastImportAt: previousState.lastImportAt,
            diagnostics: previousState.diagnostics,
            reconciliationHistory: previousState.reconciliationHistory,
            queueCapacityConfigs: previousState.queueCapacityConfigs.filter {
                $0.queueKind != queueKind
            }
        )
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            markManualTrackerUnavailable(error)
            throw error
        }
        installManualTrackerEnvelope(candidate)
    }

    /// 某个村庄×队列类别的本地占用投影（未配置容量时 capacity == nil）。
    public func queueOccupancy(
        for villageID: UUID,
        queueKind: LocalQueueKind
    ) -> LocalQueueOccupancy {
        guard let state = manualTrackerEnvelope?.state(for: villageID) else {
            return LocalQueueOccupancy(queueKind: queueKind, activeManualCount: 0, capacity: nil)
        }
        let config = state.queueCapacityConfigs.first { $0.queueKind == queueKind }
        return LocalQueueOccupancyResolver.occupancy(
            queueKind: queueKind,
            activeRecords: state.core.activeRecords,
            capacityConfig: config
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppModelManualUpgradeCommandTests 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperApp/AppModel.swift Tests/COCHelperCoreTests/AppModelManualUpgradeCommandTests.swift
git commit -m "feat(app): 本地队列容量配置命令与占用投影 (Issue #145)"
```

---

### Task 4: startManualUpgrade 增加 queueKind 与容量校验

**Files:**
- Modify: `Sources/COCHelperApp/AppModel.swift`
- Test: `Tests/COCHelperCoreTests/AppModelManualUpgradeCommandTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/COCHelperCoreTests/AppModelManualUpgradeCommandTests.swift`:

```swift
// MARK: - Issue #145 Start 队列归类与容量校验

@MainActor
private func makeTwoStartableItemsModel(
    now: Date? = nil
) throws -> (model: AppModel, villageID: UUID, first: UpgradeAction, second: UpgradeAction) {
    let snapshot = snapshot(objectSections: [
        "buildings": [
            item(section: "buildings", dataID: 1_000_001, level: 18),
            item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            item(section: "buildings", dataID: 1_000_003, level: 1, path: "2"),
        ],
    ])
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
    let villagesData = try JSONEncoder().encode([village])
    let history = TestSnapshotHistoryStore()
    let model = AppModel(
        defaults: defaults,
        historyStore: history,
        manualTrackerStore: store,
        currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
        transactionJournalURL: storeURL.deletingLastPathComponent()
            .appendingPathComponent("test-transaction.json")
    )
    let villageID = try XCTUnwrap(model.villages.first?.id)
    try Self.installObservedState(in: model, villageID: villageID, dataID: 1_000_002, level: 1, history: history)
    try Self.installObservedState(in: model, villageID: villageID, dataID: 1_000_003, level: 1, history: history)
    let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
    let projection = VillageCatalogProjection.project(
        village: village,
        catalog: catalog,
        base: .home,
        now: now ?? importedAt,
        manualUpgradeCore: core
    )
    func action(for dataID: Int64) throws -> UpgradeAction {
        let target = try XCTUnwrap(projection.items.first { $0.dataID == dataID })
        let action = try XCTUnwrap(
            UpgradeActionProjection.action(
                for: target,
                catalog: catalog,
                catalogIsUsable: true,
                manualUpgradeCore: core,
                coverage: .complete,
                now: now ?? importedAt
            )
        )
        XCTAssertTrue(action.isStartable, "fixture must produce startable action: \(action.disabledReason ?? "")")
        return action
    }
    return (model, villageID, try action(for: 1_000_002), try action(for: 1_000_003))
}

@MainActor
func testStartWithQueueKindStoresQueueKind() throws {
    let (model, villageID, action, _) = try makeTwoStartableItemsModel()
    let record = try model.startManualUpgrade(
        for: villageID, action: action, startedAt: Date(), queueKind: .builder
    )
    XCTAssertEqual(record.queueKind, LocalQueueKind.builder.rawValue)
    XCTAssertEqual(
        model.queueOccupancy(for: villageID, queueKind: .builder).activeManualCount, 1
    )
}

@MainActor
func testStartWithoutQueueKindStoresNil() throws {
    let (model, villageID, action, _) = try makeTwoStartableItemsModel()
    let record = try model.startManualUpgrade(
        for: villageID, action: action, startedAt: Date(), queueKind: nil
    )
    XCTAssertNil(record.queueKind)
}

@MainActor
func testStartRejectedWhenQueueCapacityFull() throws {
    let (model, villageID, action, _) = try makeTwoStartableItemsModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)
    _ = try model.startManualUpgrade(
        for: villageID, action: action, startedAt: Date(), queueKind: .builder
    )
    XCTAssertThrowsError(
        try model.startManualUpgrade(
            for: villageID, action: action, startedAt: Date(), queueKind: .builder
        )
    ) { error in
        XCTAssertEqual(
            error as? ManualUpgradeCommandError,
            .queueCapacityFull(
                queueKind: .builder, activeCount: 1, capacity: 1
            )
        )
    }
}

@MainActor
func testStartAllowedWhenBelowCapacity() throws {
    let (model, villageID, first, second) = try makeTwoStartableItemsModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 2)
    _ = try model.startManualUpgrade(for: villageID, action: first, startedAt: Date(), queueKind: .builder)
    // 第二个仍可启动（1 < 2）
    let record = try model.startManualUpgrade(
        for: villageID, action: second, startedAt: Date(), queueKind: .builder
    )
    XCTAssertEqual(record.status, .active)
    XCTAssertEqual(
        model.queueOccupancy(for: villageID, queueKind: .builder).activeManualCount, 2
    )
}

@MainActor
func testStartAllowedWhenCapacityNotConfigured() throws {
    let (model, villageID, first, second) = try makeTwoStartableItemsModel()
    _ = try model.startManualUpgrade(for: villageID, action: first, startedAt: Date(), queueKind: .builder)
    // 未配置容量：不限制
    let record = try model.startManualUpgrade(
        for: villageID, action: second, startedAt: Date(), queueKind: .builder
    )
    XCTAssertEqual(record.status, .active)
    XCTAssertFalse(model.queueOccupancy(for: villageID, queueKind: .builder).isCapacityConfigured)
}

@MainActor
func testStartWithNilQueueKindSkipsCapacityCheck() throws {
    let (model, villageID, first, second) = try makeTwoStartableItemsModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 0)
    _ = try model.startManualUpgrade(for: villageID, action: first, startedAt: Date(), queueKind: nil)
    // 不归类 → 不参与容量校验
    let record = try model.startManualUpgrade(
        for: villageID, action: second, startedAt: Date(), queueKind: nil
    )
    XCTAssertEqual(record.status, .active)
}

@MainActor
func testStartRejectedWhenCapacityZero() throws {
    let (model, villageID, action, _) = try makeTwoStartableItemsModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 0)
    XCTAssertThrowsError(
        try model.startManualUpgrade(
            for: villageID, action: action, startedAt: Date(), queueKind: .builder
        )
    ) { error in
        XCTAssertEqual(
            error as? ManualUpgradeCommandError,
            .queueCapacityFull(queueKind: .builder, activeCount: 0, capacity: 0)
        )
    }
}

@MainActor
func testQueueCapacityIsolatedPerVillage() throws {
    let (model, villageID, first, second) = try makeTwoStartableItemsModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)
    _ = try model.startManualUpgrade(for: villageID, action: first, startedAt: Date(), queueKind: .builder)

    // 第二个村庄：makeTwoStartableItemsModel 用同一 suite/store——新建独立村庄
    let snapshot2 = snapshot(tag: "#TEST2", objectSections: [
        "buildings": [
            item(section: "buildings", dataID: 1_000_001, level: 18),
            item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
        ],
    ])
    let defaults = UserDefaults(suiteName: suiteName)!
    let village2 = VillageProfile(name: "测试村庄2", accountSnapshot: snapshot2)
    let villagesData = try JSONEncoder().encode([village2])
    let model2 = AppModel(
        defaults: defaults,
        historyStore: TestSnapshotHistoryStore(),
        manualTrackerStore: store,
        currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
        transactionJournalURL: storeURL.deletingLastPathComponent()
            .appendingPathComponent("test-transaction2.json")
    )
    let village2ID = try XCTUnwrap(model2.villages.first?.id)
    try Self.installObservedState(in: model2, villageID: village2ID, dataID: 1_000_002, level: 1, history: TestSnapshotHistoryStore())
    let core2 = try XCTUnwrap(model2.manualUpgradeCore(for: village2ID))
    let projection2 = VillageCatalogProjection.project(
        village: village2,
        catalog: catalog,
        base: .home,
        now: importedAt,
        manualUpgradeCore: core2
    )
    let target2 = try XCTUnwrap(projection2.items.first { $0.dataID == 1_000_002 })
    let action2 = try XCTUnwrap(
        UpgradeActionProjection.action(
            for: target2, catalog: catalog, catalogIsUsable: true,
            manualUpgradeCore: core2, coverage: .complete, now: importedAt
        )
    )
    // 村庄2 未配置容量 → 不受村庄1 的容量限制
    let record2 = try model2.startManualUpgrade(
        for: village2ID, action: action2, startedAt: Date(), queueKind: .builder
    )
    XCTAssertEqual(record2.status, .active)
}

@MainActor
func testDifferentQueueKindNotBlockedByFullOtherKind() throws {
    let (model, villageID, first, second) = try makeTwoStartableItemsModel()
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 0)
    // hero 类别未配置容量，不受 builder 的 capacity 0 影响
    let record = try model.startManualUpgrade(
        for: villageID, action: first, startedAt: Date(), queueKind: .hero
    )
    XCTAssertEqual(record.status, .active)
    // builder 类别仍被拒绝
    XCTAssertThrowsError(
        try model.startManualUpgrade(
            for: villageID, action: second, startedAt: Date(), queueKind: .builder
        )
    )
}

@MainActor
func testImportedTimerDoesNotConsumeLocalCapacity() throws {
    // 快照中两个项目带升级计时（imported active），但本地只有一个 active 记录。
    let snapshot = snapshot(objectSections: [
        "buildings": [
            item(section: "buildings", dataID: 1_000_001, level: 18),
            item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            item(section: "buildings", dataID: 1_000_003, level: 1, path: "2"),
        ],
    ])
    // 手动给两个 item 加 timer（imported active 证据）
    var village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let villagesData = try JSONEncoder().encode([village])
    let history = TestSnapshotHistoryStore()
    let model = AppModel(
        defaults: defaults,
        historyStore: history,
        manualTrackerStore: store,
        currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
        transactionJournalURL: storeURL.deletingLastPathComponent()
            .appendingPathComponent("test-transaction.json")
    )
    let villageID = try XCTUnwrap(model.villages.first?.id)
    try Self.installObservedState(in: model, villageID: villageID, dataID: 1_000_002, level: 1, history: history)
    try Self.installObservedState(in: model, villageID: villageID, dataID: 1_000_003, level: 1, history: history)
    try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)
    let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
    let projection = VillageCatalogProjection.project(
        village: village,
        catalog: catalog,
        base: .home,
        now: importedAt,
        manualUpgradeCore: core
    )
    let target = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_002 })
    let action = try XCTUnwrap(
        UpgradeActionProjection.action(
            for: target, catalog: catalog, catalogIsUsable: true,
            manualUpgradeCore: core, coverage: .complete, now: importedAt
        )
    )
    _ = try model.startManualUpgrade(
        for: villageID, action: action, startedAt: Date(), queueKind: .builder
    )
    // occupancy 只统计本地 active（1），快照 timer 不计入。
    XCTAssertEqual(
        model.queueOccupancy(for: villageID, queueKind: .builder).activeManualCount, 1
    )
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppModelManualUpgradeCommandTests 2>&1 | tail -5`
Expected: FAIL（`queueKind:` 参数与 `queueCapacityFull` 不存在，编译错误）

- [ ] **Step 3: Implement start command changes**

Modify `Sources/COCHelperApp/AppModel.swift`:

1. `ManualUpgradeCommandError` 增加 case（第 128 行 `queueCapacityInvalid` 之后）:

```swift
    case queueCapacityFull(queueKind: LocalQueueKind, activeCount: Int, capacity: Int)
```

errorDescription 增加:

```swift
        case .queueCapacityFull(let queueKind, let activeCount, let capacity):
            "本地容量已满：\(queueKind.displayName) 队列已占用 \(activeCount)/\(capacity)。"
```

2. `startManualUpgrade` 签名增加参数（第 676-677 行）:

```swift
    public func startManualUpgrade(
        for villageID: UUID,
        action: UpgradeAction,
        startedAt: Date,
        queueKind: LocalQueueKind? = nil,
        now: Date = Date()
    ) throws -> ManualUpgradeRecord {
```

3. 在 `#170` baseline 校验之后（`revalidatedAction` 之前）插入容量校验:

```swift
        // Issue #145：容量校验只约束 future local manual start。
        // 未配置容量或 queueKind == nil（不归类）时不校验；
        // imported active 从不计入本地占用（occupancy 只统计 local records）。
        if let queueKind {
            let capacityConfigs = currentEnvelope.state(for: villageID)?
                .queueCapacityConfigs ?? []
            if let config = capacityConfigs.first(where: { $0.queueKind == queueKind }) {
                let occupancy = LocalQueueOccupancyResolver.occupancy(
                    queueKind: queueKind,
                    activeRecords: core.activeRecords,
                    capacityConfig: config
                )
                guard !occupancy.isFull else {
                    throw ManualUpgradeCommandError.queueCapacityFull(
                        queueKind: queueKind,
                        activeCount: occupancy.activeManualCount,
                        capacity: config.capacity
                    )
                }
            }
        }
```

4. `core.startUpgrade` 调用增加 `queueKind: queueKind?.rawValue`（第 716-727 行）:

```swift
                created = try core.startUpgrade(
                    itemKey: freshAction.itemKey,
                    fromLevel: fromLevel,
                    targetLevel: targetLevel,
                    quantity: freshAction.quantity,
                    startedAt: startedAt,
                    durationState: freshAction.durationState,
                    frozenCosts: freshAction.frozenCosts,
                    catalogProvenance: provenance,
                    baselineReference: baseline,
                    queueKind: queueKind?.rawValue,
                    now: now
                )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppModelManualUpgradeCommandTests 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperApp/AppModel.swift Tests/COCHelperCoreTests/AppModelManualUpgradeCommandTests.swift
git commit -m "feat(app): Start 支持 queueKind 归类与本地容量校验 (Issue #145)"
```

---

### Task 5: UI — Start sheet 队列类别选择与容量状态

**Files:**
- Modify: `Sources/COCHelper/ManualUpgradeActionSheetView.swift`

- [ ] **Step 1: Implement**

Modify `Sources/COCHelper/ManualUpgradeActionSheetView.swift`:

1. `startContent` 中 `detailGrid(action)` 之后、`costBlock(action)` 之前插入:

```swift
            queueKindBlock
            Divider()
```

2. 新增 `@State`（第 35 行附近）:

```swift
    @State private var selectedQueueRawValue: String = ""
```

3. 新增视图与辅助（放在 `localOnlyNote` 之后）:

```swift
    /// Issue #145：队列类别选择 + 本地占用/容量摘要。
    private var selectedQueueKind: LocalQueueKind? {
        selectedQueueRawValue.isEmpty
            ? nil
            : LocalQueueKind(rawValue: selectedQueueRawValue)
    }

    private var queueKindBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("队列类别", selection: $selectedQueueRawValue) {
                Text("不归类").tag("")
                ForEach(LocalQueueKind.knownKinds, id: \.self) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            if let kind = selectedQueueKind {
                let occupancy = model.queueOccupancy(for: villageID, queueKind: kind)
                if occupancy.isCapacityConfigured {
                    Label(
                        "本地占用 \(occupancy.activeManualCount)/\(occupancy.capacity ?? 0)",
                        systemImage: "rectangle.stack.badge.person.crop"
                    )
                    .font(.caption)
                    .foregroundStyle(occupancy.isFull ? .red : .secondary)
                    if occupancy.isFull {
                        Text("本地容量已满，不能开始新的本地升级。")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Label("未配置容量，不限制本地升级。", systemImage: "rectangle.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Label("导入快照中的升级计时不计入本地容量；本地记录与导入计时相互独立。", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
```

4. Start 确认按钮增加满容量禁用（第 80-86 行）:

```swift
                Button(busy ? "正在记录…" : "确认开始") {
                    confirmStart(action)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
                .disabled(busy || (selectedQueueKind.flatMap { kind in
                    model.queueOccupancy(for: villageID, queueKind: kind).isFull
                } ?? false))
```

5. `confirmStart` 中 `startManualUpgrade` 调用增加 `queueKind: selectedQueueKind`:

```swift
            let record = try model.startManualUpgrade(
                for: villageID,
                action: action,
                startedAt: Date(),
                queueKind: selectedQueueKind
            )
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: Commit**

```bash
git add Sources/COCHelper/ManualUpgradeActionSheetView.swift
git commit -m "feat(ui): Start 面板队列类别选择与容量状态提示 (Issue #145)"
```

---

### Task 6: UI — 容量配置面板与入口

**Files:**
- Create: `Sources/COCHelper/ManualQueueCapacitySettingsView.swift`
- Modify: `Sources/COCHelper/VillageDetailView.swift`

- [ ] **Step 1: Create settings view**

Create `Sources/COCHelper/ManualQueueCapacitySettingsView.swift`:

```swift
import SwiftUI
import COCHelperApp
import COCHelperCore

/// Issue #145：本地队列容量配置面板。
///
/// 容量是 userConfigured 的本地工作流事实，不代表游戏实际队列；只约束
/// 未来 local manual start。未配置的类别不做任何容量校验。
struct ManualQueueCapacitySettingsView: View {
    @EnvironmentObject private var model: AppModel
    let villageID: UUID
    let onDone: () -> Void

    @State private var capacityTexts: [String: String] = [:]
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地队列容量")
                .font(.title2.weight(.bold))
            Text("容量只约束本地手动升级的开始操作，不代表游戏实际队列；导入快照中的升级计时不计入容量。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ForEach(LocalQueueKind.knownKinds, id: \.self) { kind in
                capacityRow(kind)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: loadCurrent)
        .alert("容量配置无效", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func capacityRow(_ kind: LocalQueueKind) -> some View {
        let occupancy = model.queueOccupancy(for: villageID, queueKind: kind)
        return HStack(spacing: 10) {
            Text(kind.displayName)
                .frame(width: 90, alignment: .leading)
            TextField("未配置", text: Binding(
                get: { capacityTexts[kind.rawValue] ?? "" },
                set: { capacityTexts[kind.rawValue] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            Text("个同时升级")
            Spacer()
            if occupancy.isCapacityConfigured {
                Text("占用 \(occupancy.activeManualCount)/\(occupancy.capacity ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func loadCurrent() {
        capacityTexts = [:]
        for kind in LocalQueueKind.knownKinds {
            let occupancy = model.queueOccupancy(for: villageID, queueKind: kind)
            if let capacity = occupancy.capacity {
                capacityTexts[kind.rawValue] = String(capacity)
            }
        }
    }

    private func save() {
        for kind in LocalQueueKind.knownKinds {
            let text = capacityTexts[kind.rawValue] ?? ""
            if text.isEmpty {
                try? model.clearQueueCapacity(for: villageID, queueKind: kind)
                continue
            }
            guard let capacity = Int(text) else {
                errorMessage = "「\(kind.displayName)」容量必须是整数。"
                return
            }
            do {
                try model.setQueueCapacity(for: villageID, queueKind: kind, capacity: capacity)
            } catch ManualUpgradeCommandError.queueCapacityInvalid {
                errorMessage = "「\(kind.displayName)」容量必须在 0 到 \(LocalQueueCapacityConfig.maximumCapacity) 之间。"
                return
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
        }
        onDone()
    }
}
```

- [ ] **Step 2: Add entry point in VillageDetailView**

Modify `Sources/COCHelper/VillageDetailView.swift`:

1. 增加状态（第 26 行 `actionSheet` 之后）:

```swift
    @State private var showQueueCapacitySettings = false
```

2. body 的 `.sheet(item: $actionSheet)` 之后增加:

```swift
        // Issue #145：本地队列容量配置。
        .sheet(isPresented: $showQueueCapacitySettings) {
            ManualQueueCapacitySettingsView(
                villageID: villageID,
                onDone: { showQueueCapacitySettings = false }
            )
        }
```

3. `manualUpgradeFilterBar()` 中 `Spacer()` 之前增加按钮（第 870 行附近）:

```swift
            if manualUpgradeCore != nil {
                Button {
                    showQueueCapacitySettings = true
                } label: {
                    Label("队列容量", systemImage: "rectangle.stack.badge.person.crop")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("配置本地队列容量（只约束本地手动升级）")
                .accessibilityLabel("配置本地队列容量")
            }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: Commit**

```bash
git add Sources/COCHelper/ManualQueueCapacitySettingsView.swift Sources/COCHelper/VillageDetailView.swift
git commit -m "feat(ui): 村庄详情本地队列容量配置面板 (Issue #145)"
```

---

### Task 7: 全量验证与收尾

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -8`
Expected: All tests passed（1459 + 新增 ~30 tests）

- [ ] **Step 2: Verify issue acceptance items**

- [ ] local manual queue 与 imported observed timer、actual game queue 在模型和 UI 上分开（occupancy 只统计 local active records；QueueTimeline 仍 fail-closed；诊断文案明示 imported 不计入）
- [ ] 未配置容量时不套用任何默认游戏队列规则（`capacityConfig == nil` 不校验，无 6 builder 默认值）
- [ ] 已配置容量只约束 local manual start（校验只在 startManualUpgrade；cancel/adjust/settle 不动 capacity）
- [ ] imported active 不会被自动分配 builder/lab/hero/equipment（importedActive 行 action 不可启动，已有 #144 契约；occupancy 不数 imported）
- [ ] queue diagnostics 不会制造 startedAt/targetLevel/queueID 或实际完成时间（本实现只新增容量诊断，不造字段）

- [ ] **Step 3: Commit any leftovers**

```bash
git status --short
```

- [ ] **Step 4: Push branch**

```bash
git push -u origin feat/issue-145-queue-capacity
```
