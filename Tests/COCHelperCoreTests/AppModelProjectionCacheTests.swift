import XCTest
@testable import COCHelperCore
@testable import COCHelperApp

/// Issue #200：AppModel 层渲染入口集成测试。
///
/// - `villageRender` 输出与直接投影一致，且走缓存（build/hit 计数可断言）；
/// - `overviewRender` 输出与 `overviewRecords` + `overviewState` 一致，
///   且每 village×base 只构建一次（复用缓存 provider）。
final class AppModelProjectionCacheTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelProjectionCacheTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    private func seededModel() throws -> AppModel {
        let model = AppModel(defaults: defaults, historyStore: TestSnapshotHistoryStore())
        let fixtureDirectory = try XCTUnwrap(Bundle.module.resourceURL)
        XCTAssertTrue(model.loadPerformanceSample(
            fixtureDirectory: fixtureDirectory,
            promoteVerifiedCoverage: true
        ))
        return model
    }

    // MARK: - villageRender

    @MainActor
    func testVillageRenderMatchesDirectProjection() throws {
        let model = try seededModel()
        let village = try XCTUnwrap(model.villages.first(where: { $0.tag == "#ANONYMIZED" }))
        // 固定 now：避免两次调用间 Date() 微秒差异导致 remainingSeconds 不一致。
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let render = try XCTUnwrap(model.villageRender(villageID: village.id, base: .home, now: now))
        let direct = VillageCatalogProjection.project(
            village: village,
            catalog: model.gameCatalog,
            seasonalPhases: model.seasonalPhases,
            craftTableCatalog: model.craftTableCatalog,
            base: .home,
            now: now,
            manualUpgradeCore: model.manualUpgradeCores[village.id]
        )

        XCTAssertEqual(render.projection.items, direct.items)
        XCTAssertEqual(render.projection.rawItems, direct.rawItems)
        XCTAssertEqual(render.projection.effectiveTrackerItems, direct.effectiveTrackerItems)
        XCTAssertEqual(render.projection.progressMetrics, direct.progressMetrics)
        // 组卡与精制台不为空（seed 村庄有数据）。
        XCTAssertGreaterThan(render.buildingGroups.count, 0)
    }

    @MainActor
    func testVillageRenderCachesAcrossTicks() throws {
        let model = try seededModel()
        let village = try XCTUnwrap(model.villages.first(where: { $0.tag == "#ANONYMIZED" }))
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let first = model.villageRender(villageID: village.id, base: .home, now: now)
        XCTAssertNotNil(first)
        XCTAssertEqual(model.projectionCacheStats.buildCount, 1)

        // 同一静态内容 → 只动态刷新，不重建（同 now 调用 delta=0 恒命中；
        // 不同 now 的递减语义已在 VillageProjectionCacheTests 覆盖）。
        let second = model.villageRender(villageID: village.id, base: .home, now: now)
        XCTAssertNotNil(second)
        XCTAssertEqual(model.projectionCacheStats.buildCount, 1)
        XCTAssertEqual(model.projectionCacheStats.hitCount, 1)
    }

    // MARK: - overviewRender

    @MainActor
    func testOverviewRenderMatchesLegacyAPIs() throws {
        let model = try seededModel()
        let now = Date()

        let render = model.overviewRender(for: model.villages, now: now)
        let (active, pending) = UpgradeOverviewProjection.overviewRecords(
            from: model.villages,
            catalog: model.gameCatalog,
            craftTableCatalog: model.craftTableCatalog,
            seasonalPhases: model.seasonalPhases,
            manualUpgradeCores: model.manualUpgradeCores,
            at: now
        )
        let state = UpgradeOverviewProjection.overviewState(
            from: model.villages,
            catalog: model.gameCatalog,
            craftTableCatalog: model.craftTableCatalog,
            seasonalPhases: model.seasonalPhases,
            manualUpgradeCores: model.manualUpgradeCores,
            at: now
        )

        XCTAssertEqual(render.active, active)
        XCTAssertEqual(render.pending, pending)
        XCTAssertEqual(render.state.manualActiveCount, state.manualActiveCount)
        XCTAssertEqual(render.state.importedActiveCount, state.importedActiveCount)
        XCTAssertEqual(render.state.deduplicatedDisplayCount, state.deduplicatedDisplayCount)
        XCTAssertEqual(render.state.manualCompletedCount, state.manualCompletedCount)
        XCTAssertEqual(render.state.completedRecently, state.completedRecently)
        XCTAssertEqual(render.state.activeRecords, state.activeRecords)
        // attention 无排序契约（并列显示，issue #144）；内容按集合比较，
        // 避免依赖 Dictionary 遍历顺序的不稳定数组序。
        XCTAssertEqual(Set(render.state.attentionRecords), Set(state.attentionRecords))
        XCTAssertEqual(render.state.needsReimportRecords, state.needsReimportRecords)
    }

    @MainActor
    func testOverviewRenderBuildsEachVillageBaseOnce() throws {
        let model = try seededModel()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 无快照村庄（B）不走缓存（直接构建、不计数）：按有快照村庄数断言。
        let cachedVillageCount = model.villages.filter { $0.accountSnapshot != nil }.count

        let _ = model.overviewRender(for: model.villages, now: now)
        // 每次全量渲染 = 有快照村庄数 × base 数 的投影构建（缓存 miss 路径）。
        XCTAssertEqual(
            model.projectionCacheStats.buildCount,
            cachedVillageCount * TrackerBase.allCases.count,
            "overviewRender 每有快照的 village×base 恰好构建一次"
        )

        // 下一 tick：全部命中（动态刷新），无重建。
        let _ = model.overviewRender(
            for: model.villages, now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(
            model.projectionCacheStats.buildCount,
            cachedVillageCount * TrackerBase.allCases.count,
            "tick 间不得重建静态投影"
        )
        XCTAssertEqual(
            model.projectionCacheStats.hitCount,
            cachedVillageCount * TrackerBase.allCases.count
        )
    }

    // MARK: - aggregateCoverage（review P1：完整性卡必须走缓存）

    @MainActor
    func testAggregateCoverageUsesProjectionCache() throws {
        let model = try seededModel()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cachedVillageCount = model.villages.filter { $0.accountSnapshot != nil }.count
        let expectedBuilds = cachedVillageCount * TrackerBase.allCases.count

        let provider: VillageProjectionProvider = { village, base, now in
            model.villageRender(villageID: village.id, base: base, now: now)?.projection
                ?? VillageCatalogProjection.project(
                    village: village,
                    catalog: model.gameCatalog,
                    seasonalPhases: model.seasonalPhases,
                    base: base,
                    now: now,
                    manualUpgradeCore: model.manualUpgradeCores[village.id]
                )
        }

        // golden：带 provider（缓存）与直接构建逐位一致
        //（direct 需同口径透传 craftTableCatalog / manualUpgradeCores——
        // 二者影响 progressCoverage 与 snapshotCoverage，见 review 二轮）。
        let viaCache = VillageProgressProjection.aggregateCoverage(
            from: model.villages,
            catalog: model.gameCatalog,
            seasonalPhases: model.seasonalPhases,
            now: now,
            projectionProvider: provider
        )
        let direct = VillageProgressProjection.aggregateCoverage(
            from: model.villages,
            catalog: model.gameCatalog,
            seasonalPhases: model.seasonalPhases,
            now: now,
            craftTableCatalog: model.craftTableCatalog,
            manualUpgradeCores: model.manualUpgradeCores
        )
        XCTAssertEqual(viaCache, direct)

        // 每 village×base 恰好构建一次；第二次调用全命中（不再重跑投影）。
        XCTAssertEqual(model.projectionCacheStats.buildCount, expectedBuilds)
        let _ = VillageProgressProjection.aggregateCoverage(
            from: model.villages,
            catalog: model.gameCatalog,
            seasonalPhases: model.seasonalPhases,
            now: now,
            projectionProvider: provider
        )
        XCTAssertEqual(model.projectionCacheStats.buildCount, expectedBuilds)
        XCTAssertEqual(model.projectionCacheStats.hitCount, expectedBuilds)
    }
}