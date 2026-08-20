import XCTest
@testable import COCHelperCore

/// Issue #200：静态村庄投影缓存。
/// - 相同静态输入只构建一次；now 变化只做动态刷新；
/// - 到期（remaining >0 → 0）触发重建（与现状每 tick 重建行为一致）；
/// - key 覆盖 snapshot / manual core / catalogEpoch / base / phase bucket。
final class VillageProjectionCacheTests: XCTestCase {
    private var cache: VillageProjectionCache!
    private var village: VillageProfile!
    private var catalog: GameCatalog!
    private var craftTableCatalog: CraftTableCatalog?
    private var phases: SeasonalPhaseTable!
    private var t0: Date!

    override func setUpWithError() throws {
        cache = VillageProjectionCache()
        t0 = Date(timeIntervalSince1970: 1_000_000)
        village = try makeVillage(importedAt: t0)
        catalog = try makeCatalog()
        craftTableCatalog = nil
        phases = .empty
    }

    private func makeVillage(importedAt: Date) throws -> VillageProfile {
        // 1 条升级中（remaining 3600）+ 1 条普通完成。
        var sections: [String: [AccountItem]] = [:]
        sections["buildings"] = [
            AccountItem(id: "buildings:0", section: "buildings", dataID: 1_000_001,
                        level: 1, count: 1, timerSeconds: 3600,
                        remainingSeconds: 3600),
            AccountItem(id: "buildings:1", section: "buildings", dataID: 1_000_002,
                        level: 2, count: 1, timerSeconds: nil,
                        remainingSeconds: nil),
        ]
        let snapshot = AccountSnapshot(
            tag: "#TEST", capturedAt: nil, importedAt: importedAt, ageSeconds: nil,
            originalText: "", objectSections: sections, numericSections: [:],
            boosts: [:], unknownTopLevelKeys: [], diagnostics: []
        )
        return VillageProfile(name: "测试村", accountSnapshot: snapshot)
    }

    private func makeCatalog() throws -> GameCatalog {
        let json = """
        {
          "gameVersion": "18.400.13",
          "items": [
            {"section":"buildings","category":"buildings","dataID":1000001,"base":"home","name":"A","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":1,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]},
            {"section":"buildings","category":"buildings","dataID":1000002,"base":"home","name":"B","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":2,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]}
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

    private func render(at now: Date) -> VillageProjectionCache.RenderResult {
        cache.render(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: phases, base: .home, now: now,
            manualUpgradeCore: nil, catalogEpoch: 0
        )
    }

    // MARK: - 命中与刷新

    func testSameStaticInputBuildsOnce() {
        let first = render(at: t0)
        XCTAssertEqual(first.projection.items.count, 2)
        XCTAssertEqual(cache.buildCount, 1)

        let second = render(at: t0.addingTimeInterval(60))
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.hitCount, 1)
        // 动态刷新：remaining 递减。
        let upgraded = try! XCTUnwrap(second.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgraded.remainingSeconds, 3540)
    }

    func testExpirationRebuildsAndFlipsState() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        // 到期（3600s 后）。
        let expiredRender = render(at: t0.addingTimeInterval(3600))
        XCTAssertEqual(cache.buildCount, 2)
        let upgraded = try! XCTUnwrap(expiredRender.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgraded.remainingSeconds, 0)
        XCTAssertTrue(upgraded.needsReimport)
        // 重建后的新缓存再次命中。
        let _ = render(at: t0.addingTimeInterval(3660))
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testGoldenParityWithDirectProjection() {
        let render = render(at: t0)
        let direct = VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home, now: t0
        )
        XCTAssertEqual(render.projection.items, direct.items)
        XCTAssertEqual(render.projection.rawItems, direct.rawItems)
        XCTAssertEqual(render.projection.effectiveTrackerItems, direct.effectiveTrackerItems)
        XCTAssertEqual(render.projection.progressMetrics, direct.progressMetrics)
        // Issue #210 验收：身份字段（villageID/villageName）与覆盖字段
        //（snapshotCoverage）在缓存命中路径与直接 projection 完全一致。
        XCTAssertEqual(render.projection.villageID, direct.villageID)
        XCTAssertEqual(render.projection.villageName, direct.villageName)
        XCTAssertEqual(
            render.projection.progressMetrics.snapshotCoverage,
            direct.progressMetrics.snapshotCoverage
        )
        // diagnostics.id 为随机 UUID，比较内容。
        XCTAssertEqual(
            render.projection.diagnostics.map { "\($0.severity.rawValue)|\($0.path)|\($0.message)" },
            direct.diagnostics.map { "\($0.severity.rawValue)|\($0.path)|\($0.message)" }
        )
        XCTAssertEqual(render.buildingGroups.count, 2)
    }

    // MARK: - Issue #210 显示身份（改名）失效

    func testRenameChangesVillageNameAndRebuilds() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.hitCount, 0)
        // 缓存命中后改名（同 id、同快照、同 manual/base）：名称是投影身份
        // 的一部分，必须 miss 重建，不得返回旧 villageName。
        let renamedVillage = VillageProfile(
            id: village.id, name: "改名后", accountSnapshot: village.accountSnapshot
        )
        village = renamedVillage
        let renamed = render(at: t0.addingTimeInterval(60))
        XCTAssertEqual(cache.buildCount, 2, "改名必须使缓存失效并重建")
        XCTAssertEqual(renamed.projection.villageName, "改名后")
        // 新名称下再次命中（不重复重建）。
        let _ = render(at: t0.addingTimeInterval(120))
        XCTAssertEqual(cache.buildCount, 2)
        XCTAssertEqual(cache.hitCount, 1)
    }

    func testRenameRemovesStaleEntryForSameVillage() {
        // Review P2：改名（villageName 入 key）插入新 key 时须删除同村庄
        // （villageID + base）的旧 key 条目——否则 32 村 × 2 基地顶满
        // maxEntries=64 时，改名会让旧条目占位、LRU 驱逐其他村庄。
        // 验证：改回旧名若命中残留旧条目（buildCount 不增）即失败。
        let originalName = village.name
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        village = VillageProfile(
            id: village.id, name: "改名后", accountSnapshot: village.accountSnapshot
        )
        let _ = render(at: t0.addingTimeInterval(60))
        XCTAssertEqual(cache.buildCount, 2)
        // 改回旧名：旧 key 条目必须已删除 → miss 重建。
        village = VillageProfile(
            id: village.id, name: originalName, accountSnapshot: village.accountSnapshot
        )
        let _ = render(at: t0.addingTimeInterval(120))
        XCTAssertEqual(cache.buildCount, 3, "插入新 key 时必须删除同村庄旧 key 条目（P2）")
    }

    // MARK: - 失效矩阵

    func testSnapshotChangeRebuilds() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        village = try! makeVillage(importedAt: t0.addingTimeInterval(10))  // 新快照（importedAt 变化）
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testManualCoreChangeRebuilds() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        let core = try! ManualUpgradeCore()
        let _ = cache.render(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: phases, base: .home, now: t0,
            manualUpgradeCore: core, catalogEpoch: 0
        )
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testCatalogEpochChangeRebuilds() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        let _ = cache.render(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: phases, base: .home, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 1
        )
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testBaseChangeRebuilds() {
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        let _ = cache.render(
            village: village, catalog: catalog, craftTableCatalog: craftTableCatalog,
            seasonalPhases: phases, base: .builder, now: t0,
            manualUpgradeCore: nil, catalogEpoch: 0
        )
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testPhaseBucketChangeRebuilds() {
        phases = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [
                SeasonalPhase(
                    phaseID: "p1", name: nil,
                    from: t0, until: t0.addingTimeInterval(3600),
                    itemKeys: ["buildings:1000001"]
                )
            ]
        )
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        // 跨 phase 边界（until 之后）→ 新 bucket → 重建。
        let _ = render(at: t0.addingTimeInterval(7200))
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testPhaseBucketSameBucketDoesNotRebuild() {
        phases = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [
                SeasonalPhase(
                    phaseID: "p1", name: nil,
                    from: t0, until: t0.addingTimeInterval(7200),
                    itemKeys: ["buildings:1000001"]
                )
            ]
        )
        let _ = render(at: t0)
        XCTAssertEqual(cache.buildCount, 1)
        // 同一 bucket 内 → 仅刷新。
        let _ = render(at: t0.addingTimeInterval(600))
        XCTAssertEqual(cache.buildCount, 1)
    }

    // MARK: - LRU 驱逐（外部 review P2：满容量不得清空全部）

    func testLRUEvictsSingleLeastRecentlyUsedEntry() throws {
        let small = VillageProjectionCache(maxEntries: 2)
        // 每次 makeVillage 生成不同 village id → 不同 key。
        let v1 = try makeVillage(importedAt: t0)
        let v2 = try makeVillage(importedAt: t0)
        let v3 = try makeVillage(importedAt: t0)

        func render(_ v: VillageProfile, at now: Date) -> VillageProjectionCache.RenderResult {
            small.render(
                village: v, catalog: catalog, craftTableCatalog: craftTableCatalog,
                seasonalPhases: phases, base: .home, now: now,
                manualUpgradeCore: nil, catalogEpoch: 0
            )
        }

        _ = render(v1, at: t0)                    // 构建 v1
        _ = render(v2, at: t0)                    // 构建 v2
        _ = render(v1, at: t0.addingTimeInterval(1)) // 命中 v1 → v1 最新
        XCTAssertEqual(small.buildCount, 2)
        _ = render(v3, at: t0)                    // 构建 v3 → 驱逐最久未用（v2）
        XCTAssertEqual(small.buildCount, 3)
        XCTAssertEqual(small.hitCount, 1)

        // v2 被驱逐 → 重建（不是全清后 v1 也 miss）。
        _ = render(v2, at: t0)
        XCTAssertEqual(small.buildCount, 4)
        // v1 仍命中（旧实现 removeAll 后此处会是重建）。
        _ = render(v1, at: t0)
        XCTAssertEqual(small.buildCount, 4)
        XCTAssertEqual(small.hitCount, 2)
    }

    func testLRUEvictionKeepsNewerEntriesAcrossManyBuilds() throws {
        let small = VillageProjectionCache(maxEntries: 3)
        var villages: [VillageProfile] = []
        for _ in 0..<6 {
            villages.append(try makeVillage(importedAt: t0))
        }
        // 依次构建 6 个，now 递增使 lastUsedAt 有序：每超容驱逐最旧，只驱逐一条。
        for (index, v) in villages.enumerated() {
            _ = small.render(
                village: v, catalog: catalog, craftTableCatalog: craftTableCatalog,
                seasonalPhases: phases, base: .home, now: t0.addingTimeInterval(Double(index)),
                manualUpgradeCore: nil, catalogEpoch: 0
            )
        }
        XCTAssertEqual(small.buildCount, 6)
        // 最新的 3 个全部命中（旧实现每次 build 都 removeAll，这里全 miss）。
        for (offset, v) in villages.dropFirst(3).enumerated() {
            _ = small.render(
                village: v, catalog: catalog, craftTableCatalog: craftTableCatalog,
                seasonalPhases: phases, base: .home, now: t0.addingTimeInterval(Double(offset) + 10),
                manualUpgradeCore: nil, catalogEpoch: 0
            )
        }
        XCTAssertEqual(small.buildCount, 6)
        XCTAssertEqual(small.hitCount, 3)
    }
}