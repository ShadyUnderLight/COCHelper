import XCTest
@testable import COCHelperCore

/// Issue #200：动态刷新——remainingSeconds 按 (now - builtAt) 递减、
/// 到期（>0 → 0）检测、effective 层 importedRemainingSeconds 同步。
/// 刷新不改变任何静态字段（status/nextLevel/effective 状态），到期重建由
/// 缓存层负责（本层只报告 expired）。
final class VillageProjectionRefreshTests: XCTestCase {
    private var village: VillageProfile!
    private var catalog: GameCatalog!
    private var builtAt: Date!

    override func setUpWithError() throws {
        builtAt = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = try makeSnapshot(
            importedAt: builtAt,
            buildings: [
                (dataID: 1_000_001, level: 1, remaining: 3600),   // 升级中
                (dataID: 1_000_002, level: 2, remaining: 0),       // 计时结束
                (dataID: 1_000_003, level: 3, remaining: nil),     // 普通完成
            ]
        )
        village = VillageProfile(name: "测试村", accountSnapshot: snapshot)
        catalog = try makeCatalog()
    }

    private func makeSnapshot(
        importedAt: Date,
        buildings: [(dataID: Int64, level: Int, remaining: Int64?)]
    ) throws -> AccountSnapshot {
        var sections: [String: [AccountItem]] = [:]
        let items = buildings.enumerated().map { index, b in
            AccountItem(
                id: "buildings:\(index)",
                section: "buildings",
                dataID: b.dataID,
                level: b.level,
                count: 1,
                timerSeconds: b.remaining,
                remainingSeconds: b.remaining
            )
        }
        sections["buildings"] = items
        return AccountSnapshot(
            tag: "#TEST",
            capturedAt: nil,
            importedAt: importedAt,
            ageSeconds: nil,
            originalText: "",
            objectSections: sections,
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
    }

    private func makeCatalog() throws -> GameCatalog {
        // 最小合成目录：maxLevel 足够高避免满级干扰。
        let json = """
        {
          "gameVersion": "18.400.13",
          "items": [
            {"section":"buildings","category":"buildings","dataID":1000001,"base":"home","name":"A","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":1,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]},
            {"section":"buildings","category":"buildings","dataID":1000002,"base":"home","name":"B","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":2,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]},
            {"section":"buildings","category":"buildings","dataID":1000003,"base":"home","name":"C","maxLevel":10,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[{"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":100,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]}
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

    private func project(at now: Date) -> VillageCatalogProjection {
        VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home, now: now
        )
    }

    func testRemainingDecrementsByDelta() {
        let p0 = project(at: builtAt)
        let upgraded = try! XCTUnwrap(p0.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgraded.remainingSeconds, 3600)

        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(60), builtAt: builtAt, importedAt: builtAt)
        let upgradedNow = try! XCTUnwrap(refreshed.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgradedNow.remainingSeconds, 3540)
        XCTAssertFalse(refreshed.expired)
    }

    func testTimerExpirationIsDetected() {
        let p0 = project(at: builtAt)
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(3600), builtAt: builtAt, importedAt: builtAt)
        XCTAssertTrue(refreshed.expired)
        let upgradedNow = try! XCTUnwrap(refreshed.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgradedNow.remainingSeconds, 0)
        // 静态字段不被刷新改动（status 仍为投影时刻的 .upgrading——
        // 到期翻转由缓存层重建负责）。
        XCTAssertEqual(upgradedNow.status, .upgrading)
    }

    func testAlreadyExpiredTimerIsNotReportedAgain() {
        let p0 = project(at: builtAt)
        // 已结束计时（remaining == 0）不触发 expired。
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(60), builtAt: builtAt, importedAt: builtAt)
        XCTAssertFalse(refreshed.expired)
    }

    func testClockRewindKeepsRemainingUnchanged() {
        let p0 = project(at: builtAt)
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(-60), builtAt: builtAt, importedAt: builtAt)
        let upgradedNow = try! XCTUnwrap(refreshed.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgradedNow.remainingSeconds, 3600)
        XCTAssertFalse(refreshed.expired)
    }

    func testEffectiveTrackerItemsRemainingSynchronized() {
        let p0 = project(at: builtAt)
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(60), builtAt: builtAt, importedAt: builtAt)
        let effective = try! XCTUnwrap(
            refreshed.projection.effectiveTrackerItems.first { $0.itemKey.dataID == 1_000_001 }
        )
        XCTAssertEqual(effective.importedRemainingSeconds, 3540)
    }

    func testRawItemsAlsoRefreshed() {
        let p0 = project(at: builtAt)
        let refreshed = p0.refreshingTimers(at: builtAt.addingTimeInterval(120), builtAt: builtAt, importedAt: builtAt)
        let raw = try! XCTUnwrap(refreshed.projection.rawItems.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(raw.remainingSeconds, 3480)
    }

    func testCraftTableModulesRefreshAndDetectExpiration() throws {
        // 精制台三层结构：craft 行（1000097）→ types: [defense] → defense.modules: [module]。
        // id 路径含 ".types."/".modules." 触发嵌套判定（与真实导出格式一致）。
        var sections: [String: [AccountItem]] = [:]
        let module = AccountItem(
            id: "buildings:0.types.0.modules.0",
            section: "buildings",
            dataID: 103_000_001,
            level: 1,
            count: 1,
            timerSeconds: 3600,
            remainingSeconds: 3600
        )
        let defenseRow = AccountItem(
            id: "buildings:0.types.0",
            section: "buildings",
            dataID: 103_000_000,
            level: 5,
            count: 1,
            modules: [module]
        )
        let craft = AccountItem(
            id: "buildings:0",
            section: "buildings",
            dataID: BuildingDisplayCategoryRules.craftTableDataID,
            level: 5,
            count: 1,
            types: [defenseRow]
        )
        sections["buildings"] = [craft]
        let snapshot = AccountSnapshot(
            tag: "#TEST", capturedAt: nil, importedAt: builtAt, ageSeconds: nil,
            originalText: "", objectSections: sections, numericSections: [:],
            boosts: [:], unknownTopLevelKeys: [], diagnostics: []
        )
        let village = VillageProfile(name: "测试村", accountSnapshot: snapshot)
        let craftTable = CraftTableProjection.project(
            village: village, catalog: nil, base: .home, now: builtAt
        )
        let defense = try XCTUnwrap(craftTable.first)
        let moduleState = try XCTUnwrap(defense.modules.first)
        XCTAssertEqual(moduleState.remainingSeconds, 3600)
        XCTAssertEqual(moduleState.status, .upgrading)

        let refreshed = craftTable.refreshingModules(
            at: builtAt.addingTimeInterval(60), builtAt: builtAt, importedAt: builtAt
        )
        let moduleNow = try XCTUnwrap(refreshed.modules.first?.modules.first)
        XCTAssertEqual(moduleNow.remainingSeconds, 3540)
        XCTAssertFalse(refreshed.expired)

        let expired = craftTable.refreshingModules(
            at: builtAt.addingTimeInterval(3600), builtAt: builtAt, importedAt: builtAt
        )
        XCTAssertTrue(expired.expired)
    }

    /// 外部 review P2：刷新必须与直接构建同一 floor 语义（锚定 importedAt）。
    /// builtAt = importedAt + 10.9、now = importedAt + 11.1：直接构建递减
    /// floor(11.1) = 11 秒；旧实现 `floor(now - builtAt) = floor(0.2) = 0`
    /// 只递减 10 秒（相差 1 秒，到期判定最多延迟一个 tick）。
    func testFractionalSecondRefreshMatchesDirectProjection() throws {
        let importedAt = Date(timeIntervalSince1970: 1_000_000.3)
        let builtAt = importedAt.addingTimeInterval(10.9)
        let now = importedAt.addingTimeInterval(11.1)
        let snapshot = try makeSnapshot(
            importedAt: importedAt,
            buildings: [
                (dataID: 1_000_001, level: 1, remaining: 3_600),
                (dataID: 1_000_002, level: 2, remaining: 11), // 即将到期边界
                (dataID: 1_000_003, level: 3, remaining: nil),
            ]
        )
        let village = VillageProfile(name: "测试村", accountSnapshot: snapshot)

        let p0 = VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home, now: builtAt
        )
        // 直接构建锚点验证：floor(10.9) = 10
        let atBuild = try XCTUnwrap(p0.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(atBuild.remainingSeconds, 3_590)

        let refreshed = p0.refreshingTimers(at: now, builtAt: builtAt, importedAt: importedAt)
        // floor(11.1) = 11 → 递减 11 秒（旧实现只递减 floor(0.2) = 0 秒）
        let upgradedNow = try XCTUnwrap(refreshed.projection.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgradedNow.remainingSeconds, 3_589)
        // 与直接构建 at now 逐位一致
        let directNow = VillageCatalogProjection.project(
            village: village, catalog: catalog, base: .home, now: now
        )
        let directUpgraded = try XCTUnwrap(directNow.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(upgradedNow.remainingSeconds, directUpgraded.remainingSeconds)

        // 到期边界：remaining 11，floor(11.1) = 11 → 归零 → expired。
        // 旧实现 11 - floor(10.9) = 1，再减 floor(0.2) = 0 → 仍为 1 不 expired。
        XCTAssertTrue(refreshed.expired)
        let boundaryNow = try XCTUnwrap(refreshed.projection.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(boundaryNow.remainingSeconds, 0)
    }
}