import Foundation
import XCTest
@testable import COCHelperCore

final class ManualTrackerReconciliationTests: XCTestCase {
    private let villageID = UUID(uuidString: "00000000-0000-0000-0000-000000000143")!
    private let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 100)
    private let provenance = ManualCatalogProvenance(gameVersion: "18.400.13")

    private struct HistoryContext {
        let service: SnapshotHistoryService
        let envelope: SnapshotHistoryEnvelope
        let entry: SnapshotHistoryEntry
        let reference: ManualBaselineReference
        let snapshot: AccountSnapshot
    }

    private func history(
        _ raw: String,
        sectionProofs: [String: SnapshotCoverageProof] = [:],
        injectVerifiedSectionProofs: Bool = true
    ) throws -> HistoryContext {
        let snapshot = try AccountSnapshotImporter.parse(
            raw,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let proofs = mergedSectionProofs(
            raw: raw,
            explicit: sectionProofs,
            injectVerified: injectVerifiedSectionProofs
        )
        let store = MemoryHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let envelope = try service.loadOrMigrate(
            villages: [VillageProfile(
                id: villageID,
                name: "主村",
                accountSnapshot: snapshot
            )],
            now: Date(timeIntervalSince1970: 1_700_000_010),
            sectionProofs: [villageID: proofs]
        )
        let lineage = try XCTUnwrap(envelope.activeLineage(for: villageID))
        let entry = try XCTUnwrap(envelope.entry(id: lineage.lastEntryID))
        return HistoryContext(
            service: service,
            envelope: envelope,
            entry: entry,
            reference: ManualTrackerReconciliationService.reference(for: entry, in: envelope),
            snapshot: snapshot
        )
    }

    private func decision(
        _ raw: String,
        from context: HistoryContext,
        appliedAt: TimeInterval = 1_700_000_200,
        currentTag: String = "#P1",
        sectionProofs: [String: SnapshotCoverageProof] = [:],
        injectVerifiedSectionProofs: Bool = true
    ) throws -> SnapshotHistoryImportDecision {
        let snapshot = try AccountSnapshotImporter.parse(
            raw,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let proofs = mergedSectionProofs(
            raw: raw,
            explicit: sectionProofs,
            injectVerified: injectVerifiedSectionProofs
        )
        return try context.service.planImport(
            snapshot: snapshot,
            villageID: villageID,
            currentTag: currentTag,
            hasCurrentSnapshot: true,
            envelope: context.envelope,
            appliedAt: Date(timeIntervalSince1970: appliedAt),
            sectionProofs: proofs
        )
    }

    private func mergedSectionProofs(
        raw: String,
        explicit: [String: SnapshotCoverageProof],
        injectVerified: Bool
    ) -> [String: SnapshotCoverageProof] {
        guard injectVerified else { return explicit }
        var proofs = explicit
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return proofs
        }
        for section in SnapshotHistoryKnownSections.all where proofs[section] == nil {
            guard let value = object[section] else { continue }
            let expectedCount: Int?
            if let items = value as? [Any] {
                expectedCount = items.count
            } else {
                expectedCount = nil
            }
            proofs[section] = SnapshotHistoryTestCoverage.verified(
                expectedCount: expectedCount
            )
        }
        return proofs
    }

    private func observedState(
        reference: ManualBaselineReference,
        distribution: [Int: Int64]
    ) throws -> ManualTrackerVillageState {
        let imported = try ManualImportedObservation(
            reference: reference,
            levelDistribution: ManualLevelDistribution(levelQuantities: distribution),
            sourceTimestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let state = try ManualItemState(
            itemKey: key,
            baselineReference: reference,
            importedObservation: imported,
            status: .observed
        )
        return try ManualTrackerVillageState(
            villageID: villageID,
            core: ManualUpgradeCore(itemStates: [state]),
            stateUpdatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
    }

    private func activeState(
        reference: ManualBaselineReference,
        distribution: [Int: Int64] = [10: 1],
        startedAt: TimeInterval = 1_700_000_010,
        duration: Int64 = 60
    ) throws -> ManualTrackerVillageState {
        var state = try observedState(reference: reference, distribution: distribution)
        var core = state.core
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: Date(timeIntervalSince1970: startedAt),
            durationState: .timed(seconds: duration),
            frozenCosts: [CatalogUpgradeCost(
                resource: "Gold",
                amount: 100,
                rawResource: nil,
                rawAmount: nil,
                parseFailed: false
            )],
            catalogProvenance: provenance,
            baselineReference: reference,
            recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            now: Date(timeIntervalSince1970: startedAt)
        )
        state = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: Date(timeIntervalSince1970: startedAt)
        )
        return state
    }

    func testReconcileKeepsQueueCapacityConfigs() throws {
        let raw = ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##
        let context = try history(raw)
        let base = try activeState(reference: context.reference)
        let config = try LocalQueueCapacityConfig(
            villageID: villageID, queueKind: .builder, capacity: 3,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let state = try ManualTrackerVillageState(
            villageID: villageID,
            core: base.core,
            queueCapacityConfigs: [config]
        )
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##,
            from: context
        )
        XCTAssertTrue(next.duplicate)

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(
            plan.state.queueCapacityConfigs, [config],
            "reimport 对账重建 village state 不得丢失用户配置的容量"
        )
    }

    func testDuplicateRebasesWithoutRestartingOrDuplicatingRecords() throws {
        let raw = ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##
        let context = try history(raw)
        let state = try activeState(reference: context.reference)
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##,
            from: context
        )
        XCTAssertTrue(next.duplicate)

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(plan.preview.count(.duplicate), 1)
        XCTAssertEqual(plan.state.core.records.map(\.recordID), state.core.records.map(\.recordID))
        XCTAssertEqual(plan.state.core.records.first?.status, .active)
        XCTAssertEqual(plan.state.baselineReference, plan.preview.newReference)
        XCTAssertEqual(plan.state.reconciliationHistory.count, 1)
        XCTAssertEqual(
            plan.preview.sourceTimestamp,
            Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertEqual(
            plan.state.reconciliationHistory.first?.sourceTimestamp,
            plan.preview.sourceTimestamp
        )
    }

    func testReliableObservedCompletionConfirmsActiveRecordOnce() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"timer":60,"cnt":1}]}"##)
        let state = try activeState(reference: context.reference)
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1}]}"##,
            from: context
        )

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(plan.preview.items.single?.classification, .observedAhead)
        XCTAssertEqual(plan.preview.items.single?.confirmedRecordIDs, state.core.records.map(\.recordID))
        XCTAssertEqual(plan.state.core.records.single?.status, .completed)
        XCTAssertEqual(
            plan.state.core.itemState(for: key)?.manualCompletedDistribution,
            try ManualLevelDistribution(levelQuantities: [11: 1])
        )
        var settled = plan.state.core
        XCTAssertTrue(try settled.settleDue(at: Date(timeIntervalSince1970: 1_800_000_000)).isEmpty)
    }

    func testEarlyObservedMovementBeforeExpectedEndRemainsUnknownAndActive() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let state = try activeState(reference: context.reference, duration: 600)
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000020,"buildings":[{"data":100,"lvl":11,"cnt":1}]}"##,
            from: context
        )

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_020)
        )

        XCTAssertEqual(plan.preview.items.single?.classification, .unknown)
        XCTAssertTrue(plan.preview.items.single?.confirmedRecordIDs.isEmpty == true)
        XCTAssertEqual(plan.state.core.records.single?.status, .active)
    }

    func testExactObservationIsSafeWhenFingerprintChangesOnlyOutsideItemState() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let state = try observedState(reference: context.reference, distribution: [10: 1])
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1}],"future_field":1}"##,
            from: context
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertFalse(preview.duplicate)
        XCTAssertEqual(preview.items.single?.classification, .exactMatch)
        XCTAssertFalse(preview.requiresExplicitDecision)
    }

    func testOneObservedMovementCannotConfirmTwoMatchingActiveRecords() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":2}]}"##)
        var state = try observedState(reference: context.reference, distribution: [10: 2])
        var core = state.core
        let recordIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        ]
        for (offset, recordID) in recordIDs.enumerated() {
            let startedAt = Date(timeIntervalSince1970: 1_700_000_010 + Double(offset))
            _ = try core.startUpgrade(
                itemKey: key,
                fromLevel: 10,
                targetLevel: 11,
                quantity: 1,
                startedAt: startedAt,
                durationState: .timed(seconds: 60),
                frozenCosts: [],
                catalogProvenance: provenance,
                baselineReference: context.reference,
                recordID: recordID,
                now: startedAt
            )
        }
        state = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: Date(timeIntervalSince1970: 1_700_000_011)
        )
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1},{"data":100,"lvl":11,"cnt":1}]}"##,
            from: context
        )

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(plan.preview.items.single?.confirmedRecordIDs.count, 1)
        XCTAssertEqual(plan.state.core.records.filter { $0.status == .completed }.count, 1)
        XCTAssertEqual(plan.state.core.records.filter { $0.status == .active }.count, 1)
    }

    func testImportedTimerWithoutTargetRemainsPossibleDuplicate() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let state = try activeState(reference: context.reference, duration: 600)
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000020,"buildings":[{"data":100,"lvl":10,"timer":580},{"data":100,"lvl":10,"cnt":1}]}"##,
            from: context
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_020)
        )

        XCTAssertEqual(preview.items.single?.classification, .possibleDuplicate)
        XCTAssertTrue(preview.items.single?.confirmedRecordIDs.isEmpty == true)
        XCTAssertTrue(preview.requiresExplicitDecision)
    }

    func testTimerDisappearanceWithoutLevelChangeDoesNotClaimCompletion() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1,"timer":60}]}"##)
        let state = try activeState(reference: context.reference, duration: 600)
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000020,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##,
            from: context
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_020)
        )

        XCTAssertEqual(preview.items.single?.classification, .observedTimerEnded)
        XCTAssertTrue(preview.items.single?.confirmedRecordIDs.isEmpty == true)
    }

    func testOlderAndMissingTimestampNeverRollbackManualState() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000100,"buildings":[{"data":100,"lvl":11,"cnt":1}]}"##)
        let state = try observedState(reference: context.reference, distribution: [11: 1])
        let older = try decision(
            ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##,
            from: context
        )
        let olderPreview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: older,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertEqual(olderPreview.items.single?.classification, .staleImport)

        let missing = try decision(
            ##"{"tag":"#P1","buildings":[{"data":100,"lvl":12,"cnt":1}]}"##,
            from: context
        )
        let missingPreview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: missing,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertEqual(missingPreview.timeConfidence, .sourceTimestampAbsent)
        XCTAssertEqual(missingPreview.items.single?.classification, .unknown)
    }

    func testPartialLevelCoverageIsUnknownInsteadOfDeletionOrZero() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let state = try observedState(reference: context.reference, distribution: [10: 1])
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"cnt":1}]}"##,
            from: context
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(preview.items.single?.classification, .unknown)
        XCTAssertFalse(preview.items.single?.coverageComplete ?? true)
        XCTAssertNil(preview.items.single?.observedDistribution)

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let rebased = try XCTUnwrap(plan.state.core.itemState(for: key))
        XCTAssertEqual(rebased.status, .observed)
        XCTAssertNotNil(rebased.importedObservation)
        XCTAssertNil(rebased.importedObservation?.levelDistribution)
    }

    func testNewTimerOnlyObservationIsRetainedAsImportedEvidence() throws {
        // A timer-only item can be new to the manual core and still needs to
        // reach the queue-assignment UI. Its distribution is intentionally nil
        // because coverage is incomplete, but the timer evidence must survive
        // reconciliation as `observedTimer == true`.
        let context = try history(
            ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##
        )
        let state = ManualTrackerVillageState.empty(
            villageID: villageID,
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1},{"data":101,"lvl":10,"timer":60}]}"##,
            from: context
        )
        let timerKey = TrackerItemKey.root(
            base: .home, rawSection: "buildings", dataID: 101
        )

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .acceptObserved,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let rebased = try XCTUnwrap(plan.state.core.itemState(for: timerKey))
        XCTAssertEqual(rebased.status, .observed)
        XCTAssertTrue(rebased.importedObservation?.observedTimer == true)
        XCTAssertNil(rebased.importedObservation?.levelDistribution)
    }

    func testPartialCountOrTimerCoverageRemainsUnknown() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let state = try observedState(reference: context.reference, distribution: [10: 1])

        let missingCount = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1},{"data":100,"lvl":10}]}"##,
            from: context
        )
        let missingCountPreview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: missingCount,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertEqual(missingCountPreview.items.single?.classification, .unknown)

        let timerContext = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":2,"timer":60},{"data":100,"lvl":10,"cnt":1}]}"##)
        let timerState = try observedState(reference: timerContext.reference, distribution: [10: 3])
        let timerEnded = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":3}]}"##,
            from: timerContext
        )
        let timerCoveragePreview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: timerContext.entry,
            decision: timerEnded,
            currentState: timerState,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertEqual(timerCoveragePreview.items.single?.classification, .unknown)
    }

    func testPartialSectionCoveragePoisonsSiblingKeys() throws {
        let cases: [(name: String, old: String, new: String)] = [
            (
                "level",
                ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1},{"data":101,"lvl":10,"cnt":1}]}"##,
                ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1},{"data":101,"cnt":1}]}"##
            ),
            (
                "count",
                ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1},{"data":101,"lvl":10,"cnt":1}]}"##,
                ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1},{"data":101,"lvl":10}]}"##
            ),
            (
                "timer",
                ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1},{"data":101,"lvl":10,"cnt":1}]}"##,
                ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1},{"data":101,"lvl":10,"cnt":1,"timer":60}]}"##
            )
        ]

        for testCase in cases {
            let context = try history(testCase.old)
            let state = try observedState(reference: context.reference, distribution: [10: 1])
            let next = try decision(testCase.new, from: context)
            let preview = try ManualTrackerReconciliationService.preview(
                villageID: villageID,
                previousEntry: context.entry,
                decision: next,
                currentState: state,
                appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
            )
            let item = try XCTUnwrap(preview.items.first { $0.itemKey == key }, testCase.name)

            XCTAssertEqual(item.classification, .unknown, testCase.name)
            XCTAssertFalse(item.coverageComplete, testCase.name)
            XCTAssertNil(item.observedDistribution, testCase.name)
        }
    }

    func testManualAheadDoesNotRollbackLocalEffectiveDistribution() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":9,"cnt":1}]}"##)
        let state = try observedState(reference: context.reference, distribution: [11: 1])
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##,
            from: context
        )
        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(plan.preview.items.single?.classification, .manualAhead)
        XCTAssertEqual(
            plan.state.core.effectiveState(for: key)?.effectiveCompletedDistribution,
            try ManualLevelDistribution(levelQuantities: [11: 1])
        )
    }

    func testNonMonotonicHistogramMovementIsConflict() throws {
        let context = try history(
            ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1},{"data":100,"lvl":12,"cnt":1}]}"##,
            sectionProofs: [
                "buildings": SnapshotHistoryTestCoverage.verified(expectedCount: 2)
            ]
        )
        let state = try observedState(reference: context.reference, distribution: [10: 1, 12: 1])
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":2}]}"##,
            from: context,
            sectionProofs: [
                "buildings": SnapshotHistoryTestCoverage.verified(expectedCount: 1)
            ]
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(preview.items.single?.classification, .conflict)
        XCTAssertTrue(preview.requiresExplicitDecision)
    }

    func testDeclaredUniqueLevelIncreaseStaysUnknownWithoutVerifiedSection() throws {
        let context = try history(
            ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":9,"cnt":1}]}"##,
            sectionProofs: [
                "buildings": .declared(source: "u.coc", version: "1", expectedCount: 1)
            ],
            injectVerifiedSectionProofs: false
        )
        let state = try observedState(reference: context.reference, distribution: [9: 1])
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##,
            from: context,
            sectionProofs: [
                "buildings": .declared(source: "u.coc", version: "1", expectedCount: 1)
            ],
            injectVerifiedSectionProofs: false
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(preview.items.single?.classification, .unknown)
    }

    func testNonMonotonicHistogramMovementWithDeclaredProofIsUnknown() throws {
        let context = try history(
            ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1},{"data":100,"lvl":12,"cnt":1}]}"##,
            sectionProofs: [
                "buildings": .declared(source: "u.coc", version: "1", expectedCount: 2)
            ]
        )
        let state = try observedState(reference: context.reference, distribution: [10: 1, 12: 1])
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":2}]}"##,
            from: context,
            sectionProofs: [
                "buildings": .declared(source: "u.coc", version: "1", expectedCount: 1)
            ]
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(preview.items.single?.classification, .unknown)
        XCTAssertTrue(preview.requiresExplicitDecision)
    }

    func testNonMonotonicHistogramMovementWithoutProofIsUnknown() throws {
        // Issue 164: without verified section proof a non-monotonic
        // histogram movement cannot be confirmed as a conflict; it must stay
        // unknown (still requiring an explicit decision) instead of claiming
        // the observed distribution contradicts the local state.
        let context = try history(
            ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1},{"data":100,"lvl":12,"cnt":1}]}"##,
            injectVerifiedSectionProofs: false
        )
        let state = try observedState(reference: context.reference, distribution: [10: 1, 12: 1])
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":2}]}"##,
            from: context,
            injectVerifiedSectionProofs: false
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(preview.items.single?.classification, .unknown)
        XCTAssertTrue(preview.requiresExplicitDecision)
    }

    func testLineageMismatchRequiresExplicitObservedRebase() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let state = try observedState(reference: context.reference, distribution: [10: 1])
        let next = try decision(
            ##"{"tag":"#P2","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1}]}"##,
            from: context
        )
        let safePlan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertEqual(safePlan.preview.items.single?.classification, .lineageMismatch)
        XCTAssertEqual(safePlan.state.core, state.core)

        let accepted = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .acceptObserved,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertEqual(accepted.state.baselineReference, accepted.preview.newReference)
        XCTAssertEqual(
            accepted.state.core.effectiveState(for: key)?.effectiveCompletedDistribution,
            try ManualLevelDistribution(levelQuantities: [11: 1])
        )
    }

    func testOldManualLineageCannotAutoMatchAfterHistoryAlreadySwitched() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let oldManualState = try observedState(
            reference: context.reference,
            distribution: [10: 1]
        )
        let firstP2Snapshot = try AccountSnapshotImporter.parse(
            ##"{"tag":"#P2","timestamp":1700000100,"buildings":[{"data":100,"lvl":11,"cnt":1}]}"##,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let firstP2 = try context.service.planImport(
            snapshot: firstP2Snapshot,
            villageID: villageID,
            currentTag: "#P1",
            hasCurrentSnapshot: true,
            envelope: context.envelope,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let secondP2Snapshot = try AccountSnapshotImporter.parse(
            ##"{"tag":"#P2","timestamp":1700000200,"buildings":[{"data":100,"lvl":12,"cnt":1}]}"##,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let secondP2 = try context.service.planImport(
            snapshot: secondP2Snapshot,
            villageID: villageID,
            currentTag: "#P2",
            hasCurrentSnapshot: true,
            envelope: firstP2.envelope,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: firstP2.entry,
            decision: secondP2,
            currentState: oldManualState,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertFalse(preview.lineageComparable)
        XCTAssertEqual(preview.items.single?.classification, .lineageMismatch)
    }

    func testDuplicateHistogramUsesAggregateDistribution() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":2},{"data":100,"lvl":11,"cnt":1}]}"##)
        let state = try observedState(reference: context.reference, distribution: [10: 2, 11: 1])
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1},{"data":100,"lvl":11,"cnt":2}]}"##,
            from: context
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(preview.items.count, 1)
        XCTAssertEqual(preview.items.single?.classification, .observedAhead)
        XCTAssertEqual(
            preview.items.single?.observedDistribution,
            try ManualLevelDistribution(levelQuantities: [10: 1, 11: 2])
        )
    }

    func testRealExportSectionPartialCoverageBlocksAutomaticReconciliation() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(forResource: "anonymized_account_snapshot", withExtension: "json")
        )
        let raw = try String(contentsOf: fixtureURL, encoding: .utf8)
        let context = try history(raw)
        let nextRaw = raw.replacingOccurrences(of: "1785736333", with: "1785736400")
        let next = try decision(
            nextRaw,
            from: context,
            currentTag: context.snapshot.tag ?? ""
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: ManualTrackerVillageState.empty(
                villageID: villageID,
                now: Date(timeIntervalSince1970: 1_700_000_010)
            ),
            appliedAt: Date(timeIntervalSince1970: 1_785_736_400)
        )
        let buildingKey = TrackerItemKey.root(
            base: .home,
            rawSection: "buildings",
            dataID: 1_000_000
        )
        let building = try XCTUnwrap(preview.items.first { $0.itemKey == buildingKey })

        // The content is a duplicate, but its section-level partial coverage
        // still prevents treating the parsed distribution as authoritative.
        XCTAssertEqual(building.classification, .duplicate)
        XCTAssertFalse(building.coverageComplete)
        XCTAssertNil(building.observedDistribution)
    }

    func testStalePreviewIsRejectedBeforeStateMutation() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let state = try observedState(reference: context.reference, distribution: [10: 1])
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1}]}"##,
            from: context
        )
        let preview = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: next,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let changedState = try ManualTrackerVillageState(
            villageID: villageID,
            core: state.core,
            stateUpdatedAt: Date(timeIntervalSince1970: 1_700_000_201)
        )

        XCTAssertThrowsError(try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: changedState,
            expectedPreview: preview,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )) { error in
            XCTAssertEqual(error as? ManualReconciliationError, .stalePreview)
        }
    }

    func testCandidateChangeInvalidatesPreview() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let state = try observedState(reference: context.reference, distribution: [10: 1])
        let candidateA = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1}]}"##,
            from: context
        )
        let candidateB = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":12,"cnt":1}]}"##,
            from: context
        )
        let previewA = try ManualTrackerReconciliationService.preview(
            villageID: villageID,
            previousEntry: context.entry,
            decision: candidateA,
            currentState: state,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertThrowsError(try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: candidateB,
            currentState: state,
            expectedPreview: previewA,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )) { error in
            XCTAssertEqual(error as? ManualReconciliationError, .stalePreview)
        }
    }

    func testWrongVillageIDIsRejected() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1}]}"##,
            from: context
        )

        XCTAssertThrowsError(try ManualTrackerReconciliationService.preview(
            villageID: UUID(),
            previousEntry: context.entry,
            decision: next,
            currentState: try observedState(reference: context.reference, distribution: [10: 1]),
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )) { error in
            XCTAssertEqual(error as? ManualReconciliationError, .villageMismatch)
        }
    }

    // MARK: - Issue #183 queueAssignments 对账

    private func stateWithAssignment(
        reference: ManualBaselineReference,
        distribution: [Int: Int64],
        queueKind: LocalQueueKind = .builder
    ) throws -> ManualTrackerVillageState {
        var state = try observedState(reference: reference, distribution: distribution)
        state.queueAssignments = [
            try QueueAssignmentDecision(
                villageID: villageID,
                itemKey: key,
                baselineReference: reference,
                queueKind: queueKind,
                decidedAt: Date(timeIntervalSince1970: 1_700_000_010)
            ),
        ]
        return state
    }

    func testReconcileKeepsUserAssignedWithinSameLineage() throws {
        let raw = ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1,"timer":60}]}"##
        let context = try history(raw)
        let state = try stateWithAssignment(
            reference: context.reference, distribution: [10: 1]
        )
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1,"timer":60}]}"##,
            from: context
        )
        XCTAssertTrue(next.duplicate)

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(plan.state.queueAssignments.count, 1)
        XCTAssertEqual(plan.state.queueAssignments[0].status, .userAssigned)
        XCTAssertEqual(plan.state.queueAssignments[0].queueKind, .builder)
        XCTAssertEqual(
            plan.state.queueAssignments[0].baselineReference.lineageID,
            context.reference.lineageID
        )
    }

    func testReconcileDegradesCrossLineageAssignmentToUnknown() throws {
        let context = try history(##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##)
        let state = try stateWithAssignment(
            reference: context.reference, distribution: [10: 1]
        )
        let next = try decision(
            ##"{"tag":"#P2","timestamp":1700000200,"buildings":[{"data":100,"lvl":11,"cnt":1}]}"##,
            from: context,
            currentTag: "#P1"
        )

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .acceptObserved,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(plan.state.queueAssignments.count, 1,
            "对账不得删除旧 lineage 的映射，保留为历史证据")
        XCTAssertEqual(plan.state.queueAssignments[0].status, .unknown)
        XCTAssertEqual(plan.state.queueAssignments[0].queueKind, .builder)
    }

    func testReconcileDegradesTimerEndedAssignmentToObservedOnly() throws {
        let raw = ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1,"timer":60}]}"##
        let context = try history(raw)
        let state = try stateWithAssignment(
            reference: context.reference, distribution: [10: 1]
        )
        // 同 lineage、同分布，但 timer 消失。
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1}]}"##,
            from: context
        )

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(plan.state.queueAssignments.count, 1,
            "timer 消失不得删除用户映射，等待用户明确解除")
        XCTAssertEqual(plan.state.queueAssignments[0].status, .observedOnly)
    }

    func testReconcileNeverCreatesAssignmentsAutomatically() throws {
        let raw = ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1,"timer":60}]}"##
        let context = try history(raw)
        let state = try observedState(reference: context.reference, distribution: [10: 1])
        XCTAssertTrue(state.queueAssignments.isEmpty)
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1,"timer":60}]}"##,
            from: context
        )

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertTrue(plan.state.queueAssignments.isEmpty,
            "导入计时从未被自动分配到任何队列")
    }

    func testReconcileDegradesAssignmentWhenCoverageIncomplete() throws {
        // Issue #183 review P1：同 section 另一条目缺 lvl → 该 section 覆盖
        // 不完整，即使 timer 仍存在也不能保持 userAssigned 占用容量。
        let raw = ##"{"tag":"#P1","timestamp":1700000000,"buildings":[{"data":100,"lvl":10,"cnt":1,"timer":60},{"data":101,"lvl":10,"cnt":1}]}"##
        let context = try history(raw)
        let state = try stateWithAssignment(
            reference: context.reference, distribution: [10: 1]
        )
        let next = try decision(
            ##"{"tag":"#P1","timestamp":1700000200,"buildings":[{"data":100,"lvl":10,"cnt":1,"timer":60},{"data":101,"cnt":1}]}"##,
            from: context
        )

        let plan = try ManualTrackerReconciliationService.reconcile(
            villageID: villageID,
            previousEntry: context.entry,
            historyDecision: next,
            currentState: state,
            decision: .applyNonConflicting,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(plan.state.queueAssignments.count, 1,
            "覆盖不完整不得删除映射，保留记录")
        XCTAssertEqual(plan.state.queueAssignments[0].status, .observedOnly,
            "覆盖不完整时 timer 存在也不能保持 userAssigned")
    }
}

private final class MemoryHistoryStore: SnapshotHistoryStore, @unchecked Sendable {
    var transactionJournalURL: URL? { nil }
    private var data: Data?

    func load() throws -> SnapshotHistoryEnvelope? {
        guard let data else { return nil }
        return try JSONDecoder().decode(SnapshotHistoryEnvelope.self, from: data).validated()
    }

    func save(_ envelope: SnapshotHistoryEnvelope) throws { data = try envelope.encodedData() }
    func readRawData() throws -> Data? { data }
    func writeRawData(_ data: Data) throws { self.data = data }
    func restoreRawData(_ data: Data?) throws { self.data = data }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
