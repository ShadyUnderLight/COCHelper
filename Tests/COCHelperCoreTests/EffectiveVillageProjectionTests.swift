import XCTest
@testable import COCHelperCore

final class EffectiveVillageProjectionTests: XCTestCase {
    private let importedAt = Date(timeIntervalSince1970: 1_000)
    private let baseline = ManualBaselineReference(
        revision: "snapshot-1",
        fingerprint: "sha256:snapshot",
        lineageID: "village-1"
    )
    private let provenance = ManualCatalogProvenance(
        gameVersion: "18.400.13",
        buildTag: "test",
        sourceFingerprint: "sha256:catalog",
        manifestSchemaVersion: 1
    )

    private func distribution(_ values: [(Int, Int64)]) throws -> ManualLevelDistribution {
        try ManualLevelDistribution(
            levelQuantities: Dictionary(uniqueKeysWithValues: values)
        )
    }

    private func snapshot(
        objectSections: [String: [AccountItem]]
    ) -> AccountSnapshot {
        AccountSnapshot(
            tag: "#TEST",
            capturedAt: nil,
            importedAt: importedAt,
            ageSeconds: nil,
            originalText: "{}",
            objectSections: objectSections,
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
    }

    private func village(
        objectSections: [String: [AccountItem]]
    ) -> VillageProfile {
        VillageProfile(name: "测试村庄", accountSnapshot: snapshot(objectSections: objectSections))
    }

    private func item(
        section: String,
        dataID: Int64,
        level: Int?,
        count: Int? = nil,
        timerSeconds: Int64? = nil,
        remainingSeconds: Int64? = nil,
        path: String = "0"
    ) -> AccountItem {
        AccountItem(
            id: section + ":" + path,
            section: section,
            dataID: dataID,
            level: level,
            count: count,
            timerSeconds: timerSeconds,
            remainingSeconds: remainingSeconds
        )
    }

    private func level(
        _ level: Int,
        townHall: Int? = nil,
        laboratory: Int? = nil,
        heroHall: Int? = nil,
        blacksmith: Int? = nil,
        duration: Int64? = 60,
        missingReason: String? = nil
    ) -> CatalogLevel {
        CatalogLevel(
            level: level,
            durationSeconds: duration,
            upgradeCosts: [CatalogUpgradeCost(
                resource: "Gold",
                amount: 100,
                rawResource: "Gold",
                rawAmount: nil,
                parseFailed: false
            )],
            requiredTownHallLevel: townHall,
            requiredLaboratoryLevel: laboratory,
            requiredHeroTavernLevel: heroHall,
            requiredBlacksmithLevel: blacksmith,
            icon: nil,
            levelVisual: nil,
            missingReason: missingReason
        )
    }

    private func catalog(
        cannonLifecycle: CatalogLifecycle? = .permanent,
        cannonDuration: Int64? = 90,
        cannonMissingReason: String? = nil,
        sourceFingerprint: String = "sha256:catalog"
    ) -> GameCatalog {
        GameCatalog(
            gameVersion: "18.400.13",
            items: [
                CatalogItem(
                    section: "buildings",
                    category: "buildings",
                    dataID: 1_000_001,
                    base: "home",
                    baseMissingReason: nil,
                    name: "大本营",
                    maxLevel: 20,
                    icon: nil,
                    levelVisual: nil,
                    lifecycle: .permanent,
                    levels: (1...20).map { level($0) }
                ),
                CatalogItem(
                    section: "buildings",
                    category: "buildings",
                    dataID: 1_000_002,
                    base: "home",
                    baseMissingReason: nil,
                    name: "加农炮",
                    maxLevel: 3,
                    icon: nil,
                    levelVisual: nil,
                    lifecycle: cannonLifecycle,
                    levels: [
                        level(1),
                        level(
                            2,
                            townHall: 11,
                            duration: cannonDuration,
                            missingReason: cannonMissingReason
                        ),
                        level(3, townHall: 12),
                    ]
                ),
                CatalogItem(
                    section: "buildings",
                    category: "buildings",
                    dataID: 1_000_010,
                    base: "home",
                    baseMissingReason: nil,
                    name: "城墙",
                    maxLevel: 12,
                    icon: nil,
                    levelVisual: nil,
                    lifecycle: .permanent,
                    levels: (1...12).map { level($0) }
                ),
            ],
            manifest: CatalogManifest(
                schemaVersion: 1,
                gameVersion: "18.400.13",
                buildTag: "test",
                locale: "zh-CN",
                sourceFingerprint: sourceFingerprint,
                generatedFiles: [],
                counts: CatalogCounts(
                    items: 3,
                    levels: 35,
                    missingIcons: nil,
                    missingTime: nil,
                    timed: nil,
                    instant: nil,
                    notApplicable: nil,
                    initialLevel: nil,
                    sourceMissing: nil,
                    parseFailed: nil
                )
            )
        )
    }

    private func state(
        key: TrackerItemKey,
        imported: ManualLevelDistribution,
        manual: ManualLevelDistribution,
        status: ManualItemStatus
    ) throws -> ManualItemState {
        try ManualItemState(
            itemKey: key,
            baselineReference: baseline,
            importedObservation: ManualImportedObservation(
                reference: baseline,
                levelDistribution: imported,
                sourceTimestamp: importedAt
            ),
            manualCompletedDistribution: manual,
            status: status
        )
    }

    private func record(
        key: TrackerItemKey,
        from: Int,
        target: Int,
        quantity: Int64 = 1,
        expectedEndAt: Date,
        startedAt: Date
    ) throws -> ManualUpgradeRecord {
        try ManualUpgradeRecord(
            recordID: UUID(),
            itemKey: key,
            fromLevel: from,
            targetLevel: target,
            quantity: quantity,
            startedAt: startedAt,
            expectedEndAt: expectedEndAt,
            durationSeconds: Int64(expectedEndAt.timeIntervalSince(startedAt)),
            durationKind: .timed,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline
        )
    }

    private func core(
        states: [ManualItemState],
        records: [ManualUpgradeRecord] = []
    ) throws -> ManualUpgradeCore {
        try ManualUpgradeCore(itemStates: states, records: records)
    }

    func testManualTownHallChangesPrerequisiteButActiveTargetDoesNot() throws {
        let townHallKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_001)
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 10),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let imported = try distribution([(10, 1)])
        let manualCompleted = try distribution([(11, 1)])
        let completedCore = try core(states: [
            try state(key: townHallKey, imported: imported, manual: manualCompleted, status: .manualCompleted),
        ])

        let completed = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: completedCore
        )
        let cannonCompleted = try XCTUnwrap(completed.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannonCompleted.currentStageMaxLevel, 2)
        XCTAssertEqual(cannonCompleted.effectiveState?.status, .observed)

        let activeRecord = try record(
            key: townHallKey,
            from: 10,
            target: 11,
            expectedEndAt: importedAt.addingTimeInterval(60),
            startedAt: importedAt
        )
        let activeCore = try core(
            states: [
                try state(key: townHallKey, imported: imported, manual: imported, status: .manualCompleted),
            ],
            records: [activeRecord]
        )
        let active = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt.addingTimeInterval(10),
            manualUpgradeCore: activeCore
        )
        let cannonActive = try XCTUnwrap(active.items.first { $0.dataID == 1_000_002 })
        XCTAssertNil(cannonActive.currentStageMaxLevel, "active target must not unlock the prerequisite")
        XCTAssertEqual(cannonActive.status, .unverified)
        XCTAssertEqual(
            active.effectiveTrackerItems.first { $0.itemKey == townHallKey }?.status,
            .manualActive
        )

        var settledCore = activeCore
        _ = try settledCore.settleDue(at: importedAt.addingTimeInterval(60))
        let settled = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt.addingTimeInterval(60),
            manualUpgradeCore: settledCore
        )
        XCTAssertEqual(
            settled.items.first { $0.dataID == 1_000_002 }?.currentStageMaxLevel,
            2
        )
    }

    func testSnapshotCoverageRemainsSeparateFromEffectiveTrackerProgress() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_001)
        let village = village(objectSections: [
            "buildings": [item(section: "buildings", dataID: 1_000_001, level: 10)],
        ])
        let manual = try core(states: [
            try state(
                key: key,
                imported: try distribution([(10, 1)]),
                manual: try distribution([(11, 1)]),
                status: .manualCompleted
            ),
        ])

        let importedOnly = VillageCatalogProjection.project(
            village: village, catalog: catalog(), base: .home, now: importedAt
        )
        let effective = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: manual
        )

        XCTAssertEqual(
            importedOnly.progressMetrics.snapshotCoverage,
            effective.progressMetrics.snapshotCoverage,
            "manual overlay must not rewrite snapshot coverage"
        )
        XCTAssertGreaterThan(
            effective.progressMetrics.effectiveTrackerProgress.numerator,
            importedOnly.progressMetrics.effectiveTrackerProgress.numerator
        )
        XCTAssertEqual(
            effective.effectiveTrackerItems.first { $0.itemKey == key }?.importedCurrentLevel,
            10
        )
        XCTAssertEqual(
            effective.effectiveTrackerItems.first { $0.itemKey == key }?.effectiveCompletedLevel,
            11
        )
    }

    func testDuplicateBuildingUsesOneStableDistribution() throws {
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_010, level: 10, count: 5, path: "0"),
                item(section: "buildings", dataID: 1_000_010, level: 11, count: 3, path: "1"),
            ],
        ])
        let projection = VillageCatalogProjection.project(
            village: village, catalog: catalog(), base: .home, now: importedAt
        )
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_010)
        let tracker = try XCTUnwrap(projection.effectiveTrackerItems.first { $0.itemKey == key })
        XCTAssertEqual(projection.effectiveTrackerItems.filter { $0.itemKey == key }.count, 1)
        XCTAssertEqual(tracker.importedDistribution?.quantity(at: 10), 5)
        XCTAssertEqual(tracker.importedDistribution?.quantity(at: 11), 3)
        XCTAssertEqual(tracker.importedCount, 8)
        XCTAssertEqual(projection.progressMetrics.instanceProgress.denominator, 8)
    }

    func testImportedActiveIsNotConvertedToManualRecordAndExactOrAmbiguousMatchIsExplicit() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = village(objectSections: [
            "buildings": [
                item(
                    section: "buildings",
                    dataID: 1_000_002,
                    level: 1,
                    timerSeconds: 100,
                    remainingSeconds: 90
                ),
            ],
        ])
        let importedOnly = VillageCatalogProjection.project(
            village: village, catalog: catalog(), base: .home, now: importedAt
        )
        let importedState = try XCTUnwrap(importedOnly.effectiveTrackerItems.first)
        XCTAssertEqual(importedState.status, .importedActive)
        XCTAssertTrue(importedState.activeManualRecords.isEmpty)

        let activeRecord = try record(
            key: key,
            from: 1,
            target: 2,
            expectedEndAt: importedAt.addingTimeInterval(90),
            startedAt: importedAt
        )
        let manualState = try state(
            key: key,
            imported: try distribution([(1, 1)]),
            manual: try distribution([(1, 1)]),
            status: .manualCompleted
        )
        let exactCore = try core(states: [manualState], records: [activeRecord])
        let exact = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: exactCore
        )
        let exactState = try XCTUnwrap(exact.effectiveTrackerItems.first)
        XCTAssertEqual(exactState.status, .manualActive)
        XCTAssertEqual(
            Set(exactState.provenance),
            Set([.manualActive, .importedActive])
        )

        let ambiguousRecord = try record(
            key: key,
            from: 1,
            target: 2,
            expectedEndAt: importedAt.addingTimeInterval(70),
            startedAt: importedAt.addingTimeInterval(-20)
        )
        let ambiguousCore = try core(states: [manualState], records: [ambiguousRecord])
        let ambiguous = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: ambiguousCore
        )
        XCTAssertEqual(ambiguous.effectiveTrackerItems.first?.status, .conflict)
        XCTAssertTrue(ambiguous.effectiveTrackerItems.first?.diagnostic?.contains("匹配") == true)
    }

    func testActiveManualFailsClosedForCatalogProvenanceDurationAndLifecycle() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = village(objectSections: [
            "buildings": [
                item(
                    section: "buildings",
                    dataID: 1_000_002,
                    level: 1,
                    timerSeconds: 100,
                    remainingSeconds: 90
                ),
            ],
        ])
        let activeRecord = try record(
            key: key,
            from: 1,
            target: 2,
            expectedEndAt: importedAt.addingTimeInterval(90),
            startedAt: importedAt
        )
        let manualState = try state(
            key: key,
            imported: try distribution([(1, 1)]),
            manual: try distribution([(1, 1)]),
            status: .manualCompleted
        )
        let manualCore = try core(states: [manualState], records: [activeRecord])

        let cases: [(String, GameCatalog, String)] = [
            (
                "fingerprint",
                catalog(sourceFingerprint: "sha256:other"),
                "manifest"
            ),
            (
                "duration",
                catalog(cannonDuration: nil, cannonMissingReason: "time_missing"),
                "时长"
            ),
            (
                "lifecycle",
                catalog(cannonLifecycle: nil),
                "生命周期"
            ),
        ]
        for (label, currentCatalog, diagnosticFragment) in cases {
            let projection = VillageCatalogProjection.project(
                village: village,
                catalog: currentCatalog,
                base: .home,
                now: importedAt,
                manualUpgradeCore: manualCore
            )
            let effective = try XCTUnwrap(
                projection.effectiveTrackerItems.first { $0.itemKey == key },
                label
            )
            XCTAssertEqual(effective.status, .unknown, label)
            XCTAssertTrue(
                effective.diagnostic?.contains(diagnosticFragment) == true,
                "\(label): \(effective.diagnostic ?? "missing diagnostic")"
            )
        }
    }

    func testManualOverlayIsIsolatedPerVillage() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_001)
        let firstVillage = village(objectSections: [
            "buildings": [item(section: "buildings", dataID: 1_000_001, level: 10)],
        ])
        let secondVillage = village(objectSections: [
            "buildings": [item(section: "buildings", dataID: 1_000_001, level: 10)],
        ])
        let manual = try core(states: [
            try state(
                key: key,
                imported: try distribution([(10, 1)]),
                manual: try distribution([(11, 1)]),
                status: .manualCompleted
            ),
        ])

        let first = VillageCatalogProjection.project(
            village: firstVillage,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: manual
        )
        let second = VillageCatalogProjection.project(
            village: secondVillage, catalog: catalog(), base: .home, now: importedAt
        )
        XCTAssertEqual(first.effectiveTrackerItems.first?.effectiveCompletedLevel, 11)
        XCTAssertEqual(second.effectiveTrackerItems.first?.effectiveCompletedLevel, 10)
    }
}
