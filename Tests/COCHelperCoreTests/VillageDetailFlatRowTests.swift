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
        let cache = VillageDetailFlatRowCache()
        let renderKey = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        let filterKey = VillageDetailFlatRowCache.FilterKey(
            searchText: "", stateFilter: nil, sortOrder: .categoryName,
            categoryFilterKey: "all"
        )
        let bundle = makeDisplayBundle(village: village, at: t0)

        _ = cache.rows(
            renderKey: renderKey, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundle.displayGroups, statsByKey: bundle.statsByKey,
            buildingGroups: bundle.render.buildingGroups
        )
        XCTAssertEqual(cache.buildCount, 1)

        _ = cache.rows(
            renderKey: renderKey, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundle.displayGroups, statsByKey: bundle.statsByKey,
            buildingGroups: bundle.render.buildingGroups
        )
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.hitCount, 1,
                       "相同 render/筛选身份 tick 间不得重复构建 row metadata")
    }

    func testCacheMissesWhenFilterChanges() throws {
        village = makeVillage(items: [
            makeAccountItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0"),
        ])
        let cache = VillageDetailFlatRowCache()
        let renderKey = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        let bundle = makeDisplayBundle(village: village, at: t0)

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
        let cache = VillageDetailFlatRowCache()
        let renderKey = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        let filterKey = VillageDetailFlatRowCache.FilterKey(
            searchText: "", stateFilter: nil, sortOrder: .remaining,
            categoryFilterKey: "all"
        )
        let bundleA = makeDisplayBundle(village: village, at: t0, sort: .remaining)
        let bundleB = makeDisplayBundle(village: village, at: t0.addingTimeInterval(30), sort: .remaining)

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
        let cache = VillageDetailFlatRowCache()
        let filterKey = VillageDetailFlatRowCache.FilterKey(
            searchText: "", stateFilter: nil, sortOrder: .categoryName,
            categoryFilterKey: "all"
        )
        let keyOld = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: village, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        let bundle = makeDisplayBundle(village: village, at: t0)
        _ = cache.rows(
            renderKey: keyOld, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundle.displayGroups, statsByKey: bundle.statsByKey,
            buildingGroups: bundle.render.buildingGroups
        )

        var renamed = village!
        renamed.name = "新名"
        let keyNew = try XCTUnwrap(VillageDetailFlatRowCache.RenderIdentityKey(
            village: renamed, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0,
            catalog: catalog, seasonalPhases: .empty
        ))
        XCTAssertNotEqual(keyOld, keyNew)
        _ = cache.rows(
            renderKey: keyNew, filterKey: filterKey, sortDependsOnNow: false,
            displayGroups: bundle.displayGroups, statsByKey: bundle.statsByKey,
            buildingGroups: bundle.render.buildingGroups
        )
        XCTAssertEqual(cache.buildCount, 2)
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
        sort: UpgradeDisplaySort = .categoryName
    ) -> DisplayBundle {
        let render = projectRender(village: village, at: now)
        let projection = render.projection
        let displayItems = projection.items.filter { $0.status != .unavailable && $0.status != .available }
        let filtered = UpgradeActionProjection.filtered(
            displayItems,
            filter: UpgradeDisplayFilter(sort: sort),
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
        village: VillageProfile, at now: Date
    ) -> VillageProjectionCache.RenderResult {
        VillageProjectionCache().render(
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
