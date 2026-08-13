import XCTest
@testable import COCHelperCore

/// Issue #144：通用 action projection + filter/search/sort projection 的单元测试。
///
/// fixture 模式与 EffectiveVillageProjectionTests 同构（snapshot + catalog +
/// ManualUpgradeCore → VillageCatalogProjection.project → item）。
final class UpgradeActionProjectionTests: XCTestCase {
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

    // MARK: - Fixtures（与 EffectiveVillageProjectionTests 同构）

    private func distribution(_ values: [(Int, Int64)]) throws -> ManualLevelDistribution {
        try ManualLevelDistribution(levelQuantities: Dictionary(uniqueKeysWithValues: values))
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
        duration: Int64? = 60,
        costs: [CatalogUpgradeCost]? = [CatalogUpgradeCost(
            resource: "Gold", amount: 100, rawResource: "Gold", rawAmount: nil, parseFailed: false
        )],
        missingReason: String? = nil
    ) -> CatalogLevel {
        CatalogLevel(
            level: level,
            durationSeconds: duration,
            upgradeCosts: costs,
            requiredTownHallLevel: townHall,
            requiredLaboratoryLevel: nil,
            icon: nil,
            levelVisual: nil,
            missingReason: missingReason
        )
    }

    private func catalog(
        cannonMaxLevel: Int = 3,
        cannonLevels: [CatalogLevel]? = nil,
        includeCannon: Bool = true,
        sourceFingerprint: String = "sha256:catalog",
        instanceCounts: [String: [Int]]? = nil
    ) -> GameCatalog {
        let cannonItem: [CatalogItem]
        if includeCannon {
            cannonItem = [CatalogItem(
                section: "buildings",
                category: "buildings",
                dataID: 1_000_002,
                base: "home",
                baseMissingReason: nil,
                name: "加农炮",
                maxLevel: cannonMaxLevel,
                icon: nil,
                levelVisual: nil,
                lifecycle: .permanent,
                levels: cannonLevels ?? (1...cannonMaxLevel).map { level($0) }
            )]
        } else {
            cannonItem = []
        }
        let items = [
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
        ] + cannonItem
        return GameCatalog(
            gameVersion: "18.400.13",
            items: items,
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
                        items: items.count,
                        levels: 20 + (cannonLevels?.count ?? (includeCannon ? cannonMaxLevel : 0)),
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
        manual: ManualLevelDistribution = .empty,
        status: ManualItemStatus = .observed
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

    private func cannonProjection(
        objectSections: [String: [AccountItem]],
        catalog: GameCatalog? = nil,
        manualUpgradeCore: ManualUpgradeCore? = nil,
        at now: Date? = nil
    ) -> VillageCatalogProjection {
        VillageCatalogProjection.project(
            village: village(objectSections: objectSections),
            catalog: catalog ?? self.catalog(),
            base: .home,
            now: now ?? importedAt,
            manualUpgradeCore: manualUpgradeCore
        )
    }

    private func cannonItem(_ projection: VillageCatalogProjection) -> VillageItemState {
        projection.items.first { $0.dataID == 1_000_002 }!
    }

    private func action(
        for item: VillageItemState,
        catalog: GameCatalog? = nil,
        manualUpgradeCore: ManualUpgradeCore? = nil,
        coverage: UpgradeActionCoverage = .complete
    ) -> UpgradeAction? {
        UpgradeActionProjection.action(
            for: item,
            catalog: catalog ?? self.catalog(),
            catalogIsUsable: true,
            manualUpgradeCore: manualUpgradeCore,
            coverage: coverage,
            now: importedAt
        )
    }

    // MARK: - Start 可用性

    func testTopLevelRowProducesStartableAction() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: try distribution([(1, 1)])),
        ])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 1, count: 1, path: "1"),
                ],
            ],
            manualUpgradeCore: core
        )
        let action = try XCTUnwrap(action(for: cannonItem(projection), manualUpgradeCore: core))
        XCTAssertEqual(action.itemKey, key)
        XCTAssertEqual(action.fromLevel, 1)
        XCTAssertEqual(action.targetLevel, 2)
        XCTAssertEqual(action.quantity, 1)
        XCTAssertTrue(action.isStartable)
        XCTAssertNil(action.disabledReason)
        XCTAssertEqual(action.baselineReference, baseline)
        XCTAssertEqual(action.durationState, .timed(seconds: 60))
        XCTAssertEqual(action.frozenCosts?.first?.resource, "Gold")
    }

    func testUnknownCostDoesNotBlockStart() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: try distribution([(1, 1)])),
        ])
        // 目标级费用缺失（nil）与解析失败两种 unknown cost 都不阻塞启动。
        let nilCostCatalog = catalog(cannonLevels: [
            level(1, costs: nil),
            level(2, costs: nil),
            level(3, costs: nil),
        ])
        let parseFailedCostCatalog = catalog(cannonLevels: [
            level(1, costs: nil),
            level(2, costs: [CatalogUpgradeCost(
                resource: "DarkElixir", amount: nil,
                rawResource: "Dark Elixir", rawAmount: "not-a-number", parseFailed: true
            )]),
            level(3, costs: nil),
        ])

        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 1, count: 1, path: "1"),
                ],
            ],
            manualUpgradeCore: core
        )
        let item = cannonItem(projection)

        let nilAction = try XCTUnwrap(action(for: item, catalog: nilCostCatalog, manualUpgradeCore: core))
        XCTAssertTrue(nilAction.isStartable)
        XCTAssertTrue(nilAction.diagnostics.contains { $0.contains("费用未知") })

        let parseAction = try XCTUnwrap(action(for: item, catalog: parseFailedCostCatalog, manualUpgradeCore: core))
        XCTAssertTrue(parseAction.isStartable)
        XCTAssertTrue(parseAction.diagnostics.contains { $0.contains("解析失败") })
    }

    func testUnavailableDurationBlocksStart() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: try distribution([(1, 1)])),
        ])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ],
            manualUpgradeCore: core
        )
        let item = cannonItem(projection)
        let missingCatalog = catalog(cannonLevels: [
            level(1, duration: 60),
            level(2, duration: nil, missingReason: "time_missing"),
            level(3, duration: nil, missingReason: "time_missing"),
        ])
        let action = try XCTUnwrap(action(for: item, catalog: missingCatalog, manualUpgradeCore: core))
        XCTAssertFalse(action.isStartable)
        XCTAssertTrue(action.disabledReason?.contains("时长不可用") == true)
    }

    func testGlobalMaxBlocksStart() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: try distribution([(3, 1)])),
        ])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 3, count: 1, path: "1"),
                ],
            ],
            manualUpgradeCore: core
        )
        let action = action(for: cannonItem(projection), manualUpgradeCore: core)
        XCTAssertNotNil(action)
        XCTAssertFalse(action?.isStartable ?? true)
        XCTAssertTrue(action?.disabledReason?.contains("最高等级") == true)
    }

    func testStageMaxBlocksStart() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: try distribution([(1, 1)])),
        ])
        // 加农炮 2 级要求大本营 11；快照大本营 10 → 阶段上限阻塞。
        let gatedCatalog = catalog(cannonLevels: [
            level(1),
            level(2, townHall: 11),
            level(3, townHall: 12),
        ])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 10),
                    item(section: "buildings", dataID: 1_000_002, level: 1, count: 1, path: "1"),
                ],
            ],
            catalog: gatedCatalog,
            manualUpgradeCore: core
        )
        let action = action(for: cannonItem(projection), catalog: gatedCatalog, manualUpgradeCore: core)
        XCTAssertNotNil(action)
        XCTAssertFalse(action?.isStartable ?? true)
        XCTAssertTrue(action?.disabledReason?.contains("阶段上限") == true)
    }

    func testImportedActiveBlocksStart() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: try distribution([(1, 1)])),
        ])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(
                        section: "buildings", dataID: 1_000_002, level: 1,
                        timerSeconds: 100, remainingSeconds: 90, path: "1"
                    ),
                ],
            ],
            manualUpgradeCore: core
        )
        let item = cannonItem(projection)
        XCTAssertEqual(item.effectiveState?.status, .importedActive)
        let action = try XCTUnwrap(action(for: item, manualUpgradeCore: core))
        XCTAssertFalse(action.isStartable)
        XCTAssertTrue(action.disabledReason?.contains("导入计时") == true)
    }

    func testUnknownLocalStateBlocksStart() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: .empty, status: .unknown),
        ])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ],
            manualUpgradeCore: core
        )
        let item = cannonItem(projection)
        XCTAssertEqual(item.effectiveState?.status, .unknown)
        let action = try XCTUnwrap(action(for: item, manualUpgradeCore: core))
        XCTAssertFalse(action.isStartable)
    }

    func testManualActiveRowIsNotStartable() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let manualState = try state(
            key: key,
            imported: try distribution([(1, 1)]),
            manual: try distribution([(1, 1)]),
            status: .manualCompleted
        )
        let activeRecord = try record(
            key: key, from: 1, target: 2,
            expectedEndAt: importedAt.addingTimeInterval(60), startedAt: importedAt
        )
        let core = try self.core(states: [manualState], records: [activeRecord])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 1, count: 1, path: "1"),
                ],
            ],
            manualUpgradeCore: core
        )
        let item = cannonItem(projection)
        XCTAssertEqual(item.effectiveState?.status, .manualActive)
        let action = action(for: item, manualUpgradeCore: core)
        // active 目标已占用 → 不产生可启动的下一级 action。
        XCTAssertNil(action)
    }

    func testNestedItemProducesNoAction() throws {
        let projection = cannonProjection(objectSections: [
            "buildings": [item(section: "buildings", dataID: 1_000_001, level: 11)],
        ])
        // 嵌套项在聚合层带 agg: 前缀且 isNested == true。
        let nested = projection.items.first { $0.isNested }
        XCTAssertNil(nested.map { action(for: $0) } ?? nil)
    }

    func testNoManualCoreStillProducesDisabledAction() throws {
        let projection = cannonProjection(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let action = action(for: cannonItem(projection), manualUpgradeCore: nil)
        XCTAssertNotNil(action)
        XCTAssertFalse(action?.isStartable ?? true)
        XCTAssertTrue(action?.disabledReason?.contains("未提供本地 tracker") == true)
    }

    func testPartialCoverageBlocksStart() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: try distribution([(1, 1)])),
        ])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ],
            manualUpgradeCore: core
        )
        let action = action(for: cannonItem(projection), manualUpgradeCore: core, coverage: .partial)
        XCTAssertNotNil(action)
        XCTAssertFalse(action?.isStartable ?? true)
        XCTAssertTrue(action?.disabledReason?.contains("覆盖") == true)
    }

    // MARK: - Coverage 收窄

    private func coverageItem(
        section: String,
        base: TrackerBase = .home,
        dataID: Int64 = 1_000_002
    ) -> VillageItemState {
        VillageItemState(
            id: section + ":1",
            section: section,
            dataID: dataID,
            base: base,
            name: "测试项目",
            category: .buildings,
            currentLevel: 1,
            count: 1,
            timerSeconds: nil,
            remainingSeconds: nil,
            nextLevel: 2,
            nextLevelDurationSeconds: 60,
            nextLevelDurationState: .timed(seconds: 60),
            maxLevel: 3,
            status: .complete,
            missingReason: nil,
            catalogItemMissingReason: nil,
            availability: .permanent,
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: false
        )
    }

    func testCoverageNarrowing() throws {
        let buildingsItem = coverageItem(section: "buildings")
        let unitsItem = coverageItem(section: "units", dataID: 4_000_001)
        let builderItem = coverageItem(section: "buildings2", base: .builder)

        let complete = ProgressUniverseCoverage.complete
        XCTAssertEqual(
            UpgradeActionProjection.coverage(for: buildingsItem, progressCoverage: complete),
            .complete
        )

        let partialOthers = ProgressUniverseCoverage.partial(
            missingSections: ["units"],
            unmodeledCategories: [.troops]
        )
        // buildings 未缺失 → complete；units 缺失 → partial。
        XCTAssertEqual(
            UpgradeActionProjection.coverage(for: buildingsItem, progressCoverage: partialOthers),
            .complete
        )
        XCTAssertEqual(
            UpgradeActionProjection.coverage(for: unitsItem, progressCoverage: partialOthers),
            .partial
        )

        let unavailable = ProgressUniverseCoverage.unavailable
        XCTAssertEqual(
            UpgradeActionProjection.coverage(for: builderItem, progressCoverage: unavailable),
            .unavailable
        )
    }

    // MARK: - 显示状态

    func testDisplayStateMapping() throws {
        // observed → available
        let observed = cannonProjection(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        XCTAssertEqual(
            UpgradeActionProjection.displayState(of: cannonItem(observed)),
            .available
        )

        // importedActive → importedActive
        let imported = cannonProjection(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(
                    section: "buildings", dataID: 1_000_002, level: 1,
                    timerSeconds: 100, remainingSeconds: 90, path: "1"
                ),
            ],
        ])
        XCTAssertEqual(
            UpgradeActionProjection.displayState(of: cannonItem(imported)),
            .importedActive
        )

        // maxed → completed
        let maxed = cannonProjection(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 3, path: "1"),
            ],
        ])
        XCTAssertEqual(
            UpgradeActionProjection.displayState(of: cannonItem(maxed)),
            .completed
        )

        // 目录未收录 → unknown
        let unknownCatalog = catalog(includeCannon: false)
        let unknown = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ],
            catalog: unknownCatalog
        )
        XCTAssertEqual(
            UpgradeActionProjection.displayState(of: cannonItem(unknown)),
            .unknown
        )
    }

    // MARK: - Filter / Search / Sort

    func testFilterByStateAndCategory() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: try distribution([(1, 1)])),
        ])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(
                        section: "buildings", dataID: 1_000_002, level: 1,
                        timerSeconds: 100, remainingSeconds: 90, path: "1"
                    ),
                ],
            ],
            manualUpgradeCore: core
        )
        let items = projection.items.filter { $0.status != .unavailable && $0.status != .available }

        let importedOnly = UpgradeActionProjection.filtered(
            items,
            filter: UpgradeDisplayFilter(state: .importedActive),
            at: importedAt
        )
        XCTAssertEqual(importedOnly.map(\.dataID), [1_000_002])

        let buildingsOnly = UpgradeActionProjection.filtered(
            items,
            filter: UpgradeDisplayFilter(category: .buildings),
            at: importedAt
        )
        XCTAssertEqual(Set(buildingsOnly.map(\.dataID)), Set([1_000_001, 1_000_002]))
    }

    func testTextSearchMatchesNameAndRawIdentity() throws {
        let projection = cannonProjection(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let items = projection.items.filter { $0.status != .unavailable && $0.status != .available }

        let byName = UpgradeActionProjection.filtered(
            items,
            filter: UpgradeDisplayFilter(text: "加农炮"),
            at: importedAt
        )
        XCTAssertEqual(byName.map(\.dataID), [1_000_002])

        let byDataID = UpgradeActionProjection.filtered(
            items,
            filter: UpgradeDisplayFilter(text: "1000001"),
            at: importedAt
        )
        XCTAssertEqual(byDataID.map(\.dataID), [1_000_001])

        let noMatch = UpgradeActionProjection.filtered(
            items,
            filter: UpgradeDisplayFilter(text: "不存在的名字"),
            at: importedAt
        )
        XCTAssertTrue(noMatch.isEmpty)
    }

    func testSortByRemainingThenNameDeterministic() throws {
        // 两个 active 行（不同村庄基地投影不必；直接构造不同 remaining）。
        let a = cannonProjection(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(
                    section: "buildings", dataID: 1_000_002, level: 1,
                    timerSeconds: 200, remainingSeconds: 200, path: "1"
                ),
            ],
        ])
        let b = cannonProjection(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 11),
                item(
                    section: "buildings", dataID: 1_000_002, level: 1,
                    timerSeconds: 100, remainingSeconds: 100, path: "1"
                ),
            ],
        ])
        let items = [cannonItem(a), cannonItem(b)]
        let sorted = UpgradeActionProjection.filtered(
            items,
            filter: UpgradeDisplayFilter(sort: .remaining),
            at: importedAt
        )
        XCTAssertEqual(
            sorted.map { $0.effectiveRemainingSeconds(at: importedAt) },
            [100, 200]
        )
    }

    func testSortByLevelAndRecentlyChanged() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let activeRecord = try record(
            key: key, from: 1, target: 2,
            expectedEndAt: importedAt.addingTimeInterval(90),
            startedAt: importedAt.addingTimeInterval(-10)
        )
        let manualState = try state(
            key: key,
            imported: try distribution([(1, 1)]),
            manual: try distribution([(1, 1)]),
            status: .manualCompleted
        )
        let core = try self.core(states: [manualState], records: [activeRecord])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ],
            manualUpgradeCore: core
        )
        let items = projection.items.filter { $0.status != .unavailable && $0.status != .available }
        XCTAssertEqual(items.count, 2)

        // 等级升序：大本营 11 在前。
        let byLevel = UpgradeActionProjection.filtered(
            items,
            filter: UpgradeDisplayFilter(sort: .level),
            at: importedAt
        )
        XCTAssertEqual(byLevel.map(\.dataID), [1_000_002, 1_000_001])

        // recentlyChanged：有 manual active 记录的行优先。
        let byRecent = UpgradeActionProjection.filtered(
            items,
            filter: UpgradeDisplayFilter(sort: .recentlyChanged),
            at: importedAt
        )
        XCTAssertEqual(byRecent.first?.dataID, 1_000_002)
    }

    // MARK: - Group action 适配

    func testGroupActionConversionKeepsQuantityOne() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let core = try self.core(states: [
            try state(key: key, imported: try distribution([(1, 2)])),
        ])
        // 组 action 需要 home buildings scope 覆盖完整（universe 数据 + TH 在范围内）。
        let universeCatalog = catalog(instanceCounts: [
            "buildings:1000002": Array(repeating: 2, count: 18),
        ])
        let projection = cannonProjection(
            objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 11),
                    item(section: "buildings", dataID: 1_000_002, level: 1, count: 2, path: "1"),
                ],
            ],
            catalog: universeCatalog,
            manualUpgradeCore: core
        )
        let groups = BuildingGroupProjection.project(
            projection: projection,
            catalog: universeCatalog,
            base: .home,
            manualUpgradeCore: core
        )
        let group = try XCTUnwrap(groups.first { $0.dataID == 1_000_002 })
        let actions = UpgradeActionProjection.actions(for: group, catalog: catalog())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].fromLevel, 1)
        XCTAssertEqual(actions[0].targetLevel, 2)
        XCTAssertEqual(actions[0].quantity, 1)
        XCTAssertTrue(actions[0].isStartable)
        XCTAssertEqual(actions[0].itemKey, key)
        XCTAssertEqual(actions[0].baselineReference, baseline)
    }
}
