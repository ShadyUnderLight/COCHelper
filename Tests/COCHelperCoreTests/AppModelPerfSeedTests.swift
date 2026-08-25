import XCTest
@testable import COCHelperCore
@testable import COCHelperApp

/// Issue #197：性能样本加载路径（隐藏 debug seed）的可重放性契约。
///
/// seed 必须能仅从仓库 fixtures 重放 #197 的关键状态：
/// manual active/completed、conflict、Snapshot History 多快照、partial/unknown、
/// war log / raid 多页缓存；且不覆盖已有真实数据（红线）。
final class AppModelPerfSeedTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelPerfSeedTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// seed 后全部关键状态可重放。
    @MainActor
    func testLoadPerformanceSampleCreatesReplayableStates() throws {
        let historyStore = TestSnapshotHistoryStore()
        let model = AppModel(defaults: defaults, historyStore: historyStore)
        let fixtureDirectory = try XCTUnwrap(Bundle.module.resourceURL)

        XCTAssertTrue(model.loadPerformanceSample(
            fixtureDirectory: fixtureDirectory,
            promoteVerifiedCoverage: true
        ))

        // 3 村庄（home / builder / mixed）。
        XCTAssertEqual(model.villages.count, 3)
        let villageA = try XCTUnwrap(model.villages.first(where: { $0.tag == "#ANONYMIZED" }))
        // B 的快照已被 seed 清除 → tag（= accountSnapshot?.tag）随之变 nil；
        // 用 name 定位（applyImportedSnapshot 设 name = normalized tag）。
        let villageB = try XCTUnwrap(model.villages.first(where: { $0.name == "#PERF-BUILDER" }))
        let villageC = try XCTUnwrap(model.villages.first(where: { $0.tag == "#PERF-MIXED" }))
        XCTAssertNotNil(villageA.accountSnapshot)
        XCTAssertNotNil(villageC.accountSnapshot)

        // A：Snapshot History 多条相邻快照（home + variant 两次导入）。
        let historyEnvelope = try XCTUnwrap(historyStore.load())
        let villageAHistoryEntries = historyEnvelope.entries.filter { $0.villageID == villageA.id }
        XCTAssertGreaterThanOrEqual(villageAHistoryEntries.count, 2)

        // A：manual active + completed。
        let core = try XCTUnwrap(model.manualUpgradeCore(for: villageA.id))
        XCTAssertGreaterThanOrEqual(core.activeRecords.count, 3)
        XCTAssertGreaterThanOrEqual(core.completedHistory.count, 2)

        // A：1000002 冲突在有效投影层（manual active + variant 导入计时无法精确匹配）。
        let key = TrackerItemKey(base: .home, rawSection: "buildings", dataID: 1_000_002)
        let projection = VillageCatalogProjection.project(
            village: villageA,
            catalog: try XCTUnwrap(model.gameCatalog),
            base: .home,
            now: Date(),
            manualUpgradeCore: core
        )
        XCTAssertTrue(projection.effectiveTrackerItems.contains {
            $0.itemKey == key && $0.status == .conflict
        })

        // B：快照已清除 → unreconciled 路径。
        XCTAssertNil(villageB.accountSnapshot)

        // war log / raid 多页缓存（全部 3 页合并，无需 token）。
        let warState = try XCTUnwrap(model.warLogState(for: "#PERFCLAN"))
        XCTAssertEqual(warState.lastGood?.items.count, 30)
        let raidState = try XCTUnwrap(model.capitalState(for: "#PERFCLAN"))
        XCTAssertEqual(raidState.lastGood?.items.count, 17)
        XCTAssertTrue(model.trackedClans.contains { $0.clanTag == "#PERFCLAN" })
    }

    /// 非 bundled perf 目录默认不得把 `perf-fixture` 声明提升为 verified。
    @MainActor
    func testCustomFixtureDirectoryDoesNotAutoPromoteVerifiedCoverage() throws {
        let historyStore = TestSnapshotHistoryStore()
        let model = AppModel(defaults: defaults, historyStore: historyStore)
        let fixtureDirectory = try XCTUnwrap(Bundle.module.resourceURL)

        XCTAssertTrue(model.loadPerformanceSample(fixtureDirectory: fixtureDirectory))

        let villageA = try XCTUnwrap(model.villages.first(where: { $0.tag == "#ANONYMIZED" }))
        let envelope = try XCTUnwrap(historyStore.load())
        let lineage = try XCTUnwrap(envelope.activeLineage(for: villageA.id))
        let entry = try XCTUnwrap(envelope.entry(id: lineage.lastEntryID))
        let buildings = entry.coverage.section(base: .home, rawSection: "buildings")
        XCTAssertFalse(buildings?.opensTrustGates ?? true)
    }

    /// seed 必须拒绝已有真实数据（不覆盖用户数据）。
    @MainActor
    func testLoadPerformanceSampleRefusesExistingData() throws {
        let model = AppModel(defaults: defaults, historyStore: TestSnapshotHistoryStore())
        let fixtureDirectory = try XCTUnwrap(Bundle.module.resourceURL)
        // 先导入一个真实快照（默认占位村庄 → 真实数据）。
        let homeURL = fixtureDirectory.appendingPathComponent("perf_account_snapshot_home.json")
        model.importText = try String(contentsOf: homeURL, encoding: .utf8)
        model.parseAccountText()
        XCTAssertTrue(model.applyPendingAccountSnapshot())
        XCTAssertEqual(model.villages.count, 1)
        XCTAssertTrue(model.villages[0].hasImportedData)

        XCTAssertFalse(model.loadPerformanceSample(fixtureDirectory: fixtureDirectory))
        // 数据未被改动。
        XCTAssertEqual(model.villages.count, 1)
        XCTAssertTrue(model.villages[0].hasImportedData)
        // 负例必须检查生产常量 tag（#PERFCLAN）；旧 #PERF-CLAN 会假绿。
        XCTAssertNil(model.warLogState(for: "#PERFCLAN"))
        XCTAssertFalse(model.trackedClans.contains { $0.clanTag == "#PERFCLAN" })
    }

    /// seed 必须拒绝已有 #PERFCLAN 部落跟踪/缓存：合法 tag 可能真实存在，
    /// 即使无村庄快照也不能覆盖已有部落数据。
    @MainActor
    func testLoadPerformanceSampleRefusesExistingPerfClanData() throws {
        let model = AppModel(defaults: defaults, historyStore: TestSnapshotHistoryStore())
        let fixtureDirectory = try XCTUnwrap(Bundle.module.resourceURL)
        // 无村庄数据，但已有 #PERFCLAN 跟踪部落。
        guard case .success = model.addTrackedClan(rawTag: "#PERFCLAN", displayName: nil) else {
            XCTFail("addTrackedClan should succeed on empty store")
            return
        }

        XCTAssertFalse(model.loadPerformanceSample(fixtureDirectory: fixtureDirectory))
        // 未被覆盖：村庄仍为占位、跟踪保留、无 war/raid 缓存写入。
        XCTAssertEqual(model.villages.count, 1)
        XCTAssertFalse(model.villages[0].hasImportedData)
        XCTAssertTrue(model.trackedClans.contains { $0.clanTag == "#PERFCLAN" })
        XCTAssertNil(model.warLogState(for: "#PERFCLAN"))
        XCTAssertNil(model.capitalState(for: "#PERFCLAN"))
    }
}
