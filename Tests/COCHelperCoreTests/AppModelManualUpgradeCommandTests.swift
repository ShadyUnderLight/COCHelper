import XCTest
@testable import COCHelperCore
@testable import COCHelperApp

/// Issue #144：AppModel 类型化 Start/Cancel/Adjust 命令与执行前复核。
///
/// 命令必须：显式 villageID 路由；执行前重新验证 action/village/baseline/
/// 存储状态；不能信任 UI 旧 action；unknown cost 不阻塞；存储不可用时禁用。
/// 注意：AppModel 复核使用真实 bundled 目录（18.400.13），fixture 必须与
/// 真实目录一致（TH 18 解锁全部门槛、真实时长/费用）。
/// 注意：setUp/tearDown 是非隔离的 XCTestCase 生命周期方法，不能触碰
/// @MainActor 属性；类不标 @MainActor，涉及 AppModel 的方法单独标（项目惯例）。
final class AppModelManualUpgradeCommandTests: XCTestCase {
    private var suiteName: String!
    private var store: FileManualTrackerStore!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelManualUpgradeCommandTests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("manual-tracker-v1.json")
        store = FileManualTrackerStore(fileURL: storeURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        )
        super.tearDown()
    }

    private let importedAt = Date(timeIntervalSince1970: 1_000)

    /// 真实 bundled 目录（AppModel.gameCatalog 同源）。
    private var catalog: GameCatalog {
        GameCatalog.loadBundled()!
    }

    private func snapshot(
        tag: String = "#TEST",
        objectSections: [String: [AccountItem]]
    ) -> AccountSnapshot {
        AccountSnapshot(
            tag: tag,
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

    private func item(
        section: String,
        dataID: Int64,
        level: Int?,
        count: Int? = 1,
        path: String = "0"
    ) -> AccountItem {
        AccountItem(
            id: section + ":" + path,
            section: section,
            dataID: dataID,
            level: level,
            count: count,
            timerSeconds: nil,
            remainingSeconds: nil
        )
    }

    /// 真实目录加农炮（buildings:1000002）目标级时长。
    private func cannonLevel2Duration() throws -> Int64 {
        let level = try XCTUnwrap(
            catalog.item(section: "buildings", dataID: 1_000_002)?.levels.first { $0.level == 2 }
        )
        return try XCTUnwrap(level.durationSeconds)
    }

    /// 构造可启动村庄 + 安装 observed itemState（模拟真实导入后的状态）+ 最新 action。
    @MainActor
    private func makeModel(
        dataID: Int64 = 1_000_002,
        level: Int = 1,
        now: Date? = nil
    ) throws -> (model: AppModel, villageID: UUID, action: UpgradeAction) {
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: dataID, level: level, path: "1"),
            ],
        ])
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        try Self.installObservedState(
            in: model, villageID: villageID, dataID: dataID, level: level, history: history
        )
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            base: .home,
            now: now ?? importedAt,
            manualUpgradeCore: core
        )
        let target = try XCTUnwrap(projection.items.first { $0.dataID == dataID })
        let action = try XCTUnwrap(
            UpgradeActionProjection.action(
                for: target,
                catalog: catalog,
                catalogIsUsable: true,
                manualUpgradeCore: core,
                coverage: .complete,
                now: now ?? importedAt
            )
        )
        XCTAssertTrue(action.isStartable, "fixture must produce startable action: \(action.disabledReason ?? "")")
        return (model, villageID, action)
    }

    /// 按当前 history baseline 安装 observed itemState。
    @MainActor
    private static func installObservedState(
        in model: AppModel,
        villageID: UUID,
        dataID: Int64,
        level: Int,
        history: TestSnapshotHistoryStore,
        observedTimer: Bool = false
    ) throws {
        try installObservedStates(
            in: model, villageID: villageID, dataIDs: [dataID], levels: [level],
            history: history, observedTimer: observedTimer
        )
    }

    /// 批量安装多个 observed itemState（一次 updateManualUpgradeCore，避免
    /// 单条安装互相覆盖 core）。
    @MainActor
    private static func installObservedStates(
        in model: AppModel,
        villageID: UUID,
        dataIDs: [Int64],
        levels: [Int],
        history: TestSnapshotHistoryStore,
        observedTimer: Bool = false
    ) throws {
        let section = "buildings"
        let lineage = try XCTUnwrap(try history.load()?.activeLineage(for: villageID))
        let entry = try XCTUnwrap(try history.load()?.entry(id: lineage.lastEntryID))
        let currentBaseline = ManualBaselineReference(
            revision: entry.snapshotID.uuidString,
            fingerprint: entry.canonicalFingerprint,
            lineageID: entry.lineageID.uuidString
        )
        let states = try zip(dataIDs, levels).map { dataID, level in
            try ManualItemState(
                itemKey: TrackerItemKey.root(base: .home, rawSection: section, dataID: dataID),
                baselineReference: currentBaseline,
                importedObservation: ManualImportedObservation(
                    reference: currentBaseline,
                    levelDistribution: try ManualLevelDistribution(levelQuantities: [level: 1]),
                    sourceTimestamp: Date(timeIntervalSince1970: 1_000),
                    observedTimer: observedTimer,
                    observedTimerCoverageComplete: observedTimer
                ),
                manualCompletedDistribution: .empty,
                status: .observed
            )
        }
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try ManualUpgradeCore(itemStates: states)
        }
    }

    // MARK: - Start

    @MainActor
    func testStartManualUpgradePersistsActiveRecord() throws {
        let (model, villageID, action) = try makeModel()
        let record = try model.startManualUpgrade(
            for: villageID,
            action: action,
            startedAt: importedAt,
            now: importedAt
        )
        XCTAssertEqual(record.status, .active)
        XCTAssertEqual(record.itemKey, action.itemKey)
        XCTAssertEqual(record.fromLevel, 1)
        XCTAssertEqual(record.targetLevel, 2)
        XCTAssertEqual(record.quantity, 1)
        XCTAssertEqual(record.durationSeconds, try cannonLevel2Duration())
        XCTAssertEqual(record.frozenCosts?.first?.resource, "Gold")

        // 持久化：重新加载同一 store 后 active 记录仍在。
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let reloaded = AppModel(
            defaults: UserDefaults(suiteName: suiteName)!,
            historyStore: TestSnapshotHistoryStore(),
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([
                    VillageProfile(name: "测试村庄", accountSnapshot: snapshot),
                ])
            )
        )
        XCTAssertEqual(reloaded.manualUpgradeCore(for: villageID)?.activeRecords.count, 1)
    }

    @MainActor
    func testStartWithStaleActionRejected() throws {
        let (model, villageID, action) = try makeModel()
        // 先启动一次 → action 已过期（同一 fromLevel 已被 active 占用）。
        _ = try model.startManualUpgrade(
            for: villageID,
            action: action,
            startedAt: importedAt,
            now: importedAt
        )
        XCTAssertThrowsError(try model.startManualUpgrade(
            for: villageID,
            action: action,
            startedAt: importedAt,
            now: importedAt
        )) { error in
            guard case ManualUpgradeCommandError.staleAction = error else {
                return XCTFail("expected staleAction, got \(error)")
            }
        }
    }

    @MainActor
    func testStartWithUnknownCostAccepted() throws {
        // 确认面板展示 unknown cost；命令不因成本阻塞（成本只是本地记录事实）。
        let (model, villageID, action) = try makeModel()
        let unknownCostAction = UpgradeAction(
            itemKey: action.itemKey,
            itemName: action.itemName,
            base: action.base,
            fromLevel: action.fromLevel,
            targetLevel: action.targetLevel,
            quantity: action.quantity,
            durationState: action.durationState,
            frozenCosts: nil,
            catalogProvenance: action.catalogProvenance,
            baselineReference: action.baselineReference,
            isStartable: true,
            disabledReason: nil,
            diagnostics: ["目标升级费用未知，启动时保留 unknown cost 状态。"]
        )
        let record = try model.startManualUpgrade(
            for: villageID,
            action: unknownCostAction,
            startedAt: importedAt,
            now: importedAt
        )
        XCTAssertEqual(record.status, .active)
        // 复核用最新投影的冻结成本（非 UI 传入的 nil）。
        XCTAssertEqual(record.frozenCosts?.first?.resource, "Gold")
    }

    @MainActor
    func testStartRejectsVillageMismatch() throws {
        let (model, _, action) = try makeModel()
        XCTAssertThrowsError(try model.startManualUpgrade(
            for: UUID(),
            action: action,
            startedAt: importedAt,
            now: importedAt
        )) { error in
            guard case ManualUpgradeCommandError.villageMissing = error else {
                return XCTFail("expected villageMissing, got \(error)")
            }
        }
    }

    @MainActor
    func testStartRejectedWhenStoreUnavailable() throws {
        // 损坏 store → manualTrackerStatus unavailable → 写操作禁用。
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let villagesData = try JSONEncoder().encode([
            VillageProfile(name: "测试村庄", accountSnapshot: snapshot),
        ])
        try Data("corrupt".utf8).write(to: storeURL)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            defaults: defaults,
            historyStore: TestSnapshotHistoryStore(),
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData)
        )
        XCTAssertEqual(model.manualTrackerStatus, .unavailable)
        let villageID = try XCTUnwrap(model.villages.first?.id)
        // 用独立健康 store 产出的 action 调用损坏模型：storeUnavailable 必须最先触发。
        let healthyURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("manual-tracker-healthy.json")
        let healthyStore = FileManualTrackerStore(fileURL: healthyURL)
        let healthyDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("healthy")
        try? FileManager.default.createDirectory(at: healthyDirectory, withIntermediateDirectories: true)
        let (_, _, action) = try makeModelWithStore(
            store: healthyStore,
            journalURL: healthyDirectory.appendingPathComponent("journal.json")
        )
        XCTAssertThrowsError(try model.startManualUpgrade(
            for: villageID,
            action: action,
            startedAt: importedAt,
            now: importedAt
        )) { error in
            guard case ManualUpgradeCommandError.storeUnavailable = error else {
                return XCTFail("expected storeUnavailable, got \(error)")
            }
        }
    }

    /// 用真实城墙（instant）验证：确认后立即 completed，不出现负倒计时。
    @MainActor
    func testInstantUpgradeCompletesImmediately() throws {
        let (model, villageID, action) = try makeModel(dataID: 1_000_010, level: 1)
        XCTAssertEqual(action.durationState, .instant)
        let record = try model.startManualUpgrade(
            for: villageID,
            action: action,
            startedAt: importedAt,
            now: importedAt
        )
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.durationSeconds, 0)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID)?.activeRecords.count, 0)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID)?.completedHistory.count, 1)
    }

    // MARK: - Cancel / Adjust

    @MainActor
    func testCancelManualUpgrade() throws {
        let (model, villageID, action) = try makeModel()
        let record = try model.startManualUpgrade(
            for: villageID, action: action, startedAt: importedAt, now: importedAt
        )
        let cancelled = try model.cancelManualUpgrade(for: villageID, recordID: record.recordID)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID)?.activeRecords.count, 0)

        // 重复取消 → recordNotActive。
        XCTAssertThrowsError(try model.cancelManualUpgrade(for: villageID, recordID: record.recordID)) { error in
            guard case ManualUpgradeCommandError.recordNotActive = error else {
                return XCTFail("expected recordNotActive, got \(error)")
            }
        }
    }

    @MainActor
    func testAdjustStartTimeSettlesThroughSamePath() throws {
        let (model, villageID, action) = try makeModel()
        let record = try model.startManualUpgrade(
            for: villageID, action: action, startedAt: importedAt, now: importedAt
        )
        // 调整到过去足够远：expectedEndAt 提前 → 立即 settle 为 completed。
        let duration = Double(try cannonLevel2Duration())
        let adjusted = try model.adjustManualUpgradeStart(
            for: villageID,
            recordID: record.recordID,
            startedAt: importedAt.addingTimeInterval(-(duration + 10)),
            now: importedAt
        )
        XCTAssertEqual(adjusted.status, .completed)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID)?.activeRecords.count, 0)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID)?.completedHistory.count, 1)
    }

    @MainActor
    func testAdjustRejectsFutureStart() throws {
        let (model, villageID, action) = try makeModel()
        let record = try model.startManualUpgrade(
            for: villageID, action: action, startedAt: importedAt, now: importedAt
        )
        XCTAssertThrowsError(try model.adjustManualUpgradeStart(
            for: villageID,
            recordID: record.recordID,
            startedAt: importedAt.addingTimeInterval(100),
            now: importedAt
        )) { error in
            guard case ManualUpgradeCommandError.invalidTime = error else {
                return XCTFail("expected invalidTime, got \(error)")
            }
        }
    }

    @MainActor
    func testTwoVillagesDoNotCrossRoute() throws {
        // 村庄 A 启动 → 村庄 B 无 active 记录；B 的命令不影响 A。
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let snapshotA = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let snapshotB = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 2, path: "1"),
            ],
        ])
        let villagesData = try JSONEncoder().encode([
            VillageProfile(name: "A", accountSnapshot: snapshotA),
            VillageProfile(name: "B", accountSnapshot: snapshotB),
        ])
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        let villageA = model.villages[0]
        let villageB = model.villages[1]
        try Self.installObservedState(in: model, villageID: villageA.id, dataID: 1_000_002, level: 1, history: history)
        try Self.installObservedState(in: model, villageID: villageB.id, dataID: 1_000_002, level: 2, history: history)

        func action(for village: VillageProfile, core: ManualUpgradeCore) throws -> UpgradeAction {
            let projection = VillageCatalogProjection.project(
                village: village, catalog: catalog, base: .home,
                now: importedAt, manualUpgradeCore: core
            )
            let cannon = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_002 })
            return try XCTUnwrap(UpgradeActionProjection.action(
                for: cannon, catalog: catalog, catalogIsUsable: true,
                manualUpgradeCore: core, coverage: .complete, now: importedAt
            ))
        }

        let coreA = try XCTUnwrap(model.manualUpgradeCore(for: villageA.id))
        _ = try model.startManualUpgrade(
            for: villageA.id,
            action: try action(for: villageA, core: coreA),
            startedAt: importedAt,
            now: importedAt
        )
        XCTAssertEqual(model.manualUpgradeCore(for: villageA.id)?.activeRecords.count, 1)
        XCTAssertTrue(model.manualUpgradeCore(for: villageB.id)?.activeRecords.isEmpty == true)

        let coreB = try XCTUnwrap(model.manualUpgradeCore(for: villageB.id))
        _ = try model.startManualUpgrade(
            for: villageB.id,
            action: try action(for: villageB, core: coreB),
            startedAt: importedAt,
            now: importedAt
        )
        XCTAssertEqual(model.manualUpgradeCore(for: villageB.id)?.activeRecords.count, 1)
        XCTAssertEqual(model.manualUpgradeCore(for: villageA.id)?.activeRecords.count, 1)
    }

    // MARK: - 组 action（review P1-2）

    /// 构造可启动的组场景 + 组 action（sourceKind == .group）。
    @MainActor
    private func makeGroupModel(
        rows: [(level: Int, count: Int)]
    ) throws -> (model: AppModel, villageID: UUID, groupActions: [UpgradeAction]) {
        let cannonRows = rows.enumerated().map { index, row in
            item(
                section: "buildings", dataID: 1_000_002,
                level: row.level, count: row.count, path: String(index + 1)
            )
        }
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
            ] + cannonRows,
        ])
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        // 安装 observed itemState（分布 = 各行 count 汇总）。
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let quantities = Dictionary(rows.map { ($0.level, Int64($0.count)) }, uniquingKeysWith: +)
        let lineage = try XCTUnwrap(try history.load()?.activeLineage(for: villageID))
        let entry = try XCTUnwrap(try history.load()?.entry(id: lineage.lastEntryID))
        let currentBaseline = ManualBaselineReference(
            revision: entry.snapshotID.uuidString,
            fingerprint: entry.canonicalFingerprint,
            lineageID: entry.lineageID.uuidString
        )
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try ManualUpgradeCore(itemStates: [
                ManualItemState(
                    itemKey: key,
                    baselineReference: currentBaseline,
                    importedObservation: ManualImportedObservation(
                        reference: currentBaseline,
                        levelDistribution: try ManualLevelDistribution(levelQuantities: quantities),
                        sourceTimestamp: Date(timeIntervalSince1970: 1_000)
                    ),
                    manualCompletedDistribution: .empty,
                    status: .observed
                ),
            ])
        }
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let projection = VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home,
            now: importedAt, manualUpgradeCore: core
        )
        let groups = BuildingGroupProjection.project(
            projection: projection, catalog: catalog, base: .home, manualUpgradeCore: core
        )
        let group = try XCTUnwrap(groups.first { $0.dataID == 1_000_002 })
        let actions = UpgradeActionProjection.actions(for: group, catalog: catalog)
        XCTAssertFalse(actions.isEmpty)
        XCTAssertTrue(actions.allSatisfy { $0.sourceKind == .group })
        XCTAssertTrue(actions.contains(where: \.isStartable))
        return (model, villageID, actions)
    }

    /// review P1-2：组已有 active 记录后，剩余数量仍可 Start（不 stale）。
    @MainActor
    func testGroupStartRemainingQuantityAfterActiveRecord() throws {
        let (model, villageID, actions) = try makeGroupModel(rows: [(1, 2)])
        let first = try XCTUnwrap(actions.first { $0.isStartable })
        let record = try model.startManualUpgrade(
            for: villageID, action: first, startedAt: importedAt, now: importedAt
        )
        XCTAssertEqual(record.status, .active)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID)?.activeRecords.count, 1)

        // 重新取组 action：剩余 1 个实例仍可启动（普通行路径在此场景会因
        // .manualActive 返回 nil → staleAction；组路径必须放行）。
        let village = try XCTUnwrap(model.villages.first { $0.id == villageID })
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let projection = VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home,
            now: importedAt, manualUpgradeCore: core
        )
        let groups = BuildingGroupProjection.project(
            projection: projection, catalog: catalog, base: .home, manualUpgradeCore: core
        )
        let group = try XCTUnwrap(groups.first { $0.dataID == 1_000_002 })
        let refreshed = UpgradeActionProjection.actions(for: group, catalog: catalog)
        let second = try XCTUnwrap(refreshed.first { $0.fromLevel == first.fromLevel && $0.isStartable })
        let secondRecord = try model.startManualUpgrade(
            for: villageID, action: second, startedAt: importedAt, now: importedAt
        )
        XCTAssertEqual(secondRecord.status, .active)
        XCTAssertEqual(model.manualUpgradeCore(for: villageID)?.activeRecords.count, 2)
    }

    /// review P1-2：混合等级组按 fromLevel 启动（不被普通行投影抹平）。
    @MainActor
    func testMixedLevelGroupStartPreservesFromLevel() throws {
        let (model, villageID, actions) = try makeGroupModel(rows: [(1, 1), (2, 1)])
        // 混合分布 [(1,1),(2,1)] → 组 actions 含 from 1 与 from 2。
        let fromTwo = try XCTUnwrap(actions.first { $0.fromLevel == 2 && $0.isStartable })
        let record = try model.startManualUpgrade(
            for: villageID, action: fromTwo, startedAt: importedAt, now: importedAt
        )
        XCTAssertEqual(record.status, .active)
        XCTAssertEqual(record.fromLevel, 2)
        XCTAssertEqual(record.targetLevel, 3)
    }

    // MARK: - Helpers

    /// makeModel 的 store 可替换版本（store-unavailable 测试用独立健康 store）。
    @MainActor
    private func makeModelWithStore(
        store healthyStore: FileManualTrackerStore,
        journalURL: URL
    ) throws -> (model: AppModel, villageID: UUID, action: UpgradeAction) {
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let defaults = UserDefaults(suiteName: suiteName)!
        let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: healthyStore,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: journalURL
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        try Self.installObservedState(
            in: model, villageID: villageID, dataID: 1_000_002, level: 1, history: history
        )
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let projection = VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home,
            now: importedAt, manualUpgradeCore: core
        )
        let cannon = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_002 })
        let action = try XCTUnwrap(UpgradeActionProjection.action(
            for: cannon, catalog: catalog, catalogIsUsable: true,
            manualUpgradeCore: core, coverage: .complete, now: importedAt
        ))
        XCTAssertTrue(action.isStartable)
        return (model, villageID, action)
    }

    // MARK: - Issue #170：未对账基线命令 fail-closed

    /// 用真实 canonicalizer 生成合法 history entry（fingerprint/integrity 与
    /// observation 一致，通过 `SnapshotHistoryEnvelope.validated()`）。
    /// rawJSON 仅含 tag（无 item），entry 的身份字段是唯一用途。
    private func makeHistoryEntry(
        tag: String,
        villageID: UUID,
        lineageID: UUID,
        appliedAt: Date,
        isBaseline: Bool = false
    ) throws -> SnapshotHistoryEntry {
        let snapshot = try AccountSnapshotImporter.parse(
            "{\"tag\":\"\(tag)\",\"buildings\":[]}",
            now: appliedAt
        )
        return try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: appliedAt,
            isBaseline: isBaseline,
            baselineReason: isBaseline ? .initial : nil,
            catalog: catalog,
            craftTableCatalog: CraftTableCatalog.loadBundled()
        )
    }

    /// 构造一个村庄的 manual core：绑定 `baselineReference` 的 observed item
    /// state + 一条 active record（from 1 → 2）。`startedAt` 相对现在偏移
    /// `startedAtOffset` 秒，duration `durationSeconds`，保证 record 在
    /// `Date()` 时未到期（启动时的自动 settle 不触发），由测试显式推进时间。
    private func makeBoundCore(
        baselineReference: ManualBaselineReference,
        recordID: UUID,
        startedAtOffset: TimeInterval = -2_000,
        durationSeconds: Int64 = 5_000
    ) throws -> ManualUpgradeCore {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let startedAt = Date(timeIntervalSinceNow: startedAtOffset)
        let record = try ManualUpgradeRecord(
            recordID: recordID,
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: startedAt,
            expectedEndAt: startedAt.addingTimeInterval(TimeInterval(durationSeconds)),
            durationSeconds: durationSeconds,
            durationKind: .timed,
            frozenCosts: nil,
            catalogProvenance: ManualCatalogProvenance(catalog: catalog),
            baselineReference: baselineReference,
            status: .active
        )
        let state = try ManualItemState(
            itemKey: key,
            baselineReference: baselineReference,
            manualCompletedDistribution: try ManualLevelDistribution(levelQuantities: [1: 2]),
            status: .manualCompleted
        )
        return try ManualUpgradeCore(itemStates: [state], records: [record])
    }

    /// 只有 observed item state（无 record）的 core：投影可产生 startable
    /// action，用于验证 Start 在未对账时被 baseline gate 拒绝（而非先被
    /// active-record 投影的 staleAction 拦截）。
    private func makeObservedCore(
        baselineReference: ManualBaselineReference,
        recordID: UUID
    ) throws -> ManualUpgradeCore {
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let state = try ManualItemState(
            itemKey: key,
            baselineReference: baselineReference,
            importedObservation: ManualImportedObservation(
                reference: baselineReference,
                levelDistribution: try ManualLevelDistribution(levelQuantities: [1: 1]),
                sourceTimestamp: Date(timeIntervalSinceNow: -3_000)
            ),
            manualCompletedDistribution: .empty,
            status: .observed
        )
        return try ManualUpgradeCore(itemStates: [state])
    }

    /// 构造「账号已从旧 lineage 切换到新快照，但 manual core 仍绑定旧
    /// baseline」的未对账模型：
    /// - 村庄当前快照 tag 为 #TEST（history 的 active lineage B）；
    /// - core 的 item state / record 全部绑定旧 lineage A（tag #OLD）；
    /// 模拟 Tag 切换但尚未完成显式对账（#143）时的状态。
    @MainActor
    private func makeUnreconciledModel(
        coreBuilder: (ManualBaselineReference, UUID) throws -> ManualUpgradeCore
    ) throws -> (model: AppModel, villageID: UUID, recordID: UUID) {
        let villageID = UUID()
        let lineageA = UUID()
        let lineageB = UUID()
        let entryA = try makeHistoryEntry(
            tag: "#OLD",
            villageID: villageID,
            lineageID: lineageA,
            appliedAt: Date(timeIntervalSince1970: 800),
            isBaseline: true
        )
        let entryB = try makeHistoryEntry(
            tag: "#TEST",
            villageID: villageID,
            lineageID: lineageB,
            appliedAt: Date(timeIntervalSince1970: 1_600)
        )
        let historyEnvelope = SnapshotHistoryEnvelope(
            entries: [entryA, entryB],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: lineageA,
                    normalizedPlayerTag: "#OLD",
                    lastEntryID: entryA.snapshotID,
                    lastFingerprint: entryA.canonicalFingerprint,
                    lastAppliedAt: entryA.appliedAt,
                    hasConflict: false,
                    isActive: false
                ),
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: lineageB,
                    normalizedPlayerTag: "#TEST",
                    lastEntryID: entryB.snapshotID,
                    lastFingerprint: entryB.canonicalFingerprint,
                    lastAppliedAt: entryB.appliedAt,
                    hasConflict: false,
                    isActive: true
                ),
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let village = VillageProfile(
            id: villageID,
            name: "测试村庄",
            accountSnapshot: snapshot(objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 18),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ])
        )
        let baselineA = ManualBaselineReference(
            revision: entryA.snapshotID.uuidString,
            fingerprint: entryA.canonicalFingerprint,
            lineageID: lineageA.uuidString
        )
        let recordID = UUID()
        let core = try coreBuilder(baselineA, recordID)
        let stateTime = Date()
        let manualEnvelope = try ManualTrackerEnvelope(
            villages: [
                ManualTrackerVillageState(
                    villageID: villageID,
                    core: core,
                    stateUpdatedAt: stateTime,
                    lastSettleAt: stateTime,
                    lastImportAt: stateTime,
                    diagnostics: [],
                    reconciliationHistory: []
                ),
            ],
            migrationMarker: ManualTrackerMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore(envelope: historyEnvelope)
        try store.save(manualEnvelope)

        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        return (model, villageID, recordID)
    }

    /// 拒绝路径的持久化不变量（Issue #170 验收）：
    /// store 原始 bytes、core、stateUpdatedAt、lastSettleAt 全部不变。
    private func assertPersistedStateUnchanged(
        store: FileManualTrackerStore,
        villageID: UUID,
        rawDataBefore: Data?,
        stateBefore: ManualTrackerVillageState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try store.readRawData(), rawDataBefore,
            "manual store 原始 bytes 不得被改写", file: file, line: line
        )
        let after = try XCTUnwrap(
            try store.load()?.state(for: villageID), file: file, line: line
        )
        XCTAssertEqual(after.core, stateBefore.core, file: file, line: line)
        XCTAssertEqual(after.stateUpdatedAt, stateBefore.stateUpdatedAt, file: file, line: line)
        XCTAssertEqual(after.lastSettleAt, stateBefore.lastSettleAt, file: file, line: line)
    }

    @MainActor
    func testStartRejectedWhenBaselineUnreconciled() throws {
        let (model, villageID, recordID) = try makeUnreconciledModel(
            coreBuilder: { try makeObservedCore(baselineReference: $0, recordID: $1) }
        )
        // UI 投影保持 unknown（未对账状态不得被命令改写或展示为可执行）。
        let projected = try XCTUnwrap(model.manualUpgradeCores[villageID])
        XCTAssertEqual(projected.itemStates.first?.status, .unknown)

        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let rawDataBefore = try store.readRawData()
        let stateBefore = try XCTUnwrap(try store.load()?.state(for: villageID))
        let village = try XCTUnwrap(model.villages.first)
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            base: .home,
            now: Date(),
            manualUpgradeCore: core
        )
        let cannon = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_002 })
        // 旧 action 持有旧 lineage 的 baseline（切换前生成，当前仍可 start）。
        let staleAction = try XCTUnwrap(
            UpgradeActionProjection.action(
                for: cannon,
                catalog: catalog,
                catalogIsUsable: true,
                manualUpgradeCore: core,
                coverage: .complete,
                now: Date()
            )
        )
        XCTAssertTrue(staleAction.isStartable)
        XCTAssertEqual(staleAction.baselineReference, core.baselineReference)

        XCTAssertThrowsError(
            try model.startManualUpgrade(
                for: villageID, action: staleAction, startedAt: Date(), now: Date()
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError, .unreconciledSnapshot
            )
        }
        // 不落盘新 record：store 原始 bytes / core / stateUpdatedAt /
        // lastSettleAt 全部不变。
        try assertPersistedStateUnchanged(
            store: store,
            villageID: villageID,
            rawDataBefore: rawDataBefore,
            stateBefore: stateBefore
        )
        let after = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        XCTAssertEqual(after, core)
        XCTAssertNil(after.records.first { $0.recordID != recordID })
        XCTAssertTrue(after.records.isEmpty)
    }

    @MainActor
    func testCancelRejectedWhenBaselineUnreconciled() throws {
        let (model, villageID, recordID) = try makeUnreconciledModel(
            coreBuilder: { try makeBoundCore(baselineReference: $0, recordID: $1) }
        )
        let before = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let rawDataBefore = try store.readRawData()
        let stateBefore = try XCTUnwrap(try store.load()?.state(for: villageID))
        XCTAssertThrowsError(
            try model.cancelManualUpgrade(for: villageID, recordID: recordID)
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError, .unreconciledSnapshot
            )
        }
        // 旧 record bytes / stateUpdatedAt / lastSettleAt 均不变。
        try assertPersistedStateUnchanged(
            store: store,
            villageID: villageID,
            rawDataBefore: rawDataBefore,
            stateBefore: stateBefore
        )
        let after = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        XCTAssertEqual(after, before)
        let record = try XCTUnwrap(after.records.first { $0.recordID == recordID })
        XCTAssertEqual(record.status, .active)
    }

    @MainActor
    func testAdjustRejectedWhenBaselineUnreconciled() throws {
        let (model, villageID, recordID) = try makeUnreconciledModel(
            coreBuilder: { try makeBoundCore(baselineReference: $0, recordID: $1) }
        )
        let before = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let rawDataBefore = try store.readRawData()
        let stateBefore = try XCTUnwrap(try store.load()?.state(for: villageID))
        let old = try XCTUnwrap(before.records.first { $0.recordID == recordID })
        XCTAssertThrowsError(
            try model.adjustManualUpgradeStart(
                for: villageID,
                recordID: recordID,
                startedAt: old.startedAt.addingTimeInterval(60),
                now: Date()
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError, .unreconciledSnapshot
            )
        }
        // 旧 record bytes / stateUpdatedAt / lastSettleAt 均不变。
        try assertPersistedStateUnchanged(
            store: store,
            villageID: villageID,
            rawDataBefore: rawDataBefore,
            stateBefore: stateBefore
        )
        let after = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        XCTAssertEqual(after, before)
        let record = try XCTUnwrap(after.records.first { $0.recordID == recordID })
        XCTAssertEqual(record.startedAt, old.startedAt)
        XCTAssertEqual(record.expectedEndAt, old.expectedEndAt)
    }

    @MainActor
    func testSettleNoOpForReconciledVillageDoesNotPersist() throws {
        let countingStore = CountingManualTrackerStore(fileURL: storeURL)
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: countingStore,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction-counting.json")
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        try Self.installObservedState(
            in: model, villageID: villageID, dataID: 1_000_002, level: 1, history: history
        )
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let projection = VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home,
            now: importedAt, manualUpgradeCore: core
        )
        let cannon = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_002 })
        let action = try XCTUnwrap(UpgradeActionProjection.action(
            for: cannon, catalog: catalog, catalogIsUsable: true,
            manualUpgradeCore: core, coverage: .complete, now: importedAt
        ))

        let start = Date(timeIntervalSince1970: 5_000)
        _ = try model.startManualUpgrade(
            for: villageID,
            action: action,
            startedAt: start,
            now: start
        )
        let rawDataBefore = try countingStore.readRawData()
        let stateBefore = try XCTUnwrap(try countingStore.load()?.state(for: villageID))
        let saveCountBefore = countingStore.saveCount

        XCTAssertEqual(
            model.settleManualUpgrades(at: start.addingTimeInterval(1)),
            0
        )
        XCTAssertEqual(countingStore.saveCount, saveCountBefore)
        XCTAssertEqual(try countingStore.readRawData(), rawDataBefore)
        let after = try XCTUnwrap(try countingStore.load()?.state(for: villageID))
        XCTAssertEqual(after.core, stateBefore.core)
        XCTAssertEqual(after.stateUpdatedAt, stateBefore.stateUpdatedAt)
        XCTAssertEqual(after.lastSettleAt, stateBefore.lastSettleAt)
    }

    /// 统计 save 次数的 store 包装（Issue #220 no-op settle 回归）。
    private final class CountingManualTrackerStore: ManualTrackerStore, @unchecked Sendable {
        private let underlying: FileManualTrackerStore
        var transactionJournalURL: URL? { underlying.transactionJournalURL }
        private(set) var saveCount = 0

        init(fileURL: URL) {
            underlying = FileManualTrackerStore(fileURL: fileURL)
        }

        func load() throws -> ManualTrackerEnvelope? { try underlying.load() }

        func save(_ envelope: ManualTrackerEnvelope) throws {
            saveCount += 1
            try underlying.save(envelope)
        }

        func readRawData() throws -> Data? { try underlying.readRawData() }

        func writeRawData(_ data: Data) throws { try underlying.writeRawData(data) }

        func restoreRawData(_ data: Data?) throws { try underlying.restoreRawData(data) }
    }

    @MainActor
    func testSettleSkipsUnreconciledVillage() throws {
        let (model, villageID, recordID) = try makeUnreconciledModel(
            coreBuilder: { try makeBoundCore(baselineReference: $0, recordID: $1) }
        )
        let rawDataBefore = try store.readRawData()
        let stateBefore = try XCTUnwrap(try store.load()?.state(for: villageID))
        let dueAt = Date(timeIntervalSinceNow: 4_000)
        let settled = model.settleManualUpgrades(at: dueAt)
        XCTAssertEqual(settled, 0)
        let state = try XCTUnwrap(try store.load()?.state(for: villageID))
        let record = try XCTUnwrap(state.core.records.first { $0.recordID == recordID })
        XCTAssertEqual(record.status, .active, "未对账村庄的 due record 不得被自动结算")
        // store 原始 bytes / core / stateUpdatedAt / lastSettleAt 均不得被改写。
        try assertPersistedStateUnchanged(
            store: store,
            villageID: villageID,
            rawDataBefore: rawDataBefore,
            stateBefore: stateBefore
        )
    }

    @MainActor
    func testUnreconciledVillageDoesNotBlockReconciledVillage() throws {
        // v1：未对账（旧 baseline record）；v2：基线一致的对账村庄。
        let v1ID = UUID()
        let v2ID = UUID()
        let lineageA = UUID()
        let lineageB = UUID()
        let lineageC = UUID()
        let entryA = try makeHistoryEntry(
            tag: "#OLD",
            villageID: v1ID,
            lineageID: lineageA,
            appliedAt: Date(timeIntervalSince1970: 800),
            isBaseline: true
        )
        let entryB = try makeHistoryEntry(
            tag: "#TEST",
            villageID: v1ID,
            lineageID: lineageB,
            appliedAt: Date(timeIntervalSince1970: 1_600)
        )
        let entryC = try makeHistoryEntry(
            tag: "#TEST2",
            villageID: v2ID,
            lineageID: lineageC,
            appliedAt: Date(timeIntervalSince1970: 2_400),
            isBaseline: true
        )
        let historyEnvelope = SnapshotHistoryEnvelope(
            entries: [entryA, entryB, entryC],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: v1ID,
                    lineageID: lineageA,
                    normalizedPlayerTag: "#OLD",
                    lastEntryID: entryA.snapshotID,
                    lastFingerprint: entryA.canonicalFingerprint,
                    lastAppliedAt: entryA.appliedAt,
                    hasConflict: false,
                    isActive: false
                ),
                SnapshotHistoryLineageMetadata(
                    villageID: v1ID,
                    lineageID: lineageB,
                    normalizedPlayerTag: "#TEST",
                    lastEntryID: entryB.snapshotID,
                    lastFingerprint: entryB.canonicalFingerprint,
                    lastAppliedAt: entryB.appliedAt,
                    hasConflict: false,
                    isActive: true
                ),
                SnapshotHistoryLineageMetadata(
                    villageID: v2ID,
                    lineageID: lineageC,
                    normalizedPlayerTag: "#TEST2",
                    lastEntryID: entryC.snapshotID,
                    lastFingerprint: entryC.canonicalFingerprint,
                    lastAppliedAt: entryC.appliedAt,
                    hasConflict: false,
                    isActive: true
                ),
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )
        let villages = [
            VillageProfile(
                id: v1ID,
                name: "测试村庄1",
                accountSnapshot: snapshot(objectSections: [
                    "buildings": [
                        item(section: "buildings", dataID: 1_000_001, level: 18),
                        item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                    ],
                ])
            ),
            VillageProfile(
                id: v2ID,
                name: "测试村庄2",
                accountSnapshot: snapshot(tag: "#TEST2", objectSections: [
                    "buildings": [
                        item(section: "buildings", dataID: 1_000_001, level: 18),
                        item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                    ],
                ])
            ),
        ]
        let baselineA = ManualBaselineReference(
            revision: entryA.snapshotID.uuidString,
            fingerprint: entryA.canonicalFingerprint,
            lineageID: lineageA.uuidString
        )
        let baselineC = ManualBaselineReference(
            revision: entryC.snapshotID.uuidString,
            fingerprint: entryC.canonicalFingerprint,
            lineageID: lineageC.uuidString
        )
        let v1RecordID = UUID()
        let v2RecordID = UUID()
        let stateTime = Date()
        let manualEnvelope = try ManualTrackerEnvelope(
            villages: [
                ManualTrackerVillageState(
                    villageID: v1ID,
                    core: try makeBoundCore(
                        baselineReference: baselineA, recordID: v1RecordID
                    ),
                    stateUpdatedAt: stateTime,
                    lastSettleAt: stateTime,
                    lastImportAt: stateTime,
                    diagnostics: [],
                    reconciliationHistory: []
                ),
                ManualTrackerVillageState(
                    villageID: v2ID,
                    core: try makeBoundCore(
                        baselineReference: baselineC, recordID: v2RecordID
                    ),
                    stateUpdatedAt: stateTime,
                    lastSettleAt: stateTime,
                    lastImportAt: stateTime,
                    diagnostics: [],
                    reconciliationHistory: []
                ),
            ],
            migrationMarker: ManualTrackerMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let villagesData = try JSONEncoder().encode(villages)
        let history = TestSnapshotHistoryStore(envelope: historyEnvelope)
        try store.save(manualEnvelope)
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )

        // v2 的 UI 投影未被 gate（基线一致）。
        XCTAssertEqual(
            try XCTUnwrap(model.manualUpgradeCores[v2ID]).itemStates.first?.status,
            .manualCompleted
        )
        // v1 的 UI 投影保持 unknown。
        XCTAssertEqual(
            try XCTUnwrap(model.manualUpgradeCores[v1ID]).itemStates.first?.status,
            .unknown
        )

        // 未对账村庄被 gate 不影响对账村庄的 settle：v2 的 due record 正常
        // 完成，v1 的 due record 保持 active。
        let dueAt = Date(timeIntervalSinceNow: 4_000)
        XCTAssertEqual(model.settleManualUpgrades(at: dueAt), 1)
        let v1Persisted = try XCTUnwrap(try store.load()?.state(for: v1ID))
        XCTAssertEqual(
            try XCTUnwrap(v1Persisted.core.records.first { $0.recordID == v1RecordID }).status,
            .active
        )
        let v2Persisted = try XCTUnwrap(try store.load()?.state(for: v2ID))
        XCTAssertEqual(
            try XCTUnwrap(v2Persisted.core.records.first { $0.recordID == v2RecordID }).status,
            .completed
        )
    }

    // MARK: - Issue #145 队列容量配置

    @MainActor
    func testSetQueueCapacityPersistsAndProjects() throws {
        let (model, villageID, _) = try makeModel()
        XCTAssertNil(
            model.queueOccupancy(for: villageID, queueKind: .builder).capacity,
            "初始未配置容量"
        )
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 3)
        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.capacity, 3)
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertFalse(occupancy.isFull)
        // 其他类别不受影响
        XCTAssertNil(model.queueOccupancy(for: villageID, queueKind: .hero).capacity)
    }

    @MainActor
    func testClearQueueCapacityRemovesConfig() throws {
        let (model, villageID, _) = try makeModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 3)
        try model.clearQueueCapacity(for: villageID, queueKind: .builder)
        XCTAssertNil(model.queueOccupancy(for: villageID, queueKind: .builder).capacity)
    }

    @MainActor
    func testQueueCapacityConfigSurvivesUnrelatedCoreUpdate() throws {
        let (model, villageID, action) = try makeModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)
        _ = try model.startManualUpgrade(
            for: villageID, action: action, startedAt: Date(), queueKind: .builder
        )
        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.capacity, 5, "core 命令不得丢失容量配置")
        XCTAssertEqual(occupancy.activeManualCount, 1)
    }

    @MainActor
    func testQueueCapacityConfigSurvivesSettlement() throws {
        let (model, villageID, action) = try makeModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)
        _ = try model.startManualUpgrade(
            for: villageID, action: action, startedAt: importedAt,
            queueKind: .builder, now: importedAt
        )
        let duration = try cannonLevel2Duration()
        let settled = model.settleManualUpgrades(
            at: importedAt.addingTimeInterval(TimeInterval(duration) + 10)
        )
        XCTAssertEqual(settled, 1)
        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.capacity, 5, "settle 不得丢失容量配置")
        XCTAssertEqual(occupancy.activeManualCount, 0, "已 settle 的 record 不再占用")
    }

    @MainActor
    func testQueueCapacityConfigPersistsAcrossRestart() throws {
        let (model, villageID, _) = try makeModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 2)

        // 重启：同一 store 文件 + 同一村庄数据（重新编码当前 villages 保证 id 一致）。
        let defaults = UserDefaults(suiteName: suiteName)!
        let currentData = try JSONEncoder().encode(model.villages)
        let restored = AppModel(
            defaults: defaults,
            historyStore: TestSnapshotHistoryStore(),
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: currentData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        let occupancy = restored.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.capacity, 2, "重启后 userConfigured 容量必须保留")
        XCTAssertEqual(occupancy.activeManualCount, 0)
    }

    @MainActor
    func testSetQueueCapacityRejectsNegativeCapacity() throws {
        let (model, villageID, _) = try makeModel()
        XCTAssertThrowsError(
            try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: -1)
        ) { error in
            guard case ManualUpgradeCommandError.queueCapacityInvalid = error else {
                return XCTFail("期望 queueCapacityInvalid，得到 \(error)")
            }
        }
    }

    // MARK: - Issue #182 批量原子容量保存

    /// 可注入失败的 store 桩：验证批量命令失败时的字节级不变性。
    private final class FailingSaveStore: ManualTrackerStore, @unchecked Sendable {
        var transactionJournalURL: URL?
        var rawData: Data?
        var failWrite = false
        var saveCount = 0

        func load() throws -> ManualTrackerEnvelope? {
            guard let rawData else { return nil }
            return try JSONDecoder()
                .decode(ManualTrackerEnvelope.self, from: rawData)
                .validated()
        }

        func save(_ envelope: ManualTrackerEnvelope) throws {
            saveCount += 1
            try writeRawData(envelope.encodedData())
        }

        func readRawData() throws -> Data? { rawData }

        func writeRawData(_ data: Data) throws {
            if failWrite {
                throw ManualTrackerStoreError.writeFailed("测试手动状态写入失败")
            }
            rawData = data
        }

        func restoreRawData(_ data: Data?) throws { rawData = data }
    }

    @MainActor
    func testReplaceQueueCapacitiesSetsAllKindsInOneSave() throws {
        let (model, villageID, _) = try makeModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)
        let now = Date(timeIntervalSince1970: 2_000)

        try model.replaceQueueCapacities(
            for: villageID,
            updates: [
                .builder: .set(3),
                .laboratory: .set(0),
                .hero: .set(2),
                .equipment: .clear,
            ],
            now: now
        )

        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .builder).capacity, 3)
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .laboratory).capacity, 0)
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .hero).capacity, 2)
        XCTAssertNil(model.queueOccupancy(for: villageID, queueKind: .equipment).capacity)
        // 只产生一次有效 state 保存：stateUpdatedAt 统一为本次 now。
        let persisted = try XCTUnwrap(try store.load()?.state(for: villageID))
        XCTAssertEqual(persisted.stateUpdatedAt, now)
        XCTAssertEqual(persisted.queueCapacityConfigs.count, 3)
    }

    @MainActor
    func testReplaceQueueCapacitiesRejectsInvalidBeforeAnyWrite() throws {
        let (model, villageID, _) = try makeModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)
        let beforeState = try XCTUnwrap(try store.load()?.state(for: villageID))
        let beforeUpdatedAt = beforeState.stateUpdatedAt
        let beforeBytes = try store.readRawData()

        // 混合合法与非法（超过上限）：整个事务拒绝。
        XCTAssertThrowsError(
            try model.replaceQueueCapacities(
                for: villageID,
                updates: [
                    .builder: .set(3),
                    .laboratory: .set(LocalQueueCapacityConfig.maximumCapacity + 1),
                ]
            )
        ) { error in
            guard case ManualUpgradeCommandError.queueCapacityInvalid = error else {
                return XCTFail("期望 queueCapacityInvalid，得到 \(error)")
            }
        }

        // 原有配置、stateUpdatedAt、已持久化字节全部不变。
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .builder).capacity, 5)
        XCTAssertNil(model.queueOccupancy(for: villageID, queueKind: .laboratory).capacity)
        let afterState = try XCTUnwrap(try store.load()?.state(for: villageID))
        XCTAssertEqual(afterState.stateUpdatedAt, beforeUpdatedAt)
        XCTAssertEqual(try store.readRawData(), beforeBytes)
    }

    @MainActor
    func testReplaceQueueCapacitiesRejectsNegativeCapacity() throws {
        let (model, villageID, _) = try makeModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)
        XCTAssertThrowsError(
            try model.replaceQueueCapacities(
                for: villageID,
                updates: [.builder: .set(3), .hero: .set(-1)]
            )
        ) { error in
            guard case ManualUpgradeCommandError.queueCapacityInvalid = error else {
                return XCTFail("期望 queueCapacityInvalid，得到 \(error)")
            }
        }
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .builder).capacity, 5)
    }

    @MainActor
    func testReplaceQueueCapacitiesMixedClearAndSetInOneCommit() throws {
        let (model, villageID, _) = try makeModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)
        try model.setQueueCapacity(for: villageID, queueKind: .laboratory, capacity: 2)

        // 按真实 UI 路径构造：循环逐项赋值（与 SettingsView.save 相同方式），
        // 显式写入 .clear 而不是依赖字面量 nil 语义。
        var updates: [LocalQueueKind: LocalQueueCapacityUpdate] = [:]
        for kind in LocalQueueKind.knownKinds {
            switch kind {
            case .builder: updates[kind] = .clear
            case .laboratory: updates[kind] = .set(3)
            case .hero: updates[kind] = .set(1)
            case .equipment: updates[kind] = .set(0)
            default: break
            }
        }
        try model.replaceQueueCapacities(for: villageID, updates: updates)

        XCTAssertNil(model.queueOccupancy(for: villageID, queueKind: .builder).capacity)
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .laboratory).capacity, 3)
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .hero).capacity, 1)
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .equipment).capacity, 0)
        let persisted = try XCTUnwrap(try store.load()?.state(for: villageID))
        XCTAssertEqual(persisted.queueCapacityConfigs.count, 3)
    }

    @MainActor
    func testReplaceQueueCapacitiesPreservesUnknownKinds() throws {
        let (model, villageID, _) = try makeModel()
        // 预置一个未知/未来 queueKind 配置（未来类别，UI 表单不展示）。
        let unknownKind = LocalQueueKind(rawValue: "future-kind")
        var envelope = try XCTUnwrap(try store.load() ?? ManualTrackerEnvelope())
        var state = try XCTUnwrap(envelope.state(for: villageID))
        let unknownConfig = try LocalQueueCapacityConfig(
            villageID: villageID,
            queueKind: unknownKind,
            capacity: 7,
            updatedAt: Date(timeIntervalSince1970: 500)
        )
        state.queueCapacityConfigs.append(unknownConfig)
        try envelope.upsert(state)
        try store.save(envelope)

        // 重启模式：新建 AppModel 从同一 store 加载，保证内存 envelope 包含未知配置。
        let defaults = UserDefaults(suiteName: suiteName)!
        let restored = AppModel(
            defaults: defaults,
            historyStore: TestSnapshotHistoryStore(),
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode(model.villages)
            ),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )

        try restored.replaceQueueCapacities(
            for: villageID,
            updates: [.builder: .set(3)]
        )

        let persisted = try XCTUnwrap(try store.load()?.state(for: villageID))
        let unknown = try XCTUnwrap(
            persisted.queueCapacityConfigs.first { $0.queueKind == unknownKind }
        )
        XCTAssertEqual(unknown.capacity, 7, "未知类别配置不得被已知类别表单保存静默删除")
        XCTAssertEqual(
            persisted.queueCapacityConfigs.first { $0.queueKind == .builder }?.capacity, 3
        )
    }

    @MainActor
    func testReplaceQueueCapacitiesStoreFailureKeepsBytesAndMemory() throws {
        let failingStore = FailingSaveStore()
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
        let model = AppModel(
            defaults: defaults,
            historyStore: TestSnapshotHistoryStore(),
            manualTrackerStore: failingStore,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([village])
            ),
            transactionJournalURL: nil
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)
        let beforeState = try XCTUnwrap(
            try failingStore.load()?.state(for: villageID)
        )
        let beforeUpdatedAt = beforeState.stateUpdatedAt
        let beforeBytes = failingStore.rawData
        let savesBefore = failingStore.saveCount
        let beforeStatus = model.manualTrackerStatus

        failingStore.failWrite = true
        XCTAssertThrowsError(
            try model.replaceQueueCapacities(
                for: villageID,
                updates: [.builder: .set(3), .hero: .set(2)]
            )
        ) { error in
            XCTAssertNotNil(
                error as? ManualTrackerStoreError,
                "持久化失败必须明确抛错（由 UI 展示）"
            )
        }
        failingStore.failWrite = false

        // 批量命令失败时尚未 install 候选：内存与磁盘保持一致的旧状态，
        // 内存配置仍可见、状态未被标记 unavailable（.empty/.available 均
        // 不阻塞命令），允许用户直接重试本次编辑（不要求重启）。
        XCTAssertEqual(model.manualTrackerStatus, beforeStatus)
        XCTAssertNotEqual(model.manualTrackerStatus, .unavailable)
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .builder).capacity, 5)
        XCTAssertNil(model.queueOccupancy(for: villageID, queueKind: .hero).capacity)
        // store bytes 与已持久化 stateUpdatedAt 不变，且只尝试一次持久化。
        XCTAssertEqual(failingStore.rawData, beforeBytes)
        let afterState = try XCTUnwrap(try failingStore.load()?.state(for: villageID))
        XCTAssertEqual(afterState.stateUpdatedAt, beforeUpdatedAt)
        XCTAssertEqual(afterState.queueCapacityConfigs.first {
            $0.queueKind == .builder
        }?.capacity, 5)
        XCTAssertEqual(failingStore.saveCount, savesBefore + 1)

        // 重试：存储恢复后同一次编辑可直接再次提交成功。
        try model.replaceQueueCapacities(
            for: villageID,
            updates: [.builder: .set(3), .hero: .set(2)]
        )
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .builder).capacity, 3)
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .hero).capacity, 2)
        let retried = try XCTUnwrap(try failingStore.load()?.state(for: villageID))
        XCTAssertEqual(retried.queueCapacityConfigs.first {
            $0.queueKind == .builder
        }?.capacity, 3)
    }

    @MainActor
    func testReplaceQueueCapacitiesIsolatedPerVillage() throws {
        let (model, villageID, _) = try makeModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 5)

        // 第二个村庄：同一 store 文件，独立 AppModel。
        let snapshot2 = snapshot(tag: "#TEST2", objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let defaults = UserDefaults(suiteName: suiteName)!
        let village2 = VillageProfile(name: "测试村庄2", accountSnapshot: snapshot2)
        let model2 = AppModel(
            defaults: defaults,
            historyStore: TestSnapshotHistoryStore(),
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([village2])
            ),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction2.json")
        )
        let village2ID = try XCTUnwrap(model2.villages.first?.id)

        try model.replaceQueueCapacities(
            for: villageID,
            updates: [.builder: .set(3), .hero: .set(1)]
        )

        // 村庄1 更新；村庄2 仍无任何容量配置。
        XCTAssertEqual(model.queueOccupancy(for: villageID, queueKind: .builder).capacity, 3)
        XCTAssertNil(model2.queueOccupancy(for: village2ID, queueKind: .builder).capacity)
        XCTAssertNil(model2.queueOccupancy(for: village2ID, queueKind: .hero).capacity)
    }

    // MARK: - Issue #145 Start 队列归类与容量校验

    /// 两个可启动项目（加农炮 1_000_002 与箭塔 1_000_003）的村庄模型。
    @MainActor
    private func makeTwoStartableItemsModel(
        now: Date? = nil,
        observedTimer: Bool = false
    ) throws -> (model: AppModel, villageID: UUID, first: UpgradeAction, second: UpgradeAction) {
        let (model, villageID, first, second, _) = try makeTwoStartableItemsModelWithHistory(
            now: now, observedTimer: observedTimer
        )
        return (model, villageID, first, second)
    }

    /// 同 `makeTwoStartableItemsModel`，额外返回共享 history store。
    /// reload 场景必须复用同一 history 实例，否则未对账
    /// （`isBaselineReconciled == false`），候选投影/命令会被 gate。
    @MainActor
    private func makeTwoStartableItemsModelWithHistory(
        now: Date? = nil,
        observedTimer: Bool = false
    ) throws -> (
        model: AppModel, villageID: UUID, first: UpgradeAction, second: UpgradeAction,
        history: TestSnapshotHistoryStore
    ) {
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                item(section: "buildings", dataID: 1_000_003, level: 1, path: "2"),
            ],
        ])
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        try Self.installObservedStates(
            in: model, villageID: villageID, dataIDs: [1_000_002, 1_000_003],
            levels: [1, 1], history: history, observedTimer: observedTimer
        )
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            base: .home,
            now: now ?? importedAt,
            manualUpgradeCore: core
        )
        func action(for dataID: Int64) throws -> UpgradeAction {
            let target = try XCTUnwrap(projection.items.first { $0.dataID == dataID })
            let action = try XCTUnwrap(
                UpgradeActionProjection.action(
                    for: target,
                    catalog: catalog,
                    catalogIsUsable: true,
                    manualUpgradeCore: core,
                    coverage: .complete,
                    now: now ?? importedAt
                )
            )
            XCTAssertTrue(action.isStartable, "fixture must produce startable action: \(action.disabledReason ?? "")")
            return action
        }
        return (
            model, villageID, try action(for: 1_000_002), try action(for: 1_000_003),
            history
        )
    }

    @MainActor
    func testStartWithQueueKindStoresQueueKind() throws {
        let (model, villageID, action, _) = try makeTwoStartableItemsModel()
        let record = try model.startManualUpgrade(
            for: villageID, action: action, startedAt: Date(), queueKind: .builder
        )
        XCTAssertEqual(record.queueKind, LocalQueueKind.builder.rawValue)
        XCTAssertEqual(
            model.queueOccupancy(for: villageID, queueKind: .builder).activeManualCount, 1
        )
    }

    @MainActor
    func testStartWithoutQueueKindStoresNil() throws {
        let (model, villageID, action, _) = try makeTwoStartableItemsModel()
        let record = try model.startManualUpgrade(
            for: villageID, action: action, startedAt: Date(), queueKind: nil
        )
        XCTAssertNil(record.queueKind)
    }

    @MainActor
    func testStartRejectedWhenQueueCapacityFull() throws {
        let (model, villageID, first, second) = try makeTwoStartableItemsModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)
        _ = try model.startManualUpgrade(
            for: villageID, action: first, startedAt: Date(), queueKind: .builder
        )
        XCTAssertThrowsError(
            try model.startManualUpgrade(
                for: villageID, action: second, startedAt: Date(), queueKind: .builder
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError,
                .queueCapacityFull(
                    queueKind: .builder, activeCount: 1,
                    confirmedImportedCount: 0, capacity: 1
                )
            )
        }
    }

    @MainActor
    func testStartAllowedWhenBelowCapacity() throws {
        let (model, villageID, first, second) = try makeTwoStartableItemsModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 2)
        _ = try model.startManualUpgrade(
            for: villageID, action: first, startedAt: Date(), queueKind: .builder
        )
        // 第二个仍可启动（1 < 2）
        let record = try model.startManualUpgrade(
            for: villageID, action: second, startedAt: Date(), queueKind: .builder
        )
        XCTAssertEqual(record.status, .active)
        XCTAssertEqual(
            model.queueOccupancy(for: villageID, queueKind: .builder).activeManualCount, 2
        )
    }

    @MainActor
    func testStartAllowedWhenCapacityNotConfigured() throws {
        let (model, villageID, first, second) = try makeTwoStartableItemsModel()
        _ = try model.startManualUpgrade(
            for: villageID, action: first, startedAt: Date(), queueKind: .builder
        )
        // 未配置容量：不限制
        let record = try model.startManualUpgrade(
            for: villageID, action: second, startedAt: Date(), queueKind: .builder
        )
        XCTAssertEqual(record.status, .active)
        XCTAssertFalse(
            model.queueOccupancy(for: villageID, queueKind: .builder).isCapacityConfigured
        )
    }

    @MainActor
    func testStartWithNilQueueKindSkipsCapacityCheck() throws {
        let (model, villageID, first, second) = try makeTwoStartableItemsModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 0)
        _ = try model.startManualUpgrade(
            for: villageID, action: first, startedAt: Date(), queueKind: nil
        )
        // 不归类 → 不参与容量校验
        let record = try model.startManualUpgrade(
            for: villageID, action: second, startedAt: Date(), queueKind: nil
        )
        XCTAssertEqual(record.status, .active)
    }

    @MainActor
    func testStartRejectedWhenCapacityZero() throws {
        let (model, villageID, action, _) = try makeTwoStartableItemsModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 0)
        XCTAssertThrowsError(
            try model.startManualUpgrade(
                for: villageID, action: action, startedAt: Date(), queueKind: .builder
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError,
                .queueCapacityFull(
                    queueKind: .builder, activeCount: 0,
                    confirmedImportedCount: 0, capacity: 0
                )
            )
        }
    }

    @MainActor
    func testQueueCapacityIsolatedPerVillage() throws {
        let (model, villageID, first, _) = try makeTwoStartableItemsModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)
        _ = try model.startManualUpgrade(
            for: villageID, action: first, startedAt: Date(), queueKind: .builder
        )

        // 第二个村庄：独立 AppModel，同一 store 文件。
        let snapshot2 = snapshot(tag: "#TEST2", objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let defaults = UserDefaults(suiteName: suiteName)!
        let village2 = VillageProfile(name: "测试村庄2", accountSnapshot: snapshot2)
        let villagesData2 = try JSONEncoder().encode([village2])
        let history2 = TestSnapshotHistoryStore()
        let model2 = AppModel(
            defaults: defaults,
            historyStore: history2,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData2),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction2.json")
        )
        let village2ID = try XCTUnwrap(model2.villages.first?.id)
        try Self.installObservedState(in: model2, villageID: village2ID, dataID: 1_000_002, level: 1, history: history2)
        let core2 = try XCTUnwrap(model2.manualUpgradeCore(for: village2ID))
        let projection2 = VillageCatalogProjection.project(
            village: village2,
            catalog: catalog,
            base: .home,
            now: importedAt,
            manualUpgradeCore: core2
        )
        let target2 = try XCTUnwrap(projection2.items.first { $0.dataID == 1_000_002 })
        let action2 = try XCTUnwrap(
            UpgradeActionProjection.action(
                for: target2, catalog: catalog, catalogIsUsable: true,
                manualUpgradeCore: core2, coverage: .complete, now: importedAt
            )
        )
        // 村庄2 未配置容量 → 不受村庄1 的容量限制
        let record2 = try model2.startManualUpgrade(
            for: village2ID, action: action2, startedAt: Date(), queueKind: .builder
        )
        XCTAssertEqual(record2.status, .active)
    }

    @MainActor
    func testDifferentQueueKindNotBlockedByFullOtherKind() throws {
        let (model, villageID, first, second) = try makeTwoStartableItemsModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 0)
        // hero 类别未配置容量，不受 builder 的 capacity 0 影响
        let record = try model.startManualUpgrade(
            for: villageID, action: first, startedAt: Date(), queueKind: .hero
        )
        XCTAssertEqual(record.status, .active)
        // builder 类别仍被拒绝
        XCTAssertThrowsError(
            try model.startManualUpgrade(
                for: villageID, action: second, startedAt: Date(), queueKind: .builder
            )
        )
    }

    @MainActor
    func testStartNotBlockedByDueButUnsettledRecord() throws {
        // review P2：第一个记录在 start 第二个时已到期（expectedEndAt <= now）
        // 但尚未 settle（AppModel 容量校验先于 core.startUpgrade 的 settleDue），
        // 不得误报「本地容量已满」。
        let (model, villageID, first, second) = try makeTwoStartableItemsModel()
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)
        let duration = try cannonLevel2Duration()
        _ = try model.startManualUpgrade(
            for: villageID, action: first,
            startedAt: Date(timeIntervalSince1970: 1_000),
            queueKind: .builder, now: Date(timeIntervalSince1970: 1_000)
        )
        // 第二个 start 的 now 晚于第一个的 expectedEndAt（1_000 + duration）。
        let later = Date(timeIntervalSince1970: 1_000 + TimeInterval(duration) + 10)
        let record = try model.startManualUpgrade(
            for: villageID, action: second,
            startedAt: Date(timeIntervalSince1970: 1_000),
            queueKind: .builder, now: later
        )
        XCTAssertEqual(
            record.status, .active,
            "已到期未 settle 的旧记录不得阻塞新 start（容量校验排除 due records）"
        )
    }

    @MainActor
    func testSnapshotItemsDoNotConsumeLocalCapacity() throws {
        // 快照中两个项目存在（imported observation），本地只记录一个 active；
        // occupancy 只统计本地 active records，imported 不计入容量。
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                item(section: "buildings", dataID: 1_000_003, level: 1, path: "2"),
            ],
        ])
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        try Self.installObservedStates(
            in: model, villageID: villageID, dataIDs: [1_000_002, 1_000_003],
            levels: [1, 1], history: history
        )
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            base: .home,
            now: importedAt,
            manualUpgradeCore: core
        )
        let target = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_002 })
        let action = try XCTUnwrap(
            UpgradeActionProjection.action(
                for: target, catalog: catalog, catalogIsUsable: true,
                manualUpgradeCore: core, coverage: .complete, now: importedAt
            )
        )
        _ = try model.startManualUpgrade(
            for: villageID, action: action, startedAt: Date(), queueKind: .builder
        )
        // occupancy 只统计本地 active（1）；快照 timer 不计入。
        XCTAssertEqual(
            model.queueOccupancy(for: villageID, queueKind: .builder).activeManualCount, 1
        )
    }

    // MARK: - Issue #183 导入观察队列映射命令

    @MainActor
    private func importedObservationKey(
        in model: AppModel,
        villageID: UUID
    ) throws -> TrackerItemKey {
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let state = try XCTUnwrap(
            core.itemStates.first { $0.importedObservation != nil }
        )
        return state.itemKey
    }

    @MainActor
    func testAssignQueueToImportedObservationPersists() throws {
        let (model, villageID, _, _) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)

        let decision = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )
        XCTAssertEqual(decision.status, .userAssigned)
        XCTAssertEqual(decision.queueKind, .builder)
        XCTAssertEqual(decision.source, .userConfigured)

        let all = try model.queueAssignments(for: villageID)
        XCTAssertEqual(all.map(\.decisionID), [decision.decisionID])

        // 重启后保留（同一 store 文件重新加载，villageID 保持原样）。
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let reloaded = AppModel(
            defaults: UserDefaults(suiteName: suiteName)!,
            historyStore: TestSnapshotHistoryStore(),
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([
                    VillageProfile(id: villageID, name: "测试村庄", accountSnapshot: snapshot),
                ])
            )
        )
        let persisted = try reloaded.queueAssignments(for: villageID)
        XCTAssertEqual(persisted.map(\.decisionID), [decision.decisionID])
        XCTAssertEqual(persisted[0].queueKind, .builder)
    }

    @MainActor
    func testAssignSameItemKeyUpdatesQueueKindInsteadOfDuplicating() throws {
        let (model, villageID, _, _) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)

        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )
        let second = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .laboratory
        )
        let all = try model.queueAssignments(for: villageID)
        XCTAssertEqual(all.count, 1, "同一 itemKey 重复分配不得产生重复映射")
        XCTAssertEqual(all[0].queueKind, .laboratory)
        XCTAssertEqual(all[0].decisionID, second.decisionID)
    }

    @MainActor
    func testUnassignQueueRemovesDecision() throws {
        let (model, villageID, _, _) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )
        XCTAssertEqual(try model.queueAssignments(for: villageID).count, 1)

        try model.unassignQueueFromImportedObservation(for: villageID, itemKey: key)
        XCTAssertEqual(try model.queueAssignments(for: villageID), [])
    }

    @MainActor
    func testAssignRejectsUnknownItemKey() throws {
        let (model, villageID, _, _) = try makeTwoStartableItemsModel()
        let unknownKey = TrackerItemKey.root(
            base: .home, rawSection: "buildings", dataID: 999_999
        )
        XCTAssertThrowsError(
            try model.assignQueueToImportedObservation(
                for: villageID, itemKey: unknownKey, queueKind: .builder
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError, .itemNotImportedObservation
            )
        }
    }

    @MainActor
    func testAssignRejectsObservationWithoutTimerEvidence() throws {
        // Issue #183 review P1：无 timer 证据的导入观察不得确认映射。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel()
        let key = try importedObservationKey(in: model, villageID: villageID)
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let itemState = try XCTUnwrap(core.itemStates.first { $0.itemKey == key })
        XCTAssertFalse(itemState.importedObservation?.observedTimer ?? true,
            "测试 fixture 默认无 timer 证据")

        XCTAssertThrowsError(
            try model.assignQueueToImportedObservation(
                for: villageID, itemKey: key, queueKind: .builder
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError, .importedObservationWithoutTimer
            )
        }
        XCTAssertEqual(try model.queueAssignments(for: villageID), [])
    }

    @MainActor
    func testAssignAcceptedWhenObservationHasTimerEvidence() throws {
        // Issue #183 review P1：有 timer 证据的导入观察可以确认映射。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel()
        let key = try importedObservationKey(in: model, villageID: villageID)
        // 把 fixture 的 importedObservation 补上 timer 证据（模拟真实导入）。
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let itemState = try XCTUnwrap(core.itemStates.first { $0.itemKey == key })
        let upgraded = try ManualItemState(
            itemKey: itemState.itemKey,
            baselineReference: itemState.baselineReference,
            importedObservation: ManualImportedObservation(
                reference: itemState.importedObservation!.reference,
                levelDistribution: itemState.importedObservation?.levelDistribution,
                sourceTimestamp: itemState.importedObservation?.sourceTimestamp,
                observedTimer: true,
                observedTimerCoverageComplete: true
            ),
            manualCompletedDistribution: itemState.manualCompletedDistribution,
            status: itemState.status
        )
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try ManualUpgradeCore(
                itemStates: core.itemStates.map { $0.itemKey == key ? upgraded : $0 },
                records: core.records
            )
        }
        let decision = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )
        XCTAssertEqual(decision.status, .userAssigned)
    }

    @MainActor
    func testAssignRejectsObservationWithIncompleteCoverage() throws {
        // Issue #188 review P1：有 timer 但等级/数量覆盖不完整
        // （`levelDistribution == nil`，等价于对账 coverage 不完整）的导入
        // 观察不得确认映射；拒绝时 assignment、stateUpdatedAt、磁盘字节均不变
        // （fail-closed，零副作用）。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let itemState = try XCTUnwrap(core.itemStates.first { $0.itemKey == key })
        XCTAssertTrue(itemState.importedObservation?.observedTimer ?? false,
            "测试 fixture 必须带 timer 证据")

        // 模拟真实导入：条目有 timer，但所在 section 的 lvl/cnt 覆盖不完整，
        // 对账只产出 distribution == nil 的观察（ManualTrackerReconciliation
        // 中 `distribution = valid ? ... : nil`）。
        let partial = try ManualItemState(
            itemKey: itemState.itemKey,
            baselineReference: itemState.baselineReference,
            importedObservation: ManualImportedObservation(
                reference: itemState.importedObservation!.reference,
                levelDistribution: nil,
                sourceTimestamp: itemState.importedObservation?.sourceTimestamp,
                observedTimer: true,
                observedTimerCoverageComplete: true
            ),
            manualCompletedDistribution: itemState.manualCompletedDistribution,
            status: itemState.status
        )
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try ManualUpgradeCore(
                itemStates: core.itemStates.map { $0.itemKey == key ? partial : $0 },
                records: core.records
            )
        }

        // 拒绝前快照：磁盘字节、stateUpdatedAt、assignment 数量。
        let bytesBefore = try Data(contentsOf: storeURL)
        let updatedAtBefore = try XCTUnwrap(
            try store.load()?.state(for: villageID)
        ).stateUpdatedAt

        XCTAssertThrowsError(
            try model.assignQueueToImportedObservation(
                for: villageID, itemKey: key, queueKind: .builder
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError,
                .importedObservationIncompleteCoverage
            )
        }

        // 零副作用：磁盘字节、stateUpdatedAt、assignment 数量均不变。
        XCTAssertEqual(try Data(contentsOf: storeURL), bytesBefore)
        let updatedAtAfter = try XCTUnwrap(
            try store.load()?.state(for: villageID)
        ).stateUpdatedAt
        XCTAssertEqual(updatedAtAfter, updatedAtBefore)
        XCTAssertEqual(try model.queueAssignments(for: villageID), [])
    }

    @MainActor
    func testAssignRejectsObservationWithEmptyDistribution() throws {
        // Issue #188 review P2：`ManualLevelDistribution.empty` 是合法模型值
        // （构造/解码不校验非空），`levelDistribution != nil` 不能证明覆盖
        // 完整——空 distribution 必须同样拒绝确认（fail-closed）。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let itemState = try XCTUnwrap(core.itemStates.first { $0.itemKey == key })

        let emptyCoverage = try ManualItemState(
            itemKey: itemState.itemKey,
            baselineReference: itemState.baselineReference,
            importedObservation: ManualImportedObservation(
                reference: itemState.importedObservation!.reference,
                levelDistribution: .empty,
                sourceTimestamp: itemState.importedObservation?.sourceTimestamp,
                observedTimer: true,
                observedTimerCoverageComplete: true
            ),
            manualCompletedDistribution: itemState.manualCompletedDistribution,
            status: itemState.status
        )
        XCTAssertFalse(emptyCoverage.isQueueAssignmentConfirmable,
            "空 distribution 的导入观察不具备确认资格")
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try ManualUpgradeCore(
                itemStates: core.itemStates.map { $0.itemKey == key ? emptyCoverage : $0 },
                records: core.records
            )
        }

        XCTAssertThrowsError(
            try model.assignQueueToImportedObservation(
                for: villageID, itemKey: key, queueKind: .builder
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError,
                .importedObservationIncompleteCoverage
            )
        }
        XCTAssertEqual(try model.queueAssignments(for: villageID), [])
    }

    @MainActor
    func testOccupancyIgnoresUserAssignedWithoutConfirmableCoverage() throws {
        // Issue #188 review P2：即使持久化状态异常（userAssigned overlay 仍
        // 存在，但对应 itemState 的导入观察覆盖不足/空 distribution），
        // queueOccupancy 与 Start 容量校验也按 Core 资格谓词排除，不占容量。
        let (model, villageID, _, second) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)

        // 正例：正常确认后占用 1。
        XCTAssertEqual(
            model.queueOccupancy(for: villageID, queueKind: .builder).confirmedImportedCount,
            1
        )

        // 把 itemState 的导入观察改成空 distribution（模拟异常持久化/旧数据
        // 未被降级），userAssigned overlay 仍在 → 投影必须排除。
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let itemState = try XCTUnwrap(core.itemStates.first { $0.itemKey == key })
        let degraded = try ManualItemState(
            itemKey: itemState.itemKey,
            baselineReference: itemState.baselineReference,
            importedObservation: ManualImportedObservation(
                reference: itemState.importedObservation!.reference,
                levelDistribution: .empty,
                sourceTimestamp: itemState.importedObservation?.sourceTimestamp,
                observedTimer: true,
                observedTimerCoverageComplete: true
            ),
            manualCompletedDistribution: itemState.manualCompletedDistribution,
            status: itemState.status
        )
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try ManualUpgradeCore(
                itemStates: core.itemStates.map { $0.itemKey == key ? degraded : $0 },
                records: core.records
            )
        }

        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.confirmedImportedCount, 0,
            "资格不足的 userAssigned overlay 不得占容量")
        XCTAssertFalse(occupancy.isFull)

        // Start 校验同口径：另一个 item（箭塔，itemState 未动）不因残留
        // userAssigned 而阻塞。
        let record = try model.startManualUpgrade(
            for: villageID, action: second, startedAt: Date(), queueKind: .builder
        )
        XCTAssertEqual(record.status, .active)
    }

    @MainActor
    func testQueueAssignmentCandidateUserAssignedIneligibleExposesReason() throws {
        // Issue #189 review P2：userAssigned 但当前证据不足（异常持久化）
        // 的候选，UI 投影必须暴露不可确认资格 + 原因，与容量投影
        // （capacityConfirmingAssignments 排除）口径一致，UI 才能显示
        // "不计入容量"而非绿色"已确认"。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )

        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let itemState = try XCTUnwrap(core.itemStates.first { $0.itemKey == key })
        let degraded = try ManualItemState(
            itemKey: itemState.itemKey,
            baselineReference: itemState.baselineReference,
            importedObservation: ManualImportedObservation(
                reference: itemState.importedObservation!.reference,
                levelDistribution: .empty,
                sourceTimestamp: itemState.importedObservation?.sourceTimestamp,
                observedTimer: true,
                observedTimerCoverageComplete: true
            ),
            manualCompletedDistribution: itemState.manualCompletedDistribution,
            status: itemState.status
        )
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try ManualUpgradeCore(
                itemStates: core.itemStates.map { $0.itemKey == key ? degraded : $0 },
                records: core.records
            )
        }

        let candidate = try XCTUnwrap(
            model.queueAssignmentCandidates(for: villageID).first { $0.itemKey == key }
        )
        XCTAssertEqual(candidate.assignment?.status, .userAssigned)
        XCTAssertFalse(candidate.isConfirmable, "userAssigned 但证据不足 → 不可确认")
        XCTAssertEqual(candidate.unconfirmableReason, "观察证据不完整，暂不能确认")
    }

    @MainActor
    func testQueueAssignmentCandidatesHasTimerUsesObservedTimer() throws {
        // Issue #183 review P1：hasTimer 必须来自 observedTimer 证据，
        // 不能把 sourceTimestamp（快照来源时间）当成 timer。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel()
        let candidates = model.queueAssignmentCandidates(for: villageID)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertFalse(candidate.hasTimer)
    }

    @MainActor
    func testStartCapacityIncludesConfirmedImportedOverlay() throws {
        let (model, villageID, action, _) = try makeTwoStartableItemsModel(observedTimer: true)
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)
        // 用户确认某条导入观察属于 builder 队列 → 占 1 个容量。
        let key = try importedObservationKey(in: model, villageID: villageID)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )
        XCTAssertThrowsError(
            try model.startManualUpgrade(
                for: villageID, action: action, startedAt: Date(), queueKind: .builder
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError,
                .queueCapacityFull(
                    queueKind: .builder, activeCount: 0,
                    confirmedImportedCount: 1, capacity: 1
                )
            )
        }
    }

    @MainActor
    func testStartIgnoresObservedOnlyOverlayInCapacity() throws {
        // 自建共享 history：model A 安装 observed state 并 assign，
        // 降级后保存 store，model B（同一 history + store）验证投影口径。
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                item(section: "buildings", dataID: 1_000_003, level: 1, path: "2"),
            ],
        ])
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        try Self.installObservedStates(
            in: model, villageID: villageID, dataIDs: [1_000_002, 1_000_003],
            levels: [1, 1], history: history, observedTimer: true
        )
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 1)
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )

        // 模拟对账降级：用户映射变为 observedOnly（如 timer 消失）。
        var envelope = try XCTUnwrap(try store.load())
        let state = try XCTUnwrap(envelope.state(for: villageID))
        let core = state.core
        let degraded = try QueueAssignmentDecision(
            decisionID: state.queueAssignments[0].decisionID,
            villageID: villageID,
            itemKey: key,
            baselineReference: core.baselineReference!,
            queueKind: .builder,
            decidedAt: state.queueAssignments[0].decidedAt,
            status: .observedOnly
        )
        let updatedState = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: state.stateUpdatedAt,
            lastSettleAt: state.lastSettleAt,
            lastImportAt: state.lastImportAt,
            diagnostics: state.diagnostics,
            reconciliationHistory: state.reconciliationHistory,
            queueCapacityConfigs: state.queueCapacityConfigs,
            queueAssignments: [degraded]
        )
        try envelope.upsert(updatedState)
        try store.save(envelope)

        // 重载 model（同一 history + store + villageID）。
        let reloaded = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([
                    VillageProfile(id: villageID, name: "测试村庄", accountSnapshot: snapshot),
                ])
            ),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        XCTAssertEqual(
            reloaded.queueOccupancy(for: villageID, queueKind: .builder).confirmedImportedCount, 0
        )
        // observedOnly 不占容量：仍可启动。
        let core2 = try XCTUnwrap(reloaded.manualUpgradeCore(for: villageID))
        let projection = VillageCatalogProjection.project(
            village: VillageProfile(id: villageID, name: "测试村庄", accountSnapshot: snapshot),
            catalog: catalog,
            base: .home,
            now: importedAt,
            manualUpgradeCore: core2
        )
        let target = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_002 })
        let freshAction = try XCTUnwrap(
            UpgradeActionProjection.action(
                for: target, catalog: catalog, catalogIsUsable: true,
                manualUpgradeCore: core2, coverage: .complete, now: importedAt
            )
        )
        let record = try reloaded.startManualUpgrade(
            for: villageID, action: freshAction, startedAt: Date(), queueKind: .builder
        )
        XCTAssertEqual(record.status, .active)
    }

    @MainActor
    func testQueueOccupancySeparatesManualAndConfirmedImported() throws {
        let (model, villageID, first, _) = try makeTwoStartableItemsModel(observedTimer: true)
        try model.setQueueCapacity(for: villageID, queueKind: .builder, capacity: 3)
        let key = try importedObservationKey(in: model, villageID: villageID)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )
        _ = try model.startManualUpgrade(
            for: villageID, action: first, startedAt: Date(), queueKind: .builder
        )
        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.activeManualCount, 1)
        XCTAssertEqual(occupancy.confirmedImportedCount, 1)
        XCTAssertEqual(occupancy.totalOccupancyCount, 2)
        XCTAssertEqual(occupancy.availableSlots, 1)
    }

    // MARK: - Issue #183 review P2

    @MainActor
    func testAssignSaveFailureKeepsMemoryStateAndAllowsRetry() throws {
        // review P2：保存失败不标记 unavailable、不清空内存状态，
        // 用户可直接重试（与 replaceQueueCapacities 同语义）。
        let failingStore = FailingSaveStore()
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let village = VillageProfile(name: "测试村庄", accountSnapshot: snapshot)
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: failingStore,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([village])
            ),
            transactionJournalURL: nil
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        try Self.installObservedState(
            in: model, villageID: villageID, dataID: 1_000_002, level: 1,
            history: history, observedTimer: true
        )
        let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let beforeStatus = model.manualTrackerStatus
        let beforeBytes = failingStore.rawData

        failingStore.failWrite = true
        XCTAssertThrowsError(
            try model.assignQueueToImportedObservation(
                for: villageID, itemKey: key, queueKind: .builder
            )
        ) { error in
            XCTAssertNotNil(error as? ManualTrackerStoreError)
        }
        failingStore.failWrite = false

        XCTAssertEqual(model.manualTrackerStatus, beforeStatus,
            "保存失败不得标记 unavailable")
        XCTAssertNotEqual(model.manualTrackerStatus, .unavailable)
        XCTAssertEqual(failingStore.rawData, beforeBytes,
            "磁盘旧字节保持不变")

        // 重试成功：内存旧状态允许直接再次提交。
        let decision = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )
        XCTAssertEqual(decision.status, .userAssigned)
        XCTAssertEqual(try model.queueAssignments(for: villageID).count, 1)
    }

    @MainActor
    func testUnassignOnlyRemovesCurrentLineageMapping() throws {
        // review P2：unassign 只删除当前 lineage 的映射，
        // 旧 lineage 的历史证据保留为 unknown。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )
        let current = try XCTUnwrap(try model.queueAssignments(for: villageID).first)

        // 手工注入一条旧 lineage 的历史映射（unknown）。
        var envelope = try XCTUnwrap(try store.load())
        let state = try XCTUnwrap(envelope.state(for: villageID))
        let historical = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: key,
            baselineReference: ManualBaselineReference(
                revision: "old-rev", fingerprint: "old-fp", lineageID: "old-lineage"),
            queueKind: .builder,
            decidedAt: Date(timeIntervalSince1970: 500),
            status: .unknown
        )
        let withHistory = try ManualTrackerVillageState(
            villageID: villageID,
            core: state.core,
            stateUpdatedAt: state.stateUpdatedAt,
            lastSettleAt: state.lastSettleAt,
            lastImportAt: state.lastImportAt,
            diagnostics: state.diagnostics,
            reconciliationHistory: state.reconciliationHistory,
            queueCapacityConfigs: state.queueCapacityConfigs,
            queueAssignments: [current, historical]
        )
        try envelope.upsert(withHistory)
        try store.save(envelope)

        // 重新加载后 unassign：只删当前 lineage。
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let reloaded = AppModel(
            defaults: UserDefaults(suiteName: suiteName)!,
            historyStore: TestSnapshotHistoryStore(),
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([
                    VillageProfile(id: villageID, name: "测试村庄", accountSnapshot: snapshot),
                ])
            )
        )
        try reloaded.unassignQueueFromImportedObservation(for: villageID, itemKey: key)

        let remaining = try reloaded.queueAssignments(for: villageID)
        XCTAssertEqual(remaining.count, 1, "旧 lineage 历史证据必须保留")
        XCTAssertEqual(remaining[0].baselineReference.lineageID, "old-lineage")
        XCTAssertEqual(remaining[0].status, .unknown)
    }

    @MainActor
    func testQueueAssignmentCandidatesExposeHistoricalAssignments() throws {
        // review P2：UI 候选必须暴露旧 lineage 历史映射，不能隐藏。
        let (model, villageID, _, _, history) = try makeTwoStartableItemsModelWithHistory(
            observedTimer: true
        )
        let key = try importedObservationKey(in: model, villageID: villageID)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )

        var envelope = try XCTUnwrap(try store.load())
        let state = try XCTUnwrap(envelope.state(for: villageID))
        let historical = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: key,
            baselineReference: ManualBaselineReference(
                revision: "old-rev", fingerprint: "old-fp", lineageID: "old-lineage"),
            queueKind: .laboratory,
            decidedAt: Date(timeIntervalSince1970: 500),
            status: .unknown
        )
        let withHistory = try ManualTrackerVillageState(
            villageID: villageID,
            core: state.core,
            stateUpdatedAt: state.stateUpdatedAt,
            lastSettleAt: state.lastSettleAt,
            lastImportAt: state.lastImportAt,
            diagnostics: state.diagnostics,
            reconciliationHistory: state.reconciliationHistory,
            queueCapacityConfigs: state.queueCapacityConfigs,
            queueAssignments: state.queueAssignments + [historical]
        )
        try envelope.upsert(withHistory)
        try store.save(envelope)

        // reload 必须复用同一 history store（Issue #189 review P1：未对账时
        // 候选投影 fail-closed 返回空；对账才能看到历史映射）。
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                item(section: "buildings", dataID: 1_000_003, level: 1, path: "2"),
            ],
        ])
        let reloaded = AppModel(
            defaults: UserDefaults(suiteName: suiteName)!,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([
                    VillageProfile(id: villageID, name: "测试村庄", accountSnapshot: snapshot),
                ])
            )
        )
        let candidate = try XCTUnwrap(
            reloaded.queueAssignmentCandidates(for: villageID).first {
                $0.itemKey == key
            }
        )
        XCTAssertEqual(candidate.historicalAssignments.count, 1)
        XCTAssertEqual(candidate.historicalAssignments[0].status, .unknown)
        XCTAssertEqual(candidate.historicalAssignments[0].queueKind, .laboratory)
    }

    // MARK: - Issue #189 队列映射面板资格投影

    @MainActor
    func testQueueAssignmentCandidatesExposeConfirmableEligibility() throws {
        // Issue #189：UI 必须能预先知道"是否可以确认"，而不是点击后才收到
        // 命令错误。无 timer 证据的候选项不可确认，且给出原因。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel()
        let key = try importedObservationKey(in: model, villageID: villageID)
        let candidate = try XCTUnwrap(
            model.queueAssignmentCandidates(for: villageID).first { $0.itemKey == key }
        )
        XCTAssertFalse(candidate.hasTimer, "fixture 默认无 timer")
        XCTAssertFalse(candidate.isConfirmable, "无 timer 的候选项不可确认")
        XCTAssertNotNil(candidate.unconfirmableReason, "不可确认时必须有原因")
    }

    @MainActor
    func testQueueAssignmentCandidateConfirmableWhenTimerAndCoverageComplete() throws {
        // Issue #189：timer + 完整覆盖的候选项可确认，无原因。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)
        let candidate = try XCTUnwrap(
            model.queueAssignmentCandidates(for: villageID).first { $0.itemKey == key }
        )
        XCTAssertTrue(candidate.hasTimer)
        XCTAssertTrue(candidate.isConfirmable, "timer + 完整覆盖应可确认")
        XCTAssertNil(candidate.unconfirmableReason, "可确认时无不可确认原因")
    }

    @MainActor
    func testQueueAssignmentCandidateConfirmableReasonDistinguishesCoverage() throws {
        // Issue #189：有 timer 但覆盖不完整（distribution nil）→ 不可确认，
        // 原因与"无 timer"区分，UI 可显示"观察证据不完整"。
        let (model, villageID, _, _) = try makeTwoStartableItemsModel(observedTimer: true)
        let key = try importedObservationKey(in: model, villageID: villageID)
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let itemState = try XCTUnwrap(core.itemStates.first { $0.itemKey == key })
        let partial = try ManualItemState(
            itemKey: itemState.itemKey,
            baselineReference: itemState.baselineReference,
            importedObservation: ManualImportedObservation(
                reference: itemState.importedObservation!.reference,
                levelDistribution: nil,
                sourceTimestamp: itemState.importedObservation?.sourceTimestamp,
                observedTimer: true,
                observedTimerCoverageComplete: true
            ),
            manualCompletedDistribution: itemState.manualCompletedDistribution,
            status: itemState.status
        )
        try model.updateManualUpgradeCore(for: villageID) { core in
            core = try ManualUpgradeCore(
                itemStates: core.itemStates.map { $0.itemKey == key ? partial : $0 },
                records: core.records
            )
        }
        let candidate = try XCTUnwrap(
            model.queueAssignmentCandidates(for: villageID).first { $0.itemKey == key }
        )
        XCTAssertTrue(candidate.hasTimer, "fixture 有 timer 但覆盖不完整")
        XCTAssertFalse(candidate.isConfirmable, "覆盖不完整不可确认")
        let reason = try XCTUnwrap(candidate.unconfirmableReason)
        XCTAssertFalse(reason.contains("计时"), "覆盖不足原因应与无 timer 原因区分：\(reason)")
        XCTAssertTrue(reason.contains("证据不完整"), "覆盖不足原因应说明证据不完整：\(reason)")
    }

    @MainActor
    func testAssignOnObservedOnlyRestoresUserAssignedWithoutUnassign() throws {
        // Issue #189：observedOnly 的映射在证据恢复后可直接重新确认
        // （复用幂等 assign 命令），不需要先解除再分配；不产生重复映射。
        // review P2：必须在降级写入磁盘后 reload AppModel（内存 envelope
        // 才会更新为 observedOnly），否则命令仍走内存旧状态（误测）。
        let (model, villageID, _, _, history) = try makeTwoStartableItemsModelWithHistory(
            observedTimer: true
        )
        let key = try importedObservationKey(in: model, villageID: villageID)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )

        // 模拟对账降级：mapping 变为 observedOnly（如 timer 消失后新快照出现）。
        var envelope = try XCTUnwrap(try store.load())
        let state = try XCTUnwrap(envelope.state(for: villageID))
        let core = state.core
        let degraded = try QueueAssignmentDecision(
            decisionID: state.queueAssignments[0].decisionID,
            villageID: villageID,
            itemKey: key,
            baselineReference: core.baselineReference!,
            queueKind: .builder,
            decidedAt: state.queueAssignments[0].decidedAt,
            status: .observedOnly
        )
        let degradedState = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: state.stateUpdatedAt,
            lastSettleAt: state.lastSettleAt,
            lastImportAt: state.lastImportAt,
            diagnostics: state.diagnostics,
            reconciliationHistory: state.reconciliationHistory,
            queueCapacityConfigs: state.queueCapacityConfigs,
            queueAssignments: [degraded]
        )
        try envelope.upsert(degradedState)
        try store.save(envelope)

        // reload 复用同一 history（否则未对账，assign 被 unreconciledSnapshot 拒绝）。
        let reloaded = AppModel(
            defaults: UserDefaults(suiteName: suiteName)!,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([
                    VillageProfile(
                        id: villageID,
                        name: "测试村庄",
                        accountSnapshot: snapshot(objectSections: [
                            "buildings": [
                                item(section: "buildings", dataID: 1_000_001, level: 18),
                                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                                item(section: "buildings", dataID: 1_000_003, level: 1, path: "2"),
                            ],
                        ])
                    ),
                ])
            )
        )
        XCTAssertEqual(
            try reloaded.queueAssignments(for: villageID).first?.status, .observedOnly,
            "fixture：reload 后必须是 observedOnly"
        )

        // 证据恢复（当前 itemState 仍 timer + 覆盖完整）后直接重新确认：
        // 复用现有 assign 命令，无需先 unassign。
        let decision = try reloaded.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .laboratory
        )
        XCTAssertEqual(decision.status, .userAssigned)
        XCTAssertEqual(decision.queueKind, .laboratory)
        let all = try reloaded.queueAssignments(for: villageID)
        XCTAssertEqual(all.count, 1, "重新确认不产生重复映射")
        XCTAssertEqual(all[0].status, .userAssigned)
    }

    @MainActor
    func testQueueAssignmentCandidateObservedOnlyVisibleWithRestoredEligibility() throws {
        // Issue #189：observedOnly 映射在证据恢复后，candidate 同时暴露
        // observedOnly 状态（可显示"重新确认"）与 isConfirmable 资格。
        let (model, villageID, _, _, history) = try makeTwoStartableItemsModelWithHistory(
            observedTimer: true
        )
        let key = try importedObservationKey(in: model, villageID: villageID)
        _ = try model.assignQueueToImportedObservation(
            for: villageID, itemKey: key, queueKind: .builder
        )

        var envelope = try XCTUnwrap(try store.load())
        let state = try XCTUnwrap(envelope.state(for: villageID))
        let core = state.core
        let degraded = try QueueAssignmentDecision(
            decisionID: state.queueAssignments[0].decisionID,
            villageID: villageID,
            itemKey: key,
            baselineReference: core.baselineReference!,
            queueKind: .builder,
            decidedAt: state.queueAssignments[0].decidedAt,
            status: .observedOnly
        )
        let degradedState = try ManualTrackerVillageState(
            villageID: villageID,
            core: core,
            stateUpdatedAt: state.stateUpdatedAt,
            lastSettleAt: state.lastSettleAt,
            lastImportAt: state.lastImportAt,
            diagnostics: state.diagnostics,
            reconciliationHistory: state.reconciliationHistory,
            queueCapacityConfigs: state.queueCapacityConfigs,
            queueAssignments: [degraded]
        )
        try envelope.upsert(degradedState)
        try store.save(envelope)

        // reload 复用同一 history（否则未对账，候选投影 fail-closed 为空）。
        let reloaded = AppModel(
            defaults: UserDefaults(suiteName: suiteName)!,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(
                data: try JSONEncoder().encode([
                    VillageProfile(
                        id: villageID,
                        name: "测试村庄",
                        accountSnapshot: snapshot(objectSections: [
                            "buildings": [
                                item(section: "buildings", dataID: 1_000_001, level: 18),
                                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                                item(section: "buildings", dataID: 1_000_003, level: 1, path: "2"),
                            ],
                        ])
                    ),
                ])
            )
        )
        let candidate = try XCTUnwrap(
            reloaded.queueAssignmentCandidates(for: villageID).first { $0.itemKey == key }
        )
        XCTAssertEqual(candidate.assignment?.status, .observedOnly)
        XCTAssertTrue(candidate.isConfirmable, "证据恢复后 observedOnly 可重新确认")
        XCTAssertNil(candidate.unconfirmableReason)
    }

    // MARK: - Issue #189 review P1：未对账 baseline 拒绝

    /// 构造未对账村庄：manual core baseline 属于旧 lineage（lineageA），
    /// 当前快照 active lineage 是 lineageB；itemState 带完整 timer + coverage
    /// 证据（否则 assign 会先被 importedObservationWithoutTimer 拒绝，测不到
    /// baseline gate）。同时写入一条旧 lineage 的历史映射，验证未对账时
    /// 历史 overlay 证据仍可见。
    ///
    /// 注意：历史映射必须在 AppModel init 前写入 store（model 内存 envelope
    /// 只从 init 时的 store 加载，事后 store.save 不会更新已创建的 model）。
    @MainActor
    private func makeUnreconciledWithConfirmableObservation() throws -> (
        model: AppModel, villageID: UUID, key: TrackerItemKey
    ) {
        let villageID = UUID()
        let lineageA = UUID()
        let lineageB = UUID()
        let entryA = try makeHistoryEntry(
            tag: "#OLD",
            villageID: villageID,
            lineageID: lineageA,
            appliedAt: Date(timeIntervalSince1970: 800),
            isBaseline: true
        )
        let entryB = try makeHistoryEntry(
            tag: "#TEST",
            villageID: villageID,
            lineageID: lineageB,
            appliedAt: Date(timeIntervalSince1970: 1_600)
        )
        let historyEnvelope = SnapshotHistoryEnvelope(
            entries: [entryA, entryB],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: lineageA,
                    normalizedPlayerTag: "#OLD",
                    lastEntryID: entryA.snapshotID,
                    lastFingerprint: entryA.canonicalFingerprint,
                    lastAppliedAt: entryA.appliedAt,
                    hasConflict: false,
                    isActive: false
                ),
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: lineageB,
                    normalizedPlayerTag: "#TEST",
                    lastEntryID: entryB.snapshotID,
                    lastFingerprint: entryB.canonicalFingerprint,
                    lastAppliedAt: entryB.appliedAt,
                    hasConflict: false,
                    isActive: true
                ),
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let village = VillageProfile(
            id: villageID,
            name: "测试村庄",
            accountSnapshot: snapshot(objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 18),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ])
        )
        let baselineA = ManualBaselineReference(
            revision: entryA.snapshotID.uuidString,
            fingerprint: entryA.canonicalFingerprint,
            lineageID: lineageA.uuidString
        )
        let key = TrackerItemKey.root(
            base: .home, rawSection: "buildings", dataID: 1_000_002
        )
        let core = try ManualUpgradeCore(itemStates: [
            ManualItemState(
                itemKey: key,
                baselineReference: baselineA,
                importedObservation: ManualImportedObservation(
                    reference: baselineA,
                    levelDistribution: try ManualLevelDistribution(levelQuantities: [1: 1]),
                    sourceTimestamp: Date(timeIntervalSince1970: 1_000),
                    observedTimer: true
                ),
                manualCompletedDistribution: .empty,
                status: .observed
            ),
        ])
        let stateTime = Date()
        // 历史映射：旧 lineage（≠ core 的 lineageA 与当前 lineageB），
        // 未对账时也必须可见（审计证据，不占容量）。
        let historical = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: key,
            baselineReference: ManualBaselineReference(
                revision: "old-rev", fingerprint: "old-fp", lineageID: "old-lineage"
            ),
            queueKind: .laboratory,
            decidedAt: Date(timeIntervalSince1970: 500),
            status: .unknown
        )
        let manualEnvelope = try ManualTrackerEnvelope(
            villages: [
                ManualTrackerVillageState(
                    villageID: villageID,
                    core: core,
                    stateUpdatedAt: stateTime,
                    lastSettleAt: stateTime,
                    lastImportAt: stateTime,
                    diagnostics: [],
                    reconciliationHistory: [],
                    queueAssignments: [historical]
                ),
            ],
            migrationMarker: ManualTrackerMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore(envelope: historyEnvelope)
        try store.save(manualEnvelope)

        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        return (model, villageID, key)
    }

    @MainActor
    func testQueueAssignmentCandidatesIneligibleWithReasonWhenBaselineUnreconciled() throws {
        // Issue #189 review P1/P3：未对账（core baseline ≠ 当前快照 lineage）
        // 时候选可见但全部不可确认，显示「快照尚未对账」原因；历史 overlay
        // 证据保留可见。fail-closed（不提供可执行确认菜单）的同时满足验收
        // 「baseline 未对账显示原因、unknown/旧 lineage 历史仍可见」。
        let (model, villageID, key) = try makeUnreconciledWithConfirmableObservation()
        let candidate = try XCTUnwrap(
            model.queueAssignmentCandidates(for: villageID).first { $0.itemKey == key }
        )
        XCTAssertTrue(candidate.hasTimer, "fixture 证据完整（timer + coverage）")
        XCTAssertFalse(candidate.isConfirmable, "未对账时不可确认")
        XCTAssertEqual(candidate.unconfirmableReason, "快照尚未对账，暂不能确认")
        XCTAssertEqual(candidate.historicalAssignments.count, 1,
            "未对账时历史 overlay 证据必须可见")
        XCTAssertEqual(candidate.historicalAssignments[0].status, .unknown)
        XCTAssertEqual(candidate.historicalAssignments[0].queueKind, .laboratory)
    }

    @MainActor
    func testAssignRejectedWhenBaselineUnreconciled() throws {
        // Issue #189 review P1：assign 命令必须复用 isBaselineReconciled gate
        // （与 start/cancel/adjust 同口径），未对账时拒绝写入，零副作用——
        // 否则会把 userAssigned 绑到过期 lineage 的 baselineReference。
        let (model, villageID, key) = try makeUnreconciledWithConfirmableObservation()
        let assignmentsBefore = try model.queueAssignments(for: villageID)
        let bytesBefore = try Data(contentsOf: storeURL)
        XCTAssertThrowsError(
            try model.assignQueueToImportedObservation(
                for: villageID, itemKey: key, queueKind: .builder
            )
        ) { error in
            XCTAssertEqual(
                error as? ManualUpgradeCommandError, .unreconciledSnapshot
            )
        }
        XCTAssertEqual(try Data(contentsOf: storeURL), bytesBefore, "拒绝时磁盘字节不变")
        XCTAssertEqual(
            try model.queueAssignments(for: villageID), assignmentsBefore,
            "拒绝时 assignment 数量不变（仅保留预置历史映射）"
        )
    }

    // MARK: - Issue #192：未对账时容量投影 fail-closed

    /// 构造「未对账 + 旧 lineage userAssigned overlay + 容量配置」的村庄：
    /// history 当前 active lineage 是 B（#TEST），但 core baseline 是旧
    /// lineage A；存在一条 `userAssigned` overlay 绑定 lineage A（旧 core
    /// 的 `capacityConfirmingAssignments` 会把它误算为当前 lineage 占用），
    /// 另有一条未到期的 builder active record 与容量 1 配置。
    /// 该 fixture 验证：未对账时容量投影不得把旧 baseline 的 overlay 或
    /// 旧 manual active 记录当作「当前占用」显示。
    @MainActor
    private func makeUnreconciledWithCapacityOverlay(
        capacity: Int = 1
    ) throws -> (
        model: AppModel, villageID: UUID
    ) {
        let villageID = UUID()
        let lineageA = UUID()
        let lineageB = UUID()
        let entryA = try makeHistoryEntry(
            tag: "#OLD",
            villageID: villageID,
            lineageID: lineageA,
            appliedAt: Date(timeIntervalSince1970: 800),
            isBaseline: true
        )
        let entryB = try makeHistoryEntry(
            tag: "#TEST",
            villageID: villageID,
            lineageID: lineageB,
            appliedAt: Date(timeIntervalSince1970: 1_600)
        )
        let historyEnvelope = SnapshotHistoryEnvelope(
            entries: [entryA, entryB],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: lineageA,
                    normalizedPlayerTag: "#OLD",
                    lastEntryID: entryA.snapshotID,
                    lastFingerprint: entryA.canonicalFingerprint,
                    lastAppliedAt: entryA.appliedAt,
                    hasConflict: false,
                    isActive: false
                ),
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: lineageB,
                    normalizedPlayerTag: "#TEST",
                    lastEntryID: entryB.snapshotID,
                    lastFingerprint: entryB.canonicalFingerprint,
                    lastAppliedAt: entryB.appliedAt,
                    hasConflict: false,
                    isActive: true
                ),
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let village = VillageProfile(
            id: villageID,
            name: "测试村庄",
            accountSnapshot: snapshot(objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 18),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ])
        )
        let baselineA = ManualBaselineReference(
            revision: entryA.snapshotID.uuidString,
            fingerprint: entryA.canonicalFingerprint,
            lineageID: lineageA.uuidString
        )
        let key = TrackerItemKey.root(
            base: .home, rawSection: "buildings", dataID: 1_000_002
        )
        // 旧 lineage userAssigned overlay：在未对账实现前，
        // `capacityConfirmingAssignments` 以 core 的 lineageA 当 currentLineage，
        // 会把这条误算为当前占用。
        let overlay = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: key,
            baselineReference: baselineA,
            queueKind: .builder,
            decidedAt: Date(timeIntervalSince1970: 500),
            status: .userAssigned
        )
        // 未到期的 builder active record（在 `Date()` 时仍占用本地容量）。
        let startedAt = Date(timeIntervalSinceNow: -2_000)
        let record = try ManualUpgradeRecord(
            recordID: UUID(),
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: startedAt,
            expectedEndAt: startedAt.addingTimeInterval(5_000),
            durationSeconds: 5_000,
            durationKind: .timed,
            frozenCosts: nil,
            catalogProvenance: ManualCatalogProvenance(catalog: catalog),
            baselineReference: baselineA,
            queueKind: "builder",
            status: .active
        )
        let state = try ManualItemState(
            itemKey: key,
            baselineReference: baselineA,
            importedObservation: ManualImportedObservation(
                reference: baselineA,
                levelDistribution: try ManualLevelDistribution(levelQuantities: [1: 1]),
                sourceTimestamp: Date(timeIntervalSince1970: 1_000),
                observedTimer: true,
                observedTimerCoverageComplete: true
            ),
            manualCompletedDistribution: try ManualLevelDistribution(levelQuantities: [1: 1]),
            status: .manualCompleted
        )
        let core = try ManualUpgradeCore(itemStates: [state], records: [record])
        let config = try LocalQueueCapacityConfig(
            villageID: villageID,
            queueKind: .builder,
            capacity: capacity,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let stateTime = Date()
        let manualEnvelope = try ManualTrackerEnvelope(
            villages: [
                ManualTrackerVillageState(
                    villageID: villageID,
                    core: core,
                    stateUpdatedAt: stateTime,
                    lastSettleAt: stateTime,
                    lastImportAt: stateTime,
                    diagnostics: [],
                    reconciliationHistory: [],
                    queueCapacityConfigs: [config],
                    queueAssignments: [overlay]
                ),
            ],
            migrationMarker: ManualTrackerMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore(envelope: historyEnvelope)
        try store.save(manualEnvelope)

        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        return (model, villageID)
    }

    @MainActor
    func testQueueOccupancyUnreconciledDoesNotShowLegacyOverlay() throws {
        // Issue #192：未对账（core baseline A ≠ 当前快照 lineage B）时，
        // 容量投影必须 fail-closed——不得把旧 lineage 的 userAssigned overlay
        // 或旧 manual active 记录当作当前占用，也不得把「未知」压成 0 显示；
        // `status == .unreconciled` 是 UI 区分「已知 0」与「当前未知」的依据。
        let (model, villageID) = try makeUnreconciledWithCapacityOverlay()
        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.status, .unreconciled,
            "未对账时投影状态必须是 unreconciled（不是 available 的已知 0）")
        XCTAssertEqual(occupancy.confirmedImportedCount, 0,
            "未对账时不得把旧 lineage 的 userAssigned overlay 算作当前占用")
        XCTAssertEqual(occupancy.activeManualCount, 0,
            "未对账时不得把旧 baseline 的 manual active 记录算作当前占用")
        XCTAssertFalse(occupancy.isFull,
            "未对账时不得基于旧 overlay 给出「容量已满」结论")
        XCTAssertEqual(occupancy.capacity, 1,
            "本地容量配置本身仍保留（未对账不抹掉 userConfigured 配置）")
        XCTAssertTrue(occupancy.isCapacityConfigured)
        // 对照：未对账实现前，旧 overlay + active record 会把 total 算成 2，
        // 且 status 字段缺失。这里显式验证「未知」不会被静默当作空闲数字。
        XCTAssertEqual(occupancy.totalOccupancyCount, 0,
            "未知占用不提供数字，由 status 标记可信度")
    }

    @MainActor
    func testQueueOccupancyUnreconciledZeroCapacityDoesNotClaimFull() throws {
        // Issue #194：未对账 + 旧配置 capacity=0 时，`isFull` 不得用
        // `0 >= 0` 误判「容量已满」（这正是 #192 语义的剩余漏洞），
        // `availableSlots` 不得返回看似可用的 0。
        let (model, villageID) = try makeUnreconciledWithCapacityOverlay(capacity: 0)
        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.status, .unreconciled)
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertEqual(occupancy.confirmedImportedCount, 0)
        XCTAssertFalse(occupancy.isFull,
            "未对账时不得基于旧 capacity=0 给出「容量已满」结论")
        XCTAssertNil(occupancy.availableSlots,
            "未对账时不得返回看似可用的数字")
        XCTAssertEqual(occupancy.capacity, 0, "容量配置本身仍保留")
        XCTAssertTrue(occupancy.isCapacityConfigured)
    }

    /// 构造「已对账（core baseline = 当前 lineage B）+ 混合 lineage overlay」
    /// 的村庄：当前 lineage B 的 userAssigned overlay 计入容量，旧 lineage A
    /// 的 userAssigned 仅作历史证据不计入；另有一条未到期的 builder active
    /// 记录与容量 1 配置。验证对账完成后恢复正常口径。
    @MainActor
    private func makeReconciledWithMixedLineageOverlay() throws -> (
        model: AppModel, villageID: UUID
    ) {
        let villageID = UUID()
        let lineageA = UUID()
        let lineageB = UUID()
        let entryA = try makeHistoryEntry(
            tag: "#OLD",
            villageID: villageID,
            lineageID: lineageA,
            appliedAt: Date(timeIntervalSince1970: 800),
            isBaseline: true
        )
        let entryB = try makeHistoryEntry(
            tag: "#TEST",
            villageID: villageID,
            lineageID: lineageB,
            appliedAt: Date(timeIntervalSince1970: 1_600)
        )
        let historyEnvelope = SnapshotHistoryEnvelope(
            entries: [entryA, entryB],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: lineageA,
                    normalizedPlayerTag: "#OLD",
                    lastEntryID: entryA.snapshotID,
                    lastFingerprint: entryA.canonicalFingerprint,
                    lastAppliedAt: entryA.appliedAt,
                    hasConflict: false,
                    isActive: false
                ),
                SnapshotHistoryLineageMetadata(
                    villageID: villageID,
                    lineageID: lineageB,
                    normalizedPlayerTag: "#TEST",
                    lastEntryID: entryB.snapshotID,
                    lastFingerprint: entryB.canonicalFingerprint,
                    lastAppliedAt: entryB.appliedAt,
                    hasConflict: false,
                    isActive: true
                ),
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let village = VillageProfile(
            id: villageID,
            name: "测试村庄",
            accountSnapshot: snapshot(objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 18),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ])
        )
        let baselineA = ManualBaselineReference(
            revision: entryA.snapshotID.uuidString,
            fingerprint: entryA.canonicalFingerprint,
            lineageID: lineageA.uuidString
        )
        let baselineB = ManualBaselineReference(
            revision: entryB.snapshotID.uuidString,
            fingerprint: entryB.canonicalFingerprint,
            lineageID: lineageB.uuidString
        )
        let key = TrackerItemKey.root(
            base: .home, rawSection: "buildings", dataID: 1_000_002
        )
        // 当前 lineage B 的 userAssigned overlay：计入容量。
        let currentOverlay = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: key,
            baselineReference: baselineB,
            queueKind: .builder,
            decidedAt: Date(timeIntervalSince1970: 500),
            status: .userAssigned
        )
        // 旧 lineage A 的 userAssigned overlay：历史证据，不计入。
        let legacyOverlay = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: key,
            baselineReference: baselineA,
            queueKind: .builder,
            decidedAt: Date(timeIntervalSince1970: 400),
            status: .userAssigned
        )
        // 未到期的 builder active record（已对账，占用当前容量）。
        let startedAt = Date(timeIntervalSinceNow: -2_000)
        let record = try ManualUpgradeRecord(
            recordID: UUID(),
            itemKey: key,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: startedAt,
            expectedEndAt: startedAt.addingTimeInterval(5_000),
            durationSeconds: 5_000,
            durationKind: .timed,
            frozenCosts: nil,
            catalogProvenance: ManualCatalogProvenance(catalog: catalog),
            baselineReference: baselineB,
            queueKind: "builder",
            status: .active
        )
        let state = try ManualItemState(
            itemKey: key,
            baselineReference: baselineB,
            importedObservation: ManualImportedObservation(
                reference: baselineB,
                levelDistribution: try ManualLevelDistribution(levelQuantities: [1: 1]),
                sourceTimestamp: Date(timeIntervalSince1970: 1_600),
                observedTimer: true,
                observedTimerCoverageComplete: true
            ),
            manualCompletedDistribution: try ManualLevelDistribution(levelQuantities: [1: 1]),
            status: .manualCompleted
        )
        let core = try ManualUpgradeCore(itemStates: [state], records: [record])
        let config = try LocalQueueCapacityConfig(
            villageID: villageID,
            queueKind: .builder,
            capacity: 1,
            updatedAt: Date(timeIntervalSince1970: 1_600)
        )
        let stateTime = Date()
        let manualEnvelope = try ManualTrackerEnvelope(
            villages: [
                ManualTrackerVillageState(
                    villageID: villageID,
                    core: core,
                    stateUpdatedAt: stateTime,
                    lastSettleAt: stateTime,
                    lastImportAt: stateTime,
                    diagnostics: [],
                    reconciliationHistory: [],
                    queueCapacityConfigs: [config],
                    queueAssignments: [currentOverlay, legacyOverlay]
                ),
            ],
            migrationMarker: ManualTrackerMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore(envelope: historyEnvelope)
        try store.save(manualEnvelope)

        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        return (model, villageID)
    }

    @MainActor
    func testQueueOccupancyAfterReconciliationRestoresCurrentLineageOverlay() throws {
        // Issue #192 验收：对账完成后恢复正常口径——当前 lineage 且资格
        // 仍然有效的 userAssigned 重新计入；旧 lineage 映射保持历史证据不计入。
        let (model, villageID) = try makeReconciledWithMixedLineageOverlay()
        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.status, .available,
            "已对账时投影状态恢复为 available（数字可用于容量视图）")
        XCTAssertEqual(occupancy.confirmedImportedCount, 1,
            "只计当前 lineage B 的 userAssigned；旧 lineage A 不计入")
        XCTAssertEqual(occupancy.activeManualCount, 1,
            "已对账时 manual active 记录恢复计入")
        XCTAssertEqual(occupancy.totalOccupancyCount, 2)
        XCTAssertTrue(occupancy.isFull,
            "对账完成后容量满结论恢复（1 + 1 ≥ capacity 1）")
        XCTAssertEqual(occupancy.capacity, 1)
    }

    @MainActor
    func testQueueOccupancyUnavailableWhenStoreCorrupt() throws {
        // Issue #192：存储/历史不可用（损坏 store → envelope nil）时投影
        // 必须返回 `.unavailable`，不能把「未知」静默当成数字 0 的 available。
        let snapshot = snapshot(objectSections: [
            "buildings": [
                item(section: "buildings", dataID: 1_000_001, level: 18),
                item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let villagesData = try JSONEncoder().encode([
            VillageProfile(name: "测试村庄", accountSnapshot: snapshot),
        ])
        try Data("corrupt".utf8).write(to: storeURL)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            defaults: defaults,
            historyStore: TestSnapshotHistoryStore(),
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData)
        )
        XCTAssertEqual(model.manualTrackerStatus, .unavailable)
        let villageID = try XCTUnwrap(model.villages.first?.id)
        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.status, .unavailable,
            "存储不可用时投影状态必须是 unavailable")
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertEqual(occupancy.confirmedImportedCount, 0)
        XCTAssertNil(occupancy.capacity, "存储不可用时配置也无法读取")
        XCTAssertFalse(occupancy.isFull)
    }

    /// 构造「history 当前 lineage 存在身份冲突（hasConflict = true）→
    /// 当前 baseline 不可比较」的村庄：core 非空，配置了容量 1。
    /// `currentManualBaselineReference` 对冲突 lineage 返回 nil，
    /// `isBaselineReconciled` 为 false——容量投影必须 fail-closed。
    @MainActor
    /// 当前 baseline 不可确定的场景（Issue #192 review P2）。
    ///
    /// 这些场景 `currentManualBaselineReference` 返回 nil（history 加载失败、
    /// 无 active lineage、tag 不一致、lineage 冲突），容量投影应归为
    /// `.unavailable`（历史/身份不可用），而非 `.unreconciled`
    /// （stored != current 的「尚未对账」）。
    private enum UnavailableBaselineKind: Sendable {
        case historyLoadFailed
        case noActiveLineage
        case tagMismatch
        case conflict
    }

    @MainActor
    private func makeUnavailableBaselineModel(
        kind: UnavailableBaselineKind,
        capacity: Int = 1
    ) throws -> (model: AppModel, villageID: UUID) {
        let villageID = UUID()
        let lineageB = UUID()
        let entryB = try makeHistoryEntry(
            tag: "#TEST",
            villageID: villageID,
            lineageID: lineageB,
            appliedAt: Date(timeIntervalSince1970: 1_600)
        )
        let normalizedTag: String
        let hasConflict: Bool
        let isActive: Bool
        switch kind {
        case .historyLoadFailed:
            normalizedTag = "#TEST"; hasConflict = false; isActive = true
        case .noActiveLineage:
            normalizedTag = "#TEST"; hasConflict = false; isActive = false
        case .tagMismatch:
            normalizedTag = "#OLD"; hasConflict = false; isActive = true
        case .conflict:
            normalizedTag = "#TEST"; hasConflict = true; isActive = true
        }

        var historyEnvelope: SnapshotHistoryEnvelope?
        if kind != .historyLoadFailed {
            historyEnvelope = SnapshotHistoryEnvelope(
                entries: [entryB],
                lineages: [
                    SnapshotHistoryLineageMetadata(
                        villageID: villageID,
                        lineageID: lineageB,
                        normalizedPlayerTag: normalizedTag,
                        lastEntryID: entryB.snapshotID,
                        lastFingerprint: entryB.canonicalFingerprint,
                        lastAppliedAt: entryB.appliedAt,
                        hasConflict: hasConflict,
                        isActive: isActive
                    ),
                ],
                migrationMarker: SnapshotHistoryMigrationMarker(
                    completedAt: Date(timeIntervalSince1970: 1)
                )
            )
        }

        let village = VillageProfile(
            id: villageID,
            name: "测试村庄",
            accountSnapshot: snapshot(objectSections: [
                "buildings": [
                    item(section: "buildings", dataID: 1_000_001, level: 18),
                    item(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
                ],
            ])
        )
        let baselineB = ManualBaselineReference(
            revision: entryB.snapshotID.uuidString,
            fingerprint: entryB.canonicalFingerprint,
            lineageID: lineageB.uuidString
        )
        let key = TrackerItemKey.root(
            base: .home, rawSection: "buildings", dataID: 1_000_002
        )
        let state = try ManualItemState(
            itemKey: key,
            baselineReference: baselineB,
            importedObservation: ManualImportedObservation(
                reference: baselineB,
                levelDistribution: try ManualLevelDistribution(levelQuantities: [1: 1]),
                sourceTimestamp: Date(timeIntervalSince1970: 1_000),
                observedTimer: true,
                observedTimerCoverageComplete: true
            ),
            status: .observed
        )
        let core = try ManualUpgradeCore(itemStates: [state])
        let config = try LocalQueueCapacityConfig(
            villageID: villageID,
            queueKind: .builder,
            capacity: capacity,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let stateTime = Date()
        let manualEnvelope = try ManualTrackerEnvelope(
            villages: [
                ManualTrackerVillageState(
                    villageID: villageID,
                    core: core,
                    stateUpdatedAt: stateTime,
                    lastSettleAt: stateTime,
                    lastImportAt: stateTime,
                    diagnostics: [],
                    reconciliationHistory: [],
                    queueCapacityConfigs: [config],
                    queueAssignments: []
                ),
            ],
            migrationMarker: ManualTrackerMigrationMarker(
                completedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let villagesData = try JSONEncoder().encode([village])
        let history: TestSnapshotHistoryStore
        if kind == .historyLoadFailed {
            let failing = TestSnapshotHistoryStore()
            failing.failLoad = true
            history = failing
        } else {
            history = TestSnapshotHistoryStore(envelope: historyEnvelope)
        }
        try store.save(manualEnvelope)

        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("test-transaction.json")
        )
        return (model, villageID)
    }

    @MainActor
    func testQueueOccupancyUnavailableWhenCurrentBaselineUnknowable() throws {
        // Issue #192 review P2：history 加载失败 / 无 active lineage /
        // tag 不一致 / lineage 冲突 时当前 baseline 不可确定，容量投影应归为
        // `.unavailable`（历史/身份不可用，无法投影），而非 `.unreconciled`
        // （stored != current 的「尚未对账」）。仍 fail-closed：不显示数字/容量满。
        let kinds: [UnavailableBaselineKind] = [
            .historyLoadFailed, .noActiveLineage, .tagMismatch, .conflict
        ]
        for kind in kinds {
            let (model, villageID) = try makeUnavailableBaselineModel(kind: kind)
            let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
            XCTAssertEqual(occupancy.status, .unavailable,
                "\(kind)：当前 baseline 不可确定应为 unavailable")
            XCTAssertEqual(occupancy.activeManualCount, 0)
            XCTAssertEqual(occupancy.confirmedImportedCount, 0)
            XCTAssertFalse(occupancy.isFull)
            XCTAssertEqual(occupancy.capacity, 1, "容量配置本身保留")
            XCTAssertTrue(occupancy.isCapacityConfigured)
        }
    }

    @MainActor
    func testQueueOccupancyUnavailableZeroCapacityDoesNotClaimFull() throws {
        // Issue #194：当前 baseline 不可确定（unavailable）但配置了 capacity=0 时，
        // `isFull` 不得用 `0 >= 0` 误判「容量已满」，`availableSlots` 不得返回 0。
        // 取 .conflict 作为代表场景（status 逻辑对四种 unknowable 场景一致）。
        let (model, villageID) = try makeUnavailableBaselineModel(
            kind: .conflict, capacity: 0
        )
        let occupancy = model.queueOccupancy(for: villageID, queueKind: .builder)
        XCTAssertEqual(occupancy.status, .unavailable)
        XCTAssertEqual(occupancy.activeManualCount, 0)
        XCTAssertEqual(occupancy.confirmedImportedCount, 0)
        XCTAssertFalse(occupancy.isFull,
            "不可用时不得基于旧 capacity=0 给出「容量已满」结论")
        XCTAssertNil(occupancy.availableSlots,
            "不可用时不得返回看似可用的数字")
        XCTAssertEqual(occupancy.capacity, 0, "容量配置本身保留")
        XCTAssertTrue(occupancy.isCapacityConfigured)
    }

    @MainActor
    func testIssue245ReimportApplySafeStartsDrillThroughAppModel() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let village = VillageProfile(name: "主村")
        let villagesData = try JSONEncoder().encode([village])
        let history = TestSnapshotHistoryStore()
        let model = AppModel(
            defaults: defaults,
            historyStore: history,
            manualTrackerStore: store,
            currentVillagePersistence: TestCurrentVillagePersistence(data: villagesData),
            transactionJournalURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("issue245-transaction.json")
        )
        let villageID = try XCTUnwrap(model.villages.first?.id)
        let initialRaw = ##"""
        {
          "tag": "#TEST",
          "timestamp": 1787556915,
          "buildings": [
            {"data": 1000001, "lvl": 9, "timer": 64145},
            {"data": 1000006, "lvl": 10, "timer": 81532},
            {"data": 1000026, "lvl": 2, "timer": 45463}
          ]
        }
        """##
        let updatedRaw = ##"""
        {
          "tag": "#TEST",
          "timestamp": 1787557000,
          "buildings": [
            {"data": 1000001, "lvl": 9, "timer": 64145},
            {"data": 1000006, "lvl": 10, "timer": 81532},
            {"data": 1000026, "lvl": 2, "timer": 45463},
            {"data": 1000023, "lvl": 1, "cnt": 3}
          ]
        }
        """##

        model.importText = initialRaw
        model.parseAccountText()
        XCTAssertTrue(model.applyPendingAccountSnapshot())

        model.importText = updatedRaw
        model.parseAccountText()
        XCTAssertTrue(model.applyPendingAccountSnapshot(decision: .applyNonConflicting))

        let villageProfile = try XCTUnwrap(model.villages.first { $0.id == villageID })
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageID))
        let catalog = try XCTUnwrap(model.gameCatalog)
        let projection = VillageCatalogProjection.project(
            village: villageProfile,
            catalog: catalog,
            base: .home,
            now: Date(timeIntervalSince1970: 1_785_557_000),
            manualUpgradeCore: core
        )
        let drillKey = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 1_000_023)
        let group = try XCTUnwrap(
            BuildingGroupProjection.project(
                projection: projection,
                catalog: catalog,
                base: .home,
                manualUpgradeCore: core
            ).first { $0.trackerState.itemKey == drillKey }
        )
        let action = try XCTUnwrap(
            UpgradeActionProjection.actions(for: group, catalog: catalog)
                .first { $0.fromLevel == 1 && $0.targetLevel == 2 }
        )
        XCTAssertTrue(action.isStartable, action.disabledReason ?? "")

        let record = try model.startManualUpgrade(
            for: villageID,
            action: action,
            startedAt: Date(timeIntervalSince1970: 1_785_557_000),
            now: Date(timeIntervalSince1970: 1_785_557_000)
        )
        XCTAssertEqual(record.status, ManualUpgradeRecordStatus.active)
        XCTAssertEqual(record.fromLevel, 1)
        XCTAssertEqual(record.targetLevel, 2)
    }
}
