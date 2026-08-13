# Issue #165 Snapshot History Timer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 buildings/buildings2/traps/traps2 的 histogram 比较路径产生确定、可审计的 timer 状态迁移（upgradeStarted / timerChanged / upgradeCompleted / timerEndedObserved / unknown），并修复 unique 路径的裸值 timer 比较 bug。

**Architecture:** 只改 `Sources/COCHelperCore/SnapshotHistoryDiff.swift`。新增 aggregate timer 聚合逻辑（`aggregateTimerState` / `aggregateTimerTransition`），在 `compareHistogram` 的 histogram 有效/无效两条路径接入；增强 `timerTransition` 的 active→active 分支为"规范化 remaining timer 比较"（复用项目已有契约：官方 API timer 是 remaining seconds，见 `AccountSnapshot.adjustedTimer`：`remaining = max(0, raw - ageSeconds)`）。UI/统计/存储层不改：`SnapshotChangeKind` 已含全部 case，UI 已有全部文案与 badge，统计对 aggregateInferred 事件天然不重复计数（`MetricAccumulators.apply` 只在 `evidence == .confirmed` 时计 completion）。

**Tech Stack:** Swift 6 / SwiftPM / XCTest

**关键设计决策：**
1. 容差常量 `timerElapsedTolerance: TimeInterval = 30`：两次观测间 remaining timer 的期望值 = old − elapsed（`to.appliedAt − from.appliedAt`）；`|new − expected| > 30` 才算业务变化（覆盖时钟抖动与轮询延迟）。
2. aggregate timer 状态四态（absent/inactive/active/unknown）：任一实例 evidence 无法解析 → unknown；任一 active → active；全部为空 → absent。
3. active→active 的多实例比较：收集各实例同一 timer 字段的可解析数值集合，**数量不同 → unknown**（身份无法稳定聚合，fail-closed）；数量相同 → 排序后逐位规范化比较。
4. timer change 作为**独立 change 记录**输出（`evidence: .aggregateInferred`），不合并进 level migration change；`upgradeCompleted` 的 `levelDelta`/`movedQuantity` 保持 nil 且 `related = [.levelIncreased]`，避免统计重复计数。
5. histogram 无效（无 cnt）但 timer 证据可用时，输出 timer 事件而非整个 unknown（issue：缺少 cnt 时保留可证明的 timer 状态）。

---

### Task 1: unique 路径 timer 规范化（修复自然倒计时误报）

**Files:**
- Modify: `Sources/COCHelperCore/SnapshotHistoryDiff.swift`（`timerTransition` 1089 行附近 + 新增私有函数）
- Test: `Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift`

- [ ] **Step 1: 写失败测试**（追加到 `SnapshotHistoryDiffTests.swift`，`testTimerTransitionsAreGroupedWithLevelChange` 之后）

```swift
    func testUniqueTimerNaturalCountdownDoesNotCreateChange() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeItem(
            identity: identity,
            level: 1,
            timer: 90,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let natural = makeItem(
            identity: identity,
            level: 1,
            timer: 85,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [old],
                section: "heroes",
                states: ["timer": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [natural],
                section: "heroes",
                states: ["timer": .complete]
            )
        )
        XCTAssertTrue(diff.changes.isEmpty)
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testUniqueTimerRestartStillReportsTimerChanged() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeItem(
            identity: identity,
            level: 1,
            timer: 90,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let restarted = makeItem(
            identity: identity,
            level: 1,
            timer: 500,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [old],
                section: "heroes",
                states: ["timer": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 105,
                items: [restarted],
                section: "heroes",
                states: ["timer": .complete]
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .timerChanged)
    }
```

- [ ] **Step 2: 验证 RED**

Run: `swift test --filter SnapshotHistoryDiffTests/testUniqueTimerNaturalCountdownDoesNotCreateChange` 和 `--filter SnapshotHistoryDiffTests/testUniqueTimerRestartStillReportsTimerChanged`
Expected: 两个都 FAIL（`testUniqueTimerNaturalCountdownDoesNotCreateChange` 会得到 timerChanged change；`testUniqueTimerRestartStillReportsTimerChanged` 会 PASS——因为 90→500 裸值比较也报 timerChanged）。

> 注意：第二个测试其实在当前代码下已通过。它存在的意义是**锁定**增强后行为（防回归），并配合第一个测试证明规范化不破坏真实变化的检测。写完两个后先跑第一个确认 RED，再进入 Step 3。

- [ ] **Step 3: 最小实现**（`SnapshotHistoryDiff.swift`）

在 `private enum TimerState` 定义附近（约 1448 行）加常量：

```swift
    /// remaining timer 自然倒计时的容差（秒）。两次观测间期望值 = old − elapsed，
    /// 偏差超过该容差才视为业务变化（覆盖时钟抖动与抓取延迟）。
    private static let timerElapsedTolerance: TimeInterval = 30
```

替换 `timerTransition` 的 active→active 分支（约 1117-1120 行）：

```swift
        case (.active, .active):
            if timerChangedAfterNormalization(old: old, new: new, from: from, to: to) {
                return TimerResult(kind: .timerChanged, requiredFields: fields)
            }
```

在 `timerTransition` 之后新增：

```swift
    /// 规范化 remaining timer 比较：自然倒计时（new ≈ old − elapsed）不算业务变化。
    /// 所有可解析 timer 字段都必须自然流逝才判定为无变化；任一字段规范化后仍变化 → timerChanged。
    private static func timerChangedAfterNormalization(
        old: SnapshotObservationItem,
        new: SnapshotObservationItem,
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry
    ) -> Bool {
        let elapsed = to.appliedAt.timeIntervalSince(from.appliedAt)
        let fields = Set(old.rawTimerEvidence.keys).union(new.rawTimerEvidence.keys).sorted()
        for field in fields {
            guard let oldNumber = timerNumber(old.rawTimerEvidence[field]),
                  let newNumber = timerNumber(new.rawTimerEvidence[field]) else {
                continue
            }
            let expected = Double(oldNumber) - elapsed
            if abs(Double(newNumber) - expected) > timerElapsedTolerance {
                return true
            }
        }
        return false
    }
```

- [ ] **Step 4: 验证 GREEN**

Run: `swift test --filter SnapshotHistoryDiffTests`
Expected: 全部 PASS（含现有 `testTimerTransitionsAreGroupedWithLevelChange`：timer 90@100 → 80@200，elapsed 100，expected −10，|80−(−10)| = 90 > 30 → 仍报 timerChanged ✓）。

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/SnapshotHistoryDiff.swift Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift
git commit -m "fix(history): unique 路径 remaining timer 规范化，自然倒计时不再误报 timerChanged (Issue #165)"
```

---

### Task 2: aggregate timer 基础 + histogram 无 cnt 的 upgradeStarted

**Files:**
- Modify: `Sources/COCHelperCore/SnapshotHistoryDiff.swift`（`compareHistogram` 901 行附近 + 新增 `aggregateTimerState` / `aggregateTimerTransition` / `appendAggregateTimerChange`）
- Test: `Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
    func testBuildingHistogramTimerUpgradeStartedWithoutCount() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, display: binding)],
            section: "buildings",
            states: ["timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, timer: 900, display: binding)],
            section: "buildings",
            states: ["timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .upgradeStarted)
        XCTAssertEqual(change.evidence, .aggregateInferred)
        XCTAssertEqual(change.coverage.state, .complete)
    }

    func testBuilderBaseHistogramTimerUpgradeStarted() throws {
        let identity = makeIdentity(section: "buildings2", dataID: 1_000_033, base: .builder)
        let binding = SnapshotDisplayBinding(displayName: "建筑工人小屋", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, display: binding)],
            section: "buildings2",
            states: ["timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 1, timer: 60, display: binding)],
            section: "buildings2",
            states: ["timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .upgradeStarted)
        XCTAssertEqual(change.evidence, .aggregateInferred)
    }
```

- [ ] **Step 2: 验证 RED**

Run: `swift test --filter SnapshotHistoryDiffTests/testBuildingHistogramTimerUpgradeStartedWithoutCount`
Expected: FAIL（当前 histogram 无效 → unknown change，changeKind 是 .unknown 而非 .upgradeStarted）。

- [ ] **Step 3: 最小实现**

在 `timerState` / `timerSignature` 附近（约 1448 行）新增：

```swift
    /// 聚合多个重复实例的 timer 状态：任一 evidence 无法解析 → unknown；
    /// 任一 active（>0）→ active；全部为空 → absent；否则 inactive。
    private static func aggregateTimerState(_ items: [SnapshotObservationItem]) -> TimerState {
        var hasEvidence = false
        var hasActive = false
        for item in items {
            if item.rawTimerEvidence.isEmpty { continue }
            hasEvidence = true
            switch timerState(item.rawTimerEvidence) {
            case .unknown:
                return .unknown
            case .active:
                hasActive = true
            case .absent, .inactive:
                break
            }
        }
        guard hasEvidence else { return .absent }
        return hasActive ? .active : .inactive
    }

    /// 聚合 timer 状态迁移。active→active 时按"remaining 规范化"比较：
    /// 同一字段可解析数值集合数量不同 → unknown（身份无法稳定聚合，fail-closed）；
    /// 数量相同 → 排序后逐位比较，全部自然流逝才无变化。
    private static func aggregateTimerTransition(
        oldItems: [SnapshotObservationItem],
        newItems: [SnapshotObservationItem],
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry,
        hasCredibleLevelUp: Bool
    ) -> TimerResult {
        let oldState = aggregateTimerState(oldItems)
        let newState = aggregateTimerState(newItems)
        let fields = Set(oldItems.flatMap { $0.rawTimerEvidence.keys })
            .union(newItems.flatMap { $0.rawTimerEvidence.keys })
            .sorted()
        guard !fields.isEmpty else { return TimerResult() }
        guard let identity = (newItems.first ?? oldItems.first)?.identity else { return TimerResult() }

        let coverage = coverageFor(identity: identity, from: from, to: to, fields: fields)
        if oldState == .unknown || newState == .unknown || coverage.state != .complete {
            return TimerResult(
                kind: nil,
                isUnknown: true,
                reason: "timer 原始状态或 coverage 不足，不能确认 timer 变化。",
                requiredFields: fields
            )
        }

        switch (oldState, newState) {
        case (.absent, .active), (.inactive, .active):
            return TimerResult(kind: .upgradeStarted, requiredFields: fields)
        case (.active, .active):
            if aggregateTimerChangedAfterNormalization(
                oldItems: oldItems,
                newItems: newItems,
                from: from,
                to: to
            ) {
                return TimerResult(kind: .timerChanged, requiredFields: fields)
            }
        case (.active, .absent), (.active, .inactive):
            if hasCredibleLevelUp {
                return TimerResult(kind: .upgradeCompleted, requiredFields: fields)
            }
            return TimerResult(kind: .timerEndedObserved, requiredFields: fields)
        default:
            break
        }
        return TimerResult(requiredFields: fields)
    }

    private static func aggregateTimerChangedAfterNormalization(
        oldItems: [SnapshotObservationItem],
        newItems: [SnapshotObservationItem],
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry
    ) -> Bool {
        let elapsed = to.appliedAt.timeIntervalSince(from.appliedAt)
        let fields = Set(oldItems.flatMap { $0.rawTimerEvidence.keys })
            .union(newItems.flatMap { $0.rawTimerEvidence.keys })
            .sorted()
        for field in fields {
            let oldNumbers = oldItems.compactMap { timerNumber($0.rawTimerEvidence[field]) }.sorted()
            let newNumbers = newItems.compactMap { timerNumber($0.rawTimerEvidence[field]) }.sorted()
            guard !oldNumbers.isEmpty, !newNumbers.isEmpty else { continue }
            guard oldNumbers.count == newNumbers.count else { return true }
            for (oldNumber, newNumber) in zip(oldNumbers, newNumbers) {
                let expected = Double(oldNumber) - elapsed
                if abs(Double(newNumber) - expected) > timerElapsedTolerance {
                    return true
                }
            }
        }
        return false
    }

    /// 把 aggregate timer 结果输出为独立 change（evidence: .aggregateInferred）。
    private static func appendAggregateTimerChange(
        _ timerResult: TimerResult,
        identity: SnapshotItemIdentity,
        oldItems: [SnapshotObservationItem],
        newItems: [SnapshotObservationItem],
        from: SnapshotHistoryEntry,
        to: SnapshotHistoryEntry,
        changes: inout [SnapshotChange],
        diagnostics: inout [SnapshotDiffDiagnostic]
    ) {
        let timerCoverage = coverageFor(
            identity: identity,
            from: from,
            to: to,
            fields: Array(Set(timerResult.requiredFields)).sorted()
        )
        if let kind = timerResult.kind {
            changes.append(makeChange(
                identity: identity,
                old: oldItems.first,
                new: newItems.first,
                oldLevel: nil,
                newLevel: nil,
                oldQuantity: nil,
                newQuantity: nil,
                movedQuantity: nil,
                levelDelta: nil,
                changeKind: kind,
                related: kind == .upgradeCompleted ? [.levelIncreased] : [],
                evidence: .aggregateInferred,
                coverage: timerCoverage
            ))
        } else if timerResult.isUnknown {
            let reason = timerResult.reason.isEmpty
                ? "timer 证据不足，无法确认变化。"
                : timerResult.reason
            changes.append(unknownChange(
                identity: identity,
                old: oldItems.first,
                new: newItems.first,
                coverage: timerCoverage.addingReason(reason, degradingTo: .partial),
                reason: reason
            ))
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .insufficientCoverage,
                message: reason,
                identity: identity,
                rawSection: identity.rawSection
            ))
        }
    }
```

修改 `compareHistogram` 的 histogram 无效分支（约 913-926 行），在原来的 unknown 输出之前插入 timer 检查：

```swift
        guard let oldHistogram = histogram(oldItems), let newHistogram = histogram(newItems) else {
            let timerResult = aggregateTimerTransition(
                oldItems: oldItems,
                newItems: newItems,
                from: from,
                to: to,
                hasCredibleLevelUp: false
            )
            if timerResult.kind != nil || timerResult.isUnknown {
                appendAggregateTimerChange(
                    timerResult,
                    identity: identity,
                    oldItems: oldItems,
                    newItems: newItems,
                    from: from,
                    to: to,
                    changes: &changes,
                    diagnostics: &diagnostics
                )
                return
            }
            let reason = "重复建筑/城墙 histogram 的 level/count 无效或总量溢出。"
            let unknownCoverage = coverage.addingReason(reason, degradingTo: .partial)
            changes.append(unknownChange(
                identity: identity,
                old: oldItems.first,
                new: newItems.first,
                coverage: unknownCoverage,
                reason: reason
            ))
            diagnostics.append(SnapshotDiffDiagnostic(
                kind: .insufficientCoverage,
                message: reason,
                identity: identity,
                rawSection: identity.rawSection
            ))
            return
        }
```

- [ ] **Step 4: 验证 GREEN**

Run: `swift test --filter SnapshotHistoryDiffTests`
Expected: 全部 PASS（现有 `testSingleBuildingRecordStillRequiresHistogramCount` 无 timer 证据 → `aggregateTimerTransition` fields 为空 → `TimerResult()` → 仍走原 unknown 分支 ✓；`testHistogramMissingCountIsUnknownAndNeverTreatedAsOne` 同理 ✓）。

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/SnapshotHistoryDiff.swift Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift
git commit -m "feat(history): histogram 路径聚合 timer 证据，无 cnt 时仍可输出 upgradeStarted (Issue #165)"
```

---

### Task 3: histogram 有效路径的 timerChanged 与自然倒计时（traps / traps2）

**Files:**
- Modify: `Sources/COCHelperCore/SnapshotHistoryDiff.swift`（`compareHistogram` 末尾）
- Test: `Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
    func testTrapHistogramTimerChangedAfterNormalization() throws {
        let identity = makeIdentity(section: "traps", dataID: 9)
        let binding = SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 90, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 40, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .timerChanged)
        XCTAssertEqual(change.evidence, .aggregateInferred)
    }

    func testTrapHistogramNaturalCountdownCreatesNoChange() throws {
        let identity = makeIdentity(section: "traps", dataID: 9)
        let binding = SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 90, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete]
        )
        let natural = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 85, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: natural)
        XCTAssertTrue(diff.changes.isEmpty)
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testBuilderBaseTrapHistogramTimerChanged() throws {
        let identity = makeIdentity(section: "traps2", dataID: 12_000_011, base: .builder)
        let binding = SnapshotDisplayBinding(displayName: "弹簧陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 300, display: binding)],
            section: "traps2",
            states: ["cnt": .complete, "timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 10, display: binding)],
            section: "traps2",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .timerChanged)
        XCTAssertEqual(change.evidence, .aggregateInferred)
    }
```

> 数值说明：90→40 elapsed 5，expected 85，|40−85| = 45 > 30 → timerChanged；90→85 elapsed 5，expected 85 → 无变化；300→10 elapsed 5，expected 295，|10−295| = 285 > 30 → timerChanged。

- [ ] **Step 2: 验证 RED**

Run: `swift test --filter SnapshotHistoryDiffTests/testTrapHistogramTimerChangedAfterNormalization`
Expected: FAIL（当前 histogram 有效路径完全不产生 timer change，`diff.changes` 为空）。

- [ ] **Step 3: 最小实现**

在 `compareHistogram` 的 quantity change 之后（函数末尾，约 1086 行）追加：

```swift
        let timerResult = aggregateTimerTransition(
            oldItems: oldItems,
            newItems: newItems,
            from: from,
            to: to,
            hasCredibleLevelUp: anyLevelUp
        )
        if timerResult.kind != nil || timerResult.isUnknown {
            appendAggregateTimerChange(
                timerResult,
                identity: identity,
                oldItems: oldItems,
                newItems: newItems,
                from: from,
                to: to,
                changes: &changes,
                diagnostics: &diagnostics
            )
        }
```

并在 level migration 循环之前（`var oldRemaining` 之后）声明并收集 level 上移证据：

```swift
        var anyLevelUp = false
```

循环内 `if moved > 0 && oldLevel != newLevel` 的块中追加一行：

```swift
                if delta > 0 { anyLevelUp = true }
```

> `anyLevelUp` 用于 Task 4 的 `upgradeCompleted` 判定；本任务先接上（对 started/changed 无影响）。

- [ ] **Step 4: 验证 GREEN**

Run: `swift test --filter SnapshotHistoryDiffTests`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/SnapshotHistoryDiff.swift Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift
git commit -m "feat(history): histogram 路径输出 timerChanged，自然倒计时不产生噪声 (Issue #165)"
```

---

### Task 4: histogram 的 upgradeCompleted 与 timerEndedObserved

**Files:**
- Modify: `Sources/COCHelperCore/SnapshotHistoryDiff.swift`（Task 3 已接好 `anyLevelUp`）
- Test: `Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
    func testBuildingHistogramTimerCompletionWithLevelMigration() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 2, timer: 90, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 15, count: 2, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let completed = try XCTUnwrap(diff.changes.first { $0.changeKind == .upgradeCompleted })
        XCTAssertEqual(completed.evidence, .aggregateInferred)
        XCTAssertEqual(completed.relatedChangeKinds, [.levelIncreased])
        XCTAssertNil(completed.levelDelta)
        XCTAssertNil(completed.movedQuantity)
        let migration = try XCTUnwrap(diff.changes.first { $0.changeKind == .levelIncreased })
        XCTAssertEqual(migration.oldLevel, 14)
        XCTAssertEqual(migration.newLevel, 15)
        XCTAssertEqual(migration.movedQuantity, 2)
    }

    func testBuildingHistogramTimerEndedWithoutLevelMigration() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 2, timer: 90, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 14, count: 2, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .timerEndedObserved)
        XCTAssertEqual(change.evidence, .aggregateInferred)
    }
```

- [ ] **Step 2: 验证 RED**

Run: `swift test --filter SnapshotHistoryDiffTests/testBuildingHistogramTimerCompletionWithLevelMigration`
Expected: FAIL（Task 3 完成后 `anyLevelUp` 已接好，但 `hasCredibleLevelUp: anyLevelUp` 传入的 `anyLevelUp` 尚未在循环中置位 → 实际仍是 endedObserved？不对——Task 3 Step 3 已要求加 `if delta > 0 { anyLevelUp = true }`。若严格按序执行，本测试可能直接 PASS。**若 PASS，跳过一个 RED 步骤直接验证两个测试 + 现有测试全绿后提交**；若 FAIL，则补上 `anyLevelUp` 收集逻辑再 GREEN。）

- [ ] **Step 3: 验证 GREEN**

Run: `swift test --filter SnapshotHistoryDiffTests`
Expected: 全部 PASS。

- [ ] **Step 4: Commit**

```bash
git add Sources/COCHelperCore/SnapshotHistoryDiff.swift Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift
git commit -m "feat(history): histogram 聚合 timer 结束输出 upgradeCompleted/timerEndedObserved (Issue #165)"
```

---

### Task 5: fail-closed（coverage 不足与不可解析证据）

**Files:**
- Modify: `Sources/COCHelperCore/SnapshotHistoryDiff.swift`（如需）
- Test: `Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
    func testHistogramTimerUnknownOnPartialCoverage() throws {
        let identity = makeIdentity(section: "traps", dataID: 9)
        let binding = SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 90, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .partial]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 85, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .partial]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        XCTAssertTrue(change.coverage.fields.contains { $0.field == "timer" })
    }

    func testHistogramTimerUnknownOnUnparsableEvidence() throws {
        let identity = makeIdentity(section: "traps", dataID: 9)
        let binding = SnapshotDisplayBinding(displayName: "陷阱", category: "traps")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: 90, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: [makeItem(identity: identity, level: 1, count: 1, timer: -1, display: binding)],
            section: "traps",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        XCTAssertEqual(diff.comparisonState, .insufficientCoverage)
    }
```

- [ ] **Step 2: 验证 RED**

Run: `swift test --filter SnapshotHistoryDiffTests/testHistogramTimerUnknownOnPartialCoverage`
Expected: FAIL 或 PASS 视前序任务实现而定（`aggregateTimerTransition` 已有 coverage/unknown 检查，大概率直接 PASS）。**若直接 PASS 则验证全部相关测试后提交；否则补实现再验证。**

- [ ] **Step 3: 验证 GREEN + 全量核心测试**

Run: `swift test --filter SnapshotHistoryDiffTests`
Expected: 全部 PASS。

- [ ] **Step 4: Commit**

```bash
git add Sources/COCHelperCore/SnapshotHistoryDiff.swift Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift
git commit -m "test(history): histogram timer 对 coverage 不足与不可解析证据 fail-closed (Issue #165)"
```

---

### Task 6: 确定性（顺序无关）与统计不重复计数

**Files:**
- Modify: 无（如测试暴露问题再改 `Sources/COCHelperCore/SnapshotHistoryDiff.swift`）
- Test: `Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
    func testHistogramTimerOrderIndependence() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let oldItems = [
            makeItem(identity: identity, level: 14, count: 1, timer: 90, display: binding),
            makeItem(identity: identity, level: 14, count: 1, timer: 60, display: binding)
        ]
        let newItems = [
            makeItem(identity: identity, level: 14, count: 1, timer: 10, display: binding),
            makeItem(identity: identity, level: 14, count: 1, timer: 85, display: binding)
        ]
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: oldItems,
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let forward = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: newItems,
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let reversed = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 105,
            items: newItems.reversed(),
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diffA = SnapshotDiffEngine.compare(from: old, to: forward)
        let diffB = SnapshotDiffEngine.compare(from: old, to: reversed)
        XCTAssertEqual(diffA, diffB)
        XCTAssertTrue(diffA.changes.contains { $0.changeKind == .timerChanged })
    }

    func testHistogramTimerCompletionStatisticsNotDoubleCounted() throws {
        let identity = makeIdentity(section: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 14, count: 2, timer: 90, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 15, count: 2, display: binding)],
            section: "buildings",
            states: ["cnt": .complete, "timer": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertTrue(diff.changes.contains { $0.changeKind == .upgradeCompleted })
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        // aggregateInferred 事件不污染 confirmed 完成数
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.value, 0)
        XCTAssertEqual(statistics.today.buildingUpgradeCompletions.state, .available)
        // level 迁移与 timer 完成是两个独立事件，各计一次
        XCTAssertEqual(statistics.today.aggregateInferredEventCount.value, 2)
        XCTAssertEqual(statistics.today.aggregateInferredBuildingLevelGrowth.value, 2)
    }
```

> 数值说明（order independence）：elapsed 5，expected 85/55；sorted old [60, 90] → sorted new [10, 85]；85 对 90：|85−85| = 0 ✓；10 对 60：|10−55| = 45 > 30 → timerChanged ✓。数组顺序不影响排序后逐位比较。

- [ ] **Step 2: 运行验证**

Run: `swift test --filter SnapshotHistoryDiffTests/testHistogramTimerOrderIndependence` 和 `--filter SnapshotHistoryDiffTests/testHistogramTimerCompletionStatisticsNotDoubleCounted`
Expected: 若 Task 2-4 实现正确，直接 PASS（确定性由排序保证；统计由 `MetricAccumulators.apply` 的 evidence 分流保证）。若 FAIL，修实现（例如统计值不符时调整 timer change 的字段）。

- [ ] **Step 3: Commit**

```bash
git add Sources/COCHelperCore/SnapshotHistoryDiff.swift Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift
git commit -m "test(history): histogram timer 顺序无关且统计不重复计数 (Issue #165)"
```

---

### Task 7: 真实 JSON fixture 与全量验证

**Files:**
- Modify: `Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift`

- [ ] **Step 1: 写真实 fixture 测试**（复用 `testCanonicalizerConfirmsTimerAbsenceAndRejectsNegativeTimer` 的 canonicalize 模式）

```swift
    func testRealisticBuildingAndTrapTimerFixtureDiffs() throws {
        let villageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        func canonicalEntry(
            _ text: String,
            id: String,
            appliedAt: TimeInterval
        ) throws -> SnapshotHistoryEntry {
            let snapshot = try AccountSnapshotImporter.parse(
                text,
                now: Date(timeIntervalSince1970: appliedAt)
            )
            return try SnapshotHistoryCanonicalizer.canonicalize(
                snapshot: snapshot,
                villageID: villageID,
                lineageID: lineageID,
                appliedAt: Date(timeIntervalSince1970: appliedAt),
                snapshotID: UUID(uuidString: id)!
            )
        }

        let idle = try canonicalEntry(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":14}],\"traps\":[{\"data\":9000001,\"lvl\":1,\"cnt\":1}]}",
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            appliedAt: 100
        )
        let upgrading = try canonicalEntry(
            "{\"buildings\":[{\"data\":1000001,\"lvl\":14,\"timer\":900}],\"traps\":[{\"data\":9000001,\"lvl\":1,\"cnt\":1,\"timer\":60}]}",
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            appliedAt: 110
        )
        XCTAssertEqual(
            upgrading.observation.items.first { $0.identity.dataID == 1_000_001 }?.rawTimerEvidence["timer"],
            .number("900")
        )
        let started = SnapshotDiffEngine.compare(from: idle, to: upgrading)
        let buildingStarted = try XCTUnwrap(started.changes.first { $0.identity.dataID == 1_000_001 })
        XCTAssertEqual(buildingStarted.changeKind, .upgradeStarted)
        let trapStarted = try XCTUnwrap(started.changes.first { $0.identity.dataID == 9_000_001 })
        XCTAssertEqual(trapStarted.changeKind, .upgradeStarted)
    }
```

> 注意：canonicalize 依赖 bundled GameCatalog（校验 dataID 是否在宇宙内）。若 1000001（加农炮）或 9000001 不被识别，改用 `SnapshotHistoryCoreTests.swift:13` 已验证的 dataID 1000001（buildings timer 90 的既有 fixture 用法）。traps dataID 用 `testTrapHistogramFeedsBuildingStatisticsAndUnknownCoverage` 里的 9。运行后按报错调整。

- [ ] **Step 2: 验证**

Run: `swift test --filter SnapshotHistoryDiffTests/testRealisticBuildingAndTrapTimerFixtureDiffs`
Expected: PASS（若 canonicalize 因 coverage/宇宙校验失败，按报错调整 dataID 或 section 内容）。

- [ ] **Step 3: 全量验证**

Run: `swift test`（全部 1382+ 测试）和 `git diff --check`
Expected: 全部 PASS，diff 无空白错误。

- [ ] **Step 4: Commit**

```bash
git add Tests/COCHelperCoreTests/SnapshotHistoryDiffTests.swift
git commit -m "test(history): 真实 JSON fixture 验证建筑与陷阱 timer diff (Issue #165)"
```

---

### Task 8: PR 准备

- [ ] **Step 1: 自查**：`git log --oneline origin/main..HEAD` 确认 7 个 commit 都在；`git diff origin/main..HEAD --stat` 确认只动了 2 个文件（SnapshotHistoryDiff.swift + SnapshotHistoryDiffTests.swift）。
- [ ] **Step 2: 推送分支**：`git push -u origin codex/issue-165-snapshot-timer`
- [ ] **Step 3: 开 PR**：`gh pr create --base main --head codex/issue-165-snapshot-timer --title "feat(history): 建筑与陷阱 histogram 补齐 timer 状态迁移 (Issue #165)" --body "..."`（body 含：背景、改动文件、测试清单、手工验收说明、与 #164 的关系）。

---

## 自检清单

- [ ] 所有新函数有失败在先的测试（Task 1-2 明确 RED；Task 3-6 若直接 PASS 需注明原因——因前序任务已实现）
- [ ] 每个 commit 独立可构建、测试通过
- [ ] 不改 `SnapshotChangeKind` / models / canonicalizer / UI / 统计代码（除非测试暴露问题）
- [ ] `upgradeCompleted` change 不带 levelDelta/movedQuantity（防统计重复计数）
- [ ] `git diff --check` 干净
