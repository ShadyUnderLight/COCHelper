import Foundation
import XCTest
@testable import COCHelperCore

final class SnapshotHistoryProjectionTests: XCTestCase {
    private let villageA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let villageB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let lineageA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let lineageB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    func testNoSnapshotAndCurrentWithoutHistoryRemainDistinct() {
        let envelope = SnapshotHistoryEnvelope(
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: Date(timeIntervalSince1970: 1))
        )

        let noSnapshot = projection(envelope: envelope, hasCurrentSnapshot: false)
        XCTAssertEqual(noSnapshot.availability, .noSnapshot)
        XCTAssertEqual(noSnapshot.totalSnapshotCount, 0)
        XCTAssertEqual(noSnapshot.statistics.today.heroLevelGrowth.state, .insufficientData)

        let empty = projection(envelope: envelope, hasCurrentSnapshot: true)
        XCTAssertEqual(empty.availability, .empty)
        XCTAssertEqual(empty.totalSnapshotCount, 0)
    }

    func testBaselineAndDuplicateMetadataDoNotInventTimelineRows() {
        let baseline = makeEntry(
            id: "10000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: [hero(level: 1)]
        )
        let checkedAt = Date(timeIntervalSince1970: 300)
        let envelope = makeEnvelope(
            entries: [baseline],
            activeEntries: [(villageA, baseline)],
            duplicateMetadata: [
                baseline.snapshotID.uuidString: SnapshotHistoryDuplicateMetadata(
                    lastSeenAt: checkedAt,
                    lastSourceTimestamp: nil,
                    duplicateImportCount: 3
                )
            ]
        )

        let projection = projection(envelope: envelope)
        XCTAssertEqual(projection.availability, .baselineOnly)
        XCTAssertEqual(projection.totalSnapshotCount, 1)
        XCTAssertEqual(projection.timeline.count, 1)
        XCTAssertTrue(projection.timeline[0].isBaseline)
        XCTAssertEqual(projection.timeline[0].duplicateImportCount, 3)
        XCTAssertEqual(projection.latestCheckedAt, checkedAt)
        XCTAssertEqual(projection.latestSummary, "初始基线（不计变化）")
        XCTAssertFalse(projection.timeline[0].isExpandedByDefault)
    }

    func testProjectionUsesFrozenBindingsFiltersCategoriesAndCalculatesStatistics() {
        let baseline = makeEntry(
            id: "20000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: [hero(level: 1), wall(level: 12, count: 1000)]
        )
        let changed = makeEntry(
            id: "10000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 200,
            items: [hero(level: 2), wall(level: 12, count: 900), wall(level: 13, count: 100)]
        )
        let envelope = makeEnvelope(entries: [baseline, changed], activeEntries: [(villageA, changed)])

        let all = projection(envelope: envelope, referenceDate: 200)
        XCTAssertEqual(all.availability, .available)
        XCTAssertEqual(all.timeline.map(\.snapshotID), [changed.snapshotID, baseline.snapshotID])
        XCTAssertEqual(all.timeline[0].changes.count, 2)
        XCTAssertEqual(all.timeline[0].changes.first(where: { $0.category == "heroes" })?.displayName, "历史英雄名")
        XCTAssertEqual(all.statistics.today.heroLevelGrowth.value, 1)
        XCTAssertEqual(all.statistics.today.wallLevelGrowth.value, 100)
        XCTAssertEqual(all.statistics.today.aggregateInferredWallLevelGrowth.value, 100)
        XCTAssertEqual(all.statistics.today.confirmedWallLevelGrowth.value, 0)
        XCTAssertTrue(all.latestSummary?.contains("英雄 +1") == true)
        XCTAssertTrue(all.latestSummary?.contains("推断：城墙 +100") == true)

        let walls = all.applying(category: .walls)
        XCTAssertEqual(walls.selectedCategory, .walls)
        XCTAssertEqual(walls.timeline.count, 1)
        XCTAssertEqual(walls.timeline[0].changes.count, 1)
        XCTAssertEqual(walls.timeline[0].visibleChangeCount, 100)
        XCTAssertEqual(walls.timeline[0].changes[0].displayCategory, "walls")

        let pets = all.applying(category: .pets)
        XCTAssertTrue(pets.filterIsEmpty)
        XCTAssertEqual(pets.timeline, [])
        XCTAssertEqual(pets.applying(category: .all).timeline.count, 2)
    }

    func testTimerCompletionAggregateInferredProjectsToUIAndStatistics() throws {
        // Issue #175 验收：aggregate/inferred 的 timer 完成语义一路投影到
        // UI（change 行、类别）和统计（aggregateInferredEventCount）。
        let identity = SnapshotItemIdentity(base: .home, rawSection: "buildings", dataID: 1)
        let binding = SnapshotDisplayBinding(displayName: "加农炮", category: "buildings")
        let active = SnapshotObservationItem(
            identity: identity,
            level: 14,
            count: 2,
            rawTimerEvidence: ["timer": .number("90")],
            display: binding
        )
        let finished = SnapshotObservationItem(
            identity: identity,
            level: 15,
            count: 2,
            rawTimerEvidence: [:],
            display: binding
        )
        let baseline = makeEntry(
            id: "B0000000-0000-0000-0000-000000000001",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: [active]
        )
        let changed = makeEntry(
            id: "B0000000-0000-0000-0000-000000000002",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 200,
            items: [finished]
        )
        let envelope = makeEnvelope(entries: [baseline, changed], activeEntries: [(villageA, changed)])

        let all = projection(envelope: envelope, referenceDate: 200)
        XCTAssertEqual(all.availability, .available)
        let completion = try XCTUnwrap(all.timeline[0].changes.first { $0.changeKind == .upgradeCompleted })
        XCTAssertEqual(completion.evidence, .aggregateInferred)
        XCTAssertEqual(completion.category, "buildings")
        // upgradeCompleted + levelIncreased migration 两条 aggregateInferred 事件
        XCTAssertEqual(all.statistics.today.aggregateInferredEventCount.value, 2)

        let buildings = all.applying(category: .buildings)
        XCTAssertTrue(buildings.timeline[0].changes.contains { $0.changeKind == .upgradeCompleted })
    }

    func testWholeGroupAdditionAndRemovalKeepSingleSidedQuantity() throws {
        let baseline = makeEntry(
            id: "B0000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: []
        )
        let appeared = makeEntry(
            id: "B1000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 200,
            items: [wall(level: 12, count: 100)]
        )
        let disappeared = makeEntry(
            id: "B2000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 300,
            items: []
        )
        let envelope = makeEnvelope(
            entries: [baseline, appeared, disappeared],
            activeEntries: [(villageA, disappeared)]
        )

        let result = projection(envelope: envelope, referenceDate: 300)
        let removalRow = try XCTUnwrap(result.timeline.first { $0.snapshotID == disappeared.snapshotID })
        XCTAssertEqual(removalRow.changes.count, 1)
        let removal = try XCTUnwrap(removalRow.changes.first)
        XCTAssertEqual(removal.changeKind, .noLongerObserved)
        XCTAssertEqual(removal.oldQuantity, 100)
        XCTAssertNil(removal.newQuantity)
        XCTAssertEqual(removal.snapshotHistoryImpact, 100)
        XCTAssertEqual(removal.snapshotHistoryQuantityText, "×100")
        XCTAssertEqual(removalRow.visibleChangeCount, 100)
        XCTAssertEqual(removalRow.summary, "城墙 +100")

        let additionRow = try XCTUnwrap(result.timeline.first { $0.snapshotID == appeared.snapshotID })
        XCTAssertEqual(additionRow.changes.count, 1)
        let addition = try XCTUnwrap(additionRow.changes.first)
        XCTAssertEqual(addition.changeKind, .newlyObserved)
        XCTAssertNil(addition.oldQuantity)
        XCTAssertEqual(addition.newQuantity, 100)
        XCTAssertEqual(addition.snapshotHistoryImpact, 100)
        XCTAssertEqual(addition.snapshotHistoryQuantityText, "×100")
        XCTAssertEqual(additionRow.visibleChangeCount, 100)
        XCTAssertEqual(additionRow.summary, "城墙 +100")
    }

    func testUnknownChangeDoesNotPromoteSingleSidedQuantityToDelta() {
        let change = SnapshotChange(
            identity: SnapshotItemIdentity(base: .home, rawSection: "buildings", dataID: 8),
            displayName: "历史城墙名",
            category: "buildings",
            displayCategory: "walls",
            newQuantity: 100,
            changeKind: .unknown,
            evidence: .unknown,
            coverage: SnapshotDiffCoverage(state: .insufficient, reasons: ["测试覆盖不足"])
        )

        XCTAssertEqual(change.snapshotHistoryImpact, 1)
        XCTAssertNil(change.snapshotHistoryQuantityText)
        XCTAssertTrue(change.snapshotHistoryIsUncertain)
    }

    func testInterleavedVillagesStillFormAdjacentDiffWithinActiveLineage() {
        let firstA = makeEntry(
            id: "30000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: [hero(level: 1)]
        )
        let firstB = makeEntry(
            id: "40000000-0000-0000-0000-000000000000",
            villageID: villageB,
            lineageID: lineageB,
            appliedAt: 150,
            isBaseline: true,
            items: [hero(level: 20)]
        )
        let secondA = makeEntry(
            id: "50000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 200,
            items: [hero(level: 2)]
        )
        let envelope = makeEnvelope(
            entries: [firstA, firstB, secondA],
            activeEntries: [(villageA, secondA), (villageB, firstB)]
        )

        let projectionA = projection(envelope: envelope, referenceDate: 200)
        XCTAssertEqual(projectionA.totalSnapshotCount, 2)
        XCTAssertEqual(projectionA.timeline[0].changes.count, 1)
        XCTAssertEqual(projectionA.timeline[0].changes.first?.levelDelta, 1)
        XCTAssertEqual(projectionA.statistics.today.heroLevelGrowth.value, 1)

        let projectionB = SnapshotHistoryProjection.project(
            envelope: envelope,
            villageID: villageB,
            hasCurrentSnapshot: true,
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: timeZone
        )
        XCTAssertEqual(projectionB.availability, .baselineOnly)
        XCTAssertEqual(projectionB.totalSnapshotCount, 1)
        XCTAssertEqual(projectionB.timeline[0].snapshotID, firstB.snapshotID)
    }

    func testTimelineUsesSnapshotIDAsStableTieBreaker() {
        let baseline = makeEntry(
            id: "30000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: [hero(level: 1)]
        )
        let firstAtSameTime = makeEntry(
            id: "20000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 200,
            items: [hero(level: 2)]
        )
        let secondAtSameTime = makeEntry(
            id: "10000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 200,
            items: [hero(level: 3)]
        )
        let envelope = makeEnvelope(
            entries: [baseline, firstAtSameTime, secondAtSameTime],
            activeEntries: [(villageA, secondAtSameTime)]
        )

        XCTAssertEqual(
            projection(envelope: envelope).timeline.map(\.snapshotID),
            [secondAtSameTime.snapshotID, firstAtSameTime.snapshotID, baseline.snapshotID]
        )
    }

    func testProjectionShowsOnlyActiveLineageAfterTagChange() {
        let oldBaseline = makeEntry(
            id: "80000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: [hero(level: 1)]
        )
        let newBaseline = makeEntry(
            id: "90000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageB,
            appliedAt: 200,
            isBaseline: true,
            items: [hero(level: 50)]
        )
        let envelope = makeEnvelope(
            entries: [oldBaseline, newBaseline],
            activeEntries: [(villageA, newBaseline)]
        )

        let result = projection(envelope: envelope)
        XCTAssertEqual(result.availability, .baselineOnly)
        XCTAssertEqual(result.activeLineageID, lineageB)
        XCTAssertEqual(result.totalSnapshotCount, 1)
        XCTAssertEqual(result.timeline.map(\.snapshotID), [newBaseline.snapshotID])
        XCTAssertEqual(result.latestSummary, "初始基线（不计变化）")
    }

    func testComparableNoChangeIsZeroInsteadOfInsufficient() {
        let baseline = makeEntry(
            id: "A0000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: [hero(level: 1)]
        )
        let unchanged = makeEntry(
            id: "A1000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 200,
            items: [hero(level: 1)]
        )
        let envelope = makeEnvelope(entries: [baseline, unchanged], activeEntries: [(villageA, unchanged)])

        let result = projection(envelope: envelope, referenceDate: 200)
        XCTAssertEqual(result.availability, .available)
        XCTAssertEqual(result.timeline[0].summary, "没有可确认变化")
        XCTAssertEqual(result.statistics.today.heroLevelGrowth.state, .available)
        XCTAssertEqual(result.statistics.today.heroLevelGrowth.value, 0)
    }

    func testUnknownFilterKeepsCoverageDiagnosticsWithoutClaimingDeletion() {
        let baseline = makeEntry(
            id: "60000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: [hero(level: 1)]
        )
        let incomplete = makeEntry(
            id: "70000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 200,
            items: [],
            levelCoverage: .partial
        )
        let envelope = makeEnvelope(entries: [baseline, incomplete], activeEntries: [(villageA, incomplete)])

        let projection = projection(envelope: envelope, category: .unknown, referenceDate: 200)
        XCTAssertEqual(projection.availability, .insufficient("相邻快照覆盖不足，无法确认完整变化。"))
        XCTAssertFalse(projection.filterIsEmpty)
        XCTAssertEqual(projection.timeline.count, 1)
        XCTAssertTrue(projection.timeline[0].changes.allSatisfy { $0.changeKind == .unknown })
        XCTAssertFalse(projection.timeline[0].diagnostics.isEmpty)
        XCTAssertFalse(projection.timeline[0].changes.contains { $0.changeKind == .noLongerObserved })
        XCTAssertEqual(projection.statistics.today.heroLevelGrowth.state, .insufficientData)
    }

    func testLatestCoverageFailureDegradesHeaderAndUsesTentativeSummary() {
        let baseline = makeEntry(
            id: "C0000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 100,
            isBaseline: true,
            items: [hero(level: 1)]
        )
        let comparable = makeEntry(
            id: "C1000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 200,
            items: [hero(level: 2)]
        )
        let incomplete = makeEntry(
            id: "C2000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 300,
            items: [],
            levelCoverage: .partial
        )
        let envelope = makeEnvelope(
            entries: [baseline, comparable, incomplete],
            activeEntries: [(villageA, incomplete)]
        )

        let result = projection(envelope: envelope, referenceDate: 300)
        XCTAssertEqual(result.availability, .insufficient("最新相邻快照覆盖不足，部分变化仍待确认。"))
        XCTAssertEqual(result.timeline[0].comparisonState, .insufficientCoverage)
        XCTAssertTrue(result.timeline[0].containsUncertainChanges)
        XCTAssertEqual(result.latestSummary, "待确认：英雄 1 项")
        XCTAssertFalse(result.latestSummary?.contains("英雄 +1") == true)
    }

    func testCoverageTrustStateReflectsLatestEntryRuntimeTrust() {
        let trustedEntry = makeEntry(
            id: "D1000000-0000-0000-0000-000000000000",
            villageID: villageA,
            lineageID: lineageA,
            appliedAt: 400,
            items: [hero(level: 2)]
        )
        let envelope = makeEnvelope(
            entries: [trustedEntry],
            activeEntries: [(villageA, trustedEntry)]
        )
        XCTAssertEqual(projection(envelope: envelope, referenceDate: 400).coverageTrustState, .verified)

        let pendingHeroes = trustedEntry.coverage.sections.map { section in
            guard section.rawSection == "heroes" else { return section }
            return SnapshotSectionCoverage(
                base: section.base,
                rawSection: section.rawSection,
                presence: section.presence,
                completeness: section.completeness,
                proof: section.proof,
                observedCount: section.observedCount,
                runtimeTrust: .pending
            )
        }
        let pendingEntry = SnapshotHistoryEntry(
            snapshotID: trustedEntry.snapshotID,
            villageID: trustedEntry.villageID,
            lineageID: trustedEntry.lineageID,
            normalizedPlayerTag: trustedEntry.normalizedPlayerTag,
            appliedAt: trustedEntry.appliedAt,
            sourceTimestamp: trustedEntry.sourceTimestamp,
            parserVersion: trustedEntry.parserVersion,
            canonicalFingerprint: trustedEntry.canonicalFingerprint,
            rawJSON: trustedEntry.rawJSON,
            observation: trustedEntry.observation,
            coverage: SnapshotObservationCoverage(
                fields: trustedEntry.coverage.fields,
                sections: pendingHeroes,
                diagnostics: trustedEntry.coverage.diagnostics
            ),
            isBaseline: trustedEntry.isBaseline,
            baselineReason: trustedEntry.baselineReason
        )
        let pendingEnvelope = makeEnvelope(
            entries: [pendingEntry],
            activeEntries: [(villageA, pendingEntry)]
        )
        XCTAssertEqual(
            projection(envelope: pendingEnvelope, referenceDate: 400).coverageTrustState,
            .pendingRevalidation
        )
    }

    func testUnavailableProjectionPreservesTypedFailure() {
        let projection = SnapshotHistoryProjection.unavailable(
            villageID: villageA,
            hasCurrentSnapshot: true,
            availability: .corrupt("历史文件损坏：测试"),
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: timeZone
        )
        XCTAssertEqual(projection.availability, .corrupt("历史文件损坏：测试"))
        XCTAssertEqual(projection.timeline, [])
        XCTAssertEqual(projection.statistics.today.wallLevelGrowth.state, .insufficientData)
        XCTAssertEqual(projection.coverageTrustState, .insufficientCoverage)
    }

    private func projection(
        envelope: SnapshotHistoryEnvelope,
        hasCurrentSnapshot: Bool = true,
        category: SnapshotHistoryCategory = .all,
        referenceDate: TimeInterval = 300
    ) -> SnapshotHistoryProjection {
        SnapshotHistoryProjection.project(
            envelope: envelope,
            villageID: villageA,
            hasCurrentSnapshot: hasCurrentSnapshot,
            selectedCategory: category,
            referenceDate: Date(timeIntervalSince1970: referenceDate),
            calendar: Calendar(identifier: .gregorian),
            timeZone: timeZone
        )
    }

    private func makeEnvelope(
        entries: [SnapshotHistoryEntry],
        activeEntries: [(UUID, SnapshotHistoryEntry)],
        duplicateMetadata: [String: SnapshotHistoryDuplicateMetadata] = [:]
    ) -> SnapshotHistoryEnvelope {
        SnapshotHistoryEnvelope(
            entries: entries,
            lineages: activeEntries.map { villageID, entry in
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: entry.lineageID,
                    normalizedPlayerTag: entry.normalizedPlayerTag,
                    lastEntryID: entry.snapshotID,
                    lastFingerprint: entry.canonicalFingerprint,
                    lastAppliedAt: entry.appliedAt,
                    hasConflict: false
                )
            },
            duplicateMetadata: duplicateMetadata,
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: Date(timeIntervalSince1970: 1))
        )
    }

    private func makeEntry(
        id: String,
        villageID: UUID,
        lineageID: UUID,
        appliedAt: TimeInterval,
        isBaseline: Bool = false,
        items: [SnapshotObservationItem],
        levelCoverage: SnapshotCoverageState = .complete
    ) -> SnapshotHistoryEntry {
        let itemSections = Set(items.map { $0.identity.rawSection }).union(["heroes", "buildings"])
        let notApplicableSections: Set<String> = {
            var sections: Set<String> = []
            if itemSections.contains("heroes") { sections.insert("heroes2") }
            if itemSections.contains("buildings") || itemSections.contains("traps") {
                sections.formUnion(["buildings2", "traps", "traps2"])
            }
            if itemSections.contains("units") { sections.insert("units2") }
            return sections
        }()
        let sections = itemSections.union(notApplicableSections)
        var fields: [SnapshotCoverageField] = []
        for section in sections {
            let base = SnapshotHistoryBase(section: section)
            for field in ["presence", "data", "lvl", "cnt", "timer"] {
                let state: SnapshotCoverageState
                if section == "heroes" && levelCoverage != .complete {
                    state = levelCoverage
                } else if section == "heroes" && items.allSatisfy({ $0.identity.rawSection != "heroes" }) {
                    state = .partial
                } else {
                    state = .complete
                }
                fields.append(SnapshotCoverageField(base: base, rawSection: section, field: field, state: state))
            }
        }
        let coverage = SnapshotObservationCoverage(
            fields: fields,
            sections: sections.map { section in
                let observedCount = items.filter { $0.identity.rawSection == section }.count
                let isNotApplicable = notApplicableSections.contains(section)
                return SnapshotHistoryTestCoverage.trustedSection(
                    base: SnapshotHistoryBase(section: section),
                    rawSection: section,
                    presence: observedCount > 0 ? .presentNonEmpty : .presentEmpty,
                    completeness: .complete,
                    proof: isNotApplicable
                        ? SnapshotHistoryTestCoverage.verified(expectedCount: 0)
                        : SnapshotHistoryTestCoverage.verified(source: "test", expectedCount: nil),
                    observedCount: observedCount
                )
            },
            diagnostics: levelCoverage == .complete ? [] : ["heroes.lvl: 测试覆盖不足。"]
        )
        let fingerprintSeed = UUID(uuidString: id)?.uuidString.replacingOccurrences(of: "-", with: "") ?? id
        let fingerprint = "sha256:" + String(String(repeating: fingerprintSeed.lowercased(), count: 4).prefix(64))
        return SnapshotHistoryEntry(
            snapshotID: UUID(uuidString: id)!,
            villageID: villageID,
            lineageID: lineageID,
            normalizedPlayerTag: "#TEST",
            appliedAt: Date(timeIntervalSince1970: appliedAt),
            sourceTimestamp: Date(timeIntervalSince1970: appliedAt - 1),
            parserVersion: "test",
            canonicalFingerprint: fingerprint,
            rawJSON: "{}",
            observation: CanonicalSnapshotObservation(rawTopLevelFields: [:], items: items),
            coverage: coverage,
            isBaseline: isBaseline,
            baselineReason: isBaseline ? .initial : nil
        )
    }

    private func hero(level: Int) -> SnapshotObservationItem {
        SnapshotObservationItem(
            identity: SnapshotItemIdentity(base: .home, rawSection: "heroes", dataID: 1),
            level: level,
            count: 1,
            rawTimerEvidence: [:],
            unknownFields: [:],
            display: SnapshotDisplayBinding(displayName: "历史英雄名", category: "heroes")
        )
    }

    private func wall(level: Int, count: Int) -> SnapshotObservationItem {
        SnapshotObservationItem(
            identity: SnapshotItemIdentity(base: .home, rawSection: "buildings", dataID: 8),
            level: level,
            count: count,
            rawTimerEvidence: [:],
            unknownFields: [:],
            display: SnapshotDisplayBinding(
                displayName: "历史城墙名",
                category: "buildings",
                displayCategory: "walls"
            )
        )
    }
}
