# Issue #183 导入观察本地队列映射（QueueAssignmentDecision）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为导入观察计时（`ManualImportedObservation`）增加用户确认的本地队列映射 overlay `QueueAssignmentDecision`，使其在用户显式确认后参与本地容量视图与 Start 校验，且默认不占用、可审计、不修改原始数据。

**Architecture:** 在 `ManualTrackerVillageState` 上新增独立持久化字段 `queueAssignments: [QueueAssignmentDecision]`（overlay，与 `ManualUpgradeCore`/`ManualImportedObservation` 分离）。对账（`ManualTrackerReconciliationService`）按 lineage/timer 对 overlay 降级而非删除；容量投影（`LocalQueueOccupancyResolver`）只统计 `userAssigned` 且当前 lineage 的映射；AppModel 提供 assign/unassign 命令（复用 #182 原子保存模式）；UI 在容量设置面板旁增加分配 sheet。

**Tech Stack:** Swift 6, SwiftUI, XCTest, swift-testing

**基线:** `origin/main@64eb851`（含 #145、#182、#175）。审查基线按 issue 写为 `38d438b`，但 #182 已在 `d5eeeeb` 合并，以当前 main 为准。

---

## 任务总览

| Task | 内容 | 文件 |
|---|---|---|
| 1 | 模型 `QueueAssignmentStatus` / `QueueAssignmentDecision` | 新建 `Sources/COCHelperCore/QueueAssignmentModels.swift` |
| 2 | Store 持久化 + 校验 + 旧数据兼容 | `ManualTrackerStore.swift` |
| 3 | 对账降级语义（lineage / timer） | `ManualTrackerReconciliation.swift` |
| 4 | 容量投影 `confirmedImportedCount` | `LocalQueueCapacity.swift` |
| 5 | AppModel assign/unassign 命令 + Start 校验 | `AppModel.swift` |
| 6 | UI：分配 sheet + 容量面板显示 | `QueueAssignmentSettingsView.swift`（新）、`ManualQueueCapacitySettingsView.swift`、`VillageDetailView.swift` |
| 7 | 全量测试 + build_app.sh 验证 | — |

---

### Task 1: QueueAssignment 模型

**Files:**
- Create: `Sources/COCHelperCore/QueueAssignmentModels.swift`
- Test: `Tests/COCHelperCoreTests/QueueAssignmentModelsTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import COCHelperCore

final class QueueAssignmentModelsTests: XCTestCase {
    private let villageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_000)

    private func validKey() -> TrackerItemKey {
        .root(base: .home, rawSection: "buildings", dataID: 123)
    }

    private func validReference() -> ManualBaselineReference {
        ManualBaselineReference(
            revision: "rev-1",
            fingerprint: "fp-1",
            lineageID: "lineage-1"
        )
    }

    func testDefaultsToUserAssignedUserConfigured() throws {
        let decision = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: validKey(),
            baselineReference: validReference(),
            queueKind: .builder,
            decidedAt: now
        )
        XCTAssertEqual(decision.status, .userAssigned)
        XCTAssertEqual(decision.source, .userConfigured)
        XCTAssertEqual(decision.queueKind, .builder)
        XCTAssertEqual(decision.baselineReference.lineageID, "lineage-1")
    }

    func testRejectsInvalidItemKey() {
        XCTAssertThrowsError(
            try QueueAssignmentDecision(
                villageID: villageID,
                itemKey: .root(base: .home, rawSection: "", dataID: 0),
                baselineReference: validReference(),
                queueKind: .builder,
                decidedAt: now
            )
        ) { error in
            XCTAssertEqual(error as? QueueAssignmentError, .invalidItemKey)
        }
    }

    func testRejectsInvalidBaselineReference() {
        XCTAssertThrowsError(
            try QueueAssignmentDecision(
                villageID: villageID,
                itemKey: validKey(),
                baselineReference: ManualBaselineReference(revision: "  "),
                queueKind: .builder,
                decidedAt: now
            )
        ) { error in
            XCTAssertEqual(error as? QueueAssignmentError, .invalidBaselineReference)
        }
    }

    func testRejectsInvalidTimestamp() {
        XCTAssertThrowsError(
            try QueueAssignmentDecision(
                villageID: villageID,
                itemKey: validKey(),
                baselineReference: validReference(),
                queueKind: .builder,
                decidedAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        ) { error in
            XCTAssertEqual(error as? QueueAssignmentError, .invalidTimestamp)
        }
    }

    func testCodableRoundTripPreservesAllFields() throws {
        let decision = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: validKey(),
            baselineReference: validReference(),
            queueKind: .laboratory,
            decidedAt: now,
            status: .observedOnly
        )
        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(QueueAssignmentDecision.self, from: data)
        XCTAssertEqual(decoded, decision)
        XCTAssertEqual(decoded.status, .observedOnly)
        XCTAssertEqual(decoded.decidedAt, now)
    }

    func testStatusesAreDistinct() {
        XCTAssertNotEqual(QueueAssignmentStatus.userAssigned, .observedOnly)
        XCTAssertNotEqual(QueueAssignmentStatus.userAssigned, .unknown)
        XCTAssertNotEqual(QueueAssignmentStatus.observedOnly, .unknown)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter QueueAssignmentModelsTests`
Expected: FAIL — 类型不存在编译错误

- [ ] **Step 3: 实现模型**

Create `Sources/COCHelperCore/QueueAssignmentModels.swift`:

```swift
import Foundation

/// Issue #183：用户对某条导入观察的本地队列分配决定状态。
///
/// - `userAssigned`：用户明确确认该导入计时属于本地某个队列，占本地容量；
/// - `observedOnly`：只观察到计时但无法证明本地队列归属（如 timer 消失、
///   当前未确认），保留记录但不占容量；
/// - `unknown`：身份/lineage 不可靠（旧 lineage 历史证据），保留但不占容量。
///
/// 没有记录即 `unassigned`（未分配），不需要持久化状态。
public enum QueueAssignmentStatus: String, Codable, Hashable, Sendable {
    case userAssigned
    case observedOnly
    case unknown
}

/// Issue #183：用户确认的本地队列映射（overlay）。
///
/// 独立于原始快照与 `ManualUpgradeCore` 的本地工作流判断。绑定可审计观察
/// 身份（itemKey + baseline revision/fingerprint/lineage），不改写任何原始
/// JSON、不自动创建/完成/取消本地记录。
public struct QueueAssignmentDecision: Codable, Hashable, Sendable, Identifiable {
    public let decisionID: UUID
    public let villageID: UUID
    public let itemKey: TrackerItemKey
    public let baselineReference: ManualBaselineReference
    public let queueKind: LocalQueueKind
    public let source: LocalQueueCapacitySource
    public let decidedAt: Date
    public var status: QueueAssignmentStatus

    public init(
        decisionID: UUID = UUID(),
        villageID: UUID,
        itemKey: TrackerItemKey,
        baselineReference: ManualBaselineReference,
        queueKind: LocalQueueKind,
        source: LocalQueueCapacitySource = .userConfigured,
        decidedAt: Date,
        status: QueueAssignmentStatus = .userAssigned
    ) throws {
        guard itemKey.isStructurallyValid else {
            throw QueueAssignmentError.invalidItemKey
        }
        guard baselineReference.isStructurallyValid else {
            throw QueueAssignmentError.invalidBaselineReference
        }
        guard decidedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw QueueAssignmentError.invalidTimestamp
        }
        self.decisionID = decisionID
        self.villageID = villageID
        self.itemKey = itemKey
        self.baselineReference = baselineReference
        self.queueKind = queueKind
        self.source = source
        self.decidedAt = decidedAt
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            decisionID: try container.decode(UUID.self, forKey: .decisionID),
            villageID: try container.decode(UUID.self, forKey: .villageID),
            itemKey: try container.decode(TrackerItemKey.self, forKey: .itemKey),
            baselineReference: try container.decode(
                ManualBaselineReference.self, forKey: .baselineReference),
            queueKind: try container.decode(LocalQueueKind.self, forKey: .queueKind),
            source: try container.decodeIfPresent(
                LocalQueueCapacitySource.self, forKey: .source) ?? .userConfigured,
            decidedAt: try container.decode(Date.self, forKey: .decidedAt),
            status: try container.decodeIfPresent(
                QueueAssignmentStatus.self, forKey: .status) ?? .userAssigned
        )
    }

    private enum CodingKeys: String, CodingKey {
        case decisionID
        case villageID
        case itemKey
        case baselineReference
        case queueKind
        case source
        case decidedAt
        case status
    }

    public var id: UUID { decisionID }
}

public enum QueueAssignmentError: Error, Equatable, Sendable {
    case invalidItemKey
    case invalidBaselineReference
    case invalidTimestamp
    case villageMismatch
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter QueueAssignmentModelsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/QueueAssignmentModels.swift Tests/COCHelperCoreTests/QueueAssignmentModelsTests.swift
git commit -m "feat(core): Issue #183 QueueAssignmentDecision 模型与状态语义"
```

---

### Task 2: Store 持久化 queueAssignments

**Files:**
- Modify: `Sources/COCHelperCore/ManualTrackerStore.swift`
- Test: `Tests/COCHelperCoreTests/ManualTrackerStoreTests.swift`

- [ ] **Step 1: 写失败测试（追加到 ManualTrackerStoreTests）**

```swift
    // MARK: - Issue #183 queueAssignments 持久化

    func testVillageStatePersistsQueueAssignments() throws {
        let villageID = try currentVillageID(name: "new")
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 123)
        let reference = ManualBaselineReference(
            revision: "rev-1", fingerprint: "fp-1", lineageID: "lineage-1")
        let assignment = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: key,
            baselineReference: reference,
            queueKind: .builder,
            decidedAt: Date(timeIntervalSince1970: 1_000)
        )
        var state = try ManualTrackerVillageState.empty(villageID: villageID)
        state.queueAssignments = [assignment]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ManualTrackerVillageState.self, from: data)
        XCTAssertEqual(decoded.queueAssignments, [assignment])
    }

    func testVillageStateDecodesLegacyDataWithoutQueueAssignments() throws {
        // 旧数据没有 queueAssignments 键，decodeIfPresent 必须兼容为空。
        let villageID = try currentVillageID(name: "new")
        var state = try ManualTrackerVillageState.empty(villageID: villageID)
        state.queueAssignments = []
        var data = try JSONEncoder().encode(state)
        // 手动删除该键模拟旧版本字节。
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var stripped = json
        stripped.removeValue(forKey: "queueAssignments")
        data = try JSONSerialization.data(withJSONObject: stripped)
        let decoded = try JSONDecoder().decode(ManualTrackerVillageState.self, from: data)
        XCTAssertEqual(decoded.queueAssignments, [])
    }

    func testVillageStateRejectsAssignmentVillageMismatch() throws {
        let villageID = try currentVillageID(name: "new")
        let otherVillage = UUID()
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 123)
        let assignment = try QueueAssignmentDecision(
            villageID: otherVillage,
            itemKey: key,
            baselineReference: ManualBaselineReference(
                revision: "rev-1", fingerprint: "fp-1", lineageID: "lineage-1"),
            queueKind: .builder,
            decidedAt: Date(timeIntervalSince1970: 1_000)
        )
        var state = try ManualTrackerVillageState.empty(villageID: villageID)
        state.queueAssignments = [assignment]
        XCTAssertThrowsError(try JSONEncoder().encode(state)) { error in
            // ManualTrackerVillageState 的 validated() 在 encode 前校验
            XCTAssertTrue(error.localizedDescription.contains("队列分配"))
        }
    }
```

注意：`ManualTrackerVillageState` 的 validate 路径在 `validated()`（encode 前）。若实现校验放 init，则 `ManualTrackerVillageState.empty` 之后赋值的测试路径需要 `try state.validated()`。具体以现有 `validated()` 机制为准——先确认现有实现中 `queueCapacityConfigs` 的校验位置（init 内），保持一致。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ManualTrackerStoreTests`
Expected: FAIL — 编译错误（`queueAssignments` 不存在）

- [ ] **Step 3: 实现**

在 `Sources/COCHelperCore/ManualTrackerStore.swift` 中 `ManualTrackerVillageState`：

```swift
    /// Issue #183：用户确认的导入观察本地队列映射 overlay。
    /// 独立于 core 与 reconciliationHistory；只记录用户显式分配决定。
    public var queueAssignments: [QueueAssignmentDecision]
```

- init 增加参数 `queueAssignments: [QueueAssignmentDecision] = []`，与 `queueCapacityConfigs` 同风格：
  - 校验每条 `villageID == villageID`，否则 `invalidEnvelope("队列分配村庄不一致。")`
  - `Set(queueAssignments.map(\.decisionID)).count == queueAssignments.count`，否则 `invalidEnvelope("存在重复的队列分配 ID。")`
  - 数量上限 4096
  - 每条 `decidedAt` 有限、`itemKey.isStructurallyValid`、`baselineReference.isStructurallyValid`
- init(from decoder:) 增加 `queueAssignments: try container.decodeIfPresent([QueueAssignmentDecision].self, forKey: .queueAssignments) ?? []`
- CodingKeys 增加 `case queueAssignments`

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ManualTrackerStoreTests`
Expected: PASS

- [ ] **Step 5: 修复所有调用点编译**

`ManualTrackerVillageState(...)` 现有 7 处调用（AppModel 6 处 + Reconciliation 1 处）。由于参数有默认值 `[]`，无需逐处改——但 reconcile 处需要 Task 3 传值。先保持默认值编译通过。

Run: `swift build`
Expected: 编译通过

- [ ] **Step 6: Commit**

```bash
git add Sources/COCHelperCore/ManualTrackerStore.swift Tests/COCHelperCoreTests/ManualTrackerStoreTests.swift
git commit -m "feat(core): Issue #183 ManualTrackerVillageState 持久化 queueAssignments"
```

---

### Task 3: 对账降级语义

**Files:**
- Modify: `Sources/COCHelperCore/ManualTrackerReconciliation.swift`
- Test: `Tests/COCHelperCoreTests/ManualTrackerReconciliationTests.swift`

对账规则（`reconcile()` 构造新 state 时调用纯函数处理 overlay）：
1. lineage 变化（`assignment.baselineReference.lineageID != newReference.lineageID`）→ `status = .unknown`（保留历史证据，不参与容量）；
2. 同 lineage 且该 itemKey 在新 observations 中仍有 timer → 保持原 status（userAssigned 保持 userAssigned，不自动改 queueKind）；
3. 同 lineage 但 timer 消失（新快照该 key 无 timer 或 observation 缺失）→ `status = .observedOnly`（保留记录，不占容量，等待用户重新确认或解除）；
4. 从不创建、从不删除。

- [ ] **Step 1: 写失败测试（追加到 ManualTrackerReconciliationTests）**

```swift
    // MARK: - Issue #183 queueAssignments 对账

    func testReconcileKeepsUserAssignedWithinSameLineage() throws {
        let villageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 123)
        let appliedAt = Date(timeIntervalSince1970: 2_000)
        // 构造一个含该 key 导入观察的 history decision 与 state。
        // 复用本文件现有的 plan+entry helper（见 testReconcile* 系列）。
        let (decision, previousEntry) = try makeHistoryDecision(
            villageID: villageID,
            snapshotJSON: Self.snapshotWithTimerJSON,
            ...
        )
        let currentState = try makeStateWithAssignment(
            villageID: villageID,
            itemKey: key,
            queueKind: .builder,
            lineageID: previousEntry.lineageID.uuidString
        )
        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: previousEntry,
            historyDecision: decision,
            currentState: currentState,
            decision: .applyNonConflicting,
            appliedAt: appliedAt
        )
        XCTAssertEqual(plan.state.queueAssignments.count, 1)
        XCTAssertEqual(plan.state.queueAssignments[0].status, .userAssigned)
        XCTAssertEqual(plan.state.queueAssignments[0].queueKind, .builder)
    }
```

（其余 3 条规则测试同模式：跨 lineage → unknown；同 lineage timer 消失 → observedOnly；对账不自动删除。）

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ManualTrackerReconciliationTests`
Expected: FAIL — `queueAssignments` 空（对账没保留）

- [ ] **Step 3: 实现**

在 `Sources/COCHelperCore/ManualTrackerReconciliation.swift`：

```swift
    /// Issue #183：对账后对 overlay 做保守降级，从不创建/删除。
    private static func rebasedQueueAssignments(
        _ assignments: [QueueAssignmentDecision],
        newReference: ManualBaselineReference,
        observations: [TrackerItemKey: Observation]
    ) -> [QueueAssignmentDecision] {
        assignments.map { assignment in
            let lineageChanged = assignment.baselineReference.lineageID
                != newReference.lineageID
            let timerStillObserved = observations[assignment.itemKey]?.hasTimer == true
            let newStatus: QueueAssignmentStatus
            if lineageChanged {
                newStatus = .unknown
            } else if !timerStillObserved {
                newStatus = .observedOnly
            } else {
                newStatus = assignment.status
            }
            guard newStatus != assignment.status else { return assignment }
            return try! QueueAssignmentDecision(
                decisionID: assignment.decisionID,
                villageID: assignment.villageID,
                itemKey: assignment.itemKey,
                baselineReference: assignment.baselineReference,
                queueKind: assignment.queueKind,
                source: assignment.source,
                decidedAt: assignment.decidedAt,
                status: newStatus
            )
        }
    }
```

在 `reconcile()` 构造 state 处调用，把结果传给 `ManualTrackerVillageState(queueAssignments: ...)`：

```swift
        let rebasedAssignments = rebasedQueueAssignments(
            currentState.queueAssignments,
            newReference: preview.newReference,
            observations: observations
        )
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ManualTrackerReconciliationTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/ManualTrackerReconciliation.swift Tests/COCHelperCoreTests/ManualTrackerReconciliationTests.swift
git commit -m "feat(core): Issue #183 对账按 lineage/timer 降级 queueAssignments"
```

---

### Task 4: 容量投影 confirmedImportedCount

**Files:**
- Modify: `Sources/COCHelperCore/LocalQueueCapacity.swift`
- Test: `Tests/COCHelperCoreTests/LocalQueueCapacityTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
    // MARK: - Issue #183 confirmedImportedCount

    func testOccupancyCountsOnlyUserAssignedAssignments() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1)
        let reference = ManualBaselineReference(
            revision: "rev-1", fingerprint: "fp-1", lineageID: "lineage-1")
        let confirmed = try QueueAssignmentDecision(
            villageID: villageID, itemKey: key, baselineReference: reference,
            queueKind: .builder, decidedAt: now)
        let stale = try QueueAssignmentDecision(
            villageID: villageID, itemKey: key, baselineReference: reference,
            queueKind: .builder, decidedAt: now, status: .observedOnly)
        let otherQueue = try QueueAssignmentDecision(
            villageID: villageID, itemKey: key, baselineReference: reference,
            queueKind: .laboratory, decidedAt: now)
        let config = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .builder, capacity: 2, updatedAt: now)
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [],
            confirmedAssignments: [confirmed, stale, otherQueue],
            capacityConfig: config,
            at: now
        )
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertEqual(occupancy.confirmedImportedCount, 1)
        XCTAssertEqual(occupancy.totalOccupancyCount, 1)
        XCTAssertFalse(occupancy.isFull)
    }

    func testOccupancyIsFullCountsManualPlusConfirmed() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1)
        let reference = ManualBaselineReference(
            revision: "rev-1", fingerprint: "fp-1", lineageID: "lineage-1")
        let confirmed = try QueueAssignmentDecision(
            villageID: villageID, itemKey: key, baselineReference: reference,
            queueKind: .builder, decidedAt: now)
        let active = try ManualUpgradeRecord(
            itemKey: key,
            fromLevel: 1, targetLevel: 2, quantity: 1,
            startedAt: Date(timeIntervalSince1970: 1_000),
            expectedEndAt: Date(timeIntervalSince1970: 9_000),
            durationSeconds: 8_000, durationKind: .timed,
            frozenCosts: nil,
            catalogProvenance: ManualCatalogProvenance(
                gameVersion: "18.400.13", buildTag: nil,
                sourceFingerprint: nil, manifestSchemaVersion: nil),
            baselineReference: reference,
            queueKind: "builder"
        )
        let config = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .builder, capacity: 1, updatedAt: now)
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: .builder,
            activeRecords: [active],
            confirmedAssignments: [confirmed],
            capacityConfig: config,
            at: now
        )
        XCTAssertEqual(occupancy.activeManualCount, 1)
        XCTAssertEqual(occupancy.confirmedImportedCount, 1)
        XCTAssertTrue(occupancy.isFull)
        XCTAssertEqual(occupancy.availableSlots, 0)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter LocalQueueCapacityTests`
Expected: FAIL — `confirmedImportedCount` 不存在

- [ ] **Step 3: 实现**

`Sources/COCHelperCore/LocalQueueCapacity.swift`：

```swift
public struct LocalQueueOccupancy: Codable, Hashable, Sendable {
    public let queueKind: LocalQueueKind
    /// 本地手动 active 记录数（只统计 `status == .active` 且 queueKind 匹配）。
    public let activeManualCount: Int
    /// Issue #183：用户确认（userAssigned）且属于当前 lineage 的导入观察
    /// overlay 数。调用方负责先按当前 lineage 过滤传入的 assignments。
    public let confirmedImportedCount: Int
    /// 用户配置的容量；nil = 未配置（不做容量校验）。
    public let capacity: Int?

    public init(
        queueKind: LocalQueueKind,
        activeManualCount: Int,
        confirmedImportedCount: Int = 0,
        capacity: Int?
    ) {
        self.queueKind = queueKind
        self.activeManualCount = activeManualCount
        self.confirmedImportedCount = confirmedImportedCount
        self.capacity = capacity
    }

    /// 手动 active + 用户确认的导入 overlay 总数。
    public var totalOccupancyCount: Int { activeManualCount + confirmedImportedCount }

    public var isCapacityConfigured: Bool { capacity != nil }

    /// 本地容量已满（仅当配置了容量时判定）。
    public var isFull: Bool {
        guard let capacity else { return false }
        return totalOccupancyCount >= capacity
    }

    /// 剩余可启动数量；未配置容量时 nil。
    public var availableSlots: Int? {
        guard let capacity else { return nil }
        return max(0, capacity - totalOccupancyCount)
    }
}
```

`LocalQueueOccupancyResolver.occupancy` 增加参数：

```swift
    public static func occupancy(
        queueKind: LocalQueueKind,
        activeRecords: [ManualUpgradeRecord],
        confirmedAssignments: [QueueAssignmentDecision] = [],
        capacityConfig: LocalQueueCapacityConfig?,
        at now: Date
    ) -> LocalQueueOccupancy {
        let count = activeRecords
            .filter {
                $0.status == .active
                    && $0.queueKind == queueKind.rawValue
                    && $0.expectedEndAt > now
            }
            .count
        let confirmed = confirmedAssignments
            .filter { $0.status == .userAssigned && $0.queueKind == queueKind }
            .count
        return LocalQueueOccupancy(
            queueKind: queueKind,
            activeManualCount: count,
            confirmedImportedCount: confirmed,
            capacity: capacityConfig?.capacity
        )
    }
```

注意：`LocalQueueOccupancy` 增加字段会破坏现有解码（`Codable` 合成 decode 对旧字节失败）。由于它是纯投影类型（不持久化，仅内存传递），无兼容问题——但确认没有代码持久化 `LocalQueueOccupancy`（grep 验证：只在 AppModel/UI 内存使用）。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter LocalQueueCapacityTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/LocalQueueCapacity.swift Tests/COCHelperCoreTests/LocalQueueCapacityTests.swift
git commit -m "feat(core): Issue #183 容量投影计入 userAssigned overlay"
```

---

### Task 5: AppModel assign/unassign 命令 + Start 校验

**Files:**
- Modify: `Sources/COCHelperApp/AppModel.swift`
- Test: `Tests/COCHelperCoreTests/AppModelManualUpgradeCommandTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
    // MARK: - Issue #183 assign/unassign

    func testAssignQueueToImportedObservationPersists() throws {
        let villageID = try makeVillageWithImportedObservation()
        let key = try importedObservationKey(in: villageID)
        let decision = try model.assignQueueToImportedObservation(
            for: villageID,
            itemKey: key,
            queueKind: .builder
        )
        XCTAssertEqual(decision.status, .userAssigned)
        XCTAssertEqual(decision.queueKind, .builder)
        let reloaded = try model.queueAssignments(for: villageID)
        XCTAssertEqual(reloaded.map(\.decisionID), [decision.decisionID])
    }

    func testAssignSameItemKeyUpdatesQueueKindInsteadOfDuplicating() throws {
        let villageID = try makeVillageWithImportedObservation()
        let key = try importedObservationKey(in: villageID)
        _ = try model.assignQueueToImportedObservation(for: villageID, itemKey: key, queueKind: .builder)
        let second = try model.assignQueueToImportedObservation(for: villageID, itemKey: key, queueKind: .laboratory)
        let all = try model.queueAssignments(for: villageID)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].queueKind, .laboratory)
        XCTAssertEqual(all[0].decisionID, second.decisionID)
    }

    func testUnassignQueueRemovesDecision() throws {
        let villageID = try makeVillageWithImportedObservation()
        let key = try importedObservationKey(in: villageID)
        _ = try model.assignQueueToImportedObservation(for: villageID, itemKey: key, queueKind: .builder)
        try model.unassignQueueFromImportedObservation(for: villageID, itemKey: key)
        XCTAssertEqual(try model.queueAssignments(for: villageID), [])
    }

    func testAssignRejectsUnknownItemKey() throws {
        let villageID = try makeVillageWithImportedObservation()
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 999_999)
        XCTAssertThrowsError(
            try model.assignQueueToImportedObservation(for: villageID, itemKey: key, queueKind: .builder)
        )
    }

    func testStartManualUpgradeCapacityIncludesConfirmedImported() throws {
        // 容量 = 1；一条本地 active + 一条 userAssigned overlay → 拒绝启动。
        let villageID = try makeVillageWithImportedObservation()
        try model.replaceQueueCapacities(for: villageID, updates: [.builder: .set(1)])
        let key = try importedObservationKey(in: villageID)
        _ = try model.assignQueueToImportedObservation(for: villageID, itemKey: key, queueKind: .builder)
        let action = try startableAction(for: villageID, ...)
        XCTAssertThrowsError(
            try model.startManualUpgrade(for: villageID, action: action, startedAt: Date(), queueKind: .builder)
        ) { error in
            guard case ManualUpgradeCommandError.queueCapacityFull = error else {
                return XCTFail("期望 queueCapacityFull，得到 \(error)")
            }
        }
    }
```

测试 helper（追加）：

```swift
    private func makeVillageWithImportedObservation() throws -> UUID {
        // 复用现有测试的村庄创建 + 快照导入 helper，确保 itemState
        // 含 importedObservation（见 testManualStart 系列现有做法）。
        ...
    }

    private func importedObservationKey(in villageID: UUID) throws -> TrackerItemKey {
        let core = try model.manualTrackerEnvelope!.state(for: villageID)!.core
        let key = try XCTUnwrap(core.itemStates.first {
            $0.importedObservation != nil
        }?.itemKey)
        return key
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AppModelManualUpgradeCommandTests`
Expected: FAIL — 方法不存在

- [ ] **Step 3: 实现**

在 `Sources/COCHelperApp/AppModel.swift` 增加（放在 queueOccupancy 附近，复用 #182 原子保存模式）：

```swift
    // MARK: - Issue #183 导入观察队列映射

    /// 当前村庄的 queueAssignments 只读查询（按决策时间排序）。
    public func queueAssignments(for villageID: UUID) throws -> [QueueAssignmentDecision] {
        guard let state = manualTrackerEnvelope?.state(for: villageID) else {
            throw ManualTrackerStoreError.unavailable("目标村庄的手动升级状态尚未可用。")
        }
        return state.queueAssignments.sorted { $0.decidedAt < $1.decidedAt }
    }

    /// 用户确认某条导入观察属于本地队列（userConfigured overlay）。
    /// 同 itemKey 同 lineage 时更新 queueKind（幂等，不重复创建）。
    @discardableResult
    public func assignQueueToImportedObservation(
        for villageID: UUID,
        itemKey: TrackerItemKey,
        queueKind: LocalQueueKind,
        now: Date = Date()
    ) throws -> QueueAssignmentDecision {
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
        guard let previousState = currentEnvelope.state(for: villageID) else {
            throw ManualTrackerStoreError.unavailable("目标村庄的手动升级状态尚未可用。")
        }
        // 只允许对已导入观察的 item 分配。
        guard previousState.core.itemStates.contains(where: {
            $0.itemKey == itemKey && $0.importedObservation != nil
        }) else {
            throw ManualUpgradeCommandError.itemNotImportedObservation
        }
        guard let coreBaseline = previousState.core.baselineReference else {
            throw ManualUpgradeCommandError.unreconciledSnapshot
        }
        var assignments = previousState.queueAssignments.filter {
            !($0.itemKey == itemKey && $0.baselineReference.lineageID == coreBaseline.lineageID)
        }
        let decision = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: itemKey,
            baselineReference: coreBaseline,
            queueKind: queueKind,
            decidedAt: now
        )
        assignments.append(decision)
        assignments.sort { $0.decidedAt < $1.decidedAt }

        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: previousState.core,
            stateUpdatedAt: now,
            lastSettleAt: previousState.lastSettleAt,
            lastImportAt: previousState.lastImportAt,
            diagnostics: previousState.diagnostics,
            reconciliationHistory: previousState.reconciliationHistory,
            queueCapacityConfigs: previousState.queueCapacityConfigs,
            queueAssignments: assignments
        )
        var candidate = currentEnvelope
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            markManualTrackerUnavailable(error)
            throw error
        }
        installManualTrackerEnvelope(candidate)
        return decision
    }

    /// 用户解除某条导入观察的本地队列映射（删除该 itemKey 全部 overlay）。
    /// timer 消失本身不会触发本命令；本命令只由用户显式发起。
    public func unassignQueueFromImportedObservation(
        for villageID: UUID,
        itemKey: TrackerItemKey,
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
        guard let previousState = currentEnvelope.state(for: villageID) else { return }
        let remaining = previousState.queueAssignments.filter { $0.itemKey != itemKey }
        guard remaining.count != previousState.queueAssignments.count else { return }

        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: previousState.core,
            stateUpdatedAt: now,
            lastSettleAt: previousState.lastSettleAt,
            lastImportAt: previousState.lastImportAt,
            diagnostics: previousState.diagnostics,
            reconciliationHistory: previousState.reconciliationHistory,
            queueCapacityConfigs: previousState.queueCapacityConfigs,
            queueAssignments: remaining
        )
        var candidate = currentEnvelope
        try candidate.upsert(state)
        do {
            try manualTrackerStore.save(candidate)
        } catch {
            markManualTrackerUnavailable(error)
            throw error
        }
        installManualTrackerEnvelope(candidate)
    }
```

`ManualUpgradeCommandError` 增加 case：

```swift
    case itemNotImportedObservation
```

错误文案：`"该条目不是导入观察，不能确认本地队列映射。"`

`startManualUpgrade` 容量校验更新（queueCapacityFull 附带 confirmedImportedCount）：

```swift
        if let queueKind {
            let capacityConfigs = currentEnvelope.state(for: villageID)?
                .queueCapacityConfigs ?? []
            if let config = capacityConfigs.first(where: { $0.queueKind == queueKind }) {
                let state = currentEnvelope.state(for: villageID)
                let currentLineage = core.baselineReference?.lineageID
                let confirmed = state?.queueAssignments.filter {
                    $0.status == .userAssigned
                        && $0.queueKind == queueKind
                        && $0.baselineReference.lineageID == currentLineage
                } ?? []
                let occupancy = LocalQueueOccupancyResolver.occupancy(
                    queueKind: queueKind,
                    activeRecords: core.activeRecords,
                    confirmedAssignments: confirmed,
                    capacityConfig: config,
                    at: now
                )
                guard !occupancy.isFull else {
                    throw ManualUpgradeCommandError.queueCapacityFull(
                        queueKind: queueKind,
                        activeCount: occupancy.activeManualCount,
                        confirmedImportedCount: occupancy.confirmedImportedCount,
                        capacity: config.capacity
                    )
                }
            }
        }
```

`queueCapacityFull` case 更新为：

```swift
    case queueCapacityFull(
        queueKind: LocalQueueKind,
        activeCount: Int,
        confirmedImportedCount: Int,
        capacity: Int
    )
```

文案：`"本地容量已满：\(queueKind.displayName) 队列本地占用 \(activeCount) 个、已确认导入 \(confirmedImportedCount) 个，容量 \(capacity)。"`

`queueOccupancy(for:queueKind:at:)` 同步传入当前 lineage 的 confirmed assignments：

```swift
    public func queueOccupancy(
        for villageID: UUID,
        queueKind: LocalQueueKind,
        at now: Date = Date()
    ) -> LocalQueueOccupancy {
        guard let state = manualTrackerEnvelope?.state(for: villageID) else {
            return LocalQueueOccupancy(
                queueKind: queueKind, activeManualCount: 0, capacity: nil)
        }
        let config = state.queueCapacityConfigs.first { $0.queueKind == queueKind }
        let currentLineage = state.core.baselineReference?.lineageID
        let confirmed = state.queueAssignments.filter {
            $0.status == .userAssigned
                && $0.queueKind == queueKind
                && $0.baselineReference.lineageID == currentLineage
        }
        return LocalQueueOccupancyResolver.occupancy(
            queueKind: queueKind,
            activeRecords: state.core.activeRecords,
            confirmedAssignments: confirmed,
            capacityConfig: config,
            at: now
        )
    }
```

UI 候选数据（AppModel 提供，Task 6 消费）：

```swift
    /// Issue #183：村庄全部导入观察的分配候选（含显示名与当前状态）。
    public func queueAssignmentCandidates(for villageID: UUID) -> [ImportedObservationCandidate] {
        guard let state = manualTrackerEnvelope?.state(for: villageID) else { return [] }
        let catalog = gameCatalog
        let currentLineage = state.core.baselineReference?.lineageID
        return state.core.itemStates
            .filter { $0.importedObservation != nil }
            .map { itemState in
                let name = catalog?.item(
                    section: itemState.itemKey.rawSection,
                    dataID: itemState.itemKey.dataID
                )?.name ?? itemState.itemKey.stableID
                let assignment = state.queueAssignments.first {
                    $0.itemKey == itemState.itemKey
                        && $0.baselineReference.lineageID == currentLineage
                }
                return ImportedObservationCandidate(
                    itemKey: itemState.itemKey,
                    displayName: name,
                    hasTimer: itemState.importedObservation?.sourceTimestamp != nil,
                    assignment: assignment
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
```

新投影类型（放 AppModel.swift 或 Core）：

```swift
/// Issue #183：UI 展示用的导入观察分配候选。
public struct ImportedObservationCandidate: Identifiable, Hashable, Sendable {
    public let itemKey: TrackerItemKey
    public let displayName: String
    public let hasTimer: Bool
    public let assignment: QueueAssignmentDecision?

    public var id: String { itemKey.stableID }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter AppModelManualUpgradeCommandTests`
Expected: PASS

- [ ] **Step 5: 修复现有 queueCapacityFull 引用**

grep `queueCapacityFull` 更新所有引用（AppModel 抛错处、错误文案处、测试断言处）。

Run: `swift build && swift test --filter AppModelManualUpgradeCommandTests`
Expected: 编译通过 + PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/COCHelperApp/AppModel.swift Tests/COCHelperCoreTests/AppModelManualUpgradeCommandTests.swift
git commit -m "feat(app): Issue #183 assign/unassign 命令与 Start 容量校验并入 confirmed overlay"
```

---

### Task 6: UI 分配 sheet + 容量面板显示

**Files:**
- Create: `Sources/COCHelper/QueueAssignmentSettingsView.swift`
- Modify: `Sources/COCHelper/ManualQueueCapacitySettingsView.swift`
- Modify: `Sources/COCHelper/VillageDetailView.swift`

- [ ] **Step 1: 新建分配 sheet 视图**

Create `Sources/COCHelper/QueueAssignmentSettingsView.swift`：

```swift
import SwiftUI
import COCHelperApp
import COCHelperCore

/// Issue #183：导入观察的本地队列映射面板。
///
/// 列出当前村庄所有导入观察项；未分配时显示「未分配本地队列」，提供
/// 「确认分配 / 解除分配」操作。这是用户显式的本地工作流判断，不代表
/// 游戏官方队列事实；映射不修改任何导入原始数据。
struct QueueAssignmentSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let villageID: UUID
    let onDone: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        let candidates = model.queueAssignmentCandidates(for: villageID)
        VStack(alignment: .leading, spacing: 12) {
            Text("导入观察的本地队列")
                .font(.title2.weight(.bold))
            Text("确认后，该导入计时作为本地规划占用计入容量；这是本地记录，不是游戏官方队列事实。未确认的导入计时永不占用容量。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            if candidates.isEmpty {
                Text("当前没有可确认的导入观察。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(candidates) { candidate in
                            row(candidate)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ candidate: ImportedObservationCandidate) -> some View {
        let assignment = candidate.assignment
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.displayName)
                    .font(.callout.weight(.medium))
                Spacer()
                statusBadge(candidate)
            }
            if let assignment {
                HStack(spacing: 8) {
                    Text("已分配：\(assignment.queueKind.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("解除分配", role: .destructive) {
                        unassign(candidate)
                    }
                    .font(.caption)
                }
            } else {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(LocalQueueKind.knownKinds, id: \.self) { kind in
                            Button(kind.displayName) {
                                assign(candidate, queueKind: kind)
                            }
                        }
                    } label: {
                        Label("确认分配到队列…", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    Text("未分配本地队列")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.cocBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusBadge(_ candidate: ImportedObservationCandidate) -> some View {
        guard let assignment = candidate.assignment else {
            return Text("未分配")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        switch assignment.status {
        case .userAssigned:
            return Text("已确认")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15), in: Capsule())
        case .observedOnly:
            return Text("观察已结束/未确认")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: Capsule())
        case .unknown:
            return Text("身份不可靠")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: Capsule())
        }
    }

    private func assign(_ candidate: ImportedObservationCandidate, queueKind: LocalQueueKind) {
        do {
            try model.assignQueueToImportedObservation(
                for: villageID, itemKey: candidate.itemKey, queueKind: queueKind)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func unassign(_ candidate: ImportedObservationCandidate) {
        do {
            try model.unassignQueueFromImportedObservation(
                for: villageID, itemKey: candidate.itemKey)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: 修改容量面板显示占用来源**

`ManualQueueCapacitySettingsView.swift` 的 `capacityRow` 占用文本改为：

```swift
            if occupancy.isCapacityConfigured {
                if occupancy.confirmedImportedCount > 0 {
                    Text("占用 \(occupancy.activeManualCount)+\(occupancy.confirmedImportedCount)（手动+已确认导入）/\(occupancy.capacity ?? 0)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("占用 \(occupancy.activeManualCount)/\(occupancy.capacity ?? 0)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
```

面板说明文案更新：`"容量只约束本地手动升级的开始操作，不代表游戏实际队列；未确认的导入计时不计入容量。"`

- [ ] **Step 3: VillageDetailView 增加入口**

`VillageDetailView.swift` 增加状态与 sheet：

```swift
    // Issue #183：导入观察的本地队列映射面板。
    @State private var showQueueAssignmentSettings = false
```

sheet 注册（容量面板旁）：

```swift
        .sheet(isPresented: $showQueueAssignmentSettings) {
            QueueAssignmentSettingsView(
                villageID: villageID,
                onDone: { showQueueAssignmentSettings = false }
            )
        }
```

入口按钮：找到容量设置按钮位置（`showQueueCapacitySettings` 的触发处），在其旁加：

```swift
            Button("导入观察队列") {
                showQueueAssignmentSettings = true
            }
```

- [ ] **Step 4: 编译验证**

Run: `swift build`
Expected: 编译通过（UI 无单元测试，用 build 验证）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelper/QueueAssignmentSettingsView.swift Sources/COCHelper/ManualQueueCapacitySettingsView.swift Sources/COCHelper/VillageDetailView.swift
git commit -m "feat(ui): Issue #183 导入观察队列分配面板与容量占用来源显示"
```

---

### Task 7: 全量验证

- [ ] **Step 1: 全量测试**

Run: `swift test`
Expected: 全部通过（基线 1536 + 新增）

- [ ] **Step 2: Release build**

Run: `swift build -c release`
Expected: 成功

- [ ] **Step 3: build_app.sh**

Run: `./scripts/build_app.sh`
Expected: 成功（macOS app 打包）

- [ ] **Step 4: 收尾提交与文档**

- 更新 `docs/superpowers/plans/` 计划文件勾选状态（如适用）；
- 若 README 有功能列表，追加 Issue #183 条目（如适用）。

Run: `git log --oneline` 确认提交历史清晰

---

## Self-Review

**Spec 覆盖：**
- 默认不占用 → Task 4/5（未确认不统计，occupancy 只数 userAssigned）✓
- 显式映射后参与容量且区分三类数量 → Task 4/5/6（activeManualCount / confirmedImportedCount 分开，UI 标注）✓
- 映射不修改原始数据 → Task 3（overlay 独立，reconcile 不改 importedObservation / records / raw JSON）✓
- 重导入保守（不重复创建 / timer 存在不改 queueKind / timer 消失不删除 / lineage 变化降级 / 身份不稳保持 unknown）→ Task 3 ✓
- 容量校验口径（未到期 manual active + 当前 lineage userAssigned）→ Task 5 ✓
- 验收标准（持久化、重启保留、UI 区分、解除才释放、隔离、迁移兼容）→ Task 2/5/6 ✓
- 非目标（不读官方队列、不做 API、不自动转 record）→ 全计划未触碰 ✓

**风险：**
- `LocalQueueOccupancy` 加字段：纯内存投影类型，确认无持久化（Task 4 已注明验证步骤）
- `queueCapacityFull` case 签名变更：grep 所有引用更新（Task 5 Step 5）
- `ManualTrackerVillageState` 新字段默认值 `[]`：旧字节 decodeIfPresent 兼容（Task 2 测试覆盖）
