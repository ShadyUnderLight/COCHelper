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
        history: TestSnapshotHistoryStore
    ) throws {
        let section = dataID == 1_000_010 ? "buildings" : "buildings"
        let key = TrackerItemKey.root(base: .home, rawSection: section, dataID: dataID)
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
                        levelDistribution: try ManualLevelDistribution(levelQuantities: [level: 1]),
                        sourceTimestamp: Date(timeIntervalSince1970: 1_000)
                    ),
                    manualCompletedDistribution: .empty,
                    status: .observed
                ),
            ])
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
}
