import XCTest
@testable import COCHelperCore

/// Issue #144：UpgradeOverviewState（面板计数、7 天最近完成、冲突/未知行）。
///
/// 注意：投影使用真实 bundled 目录（18.400.13）。buildings:1000002 是
/// 圣水收集器（Elixir Collector）；手动记录 provenance 必须用真实 manifest
///（buildTag/sourceFingerprint），否则 activeCatalogDiagnostic 把状态降级 unknown。
final class UpgradeOverviewStateTests: XCTestCase {
    private let importedAt = Date(timeIntervalSince1970: 1_000)
    private let baseline = ManualBaselineReference(
        revision: "snapshot-1",
        fingerprint: "sha256:snapshot",
        lineageID: "village-1"
    )

    private var catalog: GameCatalog { GameCatalog.loadBundled()! }
    private var provenance: ManualCatalogProvenance {
        ManualCatalogProvenance(catalog: catalog)
    }

    /// 真实目录 1000002（圣水收集器）2 级时长。
    private var targetLevel2Duration: Int64 {
        catalog.item(section: "buildings", dataID: 1_000_002)!.levels.first { $0.level == 2 }!.durationSeconds!
    }

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

    private func village(objectSections: [String: [AccountItem]]) -> VillageProfile {
        VillageProfile(name: "测试村庄", accountSnapshot: snapshot(objectSections: objectSections))
    }

    private func item(
        section: String,
        dataID: Int64,
        level: Int?,
        count: Int? = 1,
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

    private func state(
        key: TrackerItemKey,
        level: Int,
        quantity: Int64 = 1,
        status: ManualItemStatus = .observed
    ) throws -> ManualItemState {
        try ManualItemState(
            itemKey: key,
            baselineReference: baseline,
            importedObservation: ManualImportedObservation(
                reference: baseline,
                levelDistribution: try distribution([(level, quantity)]),
                sourceTimestamp: importedAt
            ),
            manualCompletedDistribution: status == .manualCompleted
                ? try distribution([(level + 1, quantity)])
                : .empty,
            status: status
        )
    }

    private func homeVillage(withTimer: Bool) -> VillageProfile {
        village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                withTimer
                    ? item(
                        section: "buildings", dataID: 1_000_002, level: 1,
                        timerSeconds: 100, remainingSeconds: 90, path: "1"
                    )
                    : item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
    }

    /// 村庄 A：manual active（1 条进行中，时长/来源与真实目录一致）+ 1 条已完成的记录。
    /// 村庄 B：imported active（纯导入计时，空 manual core）。
    private func makeScenario() throws -> (villages: [VillageProfile], cores: [UUID: ManualUpgradeCore]) {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let villageA = homeVillage(withTimer: false)
        var coreA = try ManualUpgradeCore(itemStates: [
            try state(key: key, level: 1, quantity: 2),
        ])
        _ = try coreA.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: importedAt,
            durationState: .timed(seconds: targetLevel2Duration),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: importedAt
        )
        // 第二条：即时 → 立即 settle 进 completedHistory。
        _ = try coreA.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: importedAt.addingTimeInterval(-200),
            durationState: .instant,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: importedAt
        )

        let villageB = homeVillage(withTimer: true)
        let coreB = try ManualUpgradeCore()
        return ([villageA, villageB], [villageA.id: coreA, villageB.id: coreB])
    }

    // MARK: - 计数

    func testCountsAreSeparatedByRecordAndDisplayRow() throws {
        let (villages, cores) = try makeScenario()
        let state = UpgradeOverviewProjection.overviewState(
            from: villages,
            catalog: catalog,
            manualUpgradeCores: cores,
            at: importedAt
        )
        // 1 条 manual active 记录（A 村）。
        XCTAssertEqual(state.manualActiveCount, 1)
        // 1 条 imported active 行（B 村）。
        XCTAssertEqual(state.importedActiveCount, 1)
        // 2 条 active 展示行。
        XCTAssertEqual(state.deduplicatedDisplayCount, 2)
        // 1 条 manual completed 记录（A 村 instant settle）。
        XCTAssertEqual(state.manualCompletedCount, 1)
    }

    func testExactMatchMergesDisplayRowButKeepsBothCounts() throws {
        // 同一实例同时有 imported timer 与 exact manual record → 一行合并。
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let duration = targetLevel2Duration
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(
                    section: "buildings", dataID: 1_000_002, level: 1,
                    timerSeconds: duration + 10, remainingSeconds: duration, path: "1"
                ),
            ],
        ])
        var core = try ManualUpgradeCore(itemStates: [
            try state(key: key, level: 1),
        ])
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: importedAt,
            durationState: .timed(seconds: duration),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: importedAt
        )
        let state = UpgradeOverviewProjection.overviewState(
            from: [village],
            catalog: catalog,
            manualUpgradeCores: [village.id: core],
            at: importedAt
        )
        XCTAssertEqual(state.manualActiveCount, 1)
        XCTAssertEqual(state.importedActiveCount, 1)
        // exact match 合并为 1 行展示。
        XCTAssertEqual(state.deduplicatedDisplayCount, 1)
        let row = try XCTUnwrap(state.activeRecords.first)
        XCTAssertEqual(row.item.effectiveState?.status, .manualActive)
        XCTAssertTrue(row.item.effectiveState?.provenance.contains(.manualActive) == true)
        XCTAssertTrue(row.item.effectiveState?.provenance.contains(.importedActive) == true)
    }

    // MARK: - 最近完成

    func testCompletedRecentlyOnlyWithinSevenDays() throws {
        let (villages, cores) = try makeScenario()
        let now = importedAt.addingTimeInterval(6 * 24 * 3600)
        let recent = UpgradeOverviewProjection.overviewState(
            from: villages,
            catalog: catalog,
            manualUpgradeCores: cores,
            at: now
        )
        XCTAssertEqual(recent.completedRecently.count, 1)

        // 超过 7 天 → 不进入最近完成（但仍计入 manualCompletedCount）。
        let later = now.addingTimeInterval(2 * 24 * 3600)
        let stale = UpgradeOverviewProjection.overviewState(
            from: villages,
            catalog: catalog,
            manualUpgradeCores: cores,
            at: later
        )
        XCTAssertTrue(stale.completedRecently.isEmpty)
        XCTAssertEqual(stale.manualCompletedCount, 1)
    }

    func testCompletedRecentlySortedDescending() throws {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let village = homeVillage(withTimer: false)
        var core = try ManualUpgradeCore(itemStates: [
            try state(key: key, level: 1, quantity: 2),
        ])
        // 两条即时记录，完成时间不同（expectedEndAt = startedAt）。
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: importedAt.addingTimeInterval(-400),
            durationState: .instant,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: importedAt
        )
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: importedAt.addingTimeInterval(-200),
            durationState: .instant,
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: importedAt
        )
        let state = UpgradeOverviewProjection.overviewState(
            from: [village],
            catalog: catalog,
            manualUpgradeCores: [village.id: core],
            at: importedAt
        )
        XCTAssertEqual(state.completedRecently.count, 2)
        // 最近完成的在前（完成时间降序）。
        XCTAssertGreaterThan(
            state.completedRecently[0].completedAt,
            state.completedRecently[1].completedAt
        )
    }

    // MARK: - 同 key 多行去重（review P2）

    func testSameStableIdentityMultipleRowsDeduplicated() throws {
        // 同一 key（加农炮）两条不同等级的行都带导入计时 → 共享同一 effective
        // state（importedActive），active 展示 2 行但去重计数应为 1。
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(
                    section: "buildings", dataID: 1_000_002, level: 1,
                    timerSeconds: 100, remainingSeconds: 90, path: "1"
                ),
                item(
                    section: "buildings", dataID: 1_000_002, level: 2,
                    timerSeconds: 100, remainingSeconds: 90, path: "2"
                ),
            ],
        ])
        let core = try ManualUpgradeCore()
        let state = UpgradeOverviewProjection.overviewState(
            from: [village],
            catalog: catalog,
            manualUpgradeCores: [village.id: core],
            at: importedAt
        )
        XCTAssertEqual(state.activeRecords.count, 2)
        XCTAssertEqual(state.deduplicatedDisplayCount, 1)
        XCTAssertEqual(state.importedActiveCount, 1)
    }

    // MARK: - 冲突 / 未知行

    func testAttentionRowsAreListedNotHidden() throws {
        // manual 记录时长与目录一致但 imported timer 剩余不匹配 → conflict 行并列显示。
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let duration = targetLevel2Duration
        let village = village(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(
                    section: "buildings", dataID: 1_000_002, level: 1,
                    timerSeconds: 100, remainingSeconds: 10, path: "1"
                ),
            ],
        ])
        var core = try ManualUpgradeCore(itemStates: [
            try state(key: key, level: 1),
        ])
        _ = try core.startUpgrade(
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: importedAt,
            durationState: .timed(seconds: duration),
            frozenCosts: nil,
            catalogProvenance: provenance,
            baselineReference: baseline,
            now: importedAt
        )
        let state = UpgradeOverviewProjection.overviewState(
            from: [village],
            catalog: catalog,
            manualUpgradeCores: [village.id: core],
            at: importedAt
        )
        XCTAssertFalse(state.attentionRecords.isEmpty)
        XCTAssertTrue(
            state.attentionRecords.contains {
                $0.item.effectiveState?.status == .conflict
            }
        )
        // conflict 行在 attentionRecords 并列展示（不隐藏导入事实）；provenance 双保留。
        let conflict = try XCTUnwrap(state.attentionRecords.first {
            $0.item.effectiveState?.status == .conflict
        })
        XCTAssertTrue(conflict.item.effectiveState?.provenance.contains(.manualActive) == true)
        XCTAssertTrue(conflict.item.effectiveState?.provenance.contains(.importedActive) == true)
    }
}
