import XCTest
@testable import COCHelperCore

final class SnapshotHistoryDiffTests: XCTestCase {
    func testUniqueLevelChangeUsesStableIdentityAndHistoricalBinding() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeItem(
            identity: identity,
            level: 1,
            display: SnapshotDisplayBinding(displayName: "旧英雄", category: "heroes")
        )
        let new = makeItem(
            identity: identity,
            level: 3,
            display: SnapshotDisplayBinding(displayName: "新英雄", category: "heroes")
        )

        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [old], section: "heroes"),
            to: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [new], section: "heroes")
        )

        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.identity, identity)
        XCTAssertEqual(change.displayName, "新英雄")
        XCTAssertEqual(change.category, "heroes")
        XCTAssertEqual(change.changeKind, .levelIncreased)
        XCTAssertEqual(change.oldLevel, 1)
        XCTAssertEqual(change.newLevel, 3)
        XCTAssertEqual(change.levelDelta, 2)
        XCTAssertEqual(change.evidence, .confirmed)
        XCTAssertEqual(change.coverage.state, .complete)
        XCTAssertEqual(diff.algorithmVersion, SnapshotDiffAlgorithm.version)
        XCTAssertEqual(diff.comparisonState, .comparable)
    }

    func testUniqueNewAndMissingItemsRequireCompleteUniverseCoverage() throws {
        let firstIdentity = makeIdentity(section: "heroes", dataID: 1)
        let secondIdentity = makeIdentity(section: "heroes", dataID: 2)
        let oldEntry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: firstIdentity, level: 1)],
            section: "heroes"
        )
        let newEntry = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [
                makeItem(identity: firstIdentity, level: 1),
                makeItem(identity: secondIdentity, level: 2)
            ],
            section: "heroes"
        )

        let newDiff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let newChange = try XCTUnwrap(newDiff.changes.first { $0.identity == secondIdentity })
        XCTAssertEqual(newChange.changeKind, .newlyObserved)
        XCTAssertEqual(newChange.evidence, .confirmed)

        let missingDiff = SnapshotDiffEngine.compare(from: newEntry, to: oldEntry)
        let missingChange = try XCTUnwrap(missingDiff.changes.first { $0.identity == secondIdentity })
        XCTAssertEqual(missingChange.changeKind, .noLongerObserved)
        XCTAssertEqual(missingChange.evidence, .confirmed)

        let missingSectionEntry = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            date: 300,
            items: [],
            section: nil
        )
        let insufficient = SnapshotDiffEngine.compare(from: missingSectionEntry, to: newEntry)
        let unknown = try XCTUnwrap(insufficient.changes.first { $0.identity == firstIdentity })
        XCTAssertEqual(unknown.changeKind, .unknown)
        XCTAssertEqual(unknown.evidence, .unknown)
        XCTAssertEqual(unknown.coverage.state, .insufficient)
        XCTAssertEqual(insufficient.comparisonState, .insufficientCoverage)
    }

    func testDuplicateWallHistogramUsesDeterministicMonotonicMigration() throws {
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldItems = [
            makeItem(identity: identity, level: 12, count: 100, display: wallBinding()),
            makeItem(identity: identity, level: 13, count: 50, display: wallBinding())
        ]
        let newItems = [
            makeItem(identity: identity, level: 13, count: 70, display: wallBinding()),
            makeItem(identity: identity, level: 12, count: 80, display: wallBinding())
        ]
        let oldEntry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: oldItems,
            section: "buildings",
            states: ["cnt": .complete]
        )
        let newEntry = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: newItems,
            section: "buildings",
            states: ["cnt": .complete]
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let migration = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(migration.changeKind, .levelIncreased)
        XCTAssertEqual(migration.evidence, .aggregateInferred)
        XCTAssertEqual(migration.oldLevel, 12)
        XCTAssertEqual(migration.newLevel, 13)
        XCTAssertEqual(migration.oldQuantity, 100)
        XCTAssertEqual(migration.newQuantity, 70)
        XCTAssertEqual(migration.movedQuantity, 20)
        XCTAssertEqual(migration.levelDelta, 1)
        XCTAssertEqual(migration.displayCategory, TrackerDisplayCategory.walls.rawValue)

        let reordered = SnapshotDiffEngine.compare(
            from: oldEntry,
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: newItems.reversed(),
                section: "buildings",
                states: ["cnt": .complete]
            )
        )
        XCTAssertEqual(reordered, diff)
    }

    func testHistogramMissingCountIsUnknownAndNeverTreatedAsOne() throws {
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldEntry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [
                makeItem(identity: identity, level: 12, display: wallBinding()),
                makeItem(identity: identity, level: 13, display: wallBinding())
            ],
            section: "buildings",
            states: ["cnt": .unavailable]
        )
        let newEntry = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [
                makeItem(identity: identity, level: 13, display: wallBinding()),
                makeItem(identity: identity, level: 14, display: wallBinding())
            ],
            section: "buildings",
            states: ["cnt": .unavailable]
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        let change = try XCTUnwrap(diff.changes.single)
        XCTAssertEqual(change.changeKind, .unknown)
        XCTAssertEqual(change.evidence, .unknown)
        XCTAssertEqual(change.coverage.state, .insufficient)
        XCTAssertTrue(change.coverage.fields.contains { $0.field == "cnt" && $0.fromState == .unavailable })
    }

    func testSingleBuildingRecordStillRequiresHistogramCount() throws {
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let oldEntry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 12, display: wallBinding())],
            section: "buildings",
            states: ["cnt": .unavailable]
        )
        let newEntry = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 13, display: wallBinding())],
            section: "buildings",
            states: ["cnt": .unavailable]
        )

        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
    }

    func testTimerTransitionsAreGroupedWithLevelChange() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeItem(
            identity: identity,
            level: 1,
            timer: 90,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let changed = makeItem(
            identity: identity,
            level: 1,
            timer: 80,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )
        let completed = makeItem(
            identity: identity,
            level: 2,
            display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes")
        )

        let timerDiff = SnapshotDiffEngine.compare(
            from: makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [old], section: "heroes", states: ["timer": .complete]),
            to: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [changed], section: "heroes", states: ["timer": .complete])
        )
        XCTAssertEqual(timerDiff.changes.single?.changeKind, .timerChanged)

        let startedDiff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [makeItem(identity: identity, level: 1, display: old.display)],
                section: "heroes",
                states: ["timer": .complete]
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: [old],
                section: "heroes",
                states: ["timer": .complete]
            )
        )
        XCTAssertEqual(startedDiff.changes.single?.changeKind, .upgradeStarted)

        let completionDiff = SnapshotDiffEngine.compare(
            from: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [old], section: "heroes", states: ["timer": .complete]),
            to: makeEntry(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", date: 300, items: [completed], section: "heroes", states: ["timer": .complete])
        )
        let completion = try XCTUnwrap(completionDiff.changes.single)
        XCTAssertEqual(completion.changeKind, .upgradeCompleted)
        XCTAssertEqual(completion.relatedChangeKinds, [.levelIncreased])
        XCTAssertEqual(completion.levelDelta, 1)
        XCTAssertEqual(completion.evidence, .confirmed)

        let ended = SnapshotDiffEngine.compare(
            from: makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [old], section: "heroes", states: ["timer": .complete]),
            to: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [
                makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))
            ], section: "heroes", states: ["timer": .complete])
        )
        XCTAssertEqual(ended.changes.single?.changeKind, .timerEndedObserved)

        let partial = SnapshotDiffEngine.compare(
            from: makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [old], section: "heroes", states: ["timer": .complete]),
            to: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [
                makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))
            ], section: "heroes", states: ["presence": .partial, "data": .partial, "timer": .unavailable])
        )
        XCTAssertEqual(partial.changes.single?.changeKind, .unknown)
        XCTAssertEqual(partial.changes.single?.evidence, .unknown)

        let unavailable = SnapshotDiffEngine.compare(
            from: makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [old], section: "heroes", states: ["timer": .complete]),
            to: makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [
                makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))
            ], section: "heroes", states: ["presence": .partial, "data": .partial, "timer": .unavailable])
        )
        XCTAssertEqual(unavailable.changes.single?.changeKind, .unknown)
        XCTAssertEqual(unavailable.changes.single?.evidence, .unknown)
    }

    func testMissingRequiredLevelIsUnknownInsteadOfUnchanged() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let diff = SnapshotDiffEngine.compare(
            from: makeEntry(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                date: 100,
                items: [makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(category: "heroes"))],
                section: "heroes"
            ),
            to: makeEntry(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                date: 200,
                items: [makeItem(identity: identity, level: nil, display: SnapshotDisplayBinding(category: "heroes"))],
                section: "heroes",
                states: ["lvl": .partial]
            )
        )
        XCTAssertEqual(diff.changes.single?.changeKind, .unknown)
        XCTAssertEqual(diff.changes.single?.evidence, .unknown)
    }

    func testCanonicalCoverageWarningsRemainStructuredDiagnostics() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1, display: SnapshotDisplayBinding(category: "heroes"))],
            section: "heroes",
            diagnostics: ["heroes[0].data: unknown dataID"]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 2, display: SnapshotDisplayBinding(category: "heroes"))],
            section: "heroes"
        )

        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        XCTAssertTrue(diff.diagnostics.contains { $0.kind == .malformedObservation && $0.message.contains("unknown dataID") })
        XCTAssertEqual(diff.changes.single?.changeKind, .levelIncreased)
    }

    func testAdjacentDiffsKeepAtoBtoAAndSuppressCrossLineage() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let first = makeEntry(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", date: 100, items: [makeItem(identity: identity, level: 1)], section: "heroes")
        let second = makeEntry(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", date: 200, items: [makeItem(identity: identity, level: 2)], section: "heroes")
        let third = makeEntry(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", date: 300, items: [makeItem(identity: identity, level: 1)], section: "heroes")

        let diffs = SnapshotDiffEngine.adjacentDiffs(in: [first, second, third])
        XCTAssertEqual(diffs.count, 2)
        XCTAssertEqual(diffs.map { $0.changes.single?.levelDelta }, [1, -1])

        let otherLineage = makeEntry(
            id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            date: 400,
            items: [makeItem(identity: identity, level: 3)],
            section: "heroes",
            lineageID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let suppressed = SnapshotDiffEngine.compare(from: third, to: otherLineage)
        XCTAssertEqual(suppressed.comparisonState, .suppressed)
        XCTAssertEqual(suppressed.changes, [])
        XCTAssertEqual(suppressed.diagnostics.single?.kind, .lineageMismatch)

        let interleaved = SnapshotDiffEngine.adjacentDiffs(in: [first, otherLineage, second])
        XCTAssertEqual(interleaved, [])
    }

    func testStatisticsUseAppliedAtTimezoneAndKeepAggregateEvidenceSeparate() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        func pair(id1: String, id2: String, fromDate: Date, toDate: Date, oldLevel: Int, newLevel: Int) -> SnapshotDiff {
            SnapshotDiffEngine.compare(
                from: makeEntry(id: id1, date: fromDate.timeIntervalSince1970, items: [makeItem(identity: identity, level: oldLevel, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))], section: "heroes", sourceTimestamp: Date(timeIntervalSince1970: 1)),
                to: makeEntry(id: id2, date: toDate.timeIntervalSince1970, items: [makeItem(identity: identity, level: newLevel, display: SnapshotDisplayBinding(displayName: "英雄", category: "heroes"))], section: "heroes", sourceTimestamp: Date(timeIntervalSince1970: 2))
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = timeZone
        let reference = date("2024-04-10 10:00:00", calendar: calendar)
        let todayDiff = pair(
            id1: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            id2: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            fromDate: date("2024-04-09 23:00:00", calendar: calendar),
            toDate: date("2024-04-10 09:00:00", calendar: calendar),
            oldLevel: 1,
            newLevel: 2
        )
        let sevenBoundaryDiff = pair(
            id1: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            id2: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            fromDate: date("2024-04-03 23:00:00", calendar: calendar),
            toDate: date("2024-04-04 00:00:00", calendar: calendar),
            oldLevel: 1,
            newLevel: 2
        )
        let thirtyBoundaryDiff = pair(
            id1: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            id2: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            fromDate: date("2024-03-11 23:00:00", calendar: calendar),
            toDate: date("2024-03-12 00:00:00", calendar: calendar),
            oldLevel: 1,
            newLevel: 2
        )

        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [todayDiff, sevenBoundaryDiff, thirtyBoundaryDiff],
            referenceDate: reference,
            calendar: calendar,
            timeZone: timeZone
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.value, 1)
        XCTAssertEqual(statistics.last7Days.heroLevelGrowth.value, 2)
        XCTAssertEqual(statistics.last30Days.heroLevelGrowth.value, 3)
        XCTAssertEqual(statistics.timeZoneIdentifier, "Asia/Shanghai")

        let empty = SnapshotHistoryStatistics.calculate(
            diffs: [],
            referenceDate: reference,
            calendar: calendar,
            timeZone: timeZone
        )
        XCTAssertEqual(empty.today.heroLevelGrowth.state, .insufficientData)
    }

    func testStatisticsReturnZeroOnlyForCompleteComparableNoChange() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let entry = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes"
        )
        let same = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes"
        )
        let diff = SnapshotDiffEngine.compare(from: entry, to: same)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(diff.changes, [])
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .available)
        XCTAssertEqual(statistics.today.heroLevelGrowth.value, 0)
    }

    func testStatisticsPropagateInsufficientCoverageForAffectedCategory() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes"
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: nil)],
            section: "heroes",
            states: ["lvl": .partial]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(diff.comparisonState, .insufficientCoverage)
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .insufficientData)
    }

    func testWallHistogramStatisticsKeepAggregateEvidenceSeparate() throws {
        let identity = makeIdentity(section: "buildings", dataID: 8)
        let old = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [
                makeItem(identity: identity, level: 12, count: 100, display: wallBinding()),
                makeItem(identity: identity, level: 13, count: 50, display: wallBinding())
            ],
            section: "buildings",
            states: ["cnt": .complete]
        )
        let new = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [
                makeItem(identity: identity, level: 12, count: 80, display: wallBinding()),
                makeItem(identity: identity, level: 13, count: 70, display: wallBinding())
            ],
            section: "buildings",
            states: ["cnt": .complete]
        )
        let diff = SnapshotDiffEngine.compare(from: old, to: new)
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: [diff],
            referenceDate: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(statistics.today.wallLevelGrowth.value, 20)
        XCTAssertEqual(statistics.today.aggregateInferredWallLevelGrowth.value, 20)
        XCTAssertEqual(statistics.today.aggregateInferredEventCount.value, 1)
        XCTAssertEqual(statistics.today.buildingLevelGrowth.value, 0)
    }

    func testBaselineHasNoPredecessorDiff() throws {
        let identity = makeIdentity(section: "heroes", dataID: 1)
        let baseline = makeEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            date: 100,
            items: [makeItem(identity: identity, level: 1)],
            section: "heroes",
            isBaseline: true
        )
        let regular = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            date: 200,
            items: [makeItem(identity: identity, level: 2)],
            section: "heroes"
        )

        XCTAssertEqual(SnapshotDiffEngine.adjacentDiffs(in: [baseline]).count, 0)
        let reverse = SnapshotDiffEngine.compare(from: regular, to: baseline)
        XCTAssertEqual(reverse.comparisonState, .suppressed)
        XCTAssertTrue(reverse.changes.isEmpty)
        XCTAssertEqual(reverse.diagnostics.single?.kind, .baseline)
        XCTAssertEqual(SnapshotDiffEngine.adjacentDiffs(in: [baseline, regular]).count, 1)
    }

    private func makeEntry(
        id: String,
        date: TimeInterval,
        items: [SnapshotObservationItem],
        section: String?,
        states: [String: SnapshotCoverageState] = [:],
        diagnostics: [String] = [],
        villageID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        lineageID: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        sourceTimestamp: Date? = nil,
        isBaseline: Bool = false
    ) -> SnapshotHistoryEntry {
        let coverage: SnapshotObservationCoverage
        if let section {
            let defaults: [String: SnapshotCoverageState] = [
                "presence": .complete,
                "data": .complete,
                "lvl": .complete
            ]
            let merged = defaults.merging(states) { _, new in new }
            coverage = SnapshotObservationCoverage(fields: merged.map {
                SnapshotCoverageField(
                    base: SnapshotHistoryBase(section: section),
                    rawSection: section,
                    field: $0.key,
                    state: $0.value
                )
            }, diagnostics: diagnostics)
        } else {
            coverage = SnapshotObservationCoverage(fields: [], diagnostics: diagnostics)
        }
        return SnapshotHistoryEntry(
            snapshotID: UUID(uuidString: id)!,
            villageID: villageID,
            lineageID: lineageID,
            normalizedPlayerTag: "#TEST",
            appliedAt: Date(timeIntervalSince1970: date),
            sourceTimestamp: sourceTimestamp,
            parserVersion: "test",
            canonicalFingerprint: "test",
            rawJSON: "{}",
            observation: CanonicalSnapshotObservation(rawTopLevelFields: [:], items: items),
            coverage: coverage,
            isBaseline: isBaseline,
            baselineReason: isBaseline ? .initial : nil
        )
    }

    private func makeIdentity(
        section: String,
        dataID: Int64,
        base: SnapshotHistoryBase = .home
    ) -> SnapshotItemIdentity {
        SnapshotItemIdentity(base: base, rawSection: section, dataID: dataID)
    }

    private func makeItem(
        identity: SnapshotItemIdentity,
        level: Int?,
        count: Int? = nil,
        timer: Int? = nil,
        display: SnapshotDisplayBinding = SnapshotDisplayBinding()
    ) -> SnapshotObservationItem {
        SnapshotObservationItem(
            identity: identity,
            level: level,
            count: count,
            rawTimerEvidence: timer.map { ["timer": .number(String($0))] } ?? [:],
            display: display
        )
    }

    private func wallBinding() -> SnapshotDisplayBinding {
        SnapshotDisplayBinding(displayName: "城墙", category: "buildings", displayCategory: "walls")
    }

    private func date(_ value: String, calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)!
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
