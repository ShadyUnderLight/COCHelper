import XCTest
@testable import COCHelperCore

final class ManualUpgradeCoreTests: XCTestCase {
    private let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 100)
    private let baseline = ManualBaselineReference(
        revision: "snapshot-1",
        fingerprint: "sha256:baseline",
        lineageID: "village-1"
    )
    private let provenance = ManualCatalogProvenance(
        gameVersion: "18.400.13",
        buildTag: "catalog-test",
        sourceFingerprint: "sha256:catalog",
        manifestSchemaVersion: 1
    )

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func distribution(_ values: [(Int, Int64)]) throws -> ManualLevelDistribution {
        var entries: [ManualLevelQuantity] = []
        for (level, quantity) in values {
            entries.append(try ManualLevelQuantity(level: level, quantity: quantity))
        }
        return try ManualLevelDistribution(levels: entries)
    }

    private func state(
        imported: ManualLevelDistribution? = nil,
        manual: ManualLevelDistribution = .empty,
        status: ManualItemStatus
    ) throws -> ManualItemState {
        let observation = try imported.map {
            try ManualImportedObservation(
                reference: baseline,
                levelDistribution: $0,
                sourceTimestamp: date(900)
            )
        }
        return try ManualItemState(
            itemKey: key,
            baselineReference: baseline,
            importedObservation: observation,
            manualCompletedDistribution: manual,
            status: status
        )
    }

    private func core(
        imported: ManualLevelDistribution? = nil,
        manual: ManualLevelDistribution = .empty,
        status: ManualItemStatus
    ) throws -> ManualUpgradeCore {
        try ManualUpgradeCore(itemStates: [
            state(imported: imported, manual: manual, status: status)
        ])
    }

    private func cost(
        resource: String = "Gold",
        amount: Int64? = 500,
        rawResource: String? = "Gold",
        rawAmount: String? = nil,
        parseFailed: Bool = false
    ) -> CatalogUpgradeCost {
        CatalogUpgradeCost(
            resource: resource,
            amount: amount,
            rawResource: rawResource,
            rawAmount: rawAmount,
            parseFailed: parseFailed
        )
    }

    func testTrackerItemKeyAdapterSurvivesArrayReordering() throws {
        let typeA = AccountItem(id: "buildings[0].types[0]", section: "buildings", dataID: 201)
        let typeB = AccountItem(id: "buildings[0].types[1]", section: "buildings", dataID: 202)
        let module = AccountItem(id: "buildings[0].modules[0]", section: "buildings", dataID: 301)
        let root = AccountItem(
            id: "buildings[0]",
            section: "buildings",
            dataID: 100,
            types: [typeA, typeB],
            modules: [module]
        )
        let reorderedRoot = AccountItem(
            id: "buildings[9]",
            section: "buildings",
            dataID: 100,
            types: [typeB, typeA],
            modules: [module]
        )
        let makeSnapshot: (AccountItem) -> AccountSnapshot = { item in
            AccountSnapshot(
                tag: "#TEST",
                capturedAt: nil,
                importedAt: self.date(900),
                ageSeconds: nil,
                originalText: "{}",
                objectSections: ["buildings": [item]],
                numericSections: [:],
                boosts: [:],
                unknownTopLevelKeys: [],
                diagnostics: []
            )
        }

        let first = TrackerItemKeyAdapter.keys(in: makeSnapshot(root), base: .home)
        let second = TrackerItemKeyAdapter.keys(in: makeSnapshot(reorderedRoot), base: .home)

        XCTAssertEqual(Set(first), Set(second))
        XCTAssertEqual(first.count, 4)
        XCTAssertTrue(first.allSatisfy(\.isStructurallyValid))
        XCTAssertTrue(first.allSatisfy { !$0.stableID.contains("[") })
        XCTAssertNotEqual(
            TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 100),
            TrackerItemKey.root(base: .builder, rawSection: "buildings2", dataID: 100)
        )

        let homeRoot = TrackerRootIdentity(base: .home, rawSection: "buildings", dataID: 100)
        let otherRoot = TrackerRootIdentity(base: .home, rawSection: "buildings", dataID: 101)
        let nestedHome = TrackerItemKey.nested(
            base: .home,
            rawSection: "buildings",
            dataID: 201,
            root: homeRoot,
            path: [TrackerNestedPathComponent(kind: .type, dataID: 201)]
        )
        let nestedOtherRoot = TrackerItemKey.nested(
            base: .home,
            rawSection: "buildings",
            dataID: 201,
            root: otherRoot,
            path: [TrackerNestedPathComponent(kind: .type, dataID: 201)]
        )
        XCTAssertNotEqual(nestedHome, nestedOtherRoot)
        XCTAssertNotEqual(
            nestedHome,
            TrackerItemKey.nested(
                base: .home,
                rawSection: "buildings",
                dataID: 201,
                root: homeRoot,
                path: [TrackerNestedPathComponent(kind: .module, dataID: 201)]
            )
        )
        XCTAssertNotEqual(
            TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 201),
            TrackerItemKey.root(base: .home, rawSection: "troops", dataID: 201)
        )
    }

    func testLevelDistributionIsSortedAndRejectsInvalidEntries() throws {
        let distribution = try distribution([(12, 99), (10, 1)])
        XCTAssertEqual(distribution.levels.map(\.level), [10, 12])
        XCTAssertEqual(distribution.totalQuantity, 100)
        XCTAssertEqual(try distribution.adding(level: 12, quantity: 1).quantity(at: 12), 100)
        XCTAssertEqual(try distribution.subtracting(level: 10, quantity: 1).totalQuantity, 99)

        XCTAssertThrowsError(try ManualLevelDistribution(levelQuantities: [10: 0])) { error in
            XCTAssertEqual(error as? ManualUpgradeError, .invalidQuantity)
        }
        let duplicate = try ManualLevelQuantity(level: 10, quantity: 1)
        XCTAssertThrowsError(try ManualLevelDistribution(levels: [duplicate, duplicate])) { error in
            XCTAssertEqual(error as? ManualUpgradeError, .invalidRecord)
        }
    }

    func testTimedUpgradeReservesSourceAndSettlesIdempotently() throws {
        var core = try core(
            imported: distribution([(12, 100)]),
            status: .observed
        )
        let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let started = try core.startUpgrade(
            itemKey: key,
            fromLevel: 12,
            targetLevel: 13,
            quantity: 1,
            startedAt: date(1_000),
            durationState: .timed(seconds: 10),
            frozenCosts: [cost()],
            catalogProvenance: provenance,
            baselineReference: baseline,
            recordID: recordID,
            now: date(1_000)
        )
        XCTAssertEqual(started.status, .active)

        let active = try XCTUnwrap(core.effectiveState(for: key))
        XCTAssertEqual(active.importedDistribution?.quantity(at: 12), 100)
        XCTAssertEqual(active.effectiveCompletedDistribution?.quantity(at: 12), 99)
        XCTAssertEqual(active.activeTargetDistribution.quantity(at: 13), 1)
        XCTAssertEqual(active.activeTargetLevel, 13)

        let restored = try JSONDecoder().decode(
            ManualUpgradeCore.self,
            from: JSONEncoder().encode(core)
        )
        XCTAssertEqual(restored, core)

        XCTAssertTrue(try core.settleDue(at: date(1_009)).isEmpty)
        XCTAssertEqual(core.activeRecords.count, 1)

        let settled = try core.settleDue(at: date(1_010))
        XCTAssertEqual(settled.map(\.recordID), [recordID])
        XCTAssertEqual(settled.first?.status, .completed)
        XCTAssertTrue(try core.settleDue(at: date(2_000)).isEmpty)
        XCTAssertEqual(core.completedHistory.count, 1)

        let completed = try XCTUnwrap(core.effectiveState(for: key))
        XCTAssertTrue(completed.activeTargetDistribution.isEmpty)
        XCTAssertEqual(completed.effectiveCompletedDistribution?.quantity(at: 12), 99)
        XCTAssertEqual(completed.effectiveCompletedDistribution?.quantity(at: 13), 1)
    }

    func testInstantUpgradeCompletesImmediatelyAndRoundTripsFrozenData() throws {
        var core = try core(
            manual: distribution([(1, 1)]),
            status: .manualCompleted
        )
        let frozenCost = cost(
            resource: "DarkElixir",
            amount: nil,
            rawResource: "Dark Elixir",
            rawAmount: "not-a-number",
            parseFailed: true
        )
        let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let record = try core.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: date(1_000),
            durationState: .instant,
            frozenCosts: [frozenCost],
            catalogProvenance: provenance,
            baselineReference: baseline,
            recordID: recordID,
            now: date(1_000)
        )
        XCTAssertEqual(record.status, .completed)
        XCTAssertTrue(core.activeRecords.isEmpty)
        XCTAssertEqual(record.frozenCosts, [frozenCost])
        XCTAssertEqual(record.catalogProvenance, provenance)
        XCTAssertEqual(core.effectiveState(for: key)?.effectiveCompletedDistribution?.quantity(at: 2), 1)
        XCTAssertThrowsError(try core.cancelUpgrade(recordID: recordID)) { error in
            XCTAssertEqual(error as? ManualUpgradeError, .cannotCancelCompleted(recordID))
        }

        let laterCatalog = ManualCatalogProvenance(gameVersion: "19.0")
        XCTAssertNotEqual(laterCatalog, record.catalogProvenance)
        XCTAssertEqual(core.completedHistory.first?.catalogProvenance, provenance)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let roundTripped = try decoder.decode(ManualUpgradeCore.self, from: encoder.encode(core))
        XCTAssertEqual(roundTripped, core)
    }

    func testUnavailableDurationsCannotStartAndDoNotMutateState() throws {
        let unavailable: [CatalogDurationState?] = [
            nil,
            .initialLevel,
            .notApplicable,
            .sourceMissing,
            .parseFailed,
            .unknownReason("future-reason")
        ]

        for (offset, duration) in unavailable.enumerated() {
            var core = try core(manual: distribution([(10, 1)]), status: .manualCompleted)
            let before = core
            XCTAssertThrowsError(try core.startUpgrade(
                itemKey: key,
                fromLevel: 10,
                targetLevel: 11,
                quantity: 1,
                startedAt: date(1_000),
                durationState: duration,
                frozenCosts: nil,
                catalogProvenance: provenance,
                baselineReference: baseline,
                recordID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", offset + 10))!,
                now: date(1_000)
            ))
            XCTAssertEqual(core, before)
        }

        var zero = try core(manual: distribution([(10, 1)]), status: .manualCompleted)
        XCTAssertThrowsError(try zero.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: date(1_000),
            durationState: .timed(seconds: 0),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: date(1_000)
        )) { error in
            XCTAssertEqual(error as? ManualUpgradeError, .invalidDuration)
        }

        var future = try core(manual: distribution([(10, 1)]), status: .manualCompleted)
        let beforeFuture = future
        XCTAssertThrowsError(try future.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: date(1_001),
            durationState: .instant,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: date(1_000)
        )) { error in
            XCTAssertEqual(error as? ManualUpgradeError, .futureStart)
        }
        XCTAssertEqual(future, beforeFuture)

        XCTAssertThrowsError(try future.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 2,
            startedAt: date(1_000),
            durationState: .instant,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: date(1_000)
        )) { error in
            XCTAssertEqual(
                error as? ManualUpgradeError,
                .insufficientQuantity(level: 10, requested: 2, available: 1)
            )
        }
        XCTAssertEqual(future, beforeFuture)
    }

    func testCancelRestoresSourceAndAdjustSettlesThroughSamePath() throws {
        var core = try core(manual: distribution([(10, 2)]), status: .manualCompleted)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: date(1_000),
            durationState: .timed(seconds: 10),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            recordID: firstID,
            now: date(1_000)
        )

        let cancelled = try core.cancelUpgrade(recordID: firstID)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(core.effectiveState(for: key)?.effectiveCompletedDistribution?.quantity(at: 10), 2)
        XCTAssertTrue(core.activeRecords.isEmpty)
        XCTAssertThrowsError(try core.cancelUpgrade(recordID: firstID)) { error in
            XCTAssertEqual(error as? ManualUpgradeError, .recordNotActive(firstID))
        }

        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: date(1_000),
            durationState: .timed(seconds: 10),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            recordID: secondID,
            now: date(1_000)
        )
        let adjusted = try core.adjustStartTime(
            recordID: secondID,
            startedAt: date(990),
            now: date(1_000)
        )
        XCTAssertEqual(adjusted.status, .completed)
        XCTAssertEqual(adjusted.expectedEndAt, date(1_000))
        XCTAssertEqual(core.effectiveState(for: key)?.effectiveCompletedDistribution?.quantity(at: 11), 1)
    }

    func testDueRecordsUseStableEndTimeAndRecordIDOrdering() throws {
        var core = try core(manual: distribution([(10, 2)]), status: .manualCompleted)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        for id in [secondID, firstID] {
            _ = try core.startUpgrade(
                itemKey: key,
                fromLevel: 10,
                targetLevel: 11,
                quantity: 1,
                startedAt: date(1_000),
                durationState: .timed(seconds: 10),
                frozenCosts: nil,
                catalogProvenance: provenance,
                baselineReference: baseline,
                recordID: id,
                now: date(1_000)
            )
        }

        let settled = try core.settleDue(at: date(1_010))
        XCTAssertEqual(settled.map(\.recordID), [firstID, secondID])
        XCTAssertEqual(core.effectiveState(for: key)?.effectiveCompletedDistribution?.quantity(at: 11), 2)
    }

    func testUnknownConflictAndBaselineMismatchFailClosed() throws {
        var unknown = try core(status: .unknown)
        XCTAssertThrowsError(try unknown.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: date(1_000),
            durationState: .instant,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: date(1_000)
        )) { error in
            XCTAssertEqual(error as? ManualUpgradeError, .unavailableItemState(key))
        }

        var conflict = try core(status: .conflict)
        XCTAssertThrowsError(try conflict.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: date(1_000),
            durationState: .instant,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: date(1_000)
        )) { error in
            XCTAssertEqual(error as? ManualUpgradeError, .conflictingItemState(key))
        }

        var mismatch = try core(manual: distribution([(1, 1)]), status: .manualCompleted)
        let otherBaseline = ManualBaselineReference(revision: "snapshot-2")
        XCTAssertThrowsError(try mismatch.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: date(1_000),
            durationState: .instant,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: otherBaseline,
            now: date(1_000)
        )) { error in
            XCTAssertEqual(error as? ManualUpgradeError, .baselineMismatch(key))
        }
    }

    func testMalformedTrackerKeyCannotBeDecoded() throws {
        let malformed = TrackerItemKey(
            base: .home,
            rawSection: "buildings",
            dataID: 100,
            nestedKind: .type,
            nestedRootIdentity: nil,
            nestedPath: []
        )
        XCTAssertFalse(malformed.isStructurallyValid)
        let data = try JSONEncoder().encode(malformed)
        XCTAssertThrowsError(try JSONDecoder().decode(TrackerItemKey.self, from: data))

        var validCore = try core(manual: distribution([(10, 1)]), status: .manualCompleted)
        _ = try validCore.startUpgrade(
            itemKey: key,
            fromLevel: 10,
            targetLevel: 11,
            quantity: 1,
            startedAt: date(1_000),
            durationState: .timed(seconds: 10),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: date(1_000)
        )
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(validCore)
            ) as? [String: Any]
        )
        var records = try XCTUnwrap(payload["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "expectedEndAt")
        payload["records"] = records
        let partial = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertThrowsError(try JSONDecoder().decode(ManualUpgradeCore.self, from: partial))
    }

    func testEmptyCoreIsValid() throws {
        let core = try ManualUpgradeCore()
        XCTAssertTrue(core.itemStates.isEmpty)
        XCTAssertTrue(core.records.isEmpty)
    }
}
