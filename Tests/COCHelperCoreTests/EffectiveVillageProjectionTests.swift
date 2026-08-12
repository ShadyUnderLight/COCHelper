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
        sourceFingerprint: String = "sha256:catalog",
        instanceCounts: [String: [Int]]? = nil
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
                generatedFiles: [
                    CatalogGeneratedFile(
                        path: "catalog.json",
                        sha256: "sha256:catalog",
                        size: nil,
                        kind: nil,
                        entries: nil
                    ),
                ],
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
            ),
            instanceCounts: instanceCounts
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
        startedAt: Date,
        recordID: UUID = UUID()
    ) throws -> ManualUpgradeRecord {
        try ManualUpgradeRecord(
            recordID: recordID,
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

    func testActiveMatchingCannotReuseOneImportedTimerForTwoManualRecords() throws {
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
        let manualState = try state(
            key: key,
            imported: try distribution([(1, 2)]),
            manual: try distribution([(1, 2)]),
            status: .manualCompleted
        )
        let first = try record(
            key: key,
            from: 1,
            target: 2,
            expectedEndAt: importedAt.addingTimeInterval(90),
            startedAt: importedAt,
            recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let second = try record(
            key: key,
            from: 1,
            target: 2,
            expectedEndAt: importedAt.addingTimeInterval(90),
            startedAt: importedAt,
            recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: try core(states: [manualState], records: [first, second])
        )

        let effective = try XCTUnwrap(projection.effectiveTrackerItems.first)
        XCTAssertEqual(effective.status, .conflict)
        XCTAssertTrue(effective.diagnostic?.contains("匹配") == true)
    }

    func testNeedsReimportIsUnknownToEffectiveInstanceProgress() throws {
        let townHallKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_001)
        let cannonKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(
                    section: "buildings",
                    dataID: 1_000_002,
                    level: 2,
                    timerSeconds: 100,
                    remainingSeconds: 0,
                    path: "1"
                ),
            ],
        ])
        let manual = try core(states: [
            try state(
                key: townHallKey,
                imported: try distribution([(11, 1)]),
                manual: try distribution([(11, 1)]),
                status: .observed
            ),
        ])

        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: manual
        )

        let cannon = try XCTUnwrap(projection.effectiveTrackerItems.first { $0.itemKey == cannonKey })
        XCTAssertEqual(cannon.status, .needsReimport)
        XCTAssertEqual(projection.progressMetrics.instanceProgress.numerator, 0)
        XCTAssertEqual(projection.progressMetrics.instanceProgress.denominator, 2)
        XCTAssertEqual(projection.progressMetrics.instanceProgress.state, .partial)
        XCTAssertTrue(projection.progressMetrics.instanceProgress.degradedReason?.contains("1 个实例") == true)
        XCTAssertFalse(projection.progressMetrics.instanceProgress.degradedReason?.contains("(unknownWeight)") == true)
    }

    func testManualInstanceProgressKeepsAvailableUniverseDenominator() throws {
        let cannonKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let universe = [
            "buildings:1000002": Array(repeating: 2, count: 18),
            "buildings:1000010": Array(repeating: 3, count: 18),
        ]
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                item(section: "buildings", dataID: 1_000_010, level: 1, path: "2"),
            ],
        ])
        let manual = try core(states: [
            try state(
                key: cannonKey,
                imported: try distribution([(1, 1)]),
                manual: try distribution([(3, 1)]),
                status: .manualCompleted
            ),
        ])
        let currentCatalog = catalog(instanceCounts: universe)

        let importedOnly = VillageCatalogProjection.project(
            village: village,
            catalog: currentCatalog,
            base: .home,
            now: importedAt
        )
        let effective = VillageCatalogProjection.project(
            village: village,
            catalog: currentCatalog,
            base: .home,
            now: importedAt,
            manualUpgradeCore: manual
        )

        XCTAssertEqual(importedOnly.items.filter { $0.status == .available }.count, 2)
        XCTAssertEqual(importedOnly.progressMetrics.instanceProgress.denominator, 6)
        XCTAssertEqual(
            effective.progressMetrics.instanceProgress.denominator,
            importedOnly.progressMetrics.instanceProgress.denominator
        )
        XCTAssertEqual(effective.progressMetrics.instanceProgress.numerator, 1)
    }

    func testManualInstanceProgressDoesNotDuplicateStableDistributionAcrossRows() throws {
        let cannonKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 1, count: 2, path: "1"),
                item(section: "buildings", dataID: 1_000_002, level: 2, count: 1, path: "2"),
            ],
        ])
        let importedDistribution = try distribution([(1, 2), (2, 1)])
        let manual = try core(states: [
            try state(
                key: cannonKey,
                imported: importedDistribution,
                manual: importedDistribution,
                status: .manualCompleted
            ),
        ])

        let importedOnly = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt
        )
        let effective = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: manual
        )

        XCTAssertEqual(importedOnly.progressMetrics.instanceProgress.denominator, 4)
        XCTAssertEqual(
            effective.progressMetrics.instanceProgress.denominator,
            importedOnly.progressMetrics.instanceProgress.denominator
        )
    }

    func testDetailAndBuildingGroupUseEffectiveCompletedState() throws {
        let cannonKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 12),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let manual = try core(states: [
            try state(
                key: cannonKey,
                imported: try distribution([(1, 1)]),
                manual: try distribution([(3, 1)]),
                status: .manualCompleted
            ),
        ])
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: manual
        )

        let displayItems = projection.items.filter { $0.status != .unavailable && $0.status != .available }
        let total = VillageDetailProjection.totalCompletion(from: displayItems)
        XCTAssertEqual(total.completedCount, 1)
        XCTAssertEqual(total.knownCount, 2)

        let group = try XCTUnwrap(
            BuildingGroupProjection.project(projection: projection, catalog: catalog(), base: .home)
                .first { $0.dataID == 1_000_002 }
        )
        XCTAssertEqual(group.summary.remainingLevelCount, 0)
        XCTAssertTrue(group.instances.first?.steps.isEmpty == true)
        XCTAssertEqual(group.instances.first?.item.effectiveCurrentLevel, 3)
    }

    func testManualCompletedLevelReprojectsNextUpgradeFromEffectiveLevel() throws {
        let cannonKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 12),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: try core(states: [
                try state(
                    key: cannonKey,
                    imported: try distribution([(1, 1)]),
                    manual: try distribution([(2, 1)]),
                    status: .manualCompleted
                ),
            ])
        )

        let cannon = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.effectiveCurrentLevel, 2)
        guard case .available(let level, let duration) = cannon.effectiveNextUpgrade else {
            return XCTFail("manual completed level should reproject the next catalog level")
        }
        XCTAssertEqual(level, 3)
        XCTAssertEqual(duration, 60)
        XCTAssertEqual(cannon.effectiveNextLevelDurationState, .timed(seconds: 60))
    }

    func testManualCoverageDiagnosticsUseConcreteCounts() throws {
        let townHallKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_001)
        let cannonKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let unmatchedKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_010)
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: try core(states: [
                try state(
                    key: townHallKey,
                    imported: try distribution([(11, 1)]),
                    manual: try distribution([(11, 1)]),
                    status: .observed
                ),
                try state(
                    key: cannonKey,
                    imported: try distribution([(1, 1)]),
                    manual: try distribution([(1, 1)]),
                    status: .conflict
                ),
                try state(
                    key: unmatchedKey,
                    imported: try distribution([(1, 1)]),
                    manual: try distribution([(1, 1)]),
                    status: .unknown
                ),
            ])
        )

        XCTAssertTrue(projection.manualCoverage.diagnostics.contains { $0.contains("有 1 条本地手动状态") })
        XCTAssertTrue(projection.manualCoverage.diagnostics.contains { $0.contains("有 1 个项目") })
        XCTAssertFalse(projection.manualCoverage.diagnostics.contains { $0.contains("(unmatched)") })
        XCTAssertFalse(projection.manualCoverage.diagnostics.contains { $0.contains("(unknown)") })
        XCTAssertFalse(projection.progressMetrics.instanceProgress.degradedReason?.contains("(unknownWeight)") == true)
    }

    func testManualOnlyActiveAppearsInOverview() throws {
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let activeRecord = try record(
            key: key,
            from: 1,
            target: 2,
            expectedEndAt: importedAt.addingTimeInterval(90),
            startedAt: importedAt
        )
        let manual = try core(states: [
            try state(
                key: key,
                imported: try distribution([(1, 1)]),
                manual: try distribution([(1, 1)]),
                status: .manualCompleted
            ),
        ], records: [activeRecord])

        let overview = UpgradeOverviewProjection.overviewRecords(
            from: [village],
            catalog: catalog(),
            manualUpgradeCores: [village.id: manual],
            at: importedAt
        )

        let active = try XCTUnwrap(overview.active.first)
        XCTAssertEqual(overview.active.count, 1)
        XCTAssertEqual(active.item.effectiveState?.status, .manualActive)
        XCTAssertEqual(active.completionDate(from: importedAt), importedAt.addingTimeInterval(90))
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

    func testEffectiveActiveConsumersFailClosedForSettledOrInvalidManualStates() throws {
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
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt
        )
        let importedItem = try XCTUnwrap(importedOnly.items.first { $0.dataID == 1_000_002 })
        XCTAssertTrue(importedItem.isEffectivelyUpgrading)
        XCTAssertEqual(importedItem.effectiveRemainingSeconds(at: importedAt), 90)

        let cases: [(ManualItemStatus, EffectiveVillageItemStatus)] = [
            (.manualCompleted, .manualCompleted),
            (.unknown, .unknown),
            (.conflict, .conflict),
        ]
        for (manualStatus, expectedStatus) in cases {
            let projection = VillageCatalogProjection.project(
                village: village,
                catalog: catalog(),
                base: .home,
                now: importedAt,
                manualUpgradeCore: try core(states: [
                    try state(
                        key: key,
                        imported: try distribution([(1, 1)]),
                        manual: try distribution([(1, 1)]),
                        status: manualStatus
                    ),
                ])
            )
            let effectiveItem = try XCTUnwrap(
                projection.items.first { $0.dataID == 1_000_002 },
                manualStatus.rawValue
            )
            XCTAssertEqual(effectiveItem.effectiveState?.status, expectedStatus)
            XCTAssertFalse(effectiveItem.isEffectivelyUpgrading, manualStatus.rawValue)
            XCTAssertNil(effectiveItem.effectiveTargetLevel, manualStatus.rawValue)
            XCTAssertNil(
                effectiveItem.effectiveRemainingSeconds(at: importedAt),
                manualStatus.rawValue
            )

            let overview = UpgradeOverviewProjection.overviewRecords(
                from: [village],
                catalog: catalog(),
                manualUpgradeCores: [village.id: try core(states: [
                    try state(
                        key: key,
                        imported: try distribution([(1, 1)]),
                        manual: try distribution([(1, 1)]),
                        status: manualStatus
                    ),
                ])],
                at: importedAt
            )
            XCTAssertTrue(overview.active.isEmpty, manualStatus.rawValue)
        }
    }

    func testEffectiveActiveAtStageCapIsNotMaxed() throws {
        let townHallKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_001)
        let cannonKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(
                    section: "buildings",
                    dataID: 1_000_002,
                    level: 2,
                    timerSeconds: 60,
                    remainingSeconds: 60,
                    path: "1"
                ),
            ],
        ])
        let activeRecord = try record(
            key: cannonKey,
            from: 2,
            target: 3,
            expectedEndAt: importedAt.addingTimeInterval(60),
            startedAt: importedAt
        )
        let manual = try core(
            states: [
                try state(
                    key: townHallKey,
                    imported: try distribution([(11, 1)]),
                    manual: try distribution([(11, 1)]),
                    status: .observed
                ),
                try state(
                    key: cannonKey,
                    imported: try distribution([(2, 1)]),
                    manual: try distribution([(2, 1)]),
                    status: .manualCompleted
                ),
            ],
            records: [activeRecord]
        )
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: manual
        )

        let cannon = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.effectiveState?.status, .manualActive)
        XCTAssertEqual(cannon.currentStageMaxLevel, 2)
        XCTAssertTrue(cannon.isEffectivelyUpgrading)
        XCTAssertFalse(cannon.isEffectivelyMaxed)
        XCTAssertEqual(cannon.effectiveTargetLevel, 3)
        XCTAssertEqual(cannon.effectiveRemainingSeconds(at: importedAt), 60)

        let completion = VillageDetailProjection.totalCompletion(
            from: projection.items.filter { $0.status != .available && $0.status != .unavailable }
        )
        XCTAssertEqual(completion.completedCount, 0)
    }

    func testExtremeManualDurationFailsClosedWithoutDoubleToInt64Trap() throws {
        let townHallKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_001)
        let cannonKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let activeRecord = try ManualUpgradeRecord(
            itemKey: cannonKey,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: importedAt,
            expectedEndAt: importedAt.addingTimeInterval(Double(Int64.max)),
            durationSeconds: Int64.max,
            durationKind: .timed,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline
        )
        let manual = try core(
            states: [
                try state(
                    key: townHallKey,
                    imported: try distribution([(11, 1)]),
                    manual: try distribution([(11, 1)]),
                    status: .observed
                ),
                try state(
                    key: cannonKey,
                    imported: try distribution([(1, 1)]),
                    manual: try distribution([(1, 1)]),
                    status: .manualCompleted
                ),
            ],
            records: [activeRecord]
        )
        let catalogWithExtremeDuration = catalog(cannonDuration: Int64.max)

        let manualOnly = VillageCatalogProjection.project(
            village: village,
            catalog: catalogWithExtremeDuration,
            base: .home,
            now: importedAt,
            manualUpgradeCore: manual
        )
        let manualOnlyItem = try XCTUnwrap(manualOnly.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(manualOnlyItem.effectiveState?.status, .manualActive)
        XCTAssertNil(manualOnlyItem.effectiveRemainingSeconds(at: importedAt))

        let matchingVillage = self.village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(
                    section: "buildings",
                    dataID: 1_000_002,
                    level: 1,
                    timerSeconds: Int64.max,
                    remainingSeconds: Int64.max,
                    path: "1"
                ),
            ],
        ])
        let matching = VillageCatalogProjection.project(
            village: matchingVillage,
            catalog: catalogWithExtremeDuration,
            base: .home,
            now: importedAt,
            manualUpgradeCore: manual
        )
        XCTAssertEqual(
            matching.effectiveTrackerItems.first { $0.itemKey == cannonKey }?.status,
            .conflict
        )
        XCTAssertNil(VillageCatalogProjection.safeFloorInt64(Double(Int64.max)))
        XCTAssertEqual(
            VillageCatalogProjection.safeFloorInt64(Double(Int64.min)),
            Int64.min
        )
    }

    func testMalformedImportedLevelsPreserveRawInstanceWeightAndOverflow() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let malformedVillage = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_002, level: nil, count: 2, path: "1"),
                item(section: "buildings", dataID: 1_000_002, level: 1, count: 3, path: "2"),
            ],
        ])
        let projection = VillageCatalogProjection.project(
            village: malformedVillage,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: try core(states: [
                try state(
                    key: key,
                    imported: .empty,
                    manual: .empty,
                    status: .unknown
                ),
            ])
        )

        let effective = try XCTUnwrap(
            projection.effectiveTrackerItems.first { $0.itemKey == key }
        )
        XCTAssertNil(effective.importedDistribution)
        XCTAssertEqual(effective.importedInstanceWeight, 5)
        XCTAssertFalse(effective.importedCountOverflowed)
        XCTAssertEqual(projection.progressMetrics.instanceProgress.denominator, 5)
        XCTAssertTrue(
            projection.progressMetrics.instanceProgress.degradedReason?.contains("5 个实例") == true
        )
        XCTAssertTrue(
            projection.progressMetrics.effectiveTrackerProgress.degradedReason?.contains("5 个实例") == true
        )

        let exactMaxVillage = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_002, level: nil, count: Int.max, path: "1"),
            ],
        ])
        let exactMaxProjection = VillageCatalogProjection.project(
            village: exactMaxVillage,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: try core(states: [
                try state(
                    key: key,
                    imported: .empty,
                    manual: .empty,
                    status: .unknown
                ),
            ])
        )
        let exactMaxEffective = try XCTUnwrap(
            exactMaxProjection.effectiveTrackerItems.first { $0.itemKey == key }
        )
        XCTAssertEqual(exactMaxEffective.importedInstanceWeight, Int64.max)
        XCTAssertFalse(exactMaxEffective.importedCountOverflowed)
        XCTAssertEqual(exactMaxProjection.progressMetrics.instanceProgress.denominator, Int.max)
        XCTAssertFalse(exactMaxProjection.progressMetrics.instanceProgress.saturated)
        XCTAssertFalse(exactMaxProjection.progressMetrics.effectiveTrackerProgress.saturated)

        let overflowVillage = village(objectSections: [
            "buildings": [
                item(
                    section: "buildings",
                    dataID: 1_000_002,
                    level: 1,
                    count: Int.max,
                    path: "1"
                ),
                item(section: "buildings", dataID: 1_000_002, level: 1, count: 1, path: "2"),
            ],
        ])
        let overflowProjection = VillageCatalogProjection.project(
            village: overflowVillage,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: try core(states: [
                try state(
                    key: key,
                    imported: .empty,
                    manual: .empty,
                    status: .unknown
                ),
            ])
        )
        let overflowEffective = try XCTUnwrap(
            overflowProjection.effectiveTrackerItems.first { $0.itemKey == key }
        )
        XCTAssertEqual(overflowEffective.importedInstanceWeight, Int64.max)
        XCTAssertTrue(overflowEffective.importedCountOverflowed)
        XCTAssertEqual(
            overflowProjection.progressMetrics.instanceProgress.denominator,
            Int.max
        )
        XCTAssertTrue(overflowProjection.progressMetrics.instanceProgress.saturated)
        XCTAssertTrue(overflowProjection.progressMetrics.effectiveTrackerProgress.saturated)
    }

    func testEffectiveMetricPropagatesKnownLevelMultiplicationOverflow() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 1, count: Int.max, path: "1"),
            ],
        ])
        let exactDistribution = try distribution([(1, Int64.max)])
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog(),
            base: .home,
            now: importedAt,
            manualUpgradeCore: try core(states: [
                try state(
                    key: key,
                    imported: exactDistribution,
                    manual: exactDistribution,
                    status: .observed
                ),
            ])
        )

        let metric = projection.progressMetrics.effectiveTrackerProgress
        XCTAssertEqual(metric.numerator, Int.max)
        XCTAssertEqual(metric.denominator, Int.max)
        XCTAssertTrue(metric.saturated)
        XCTAssertNil(metric.ratio)
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
