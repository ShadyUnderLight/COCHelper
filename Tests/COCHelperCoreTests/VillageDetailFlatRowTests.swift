import XCTest
@testable import COCHelperCore

/// Issue #212：村庄详情扁平 row 元数据构建与缓存。
final class VillageDetailFlatRowTests: XCTestCase {
    private var catalog: GameCatalog!
    private var village: VillageProfile!
    private var t0: Date!

    override func setUpWithError() throws {
        t0 = Date(timeIntervalSince1970: 1_000_000)
        catalog = try makeCatalog()
    }

    // MARK: - 1000+ 稳定 ID / 顺序

    func testThousandsOfInstancesProduceStableRowIDsAndOrder() throws {
        let itemCount = 1_005
        let items = (0..<itemCount).map {
            makeAccountItem(section: "buildings", dataID: 1_000_008, level: ($0 % 12) + 1, path: String($0))
        }
        village = makeVillage(items: items)
        let render = projectRender(village: village, at: t0)
        let projection = render.projection
        let displayItems = projection.items.filter { $0.status != .unavailable && $0.status != .available }
        let groups = VillageDetailProjection.groups(from: displayItems)
        let displayGroups = groups
        let stats = Dictionary(
            uniqueKeysWithValues: VillageDetailProjection.completionStats(
                from: displayItems, catalogIsUsable: projection.catalogIsUsable
            ).map { ($0.id, $0) }
        )
        let groupByInstanceID = VillageDetailFlatRowProjection.groupByInstanceID(
            from: render.buildingGroups
        )
        let rows = VillageDetailFlatRowProjection.build(
            displayGroups: displayGroups,
            statsByKey: stats,
            groupByInstanceID: groupByInstanceID
        )

        let instanceRows = rows.compactMap { row -> String? in
            if case .instance(let groupID, let instanceID, _) = row {
                return "\(groupID):\(instanceID)"
            }
            return nil
        }
        XCTAssertEqual(instanceRows.count, itemCount)
        XCTAssertEqual(Set(instanceRows).count, itemCount, "row ID 不得碰撞")
        XCTAssertEqual(
            instanceRows,
            (0..<itemCount).map { "home:buildings:1000008:buildings:\($0)" }
        )
        XCTAssertEqual(rows.first(where: { if case .groupHeader = $0 { return true }; return false })?.id,
                       "groupHeader:home:buildings:1000008")
    }

    // MARK: - 缓存

    func testCacheHitsOnRepeatedTickWithSameFilters() throws {
        village = makeVillage(items: [
            makeAccountItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0"),
        ])
        let projectionCache = VillageProjectionCache()
        let cache = VillageDetailFlatRowCache()
        let bundle = makeDisplayBundle(village: village, at: t0, projectionCache: projectionCache)
        let renderKey = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, render: bundle.render, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        let filterKey = VillageDetailFlatRowCache.FilterKey(
            searchText: "", stateFilter: nil, sortOrder: .categoryName,
            categoryFilterKey: "all"
        )

        _ = cache.rows(
            renderKey: renderKey, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundle.displayGroups, statsByKey: bundle.statsByKey,
            buildingGroups: bundle.render.buildingGroups
        )
        XCTAssertEqual(cache.buildCount, 1)

        let bundleTick = makeDisplayBundle(
            village: village, at: t0.addingTimeInterval(60), projectionCache: projectionCache
        )
        XCTAssertEqual(bundleTick.render.projectionGeneration, bundle.render.projectionGeneration)
        let renderKeyTick = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, render: bundleTick.render, base: .home,
            now: t0.addingTimeInterval(60),
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        XCTAssertEqual(renderKey, renderKeyTick)

        _ = cache.rows(
            renderKey: renderKeyTick, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundleTick.displayGroups, statsByKey: bundleTick.statsByKey,
            buildingGroups: bundleTick.render.buildingGroups
        )
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.hitCount, 1,
                       "相同 render/筛选身份 tick 间不得重复构建 row metadata")
    }

    func testCacheMissesWhenFilterChanges() throws {
        village = makeVillage(items: [
            makeAccountItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0"),
        ])
        let projectionCache = VillageProjectionCache()
        let cache = VillageDetailFlatRowCache()
        let bundle = makeDisplayBundle(village: village, at: t0, projectionCache: projectionCache)
        let renderKey = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, render: bundle.render, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))

        _ = cache.rows(
            renderKey: renderKey,
            filterKey: VillageDetailFlatRowCache.FilterKey(
                searchText: "", stateFilter: nil, sortOrder: .categoryName,
                categoryFilterKey: "all"
            ),
            sortDependsOnNow: false,
            displayGroups: bundle.displayGroups, statsByKey: bundle.statsByKey,
            buildingGroups: bundle.render.buildingGroups
        )
        _ = cache.rows(
            renderKey: renderKey,
            filterKey: VillageDetailFlatRowCache.FilterKey(
                searchText: "加农", stateFilter: nil, sortOrder: .categoryName,
                categoryFilterKey: "all"
            ),
            sortDependsOnNow: false,
            displayGroups: bundle.displayGroups, statsByKey: bundle.statsByKey,
            buildingGroups: bundle.render.buildingGroups
        )
        XCTAssertEqual(cache.buildCount, 2)
        XCTAssertEqual(cache.hitCount, 0)
    }

    func testRemainingSortSkipsCacheAcrossTicks() throws {
        village = makeVillage(items: [
            makeAccountItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0",
                            timerSeconds: 3600, remainingSeconds: 3600),
        ])
        let projectionCache = VillageProjectionCache()
        let cache = VillageDetailFlatRowCache()
        let bundleA = makeDisplayBundle(
            village: village, at: t0, sort: .remaining, projectionCache: projectionCache
        )
        let renderKey = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, render: bundleA.render, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        let filterKey = VillageDetailFlatRowCache.FilterKey(
            searchText: "", stateFilter: nil, sortOrder: .remaining,
            categoryFilterKey: "all"
        )
        let bundleB = makeDisplayBundle(
            village: village, at: t0.addingTimeInterval(30), sort: .remaining,
            projectionCache: projectionCache
        )

        _ = cache.rows(
            renderKey: renderKey, filterKey: filterKey, sortDependsOnNow: true,
            displayGroups: bundleA.displayGroups, statsByKey: bundleA.statsByKey,
            buildingGroups: bundleA.render.buildingGroups
        )
        _ = cache.rows(
            renderKey: renderKey, filterKey: filterKey, sortDependsOnNow: true,
            displayGroups: bundleB.displayGroups, statsByKey: bundleB.statsByKey,
            buildingGroups: bundleB.render.buildingGroups
        )
        XCTAssertEqual(cache.buildCount, 2)
        XCTAssertEqual(cache.hitCount, 0)
    }

    func testRenderIdentityChangeInvalidatesCache() throws {
        village = makeVillage(name: "旧名", items: [
            makeAccountItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0"),
        ])
        let projectionCache = VillageProjectionCache()
        let cache = VillageDetailFlatRowCache()
        let filterKey = VillageDetailFlatRowCache.FilterKey(
            searchText: "", stateFilter: nil, sortOrder: .categoryName,
            categoryFilterKey: "all"
        )
        let bundle = makeDisplayBundle(village: village, at: t0, projectionCache: projectionCache)
        let keyOld = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, render: bundle.render, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        _ = cache.rows(
            renderKey: keyOld, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundle.displayGroups, statsByKey: bundle.statsByKey,
            buildingGroups: bundle.render.buildingGroups
        )

        var renamed = village!
        renamed.name = "新名"
        let bundleRenamed = makeDisplayBundle(village: renamed, at: t0, projectionCache: projectionCache)
        let keyNew = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: renamed, render: bundleRenamed.render, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        XCTAssertNotEqual(keyOld, keyNew)
        _ = cache.rows(
            renderKey: keyNew, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundleRenamed.displayGroups, statsByKey: bundleRenamed.statsByKey,
            buildingGroups: bundleRenamed.render.buildingGroups
        )
        XCTAssertEqual(cache.buildCount, 2)
    }

    /// timer expiry 后上游 projection 在相同 static identity 下 rebuild，
    /// flat-row cache 必须因 generation 变化而 miss，不得继续展示旧 importedActive rows。
    func testTimerExpiryRebuildInvalidatesFlatRowCacheForImportedActiveFilter() throws {
        village = makeVillage(items: [
            makeAccountItem(
                section: "buildings", dataID: 1_000_001, level: 1, path: "0",
                timerSeconds: 30, remainingSeconds: 30
            ),
        ])
        let projectionCache = VillageProjectionCache()
        let flatCache = VillageDetailFlatRowCache()
        let filterKey = VillageDetailFlatRowCache.FilterKey(
            searchText: "", stateFilter: .importedActive, sortOrder: .categoryName,
            categoryFilterKey: "all"
        )
        let groupID = "home:buildings:1000001"

        let bundleActive = makeDisplayBundle(
            village: village, at: t0, stateFilter: .importedActive,
            projectionCache: projectionCache
        )
        let itemActive = try XCTUnwrap(
            bundleActive.render.projection.items.first { $0.dataID == 1_000_001 }
        )
        XCTAssertEqual(UpgradeActionProjection.displayState(of: itemActive), .importedActive)

        let renderKeyActive = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, render: bundleActive.render, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        let rowsActive = flatCache.rows(
            renderKey: renderKeyActive, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundleActive.displayGroups, statsByKey: bundleActive.statsByKey,
            buildingGroups: bundleActive.render.buildingGroups
        ).rows
        XCTAssertTrue(rowsActive.contains {
            if case .instance(let id, _, _) = $0 { return id == groupID }
            return false
        })

        let tExpired = t0.addingTimeInterval(30)
        let bundleExpired = makeDisplayBundle(
            village: village, at: tExpired, stateFilter: .importedActive,
            projectionCache: projectionCache
        )
        let itemExpired = try XCTUnwrap(
            bundleExpired.render.projection.items.first { $0.dataID == 1_000_001 }
        )
        XCTAssertEqual(UpgradeActionProjection.displayState(of: itemExpired), .needsReimport)
        XCTAssertGreaterThan(
            bundleExpired.render.projectionGeneration,
            bundleActive.render.projectionGeneration
        )

        let renderKeyExpired = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, render: bundleExpired.render, base: .home, now: tExpired,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        XCTAssertNotEqual(renderKeyActive, renderKeyExpired)

        let rowsExpiredImported = flatCache.rows(
            renderKey: renderKeyExpired, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundleExpired.displayGroups, statsByKey: bundleExpired.statsByKey,
            buildingGroups: bundleExpired.render.buildingGroups
        ).rows
        XCTAssertFalse(rowsExpiredImported.contains {
            if case .groupHeader(let id) = $0 { return id == groupID }
            if case .instance(let id, _, _) = $0 { return id == groupID }
            return false
        })
        XCTAssertEqual(flatCache.buildCount, 2)
        XCTAssertEqual(flatCache.hitCount, 0)

        let needsReimportKey = VillageDetailFlatRowCache.FilterKey(
            searchText: "", stateFilter: .needsReimport, sortOrder: .categoryName,
            categoryFilterKey: "all"
        )
        let bundleNeedsReimport = makeDisplayBundle(
            village: village, at: tExpired, stateFilter: .needsReimport,
            projectionCache: projectionCache
        )
        let rowsNeedsReimport = flatCache.rows(
            renderKey: renderKeyExpired, filterKey: needsReimportKey, sortDependsOnNow: false,
            displayGroups: bundleNeedsReimport.displayGroups,
            statsByKey: bundleNeedsReimport.statsByKey,
            buildingGroups: bundleNeedsReimport.render.buildingGroups
        ).rows
        XCTAssertTrue(rowsNeedsReimport.contains {
            if case .instance(let id, _, _) = $0 { return id == groupID }
            if case .groupHeader(let id) = $0 { return id == groupID }
            return false
        })
    }

    // MARK: - Helpers

    private struct DisplayBundle {
        let render: VillageProjectionCache.RenderResult
        let displayGroups: [VillageDetailGroup]
        let statsByKey: [String: VillageCategoryCompletion]
    }

    private func makeDisplayBundle(
        village: VillageProfile,
        at now: Date,
        sort: UpgradeDisplaySort = .categoryName,
        stateFilter: UpgradeDisplayStateFilter? = nil,
        projectionCache: VillageProjectionCache? = nil
    ) -> DisplayBundle {
        let render = projectRender(village: village, at: now, projectionCache: projectionCache)
        let projection = render.projection
        let displayItems = projection.items.filter { $0.status != .unavailable && $0.status != .available }
        let filtered = UpgradeActionProjection.filtered(
            displayItems,
            filter: UpgradeDisplayFilter(state: stateFilter, sort: sort),
            at: now
        )
        let groups = VillageDetailProjection.groups(from: filtered)
        let stats = Dictionary(
            uniqueKeysWithValues: VillageDetailProjection.completionStats(
                from: filtered, catalogIsUsable: projection.catalogIsUsable
            ).map { ($0.id, $0) }
        )
        return DisplayBundle(render: render, displayGroups: groups, statsByKey: stats)
    }

    private func projectRender(
        village: VillageProfile,
        at now: Date,
        projectionCache: VillageProjectionCache? = nil
    ) -> VillageProjectionCache.RenderResult {
        let cache = projectionCache ?? VillageProjectionCache()
        return cache.render(
            village: village, catalog: catalog, craftTableCatalog: nil,
            seasonalPhases: .empty, base: .home, now: now,
            manualUpgradeCore: nil, catalogEpoch: 0
        )
    }

    private func makeVillage(
        name: String = "测试村",
        items: [AccountItem]
    ) -> VillageProfile {
        let snapshot = AccountSnapshot(
            tag: "#TEST", capturedAt: nil, importedAt: t0, ageSeconds: nil,
            originalText: "", objectSections: ["buildings": items],
            numericSections: [:], boosts: [:],
            unknownTopLevelKeys: [], diagnostics: []
        )
        return VillageProfile(name: name, accountSnapshot: snapshot)
    }

    private func makeAccountItem(
        section: String, dataID: Int64, level: Int, path: String,
        timerSeconds: Int64? = nil, remainingSeconds: Int64? = nil
    ) -> AccountItem {
        AccountItem(
            id: "\(section):\(path)", section: section, dataID: dataID,
            level: level, count: 1, timerSeconds: timerSeconds,
            remainingSeconds: remainingSeconds
        )
    }

    private func makeCatalog() throws -> GameCatalog {
        let json = """
        {
          "gameVersion": "18.400.13",
          "items": [
            {"section":"buildings","category":"buildings","dataID":1000001,"base":"home","name":"加农炮","maxLevel":16,
             "displayCategory":"defense","icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":1,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
                       {"level":2,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":200,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]},
            {"section":"buildings","category":"buildings","dataID":1000008,"base":"home","name":"城墙","maxLevel":12,
             "displayCategory":"walls","icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":1,"durationSeconds":60,"upgradeResource":"Gold","upgradeCost":50,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]}
          ]
        }
        """
        struct Payload: Decodable {
            let gameVersion: String
            let items: [CatalogItem]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        return try GameCatalog(gameVersion: payload.gameVersion, items: payload.items)
    }
}
