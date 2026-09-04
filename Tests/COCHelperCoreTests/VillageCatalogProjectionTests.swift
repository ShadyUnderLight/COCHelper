import XCTest
@testable import COCHelperCore

/// 固定种子的可复现随机源（property-based 无外部依赖）。
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &* 0x5851_F42D_4C95_7F2D &+ 0x1405_7B7E_F767_814F
        return state
    }
}

final class VillageCatalogProjectionTests: XCTestCase {
    // MARK: - Helpers

    private var syntheticCatalog: GameCatalog!
    private var stageCatalog: GameCatalog!

    override func setUpWithError() throws {
        syntheticCatalog = try makeCatalog(from: Self.syntheticCatalogJSON)
        stageCatalog = try makeCatalog(from: Self.stageCatalogJSON)
    }

    /// 小型合成目录：加农炮(建筑语义)、野蛮人(单位语义)、建筑工人小屋(builder)、野蛮人木偶(装备无时长)。
    static let syntheticCatalogJSON = """
    {
      "gameVersion": "18.400.13",
      "items": [
        {"section":"buildings","category":"buildings","dataID":1000001,"base":"home","name":"加农炮","maxLevel":2,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":60,"upgradeResource":"Elixir","upgradeCost":200,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":2,"durationSeconds":300,"upgradeResource":"Elixir","upgradeCost":2000,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"units","category":"troops","dataID":4000000,"base":"home","name":"野蛮人","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
           {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"buildings2","category":"buildings","dataID":1000033,"base":"builder","name":"建筑工人小屋","maxLevel":2,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":60,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":2,"durationSeconds":600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"equipment","category":"equipment","dataID":90000000,"base":"home","name":"野蛮人木偶","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"},
           {"level":2,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"},
           {"level":3,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"}
         ]},
        {"section":"buildings","category":"buildings","dataID":1000008,"base":"home","name":"加农炮","maxLevel":2,"displayCategory":"defense",
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":60,"upgradeResource":"Elixir","upgradeCost":200,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":2,"durationSeconds":300,"upgradeResource":"Elixir","upgradeCost":2000,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"buildings","category":"buildings","dataID":1000000,"base":"home","name":"兵营","maxLevel":2,"displayCategory":"military",
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":60,"upgradeResource":"Elixir","upgradeCost":200,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":2,"durationSeconds":300,"upgradeResource":"Elixir","upgradeCost":2000,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"buildings","category":"buildings","dataID":1000013,"base":"home","name":"迫击炮","maxLevel":2,"displayCategory":"defense",
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":60,"upgradeResource":"Gold","upgradeCost":200,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":2,"durationSeconds":300,"upgradeResource":"Gold","upgradeCost":2000,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
         ]}
      ]
    }
    """

    /// Issue #67 阶段上限专用合成目录。与 syntheticCatalogJSON 的关键差异：
    /// 加农炮 dataID 用 1000002——syntheticCatalogJSON 里 1000001 被加农炮占用，
    /// 而 1000001 是真实大本营 dataID（PlayerUnlockLevels 从 buildings 按 dataID
    /// 查大本营等级）；若村庄加农炮记录用 1000001，会把加农炮等级误读成大本营。
    /// 本目录另含带 requiredHeroTavernLevel 的英雄（tavern 门槛 2/4/6/8/10）与
    /// 带 builderHall 门槛（requiredTownHallLevel → builder 语义）的双管加农炮。
    static let stageCatalogJSON = """
    {
      "gameVersion": "18.400.13",
      "items": [
        {"section":"buildings","category":"buildings","dataID":1000002,"base":"home","name":"加农炮","maxLevel":2,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":60,"upgradeResource":"Elixir","upgradeCost":200,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":2,"durationSeconds":300,"upgradeResource":"Elixir","upgradeCost":2000,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"units","category":"troops","dataID":4000000,"base":"home","name":"野蛮人","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
           {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"buildings2","category":"buildings","dataID":1000033,"base":"builder","name":"建筑工人小屋","maxLevel":2,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":60,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":2,"durationSeconds":600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"equipment","category":"equipment","dataID":90000000,"base":"home","name":"野蛮人木偶","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredBlacksmithLevel":1,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"},
           {"level":2,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredBlacksmithLevel":2,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"},
           {"level":3,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredBlacksmithLevel":3,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"}
         ]},
        {"section":"heroes","category":"heroes","dataID":28000000,"base":"home","name":"野蛮人之王","maxLevel":10,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
           {"level":2,"durationSeconds":3600,"upgradeResource":"DarkElixir","upgradeCost":100,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":2,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":3,"durationSeconds":7200,"upgradeResource":"DarkElixir","upgradeCost":200,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":4,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":4,"durationSeconds":10800,"upgradeResource":"DarkElixir","upgradeCost":300,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":4,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":5,"durationSeconds":14400,"upgradeResource":"DarkElixir","upgradeCost":400,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":6,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":6,"durationSeconds":18000,"upgradeResource":"DarkElixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":6,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":7,"durationSeconds":21600,"upgradeResource":"DarkElixir","upgradeCost":600,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":8,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":8,"durationSeconds":25200,"upgradeResource":"DarkElixir","upgradeCost":700,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":8,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":9,"durationSeconds":28800,"upgradeResource":"DarkElixir","upgradeCost":800,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":10,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":10,"durationSeconds":32400,"upgradeResource":"DarkElixir","upgradeCost":900,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"requiredHeroTavernLevel":10,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"buildings2","category":"buildings","dataID":1000042,"base":"builder","name":"双管加农炮","maxLevel":4,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":60,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":2,"durationSeconds":600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":3,"durationSeconds":1800,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":4,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":4,"durationSeconds":3600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":6,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
         ]}
      ]
    }
    """

    private func makeCatalog(from json: String) throws -> GameCatalog {
        let data = Data(json.utf8)
        struct Payload: Decodable {
            let gameVersion: String
            let items: [CatalogItem]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return GameCatalog(gameVersion: payload.gameVersion, items: payload.items)
    }

    private func makeVillage(
        tag: String? = "#TEST",
        objectSections: [String: [AccountItem]] = [:],
        boosts: [String: Int64] = [:]
    ) -> VillageProfile {
        VillageProfile(
            name: "测试村庄",
            accountSnapshot: AccountSnapshot(
                tag: tag,
                capturedAt: nil,
                importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                ageSeconds: nil,
                originalText: "",
                objectSections: objectSections,
                numericSections: [:],
                boosts: boosts,
                unknownTopLevelKeys: [],
                diagnostics: []
            )
        )
    }

    private func makeItem(
        section: String,
        dataID: Int64,
        level: Int? = nil,
        count: Int? = nil,
        timerSeconds: Int64? = nil,
        remainingSeconds: Int64? = nil,
        types: [AccountItem] = [],
        modules: [AccountItem] = [],
        path: String = "0"
    ) -> AccountItem {
        AccountItem(
            id: section + ":" + path,
            section: section,
            dataID: dataID,
            level: level,
            count: count,
            timerSeconds: timerSeconds,
            remainingSeconds: remainingSeconds,
            types: types,
            modules: modules
        )
    }

    private func loadRealFixture() throws -> [String: [AccountItem]] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "anonymized_account_snapshot", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        // now 固定为 fixture timestamp（age = 0）：输入不随运行日期漂移，
        // 全部 timer 记录保持升级中（remaining = raw > 0），测试行为可预测。
        let snapshot = try AccountSnapshotImporter.parse(
            String(data: data, encoding: .utf8) ?? "",
            now: Date(timeIntervalSince1970: 1_785_736_333)
        )
        return snapshot.objectSections
    }

    private func project(
        village: VillageProfile,
        catalog: GameCatalog?,
        expectedGameVersion: String? = nil,  // Issue #74a：默认不自我比较（unverified）
        base: TrackerBase,
        // 默认 now == importedAt（elapsed = 0）：计时记录保持原样，不被快照年龄消耗。
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> VillageCatalogProjection {
        VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            expectedGameVersion: expectedGameVersion,
            base: base,
            now: now
        )
    }

    // MARK: - Base separation

    func testProjectionSeparatesHomeAndBuilderBase() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let builder = project(village: village, catalog: syntheticCatalog, base: .builder)

        XCTAssertEqual(home.items.count, 1)
        XCTAssertEqual(home.items.first?.dataID, 1_000_001)
        XCTAssertEqual(builder.items.count, 1)
        XCTAssertEqual(builder.items.first?.dataID, 1_000_033)
        XCTAssertFalse(home.items.contains { $0.section.hasSuffix("2") })
        XCTAssertTrue(builder.items.allSatisfy { $0.section.hasSuffix("2") })
    }

    // MARK: - Real fixture integration

    func testRealFixtureJoinsAllSupportedCategories() throws {
        let sections = try loadRealFixture()
        let village = makeVillage(objectSections: sections)
        let catalog = GameCatalog.loadBundled()
        let home = project(village: village, catalog: catalog, base: .home)

        let categories = Set(home.items.compactMap(\.category))
        for expected in [
            TrackerCategory.buildings, .traps, .troops, .spells,
            .siegeMachines, .heroes, .pets, .equipment, .guardians,
        ] {
            XCTAssertTrue(categories.contains(expected), "缺少类别 \(expected)")
        }
        // 非嵌套追踪项应全部命中目录（fixture 验证结论）；
        // 嵌套 types/modules 在快照中保留父 section，目录无对应条目 → unknown + 诊断（issue 要求保留可追溯）。
        let tracked = home.items.filter { $0.category != nil && !$0.isNested }
        XCTAssertFalse(tracked.isEmpty)
        XCTAssertTrue(tracked.allSatisfy { $0.status != .unknown },
                       "真实 fixture 的非嵌套追踪项应全部命中目录")

        let nested = home.items.filter(\.isNested)
        XCTAssertFalse(nested.isEmpty, "fixture 应包含嵌套 types 项")
        for item in nested {
            XCTAssertEqual(item.status, .unknown)
            XCTAssertNotNil(item.missingReason, "嵌套项未命中目录时应有缺失原因")
        }
        XCTAssertTrue(nested.contains { $0.dataID == 103_000_011 },
                      "嵌套 types 项 103000011 应可追溯")
    }

    func testRealFixtureUpgradingItemsHaveStaticDuration() throws {
        let sections = try loadRealFixture()
        let village = makeVillage(objectSections: sections)
        let catalog = GameCatalog.loadBundled()
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let home = project(village: village, catalog: catalog, base: .home, now: now)

        let upgrading = home.items.filter(\.isUpgrading)
        XCTAssertFalse(upgrading.isEmpty)
        for item in upgrading {
            if let level = item.currentLevel {
                XCTAssertEqual(item.nextLevel, level + 1)
            } else {
                XCTAssertNil(item.nextLevel)
            }
            XCTAssertNotNil(item.nextLevelDurationSeconds,
                            "升级项 \(item.name) 应有目录完整时长")
            XCTAssertNotNil(item.remainingSeconds)
        }
    }

    // MARK: - Aggregation

    func testDuplicateBuildingsAggregateByLevel() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_013, level: 18, count: nil, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_013, level: 18, count: 1, path: "1"),
                makeItem(section: "buildings", dataID: 1_000_013, level: 17,
                         timerSeconds: 369_441, remainingSeconds: 1000, path: "2"),
                makeItem(section: "buildings", dataID: 1_000_013, level: 17,
                         timerSeconds: 414_387, remainingSeconds: 2000, path: "3"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)

        let lvl18 = home.items.filter { $0.dataID == 1_000_013 && $0.currentLevel == 18 }
        XCTAssertEqual(lvl18.count, 1, "非升级重复记录应合并")
        XCTAssertEqual(lvl18.first?.count, 2)

        let lvl17 = home.items.filter { $0.dataID == 1_000_013 && $0.currentLevel == 17 }
        XCTAssertEqual(lvl17.count, 2, "升级记录各自保留")
        XCTAssertTrue(lvl17.allSatisfy(\.isUpgrading))
    }

    func testAggregatedStateRetainsTimersAndLevels() throws {
        let village = makeVillage(objectSections: [
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2, count: nil, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2, count: nil, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.count, 1)
        XCTAssertEqual(home.items.first?.currentLevel, 2)
        XCTAssertEqual(home.items.first?.count, 2)
        XCTAssertNil(home.items.first?.timerSeconds)
    }

    // MARK: - Status machine

    func testUpgradingItemHasNextLevelAndStaticDuration() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_007, level: 1, path: "lab")],  // 实验室
                        "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 3600, remainingSeconds: 500, path: "0"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first { $0.dataID == 4_000_000 }, "野蛮人记录")
        XCTAssertEqual(item.status, .upgrading)
        XCTAssertEqual(item.nextLevel, 3)
        // 野蛮人 2→3 的目录时长 = levels[2].durationSeconds
        XCTAssertEqual(item.nextLevelDurationSeconds, 3600)
    }

    func testNextLevelNilWhenNotUpgrading() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_007, level: 1, path: "lab")],  // 实验室
                        "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first { $0.dataID == 4_000_000 }, "野蛮人记录")
        XCTAssertNil(item.nextLevel)
        XCTAssertEqual(item.status, .complete)
    }

    func testMaxedWhenLevelReachesCatalogCap() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertEqual(item.status, .maxed)
        XCTAssertEqual(item.maxLevel, 2)
    }

    func testUnsupportedCategoryIsUnavailable() throws {
        let village = makeVillage(objectSections: [
            "helpers": [
                makeItem(section: "helpers", dataID: 93_000_000, level: 1, path: "0"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertEqual(item.status, .unavailable)
        XCTAssertNotNil(item.missingReason)
        XCTAssertEqual(item.category, nil)
    }

    func testUnknownDataIDKeptWithReason() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 3_999_999_999, level: 3, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertEqual(item.status, .unknown)
        XCTAssertEqual(item.dataID, 3_999_999_999, "未知项不得丢弃")
        XCTAssertNotNil(item.missingReason)
        XCTAssertTrue(item.missingReason?.contains("3999999999") == true)
    }

    func testNamePriorityCatalogOverRawID() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.first?.name, "野蛮人")
    }

    func testUnknownItemNameFallsBackToRawID() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 3_999_999_999, level: 3, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.first?.name, "#3999999999")
    }

    // MARK: - Diagnostics

    func testMissingCatalogProducesWarningAndUnknownItems() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let projection = project(village: village, catalog: nil, base: .home)
        XCTAssertTrue(projection.diagnostics.contains { $0.severity == .warning })
        XCTAssertNil(projection.catalogVersion)
        let item = try XCTUnwrap(projection.items.first)
        XCTAssertEqual(item.status, .unknown)
        XCTAssertEqual(item.name, "野蛮人", "目录不可用时名称仍可从现有名称目录解析")
        XCTAssertNil(item.maxLevel)
        XCTAssertNil(item.nextLevelDurationSeconds)
    }

    func testCatalogVersionMismatchProducesWarning() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let projection = project(
            village: village,
            catalog: syntheticCatalog,
            expectedGameVersion: "99.0.0",
            base: .home
        )
        XCTAssertTrue(projection.diagnostics.contains {
            $0.severity == .warning
                && $0.message.contains("99.0.0")
                && $0.path == "GameCatalog/home"
        })
        XCTAssertEqual(projection.catalogVersion, "18.400.13")
    }

    // MARK: - 目录可用性（issue #16：版本不匹配不纳入可确认完成度）

    func testCatalogIsUsableTrueWhenVersionMatches() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let projection = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertTrue(projection.catalogIsUsable, "版本匹配时目录可用于可确认统计")
    }

    func testCatalogIsUsableFalseWhenVersionMismatches() throws {
        // 旧版本目录仍能 join（maxLevel 可用于展示），但行状态不得判 maxed/complete
        // ——Issue #67 fail-closed（P1-2）：版本不匹配时不得产生看似权威的满级状态。
        let staleCatalog = try makeCatalog(from: Self.syntheticCatalogJSON
            .replacingOccurrences(of: "\"gameVersion\": \"18.400.13\"", with: "\"gameVersion\": \"9.9.9\""))
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0")],
        ])
        let projection = project(village: village, catalog: staleCatalog,
                           expectedGameVersion: GameCatalog.defaultBundledVersion, base: .home)
        XCTAssertFalse(projection.catalogIsUsable)
        XCTAssertTrue(projection.diagnostics.contains { $0.severity == .warning })
        // maxLevel 仍保留供 UI 展示（旧目录 join 数据）
        XCTAssertEqual(projection.items.first?.maxLevel, 2)
        // 行状态降级：版本不匹配不得判 maxed（level 2 == 旧 maxLevel 2 也不能）
        XCTAssertEqual(projection.items.first?.status, .unknown,
                       "版本不匹配 → 行状态降级 unknown（fail-closed，P1-2）")
        XCTAssertTrue(projection.items.first?.missingReason?.contains("版本不匹配") == true)
        // 详情页输入数据 fail-closed（P1-2 复审）：nextLevelDuration nil → 详情页
        // 不得标「下一级」；currentStageMaxLevel nil → 不得展示阶段上限——旧目录
        // 等级/时长/费用不得成为可操作数据源。
        XCTAssertNil(projection.items.first?.nextLevelDurationSeconds,
                     "版本不匹配 → 详情页不得从旧目录推断下一级时长")
        XCTAssertNil(projection.items.first?.currentStageMaxLevel,
                     "版本不匹配 → 阶段上限不可计算")
        // 完成度：catalogIsUsable=false 时全部归 unknown（既有契约）
        let total = VillageDetailProjection.totalCompletion(
            from: projection.items, catalogIsUsable: false
        )
        XCTAssertEqual(total.knownCount, 0)
    }

    func testCatalogIsUsableFalseWhenCatalogUnavailable() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let projection = project(village: village, catalog: nil, base: .home)
        XCTAssertFalse(projection.catalogIsUsable)
    }

    func testCatalogIsUsableTrueWhenExpectedVersionNil() throws {
        // expectedGameVersion == nil：不做版本校验（未来版本目录视为可用）。
        let futureCatalog = try makeCatalog(from: Self.syntheticCatalogJSON
            .replacingOccurrences(of: "\"gameVersion\": \"18.400.13\"", with: "\"gameVersion\": \"99.0.0\""))
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let projection = project(village: village, catalog: futureCatalog, expectedGameVersion: nil, base: .home)
        XCTAssertTrue(projection.catalogIsUsable)
    }

    // MARK: - Nested items

    func testNestedModulesKeepSourcePath() throws {
        // 真实解析器行为：嵌套项保留父 section（"heroes"），路径含 ".modules."。
        let module = makeItem(section: "heroes", dataID: 102_000_001, level: 1, path: "0.modules.0")
        let village = makeVillage(objectSections: [
            "heroes": [
                makeItem(section: "heroes", dataID: 28_000_000, level: 3,
                         modules: [module], path: "0"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.count, 2)
        let hero = try XCTUnwrap(home.items.first { !$0.isNested })
        let nested = try XCTUnwrap(home.items.first(where: \.isNested))
        XCTAssertEqual(hero.status, .unknown, "合成目录没有英雄，保留 unknown 而非丢弃")
        XCTAssertTrue(nested.id.contains(".modules."))
        XCTAssertEqual(nested.section, "heroes", "嵌套项保留父 section")
        XCTAssertEqual(nested.isNested, true)
        XCTAssertEqual(nested.status, .unknown)
        XCTAssertNotNil(nested.missingReason)
        XCTAssertTrue(nested.missingReason?.contains("不参与") == true,
                      "嵌套项缺失原因应说明不参与目录 join")
        XCTAssertEqual(nested.name, "钩索塔攻击力模组", "嵌套模块名应解析自模块名称目录")
        XCTAssertNil(nested.maxLevel)
        XCTAssertNil(nested.icon)
    }

    func testNestedItemNeverJoinsParentCatalogDataID() throws {
        // 回归（P2-1）：嵌套 dataID 与父类目录物品相同（4_000_000 = 野蛮人）也不得误命中。
        // 若嵌套项复用父 section join，会错误命中 units:4000000 并显示 complete/maxLevel。
        let module = makeItem(section: "units", dataID: 4_000_000, level: 1, path: "0.modules.0")
        let village = makeVillage(objectSections: [
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         modules: [module], path: "0"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let nested = try XCTUnwrap(home.items.first(where: \.isNested))
        XCTAssertEqual(nested.status, .unknown)
        XCTAssertNil(nested.maxLevel)
        XCTAssertNil(nested.nextLevelDurationSeconds)
        XCTAssertNotNil(nested.missingReason)
    }

    func testAggregationKeySeparatesNestedFromParentAtSameLevel() throws {
        // 回归（P2）：父项与嵌套项同 (section, dataID, level) 时不得合并——
        // 聚合键若不区分 isNested，嵌套项会被并入父项组而消失。
        let module = makeItem(section: "units", dataID: 4_000_000, level: 2, path: "1.modules.0")
        let village = makeVillage(objectSections: [
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         modules: [module], path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        // 两条父项聚合为一条（count 2），嵌套项独立保留：共 2 条。
        XCTAssertEqual(home.items.count, 2,
                       "父项与嵌套项同键时嵌套项不得消失")
        let flat = try XCTUnwrap(home.items.first { !$0.isNested })
        let nested = try XCTUnwrap(home.items.first(where: \.isNested))
        XCTAssertEqual(flat.count, 2)
        XCTAssertEqual(flat.isNested, false)
        XCTAssertEqual(nested.status, .unknown)
        XCTAssertTrue(nested.id.contains(".modules."))
        XCTAssertEqual(nested.currentLevel, 2)
    }

    func testAggregateKeepsNestedItemsWithDifferentRootParentsSeparate() throws {
        // 回归（issue #37 展示分类评审）：聚合键若缺根父身份，两个不同根父下的
        // 同 dataID/level 嵌套项会合并为一条，displayCategory 取 first → 嵌套项错归展示分类组。
        // 根父必须真实存在于快照（records() 第一遍扫描以平铺项构建根父 dataID 映射）。
        let nestedA = makeItem(section: "buildings", dataID: 103_000_011, level: 1, path: "1.types.0")
        let nestedB = makeItem(section: "buildings", dataID: 103_000_011, level: 1, path: "2.types.0")
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_008, level: 1,
                         types: [nestedA], path: "1"),
                makeItem(section: "buildings", dataID: 1_000_000, level: 1,
                         types: [nestedB], path: "2"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let nested = home.items.filter(\.isNested)
        XCTAssertEqual(nested.count, 2, "不同根父的同 dataID/level 嵌套项不得合并")
        func stripped(_ id: String) -> String { id.hasPrefix("agg:") ? String(id.dropFirst(4)) : id }
        let underCannon = try XCTUnwrap(nested.first { stripped($0.id) == "buildings:1.types.0" })
        let underBarracks = try XCTUnwrap(nested.first { stripped($0.id) == "buildings:2.types.0" })
        XCTAssertEqual(underCannon.displayCategory, .defense, "加农炮(1000008)后代跟随防御")
        XCTAssertEqual(underBarracks.displayCategory, .military, "兵营(1000000)后代跟随军事")
    }

    func testFinishedTimerSurvivesAggregationAsNeedsReimport() throws {
        // 回归（P1）：计时已结束（timer 存在、remaining 归零）的记录聚合后必须保留
        // 「需重新导入」信号（timerSeconds 非 nil、remainingSeconds == 0），
        // 不能与普通完成状态混淆。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_007, level: 1, path: "lab")],  // 实验室
                        "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 3600, remainingSeconds: 0, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.filter { $0.dataID == 4_000_000 }.count, 1, "实验室记录不计入野蛮人聚合")
        let item = try XCTUnwrap(home.items.first { $0.dataID == 4_000_000 }, "野蛮人聚合项")
        XCTAssertEqual(item.count, 2)
        XCTAssertNotNil(item.timerSeconds, "计时已结束信号不能因聚合丢失")
        XCTAssertEqual(item.remainingSeconds, 0)
        XCTAssertFalse(item.isUpgrading)
        XCTAssertEqual(item.status, .complete)
        XCTAssertNil(item.nextLevel)
    }

    func testMalformedTimerWithoutRemainingDoesNotBecomeNeedsReimport() throws {
        // 回归（P2-1）：malformed 快照记录（有 timer 无 remaining：timerSeconds=600、
        // remainingSeconds=nil）不得在聚合时被当作「计时已结束」——旧实现只检查
        // timer 存在就把聚合项强制写成 remainingSeconds = 0，导致 UI 误报
        // 「待重新导入确认」。聚合后必须回到普通完成状态：无 timer、无 remaining。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_007, level: 1, path: "lab")],  // 实验室
                        "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 600, remainingSeconds: nil, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.filter { $0.dataID == 4_000_000 }.count, 1, "实验室记录不计入野蛮人聚合")
        let item = try XCTUnwrap(home.items.first { $0.dataID == 4_000_000 }, "野蛮人聚合项")
        XCTAssertEqual(item.count, 2)
        XCTAssertNil(item.timerSeconds, "malformed 记录不得伪造计时结束信号")
        XCTAssertNil(item.remainingSeconds, "malformed 记录不得强制写入 remainingSeconds = 0")
        XCTAssertFalse(item.needsReimport, "malformed 记录不得误报「待重新导入」")
        XCTAssertEqual(item.status, .complete)
    }

    func testMixedGroupFinishedTimerWithMalformedKeepsReimportSignal() throws {
        // 回归（P2-1 覆盖缺口，场景 d）：同键组内既有合法计时结束记录
        // （timer=3600、remaining=0）又有 malformed 记录（有 timer 无 remaining）时，
        // 聚合项必须保留「计时已结束」信号——组内确实存在计时结束实例，
        // 不得因 malformed 记录参与聚合而把 needsReimport 一起吞掉。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_007, level: 1, path: "lab")],  // 实验室
                        "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 3600, remainingSeconds: 0, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 600, remainingSeconds: nil, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.filter { $0.dataID == 4_000_000 }.count, 1, "实验室记录不计入野蛮人聚合")
        let item = try XCTUnwrap(home.items.first { $0.dataID == 4_000_000 }, "野蛮人聚合项")
        XCTAssertEqual(item.count, 2)
        XCTAssertNotNil(item.timerSeconds,
                        "组内合法计时结束实例的信号不能因 malformed 记录而丢失")
        XCTAssertEqual(item.remainingSeconds, 0)
        XCTAssertTrue(item.needsReimport,
                      "组内存在计时结束实例时聚合项必须报「待重新导入」")
        XCTAssertEqual(item.status, .complete)
        XCTAssertFalse(item.isUpgrading)
    }

    /// mixed 组（已结束计时 + malformed 记录）的反序变体：malformed 在前时
    /// 代表值不得被污染（filter{remaining==0} 后取 min；旧 first 实现会取到
    /// malformed 的 timer 值）。issue 验收 #6 的次序无关性延伸。
    func testMixedGroupFinishedTimerWithMalformedReversedOrder() throws {
        func makeItem(_ timer: Int64?, _ remaining: Int64?, path: String) -> AccountItem {
            AccountItem(
                id: "buildings:" + path,
                section: "buildings",
                dataID: 1_000_032,
                level: 12,
                timerSeconds: timer,
                remainingSeconds: remaining
            )
        }
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(600, nil, path: "0"),   // malformed：有 timer 无 remaining
                makeItem(3_600, 0, path: "1"),   // 已结束
            ],
        ])
        let projection = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(projection.items.first { $0.dataID == 1_000_032 })
        XCTAssertEqual(item.timerSeconds, 3_600, "代表值必须来自已结束记录（不得取 malformed 的 600）")
        XCTAssertTrue(item.needsReimport)
    }

    func testMixedGroupUpgradingWithMalformedStaysSeparated() throws {
        // 回归（P2-1 覆盖缺口，场景 e）：同键组内升级记录与 malformed 记录并存时，
        // 升级记录必须单独保留（不聚合、count 独立），malformed 记录进「|idle」组
        // 聚合成普通完成项（无 timer、无 remaining、不报「待重新导入」）——
        // 不得混入升级组、不得伪造升级/计时结束状态。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_007, level: 1, path: "lab")],  // 实验室
                        "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2, count: 1,
                         timerSeconds: 3600, remainingSeconds: 300, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 600, remainingSeconds: nil, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.filter { $0.dataID == 4_000_000 }.count, 2,
                       "升级记录与 |idle 聚合项必须各自保留（实验室记录不计入）")
        let upgrading = try XCTUnwrap(home.items.first(where: \.isUpgrading))
        XCTAssertEqual(upgrading.count, 1)
        XCTAssertTrue(upgrading.isUpgrading)
        XCTAssertEqual(upgrading.status, .upgrading)
        XCTAssertEqual(upgrading.remainingSeconds, 300)
        XCTAssertEqual(upgrading.timerSeconds, 3600)
        XCTAssertFalse(upgrading.needsReimport)

        let idle = try XCTUnwrap(home.items.first { !$0.isUpgrading && $0.dataID == 4_000_000 }, "malformed 聚合项")
        XCTAssertEqual(idle.status, .complete, "malformed 记录不得混入升级组")
        XCTAssertEqual(idle.count, 1)
        XCTAssertNil(idle.timerSeconds, "malformed 记录不得伪造计时结束信号")
        XCTAssertNil(idle.remainingSeconds)
        XCTAssertFalse(idle.needsReimport, "malformed 记录不得误报「待重新导入」")
        XCTAssertNil(idle.nextLevel)
    }

    // MARK: - Property-based tests

    private func makeRandomSnapshot(
        rng: inout SeededRNG,
        count: Int,
        dataIDPool: [Int64],
        sections: [String]
    ) -> [String: [AccountItem]] {
        var result: [String: [AccountItem]] = [:]
        for index in 0..<count {
            let section = sections[Int.random(in: 0..<sections.count, using: &rng)]
            let dataID = dataIDPool[Int.random(in: 0..<dataIDPool.count, using: &rng)]
            let level = Int.random(in: 1...5, using: &rng)
            let upgrading = Bool.random(using: &rng)
            let item = makeItem(
                section: section,
                dataID: dataID,
                level: level,
                count: Bool.random(using: &rng) ? Int.random(in: 1...5, using: &rng) : nil,
                timerSeconds: upgrading ? Int64(1000) : nil,
                remainingSeconds: upgrading ? Int64(Int.random(in: 1...999, using: &rng)) : nil,
                path: String(index)
            )
            result[section, default: []].append(item)
        }
        return result
    }

    func testPropertyHomeNeverContainsBuilderSections() throws {
        var rng = SeededRNG(seed: 42)
        let sections = ["buildings", "units", "buildings2", "units2", "traps2"]
        let pool: [Int64] = [1_000_001, 4_000_000, 1_000_033, 12_000_010]
        for _ in 0..<20 {
            let snapshot = makeRandomSnapshot(
                rng: &rng, count: 30, dataIDPool: pool, sections: sections
            )
            let village = makeVillage(objectSections: snapshot)
            let home = project(village: village, catalog: syntheticCatalog, base: .home)
            XCTAssertFalse(home.items.contains { $0.section.hasSuffix("2") },
                           "主村投影混入建筑工人基地项目")
            let builder = project(village: village, catalog: syntheticCatalog, base: .builder)
            XCTAssertFalse(builder.items.contains { !$0.section.hasSuffix("2") },
                           "建筑工人基地投影混入主村项目")
        }
    }

    func testPropertyNextLevelFollowsUpgradingOnly() throws {
        var rng = SeededRNG(seed: 7)
        let sections = ["units", "buildings"]
        let pool: [Int64] = [4_000_000, 1_000_001]
        for _ in 0..<20 {
            let snapshot = makeRandomSnapshot(
                rng: &rng, count: 25, dataIDPool: pool, sections: sections
            )
            let village = makeVillage(objectSections: snapshot)
            let home = project(village: village, catalog: syntheticCatalog, base: .home)
            for item in home.items {
                if item.isUpgrading, let level = item.currentLevel {
                    XCTAssertEqual(item.nextLevel, level + 1)
                } else {
                    XCTAssertNil(item.nextLevel,
                                 "nextLevel 只允许显式推断当前等级 + 1")
                }
            }
        }
    }

    func testNextLevelNilWhenLevelUnknownEvenUpgrading() throws {
        // issue 语义：当前等级未知时不得推断目标等级（0 级推断是错误）。
        let village = makeVillage(objectSections: [
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: nil,
                         timerSeconds: 1000, remainingSeconds: 500, path: "0"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertTrue(item.isUpgrading)
        XCTAssertEqual(item.status, .upgrading)
        XCTAssertNil(item.nextLevel)
        XCTAssertNil(item.nextLevelDurationSeconds)
    }

    func testIdleCatalogHitItemGetsNextLevelDuration() throws {
        // issue #16：普通建筑（非升级、目录命中、未满级）行显示下一等级时间。
        // stageCatalog 加农炮 buildings:1000002 maxLevel=2（TH 门槛 1/2），村庄大本营
        // 12 级满足全部门槛 → 阶段上限 2；level 1 未满级 → 推下一级（2 级）时长 300s。
        // 注：不能用 syntheticCatalog 的 1000001（加农炮）——1000001 是真实大本营
        // dataID，村庄加农炮记录会被 PlayerUnlockLevels 误读成大本营等级（Issue #67 测试数据约定）。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),  // 大本营
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),   // 加农炮
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(item.status, .complete)
        XCTAssertNil(item.nextLevel, "#14：目标等级只允许升级中显式推断")
        XCTAssertEqual(item.nextLevelDurationSeconds, 300, "目录命中的未满级项应有下一级时长")
    }

    func testMaxedItemHasNoNextLevelDuration() throws {
        // 已满级（level >= maxLevel）：没有下一级，不推时长。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertEqual(item.status, .maxed)
        XCTAssertNil(item.nextLevelDurationSeconds)
    }

    func testEquipmentWithoutDurationStaysNil() throws {
        // issue 数据边界：装备缺少升级时长时显示「暂无目录数据」——
        // 目录命中但该级 durationSeconds 为 nil 时不得伪造时长。
        let village = makeVillage(objectSections: [
            "equipment": [makeItem(section: "equipment", dataID: 90_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertEqual(item.status, .complete)
        XCTAssertNil(item.nextLevelDurationSeconds, "目录该级无时长数据时保持 nil")
    }

    func testAggregatedIdleItemsPreserveDuration() throws {
        // 非升级重复项聚合后保留代表记录的下一级时长。
        // 用 stageCatalog：大本营 1000001@2（阶段上限 2）+ 加农炮 1000002@1 ×2
        // → level 1 < stage 2 → complete，时长推断可用（synthetic 的 1000001
        // 是加农炮且会被 PlayerUnlockLevels 误读为大本营，见 stageCatalogJSON 注释）。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertTrue(item.id.hasPrefix("agg:"), "非升级重复项应聚合")
        XCTAssertEqual(item.count, 2)
        XCTAssertEqual(item.nextLevelDurationSeconds, 300, "聚合项应保留下一级时长")
    }

    func testPropertyStatusAssignmentIsExhaustiveAndExclusive() throws {
        var rng = SeededRNG(seed: 99)
        let sections = ["units", "buildings", "helpers", "traps2", "equipment"]
        // 加农炮用 1000002（stageCatalog）：pool 不含任何解锁建筑（1000001/1000007/
        // 1000071/1000034/1000046/1000070）→ 所有 requirement 型 item（含 Issue #97
        // 起带 .blacksmith 门槛的 equipment）阶段上限不可计算 → 回退全局 maxLevel，
        // oracle 保持 level >= maxLevel 判定（见 stageCatalogJSON 注释）。
        let pool: [Int64] = [4_000_000, 1_000_002, 93_000_000, 12_000_010, 90_000_000]
        // stageCatalog 收录键（section, dataID, base）：oracle 独立于输出状态计算。
        // stageCatalog 有 6 项，pool 涉及 4 项：units 4000000(home)、buildings 1000002(home)、
        // buildings2 1000033(builder)、equipment 90000000(home)。
        let catalogHits: Set<String> = [
            "units:4000000:home", "buildings:1000002:home",
            "buildings2:1000033:builder", "equipment:90000000:home",
        ]
        for _ in 0..<20 {
            let snapshot = makeRandomSnapshot(
                rng: &rng, count: 40, dataIDPool: pool, sections: sections
            )
            let village = makeVillage(objectSections: snapshot)
            for base in TrackerBase.allCases {
                let projection = project(village: village, catalog: stageCatalog, base: base)
                XCTAssertFalse(projection.items.isEmpty)
                for item in projection.items {
                    let expected: VillageItemStatus
                    let isBuilderSection = item.section.hasSuffix("2")
                    if item.category == nil {
                        // helpers 等不支持类别（投影保留为 unavailable）。
                        expected = .unavailable
                    } else if isBuilderSection != (base == .builder) {
                        // map 的 guard 会丢弃跨基地记录；此分支不应出现。
                        XCTFail("跨基地记录不应出现在投影中: \(item.section):\(item.dataID)")
                        continue
                    } else if item.isUpgrading {
                        // 升级状态独立于目录。
                        expected = .upgrading
                    } else if !catalogHits.contains("\(item.section):\(item.dataID):\(base.rawValue)") {
                        expected = .unknown
                    } else if item.currentStageMaxLevel == nil {
                        // pool 不含解锁建筑 → 有 requirement 的 item 阶段上限不可计算
                        // → unverified（Issue #67 fail-closed，取代旧的「回退全局」语义）。
                        // equipment 自 Issue #97 起带 .blacksmith 门槛 → 同样不可计算。
                        expected = .unverified
                    } else if item.currentLevel ?? -1 >= (item.currentStageMaxLevel ?? .max) {
                        expected = .maxed
                    } else {
                        expected = .complete
                    }
                    XCTAssertEqual(item.status, expected,
                                   "\(item.section):\(item.dataID)@\(item.currentLevel ?? -1) 状态不符")
                }
            }
        }
    }

    func testPropertyAggregatedCountAtLeastRecordCount() throws {
        var rng = SeededRNG(seed: 1234)
        let sections = ["units"]
        let pool: [Int64] = [4_000_000]
        for _ in 0..<20 {
            let snapshot = makeRandomSnapshot(
                rng: &rng, count: 20, dataIDPool: pool, sections: sections
            )
            let village = makeVillage(objectSections: snapshot)
            let home = project(village: village, catalog: syntheticCatalog, base: .home)
            // 输入：同 (section,dataID,level) 的非升级记录，每条按 (count ?? 1) 计。
            var expectedByKey: [String: Int] = [:]
            for record in snapshot["units"] ?? [] where (record.remainingSeconds ?? 0) <= 0 {
                let key = "\(record.section):\(record.dataID):\(record.level.map(String.init) ?? "nil")"
                expectedByKey[key, default: 0] += record.count ?? 1
            }
            // 输出：聚合项 count 必须等于输入之和（非升级组），且逐组一一对应。
            let outputByKey = Dictionary(grouping: home.items.filter { !$0.isUpgrading }) {
                "\($0.section):\($0.dataID):\($0.currentLevel.map(String.init) ?? "nil")"
            }
            XCTAssertEqual(Set(outputByKey.keys), Set(expectedByKey.keys),
                           "聚合分组应与输入非升级记录一致")
            for (key, group) in outputByKey {
                XCTAssertEqual(group.count, 1, "非升级同键记录应合并为一条")
                XCTAssertEqual(group.first?.count, expectedByKey[key],
                               "key \(key) 聚合 count 应等于输入 (count ?? 1) 之和")
            }
        }
    }

    // MARK: - 聚合 count 归一化与饱和（issue #66 外部评审 P2 闭环）

    func testAggregateNormalizesInvalidCountsBeforeSumming() throws {
        // 同 (section,dataID,level) 4 条非升级记录 count=[5, 0, -3, nil]：
        // 聚合 count == 8（instanceWeight 契约：nil/≤0 计 1 → 5+1+1+1）。
        // 旧实现裸相加得 5+0−3+1 = 3：丢失实例贡献、可制造负值。
        // 用 stageCatalog（加农炮 1000002）+ 大本营 1000001@12：阶段上限 2，
        // level 1 未满级 → complete（synthetic 的 1000001 被加农炮占用，见 stageCatalogJSON 注释）。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, count: 5, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, count: 0, path: "1"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, count: -3, path: "2"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, count: nil, path: "3"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.count, 8,
                       "非法 count（0/−3）按 instanceWeight 计 1，不得累加 0/负值")

        // 全链路：聚合行权重进入完成度统计（level 1 < 阶段上限 2 → 全 complete）。
        let total = VillageDetailProjection.totalCompletion(from: home.items)
        XCTAssertEqual(total.knownCount, 8, "got known=\(total.knownCount)")
        XCTAssertEqual(total.completedCount, 0)
        XCTAssertEqual(total.unknownCount, 1, "大本营 1000001 未收录于 stageCatalog → unknown 行")
    }

    func testAggregateSaturatesHugeCounts() throws {
        // 两条 count=Int.max 同键记录：聚合层必须在统计层饱和保护之前就饱和，
        // 裸相加会在 debug 构建 SIGTRAP 崩溃整个测试进程（非断言失败）——
        // 故测试与修复同 commit，运行验证以新实现无崩溃且饱和为准。
        // stageCatalog 加农炮 1000002 + 大本营 1000001@12（阶段上限 2，level 1 未满级）。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, count: Int.max, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, count: Int.max, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.count, Int.max, "聚合层溢出必须饱和到 Int.max")

        let total = VillageDetailProjection.totalCompletion(from: home.items)
        XCTAssertEqual(total.knownCount, Int.max, "got known=\(total.knownCount)")
        XCTAssertEqual(total.completedCount, 0)
        XCTAssertEqual(total.unknownCount, 1, "大本营 1000001 未收录于 stageCatalog → unknown 行")
        // 第 7 轮修复回归：聚合行单行 count=Int.max 求和恰好 Int.max 无算术溢出，
        // 若聚合层饱和标志不传播，统计层会误判 saturated == false（契约绕过）。
        XCTAssertTrue(total.saturated, "聚合层饱和标志必须传播到统计层")
    }

    func testAggregateSaturationFlagPropagatesToStats() throws {
        // 第 7 轮修复回归：同键两条 maxed count=Int.max 经聚合层饱和为单行
        // count=Int.max（原始和 = 2×Int.max > Int.max，确实溢出）。聚合行单行
        // 求和恰好 Int.max 无算术溢出——若聚合层饱和标志不传播，统计层会误判
        // saturated == false，isFullyMaxed 契约在链路前端被绕过（completed == known
        // 且无 unknown → 误判满级，百分比可显示 100%）。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 2, count: Int.max, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_001, level: 2, count: Int.max, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.count, 1, "同键非升级记录应聚合为一条")
        let aggregated = try XCTUnwrap(home.items.first)
        XCTAssertEqual(aggregated.count, Int.max, "聚合层溢出必须饱和到 Int.max")
        XCTAssertEqual(aggregated.status, .maxed, "level 2 == maxLevel 2 → maxed")

        let total = VillageDetailProjection.totalCompletion(from: home.items)
        XCTAssertEqual(total.knownCount, Int.max, "got known=\(total.knownCount)")
        XCTAssertEqual(total.completedCount, Int.max, "got completed=\(total.completedCount)")
        XCTAssertEqual(total.unknownCount, 0)
        XCTAssertTrue(total.saturated, "聚合层饱和标志必须传播到统计层（fail-closed 契约不得在链路前端被绕过）")
        XCTAssertFalse(total.isFullyMaxed, "饱和数据不得判满级（fail closed）")
        XCTAssertNil(total.completionRatio, "饱和数据不得给出百分比")
    }

    // MARK: - 完成度全链路（issue #66：投影聚合 × count 加权）

    /// 真实 bundled 目录（加农炮 buildings:1000008 maxLevel=21）全链路：
    /// 6 条 21 级（count 各 1）+ 1 条 20 级 → 聚合 2 行（count 6/1）→
    /// totalCompletion (7, 6, 0)、ratio 6/7。锁住 bug 根因「行数 ≠ 实例数」。
    func testFullChainCompletionWeightedByCount() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        // 契约硬化（审核 B）：等级锚点从 bundled 目录动态读取——目录升级立即红并
        // 提示更新本用例，避免硬编码等级在目录漂移后静默失效。
        XCTAssertEqual(catalog.gameVersion, GameCatalog.defaultBundledVersion,
                       "bundled 目录版本已升级，请更新本用例锚点")
        let cannon = try XCTUnwrap(
            catalog.item(section: "buildings", dataID: 1_000_008),
            "bundled 目录应包含 buildings:1000008（加农炮）"
        )
        XCTAssertEqual(cannon.maxLevel, 21,
                       "bundled 目录已升级：加农炮 maxLevel 应为 21，请更新本用例锚点")
        let maxedLevel = cannon.maxLevel       // = 21（上面已锚定）
        let lowerLevel = cannon.maxLevel - 1   // = 20

        let cannon21 = (0..<6).map { i in
            makeItem(section: "buildings", dataID: 1_000_008, level: maxedLevel, count: 1, path: "c\(i)")
        }
        let cannon20 = makeItem(section: "buildings", dataID: 1_000_008, level: lowerLevel, count: 1, path: "c6")
        let village = makeVillage(objectSections: ["buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th"),
            ] + cannon21 + [cannon20]])
        let home = project(village: village, catalog: catalog, base: .home)

        XCTAssertTrue(home.catalogIsUsable)
        // 投影聚合形态：7 条实例记录 → 2 行（行数 < 实例数，聚合真实发生）。
        let cannons = home.items.filter { $0.dataID == 1_000_008 }
        XCTAssertEqual(cannons.count, 2, "6 条 21 级 + 1 条 20 级应聚合为 2 行")
        let maxedRow = try XCTUnwrap(cannons.first { $0.currentLevel == maxedLevel })
        XCTAssertEqual(maxedRow.count, 6, "21 级聚合行 count = 6")
        XCTAssertEqual(maxedRow.status, .maxed)
        let lowerRow = try XCTUnwrap(cannons.first { $0.currentLevel == lowerLevel })
        XCTAssertEqual(lowerRow.count, 1)
        XCTAssertEqual(lowerRow.status, .complete)

        // 加权统计：实例口径 7 = 6 + 1（行数口径只有 2，必错）。
        // 统计仅针对被测加农炮（TH 记录本身满级会 +1，须过滤）。
        let targetItems = home.items.filter { $0.dataID == 1_000_008 }
        let total = VillageDetailProjection.totalCompletion(from: targetItems)
        XCTAssertEqual(total.knownCount, 7, "got known=\(total.knownCount)")
        XCTAssertEqual(total.completedCount, 6, "got completed=\(total.completedCount)")
        XCTAssertEqual(total.unknownCount, 0)
        XCTAssertEqual(total.completionRatio ?? -1, 6.0 / 7.0, accuracy: 0.0001)
        XCTAssertFalse(total.isFullyMaxed, "1 条未满级实例 → 不得判满级")

        // 全链路防御组（审核 B）：加农炮 1000008 投影后 displayCategory == .defense
        //（Issue #75 工作流 C：catalog displayCategory 字段标注 defense，
        // section buildings + base home），
        // 组统计与总统计同口径 (7, 6, 0)，且 known + unknown == 该组 Σweight（守恒）。
        let stats = VillageDetailProjection.completionStats(from: targetItems)
        let defense = try XCTUnwrap(
            stats.first { $0.displayCategory == .defense },
            "加农炮 1000008 投影后应归防御组；实际组: \(stats.map { $0.id })"
        )
        XCTAssertEqual(defense.knownCount, 7, "got known=\(defense.knownCount)")
        XCTAssertEqual(defense.completedCount, 6, "got completed=\(defense.completedCount)")
        XCTAssertEqual(defense.unknownCount, 0, "got unknown=\(defense.unknownCount)")
        let defenseGroup = try XCTUnwrap(
            VillageDetailProjection.groups(from: home.items).first { $0.displayCategory == .defense }
        )
        // 同 testFullChainCompletionWeightedByCount：宇宙差集 .available 项
        // 不参与完成度统计，守恒只针对组内观测项。
        let defenseObserved = defenseGroup.items.filter { $0.status != .available }
        XCTAssertEqual(
            defense.knownCount + defense.unknownCount,
            VillageDetailProjection.instanceCount(of: defenseObserved),
            "防御组三列守恒：known + unknown == 该组 Σweight（宇宙差集项不参与完成度统计）"
        )
    }

    /// 300 条满级城墙（buildings:1000010 maxLevel=19）+ 25 条 18 级 →
    /// 聚合 2 行（count 300/25）→ (325, 300, 0)、ratio 300/325。
    func testFullChainWalls300Maxed25Lower() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        // 契约硬化（审核 B）：等级锚点从 bundled 目录动态读取（同
        // testFullChainCompletionWeightedByCount）。
        XCTAssertEqual(catalog.gameVersion, GameCatalog.defaultBundledVersion,
                       "bundled 目录版本已升级，请更新本用例锚点")
        let wall = try XCTUnwrap(
            catalog.item(section: "buildings", dataID: 1_000_010),
            "bundled 目录应包含 buildings:1000010（城墙）"
        )
        XCTAssertEqual(wall.maxLevel, 19,
                       "bundled 目录已升级：城墙 maxLevel 应为 19，请更新本用例锚点")
        let maxedLevel = wall.maxLevel        // = 19（上面已锚定）
        let lowerLevel = wall.maxLevel - 1    // = 18

        let walls19 = (0..<300).map { i in
            makeItem(section: "buildings", dataID: 1_000_010, level: maxedLevel, count: 1, path: "w\(i)")
        }
        let walls18 = (0..<25).map { i in
            makeItem(section: "buildings", dataID: 1_000_010, level: lowerLevel, count: 1, path: "l\(i)")
        }
        let village = makeVillage(objectSections: ["buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th"),
            ] + walls19 + walls18])
        let home = project(village: village, catalog: catalog, base: .home)

        XCTAssertTrue(home.catalogIsUsable)
        let walls = home.items.filter { $0.dataID == 1_000_010 }
        XCTAssertEqual(walls.count, 2, "325 条实例记录应聚合为 2 行（行数 < 实例数）")
        let maxedRow = try XCTUnwrap(walls.first { $0.currentLevel == maxedLevel })
        XCTAssertEqual(maxedRow.count, 300)
        XCTAssertEqual(maxedRow.status, .maxed)
        let lowerRow = try XCTUnwrap(walls.first { $0.currentLevel == lowerLevel })
        XCTAssertEqual(lowerRow.count, 25)
        XCTAssertEqual(lowerRow.status, .complete)

        // 统计仅针对被测城墙（TH 记录本身满级会 +1，须过滤）。
        let targetItems = home.items.filter { $0.dataID == 1_000_010 }
        let total = VillageDetailProjection.totalCompletion(from: targetItems)
        XCTAssertEqual(total.knownCount, 325, "got known=\(total.knownCount)")
        XCTAssertEqual(total.completedCount, 300, "got completed=\(total.completedCount)")
        XCTAssertEqual(total.unknownCount, 0)
        XCTAssertEqual(total.completionRatio ?? -1, 300.0 / 325.0, accuracy: 0.0001)

        // 全链路城墙组（Issue #123）：城墙 1000010 投影后 displayCategory == .walls
        //（Issue #75 工作流 C：catalog displayCategory 字段标注 walls，分类从
        // defense 迁入 walls），组统计 == (325, 300, 0)，且 known + unknown ==
        // 该组 Σweight（守恒）。
        let stats = VillageDetailProjection.completionStats(from: targetItems)
        let wallsStats = try XCTUnwrap(
            stats.first { $0.displayCategory == .walls },
            "城墙 1000010 投影后应归城墙组；实际组: \(stats.map { $0.id })"
        )
        XCTAssertEqual(wallsStats.knownCount, 325, "got known=\(wallsStats.knownCount)")
        XCTAssertEqual(wallsStats.completedCount, 300, "got completed=\(wallsStats.completedCount)")
        XCTAssertEqual(wallsStats.unknownCount, 0, "got unknown=\(wallsStats.unknownCount)")
        let wallsGroup = try XCTUnwrap(
            VillageDetailProjection.groups(from: home.items).first { $0.displayCategory == .walls }
        )
        // Issue #70 阶段 2：宇宙差集 .available 项会进城墙组（TH18 全宇宙），
        // 但完成度统计（isKnown）显式排除差集项——守恒只针对观测项
        //（known + unknown == 组内非差集 Σweight）。
        let wallsObserved = wallsGroup.items.filter { $0.status != .available }
        XCTAssertEqual(
            wallsStats.knownCount + wallsStats.unknownCount,
            VillageDetailProjection.instanceCount(of: wallsObserved),
            "城墙组三列守恒：known + unknown == 该组 Σweight（宇宙差集项不参与完成度统计）"
        )
    }

    // MARK: - VillageItemState.assetMissingReason 谓词

    /// 直接构造状态（成员初始化器，@testable 可访问），用于验证 assetMissingReason 真值表。
    private func makeAssetState(
        icon: CatalogAssetRef?,
        levelVisual: CatalogAssetRef?,
        currentLevelIcon: CatalogAssetRef? = nil,
        currentLevelVisual: CatalogAssetRef? = nil
    ) -> VillageItemState {
        VillageItemState(
            id: "units:0",
            section: "units",
            dataID: 4_000_000,
            base: .home,
            name: "野蛮人",
            category: .troops,
            currentLevel: 2,
            count: nil,
            timerSeconds: nil,
            remainingSeconds: nil,
            nextLevel: 3,
            nextLevelDurationSeconds: 3600,
            nextLevelDurationState: nil,
            maxLevel: 3,
            status: .complete,
            missingReason: nil,
            catalogItemMissingReason: nil,
            availability: .unconfigured,
            icon: icon,
            levelVisual: levelVisual,
            currentLevelIcon: currentLevelIcon,
            currentLevelVisual: currentLevelVisual,
            isNested: false
        )
    }

    func testAssetMissingReasonTruthTable() throws {
        // 公共谓词真值表：icon 缺失原因优先，levelVisual 兜底；两者均可用才返回 nil。
        // 用不同的原因串区分返回值来源，验证优先级而非只看非 nil。
        let iconMissing = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: nil, missingReason: "icon_missing_reason"
        )
        let levelVisualMissing = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: nil, missingReason: "level_visual_missing_reason"
        )
        let iconRenderable = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: "icons/barracks.png", missingReason: nil
        )

        XCTAssertEqual(
            makeAssetState(icon: iconMissing, levelVisual: levelVisualMissing).assetMissingReason,
            "icon_missing_reason",
            "icon 缺失 + levelVisual 缺失 → 返回 icon 的原因（icon 优先）"
        )
        XCTAssertEqual(
            makeAssetState(icon: iconMissing, levelVisual: nil).assetMissingReason,
            "icon_missing_reason",
            "icon 缺失 + levelVisual nil → 返回 icon 的原因"
        )
        XCTAssertEqual(
            makeAssetState(icon: nil, levelVisual: levelVisualMissing).assetMissingReason,
            "level_visual_missing_reason",
            "icon nil + levelVisual 缺失 → 返回 levelVisual 的原因（修复核心场景）"
        )
        XCTAssertNil(
            makeAssetState(icon: nil, levelVisual: nil).assetMissingReason,
            "icon nil + levelVisual nil → nil（无缺失，不显示角标）"
        )
        XCTAssertEqual(
            makeAssetState(icon: iconRenderable, levelVisual: levelVisualMissing).assetMissingReason,
            "level_visual_missing_reason",
            "icon 可渲染 + levelVisual 缺失 → 返回 levelVisual 的原因（icon 可渲染不代表 levelVisual 不缺失）"
        )
    }

    /// P2 扩展（Issue #39）：assetMissingReason 必须覆盖 current-level 资产。
    /// level-level 缺失优先于 item-level（显示链首选缺失最值得提示），
    /// 同层级内 icon 优先（保持 #34 缺失原因哲学）。
    func testAssetMissingReasonCoversCurrentLevelAssets() throws {
        let itemIconMissing = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: nil, missingReason: "item_icon_missing"
        )
        let levelIconMissing = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: nil, missingReason: "level_icon_missing"
        )
        let levelLevelVisualMissing = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: nil, missingReason: "level_lv_missing"
        )
        let renderable = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: "icons/barracks.png", missingReason: nil
        )

        // 当前等级 levelVisual 缺失 + item-level 全部可渲染 → 必须提示 level 级缺失
        // （P2 核心场景：buildings:1000059 Lv2-9 静默回退的修复）。
        XCTAssertEqual(
            makeAssetState(icon: renderable, levelVisual: renderable,
                           currentLevelVisual: levelLevelVisualMissing).assetMissingReason,
            "level_lv_missing",
            "currentLevelVisual 缺失 → 返回其缺失原因（即使 item-level 可渲染）"
        )
        // 同层级 icon 优先：currentLevelIcon 缺失优先于 currentLevelVisual 缺失。
        XCTAssertEqual(
            makeAssetState(icon: renderable, levelVisual: renderable,
                           currentLevelIcon: levelIconMissing,
                           currentLevelVisual: levelLevelVisualMissing).assetMissingReason,
            "level_icon_missing",
            "level 级 icon 缺失 → 优先于 level 级 levelVisual（icon 优先哲学）"
        )
        // level-level 优先于 item-level：currentLevelVisual 缺失 + item icon 缺失
        // → 返回 level 级原因（显示链首选）。
        XCTAssertEqual(
            makeAssetState(icon: itemIconMissing, levelVisual: renderable,
                           currentLevelVisual: levelLevelVisualMissing).assetMissingReason,
            "level_lv_missing",
            "level 级缺失优先于 item 级缺失（显示链首选）"
        )
        // 全部可渲染 → nil（无角标）。
        XCTAssertNil(
            makeAssetState(icon: renderable, levelVisual: renderable,
                           currentLevelIcon: renderable, currentLevelVisual: renderable).assetMissingReason,
            "全部可渲染 → nil（不显示缺失角标）"
        )
    }

    /// 递归 MovieClip 展开后的数据锚点（bundled）：buildings:1000059
    /// （攻城机器工坊）Lv2 应解析出当前等级的真实视觉资产，而不是退回 Lv1。
    func testBundledSiegeWorkshopLevelAssetResolvesCurrentLevel() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_059, level: 2, path: "0")]
        ])
        let state = try XCTUnwrap(
            project(village: village, catalog: catalog, base: .home).items.first
        )
        XCTAssertEqual(
            state.currentLevelVisual?.renderedPath,
            "icons/buildings/siegeWorkshop_lvl2.png",
            "buildings:1000059 Lv2 应命中当前等级的递归渲染资产"
        )
        XCTAssertTrue(state.currentLevelVisual?.isRenderable == true,
                      "buildings:1000059 Lv2 levelVisual 应可渲染")
        XCTAssertNil(state.assetMissingReason,
                     "当前等级资产可渲染时不应显示缺失提示")
    }

    // MARK: - VillageItemState.preferredAssetURLs 运行时回退（Issue #34，P2 评审修复）

    /// bundled 目录前 count 个可渲染且文件真实存在的资产路径（顺序稳定：buildings 优先）。
    /// 测试需要「真实存在」的路径作为加载成功基准；文件存在性由
    /// GameCatalogTests 的 bundledURL 测试锁定，这里只取路径。
    private func realRenderedPaths(_ catalog: GameCatalog, count: Int) -> [String] {
        var seen: [String] = []
        var visited = Set<String>()
        for section in ["buildings", "buildings2", "traps", "units"] {
            for item in catalog.items(in: section) {
                for ref in [item.icon, item.levelVisual].compactMap({ $0 }) where ref.isRenderable {
                    guard let path = ref.renderedPath, visited.insert(path).inserted else { continue }
                    seen.append(path)
                    if seen.count == count { return seen }
                }
            }
        }
        XCTFail("bundled 目录应有至少 \(count) 个可渲染资产路径，实际 \(seen.count)")
        return seen
    }

    /// 运行时候选 URL 数组（levelVisual → icon 优先级）：`bundledURL` 只在
    /// isRenderable 且 Bundle 文件真实存在时返回 URL——元数据可渲染但文件缺失
    /// 时该候选被过滤，UI 对返回数组依次做 NSImage 加载探测后回退次选/SF
    /// Symbol。列表行（UpgradeDisplayRow）与详情 sheet（LevelDetailSheet）
    /// 必须共用此解析防漂移。
    func testPreferredAssetURLsTruthTable() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let realPaths = realRenderedPaths(catalog, count: 2)
        let realFirst = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: realPaths[0], missingReason: nil
        )
        let realSecond = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: realPaths[1], missingReason: nil
        )
        // 元数据可渲染（isRenderable true）但 Bundle 文件不存在的路径（P2 核心场景）。
        let phantom = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: "icons/buildings/phantom_lvl1.png", missingReason: nil
        )
        let missingRef = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: nil, missingReason: "icons_not_rendered"
        )
        let version = GameCatalog.defaultBundledVersion

        // P2 核心：levelVisual 文件缺失 + icon 真实存在 → 数组只含 icon 的真实 URL，
        // UI 才能渲染 icon 而不是直接 SF Symbol。
        XCTAssertEqual(
            makeAssetState(icon: realFirst, levelVisual: phantom).preferredAssetURLs(version: version),
            [try XCTUnwrap(realFirst.bundledURL(version: version))],
            "levelVisual 文件缺失 + icon 文件存在 → 回退 icon 的真实 URL（P2 核心修复场景）"
        )
        // 两者文件都存在 → 按 levelVisual → icon 顺序保留（UI 依次加载，levelVisual 优先）。
        XCTAssertEqual(
            makeAssetState(icon: realSecond, levelVisual: realFirst).preferredAssetURLs(version: version),
            [try XCTUnwrap(realFirst.bundledURL(version: version)),
             try XCTUnwrap(realSecond.bundledURL(version: version))],
            "两者文件均存在 → 数组按 levelVisual → icon 顺序（与详情 sheet 同规则，防漂移）"
        )
        // levelVisual nil + icon 真实存在 → icon URL（兜底）。
        XCTAssertEqual(
            makeAssetState(icon: realFirst, levelVisual: nil).preferredAssetURLs(version: version),
            [try XCTUnwrap(realFirst.bundledURL(version: version))],
            "levelVisual nil + icon 文件存在 → icon URL 兜底"
        )
        // levelVisual 带缺失原因（isRenderable false）+ icon 真实存在 → icon URL。
        XCTAssertEqual(
            makeAssetState(icon: realFirst, levelVisual: missingRef).preferredAssetURLs(version: version),
            [try XCTUnwrap(realFirst.bundledURL(version: version))],
            "levelVisual 缺失原因（isRenderable false）→ 过滤，icon URL 兜底"
        )
        // 两者都缺失/不可渲染 → 空数组（UI 回退 SF Symbol）。
        XCTAssertEqual(
            makeAssetState(icon: nil, levelVisual: nil).preferredAssetURLs(version: version),
            [],
            "两者均 nil → 空数组（SF Symbol 回退）"
        )
        XCTAssertEqual(
            makeAssetState(icon: missingRef, levelVisual: phantom).preferredAssetURLs(version: version),
            [],
            "两者均不可加载 → 空数组（SF Symbol 回退）"
        )
    }

    /// P1 property-based（穷举全空间）：候选链 currentLevelVisual → currentLevelIcon
    /// → levelVisual → icon，4 槽位 × 4 状态（nil / 真实可加载 / phantom 文件缺失 /
    /// 带缺失原因）= 256 组合。断言：输出 == 候选序列中有序过滤「isRenderable 且
    /// Bundle 文件真实存在」后的 URL 子序列（顺序保持、无泄漏、无乱序）。
    func testPropertyAssetChainExhaustivePriority256() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let realPaths = realRenderedPaths(catalog, count: 4)
        let version = GameCatalog.defaultBundledVersion
        enum Slot: Int, CaseIterable { case nilRef, real, phantom, missing }
        // 每个槽位一个独立真实路径（可区分顺序），phantom/missing 均为不可加载。
        let refFor: (Slot, Int) -> CatalogAssetRef? = { slot, idx in
            switch slot {
            case .nilRef: return nil
            case .real:
                return CatalogAssetRef(
                    container: nil, exportName: nil,
                    renderedPath: realPaths[idx], missingReason: nil
                )
            case .phantom:
                return CatalogAssetRef(
                    container: nil, exportName: nil,
                    renderedPath: "icons/buildings/phantom_lvl\(idx).png", missingReason: nil
                )
            case .missing:
                return CatalogAssetRef(
                    container: nil, exportName: nil,
                    renderedPath: nil, missingReason: "icons_not_rendered"
                )
            }
        }
        var combos = 0
        for a in Slot.allCases { for b in Slot.allCases {
            for c in Slot.allCases { for d in Slot.allCases {
                let state = makeAssetState(
                    icon: refFor(d, 3), levelVisual: refFor(c, 2),
                    currentLevelIcon: refFor(b, 1), currentLevelVisual: refFor(a, 0)
                )
                let urls = state.preferredAssetURLs(version: version)
                // 期望：按链序取所有 .real 槽位的真实 URL
                var expected: [URL] = []
                let slots: [(Slot, Int)] = [(a, 0), (b, 1), (c, 2), (d, 3)]
                for (slot, idx) in slots where slot == .real {
                    let ref = try XCTUnwrap(refFor(slot, idx))
                    expected.append(try XCTUnwrap(ref.bundledURL(version: version)))
                }
                XCTAssertEqual(
                    urls, expected,
                    "组合 a=\(a) b=\(b) c=\(c) d=\(d)：输出应为可加载候选的有序子序列"
                )
                combos += 1
            }}
        }}
        XCTAssertEqual(combos, 256, "穷举应覆盖 4^4 全空间")
    }

    /// 数据锚点：锁定真实 bundled 目录满足 Issue #34 触发场景——buildings:1000000
    /// （兵营）icon 为 nil 但 levelVisual 可渲染（fireplace_lvl1.png），且运行时
    /// 解析出的首选 URL 真实指向该 PNG。若目录数据漂移（icon 补全或 levelVisual
    /// 不可渲染/文件缺失），本测试立即红，防止修复在无真实场景下空转。
    func testBundledCatalogFireplaceHasRenderableLevelVisual() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let fireplace = try XCTUnwrap(
            catalog.item(section: "buildings", dataID: 1_000_000),
            "bundled 目录应包含 buildings:1000000（兵营）"
        )
        XCTAssertNil(fireplace.icon, "buildings:1000000 icon 应为 nil（Issue #34 数据契约）")
        let levelVisual = try XCTUnwrap(
            fireplace.levelVisual,
            "buildings:1000000 应有 levelVisual（Issue #34 数据契约）"
        )
        XCTAssertTrue(
            levelVisual.isRenderable,
            "buildings:1000000 levelVisual 应可渲染（fireplace_lvl1.png，Issue #34 数据契约）"
        )
        // 运行时解析必须命中 levelVisual 的真实 URL——列表行依赖此契约显示真实 PNG。
        let urls = makeAssetState(icon: fireplace.icon, levelVisual: fireplace.levelVisual)
            .preferredAssetURLs(version: catalog.gameVersion)
        let expected = try XCTUnwrap(levelVisual.bundledURL(version: catalog.gameVersion))
        XCTAssertEqual(urls, [expected], "buildings:1000000 首选 URL 应为 fireplace_lvl1.png（Issue #34 核心修复场景）")
    }

    func testPropertyEveryUpgradingRecordSurvivesProjection() throws {
        var rng = SeededRNG(seed: 2024)
        let sections = ["buildings", "units"]
        let pool: [Int64] = [1_000_001, 4_000_000]
        // now == importedAt：剩余时间不被快照年龄消耗，随机 remaining 1...999 全部保持升级中。
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<20 {
            let snapshot = makeRandomSnapshot(
                rng: &rng, count: 30, dataIDPool: pool, sections: sections
            )
            let village = makeVillage(objectSections: snapshot)
            let home = project(village: village, catalog: syntheticCatalog, base: .home, now: now)
            let upgradingInput = snapshot.values
                .flatMap { $0 }
                .filter { ($0.remainingSeconds ?? 0) > 0 }
            // 按 key 计数对比：同 (section,dataID,level) 多条升级记录一条都不能丢。
            var expectedCounts: [String: Int] = [:]
            for record in upgradingInput {
                let key = "\(record.section):\(record.dataID):\(record.level.map(String.init) ?? "nil")"
                expectedCounts[key, default: 0] += 1
            }
            var actualCounts: [String: Int] = [:]
            for item in home.items where item.isUpgrading {
                let key = "\(item.section):\(item.dataID):\(item.currentLevel.map(String.init) ?? "nil")"
                actualCounts[key, default: 0] += 1
            }
            XCTAssertEqual(actualCounts, expectedCounts,
                           "升级记录在投影中必须逐条保留（同键计数一致）")
        }
    }


    // MARK: - Issue #37 展示分类

    func testRealFixtureDisplayCategoryForCraftTableAndNested() throws {
        let sections = try loadRealFixture()
        let village = makeVillage(objectSections: sections)
        let catalog = GameCatalog.loadBundled()
        let home = project(village: village, catalog: catalog, base: .home)

        // 精制台父项（fixture dataID 1000097）
        let craftParent = try XCTUnwrap(home.items.first {
            !$0.isNested && $0.section == "buildings" && $0.dataID == 100_0097
        })
        XCTAssertEqual(craftParent.displayCategory, .craftTable)

        // 嵌套 types/modules 后代全部归精制台（按根父归属）
        let nested = home.items.filter(\.isNested)
        XCTAssertFalse(nested.isEmpty)
        XCTAssertTrue(nested.allSatisfy { $0.displayCategory == .craftTable },
                       "fixture 嵌套项（精制台后代）应全部归精制台")

        // 兵营 → 军事设施；迫击炮(1000013) → 防御建筑
        XCTAssertEqual(
            home.items.first { $0.dataID == 1_000_000 && !$0.isNested }?.displayCategory, .military
        )
        XCTAssertEqual(
            home.items.first { $0.dataID == 1_000_013 && !$0.isNested }?.displayCategory, .defense
        )
    }

    func testBuilderBaseItemsHaveNilDisplayCategory() throws {
        let sections = try loadRealFixture()
        let village = makeVillage(objectSections: sections)
        let catalog = GameCatalog.loadBundled()
        let builder = project(village: village, catalog: catalog, base: .builder)
        XCTAssertFalse(builder.items.isEmpty)
        XCTAssertTrue(builder.items.allSatisfy { $0.displayCategory == nil },
                       "建筑工人基地项目不应细分")
    }

    func testAggregatedItemPreservesDisplayCategory() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_013, level: 18, count: nil, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_013, level: 18, count: 1, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let agg = home.items.first { $0.id.hasPrefix("agg:") }
        XCTAssertEqual(agg?.displayCategory, .defense, "聚合项应透传展示分类")

    }

    // MARK: - Issue #39: currentLevel 资产解析

    /// 投影层按 currentLevel 解析等级资产：命中 CatalogLevel 的 levelVisual/icon；
    /// 聚合传播（P4）；升级中仍显示当前等级外观（P5，nextLevel 不参与）。
    func testProjectionResolvesCurrentLevelAssets() throws {
        let bundled = try XCTUnwrap(GameCatalog.loadBundled())
        let realPaths = realRenderedPaths(bundled, count: 2)
        let level1Visual = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: realPaths[0], missingReason: nil
        )
        let level2Visual = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: realPaths[1], missingReason: nil
        )
        let item = CatalogItem(
            section: "buildings", category: "buildings", dataID: 1_000_001,
            base: "home", baseMissingReason: nil, name: "加农炮", maxLevel: 2,
            icon: nil, levelVisual: nil,
            levels: [
                CatalogLevel(level: 1, durationSeconds: 60, upgradeCosts: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil,
                             icon: nil, levelVisual: level1Visual, missingReason: nil),
                CatalogLevel(level: 2, durationSeconds: 300, upgradeCosts: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil,
                             icon: nil, levelVisual: level2Visual, missingReason: nil),
            ]
        )
        let catalog = GameCatalog(gameVersion: GameCatalog.defaultBundledVersion, items: [item])

        // 当前等级 2 → 命中 levels[2].levelVisual
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0")]
        ])
        let home = project(village: village, catalog: catalog, base: .home)
        let state = try XCTUnwrap(home.items.first)
        XCTAssertEqual(state.currentLevel, 2)
        XCTAssertEqual(state.currentLevelVisual, level2Visual,
                       "currentLevel=2 → 命中 levels[2] 的 levelVisual")
        XCTAssertNil(state.currentLevelIcon)
        XCTAssertNil(state.levelVisual, "item-level 无资产 → nil（不被伪造）")
        XCTAssertNil(state.icon, "item-level 无 icon → nil（不被伪造）")
        XCTAssertNil(state.currentLevelVisual?.missingReason, "可渲染资产无缺失原因")

        // 聚合传播（P4）：两条同 (section,dataID,level=2) 非升级记录 → 聚合 1 条，字段保留
        let village2 = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "1"),
            ]
        ])
        let home2 = project(village: village2, catalog: catalog, base: .home)
        let aggregated = try XCTUnwrap(home2.items.first)
        XCTAssertEqual(aggregated.count, 2, "两条同键非升级记录应聚合为一条 ×2")
        XCTAssertEqual(aggregated.currentLevelVisual, level2Visual,
                       "聚合项必须保留当前等级资产（P4）")

        // 升级中（P5）：remaining > 0 且 currentLevel=2 → 仍命中 Lv2，与 nextLevel 无关
        let village3 = makeVillage(objectSections: [
            "buildings": [makeItem(
                section: "buildings", dataID: 1_000_001, level: 2,
                timerSeconds: 600, remainingSeconds: 300, path: "0"
            )]
        ])
        let home3 = project(village: village3, catalog: catalog, base: .home)
        let upgrading = try XCTUnwrap(home3.items.first)
        XCTAssertTrue(upgrading.isUpgrading)
        XCTAssertEqual(upgrading.nextLevel, 3, "升级中 nextLevel = currentLevel + 1（#14 契约）")
        XCTAssertEqual(upgrading.currentLevelVisual, level2Visual,
                       "升级中仍显示当前等级外观，不提前显示目标等级（P5）")

        // 当前等级 1 → 命中 levels[1]
        let village4 = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")]
        ])
        let home4 = project(village: village4, catalog: catalog, base: .home)
        XCTAssertEqual(home4.items.first?.currentLevelVisual, level1Visual,
                       "currentLevel=1 → 命中 levels[1] 的 levelVisual")
    }

    /// 等级号不连续时按值匹配（非下标）：合成目录 levels = [1, 5, 9]，
    /// currentLevel=5 必须命中 Lv5 资产——若实现误用下标会命中 Lv1/Lv9 而立即红。
    func testProjectionValueMatchesNonContiguousLevels() throws {
        let bundled = try XCTUnwrap(GameCatalog.loadBundled())
        let realPaths = realRenderedPaths(bundled, count: 3)
        func makeRef(_ i: Int) -> CatalogAssetRef {
            CatalogAssetRef(container: nil, exportName: nil,
                            renderedPath: realPaths[i], missingReason: nil)
        }
        let item = CatalogItem(
            section: "buildings", category: "buildings", dataID: 1_000_009,
            base: "home", baseMissingReason: nil, name: "不连续等级", maxLevel: 9,
            icon: nil, levelVisual: nil,
            levels: [
                CatalogLevel(level: 1, durationSeconds: 60, upgradeCosts: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil, icon: nil,
                             levelVisual: makeRef(0), missingReason: nil),
                CatalogLevel(level: 5, durationSeconds: 300, upgradeCosts: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil, icon: nil,
                             levelVisual: makeRef(1), missingReason: nil),
                CatalogLevel(level: 9, durationSeconds: 600, upgradeCosts: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil, icon: nil,
                             levelVisual: makeRef(2), missingReason: nil),
            ]
        )
        let catalog = GameCatalog(gameVersion: GameCatalog.defaultBundledVersion, items: [item])
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_009, level: 5, path: "0")]
        ])
        let state = try XCTUnwrap(
            project(village: village, catalog: catalog, base: .home).items.first
        )
        XCTAssertEqual(state.currentLevelVisual, makeRef(1),
                       "currentLevel=5 必须按值命中 Lv5 资产（非下标）")
        XCTAssertNotEqual(state.currentLevelVisual, makeRef(0),
                          "不得命中 Lv1（下标错位防护）")
    }

    /// 目录物品的 base 与投影基地不匹配（baseMatches false → 未知状态）时，
    /// currentLevel 资产必须保持 nil：不按名称/位置猜测等级资产，也不暴露
    /// item 级资产（Issue #39 与既有 base 防御规则一致）。
    func testProjectionBaseMismatchLeavesCurrentLevelAssetsNil() throws {
        let bundled = try XCTUnwrap(GameCatalog.loadBundled())
        let realPath = try XCTUnwrap(realRenderedPaths(bundled, count: 1).first)
        let level1Visual = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: realPath, missingReason: nil
        )
        // 唯一目录项：section "buildings"（主村语义）但 base 为 "builder"。
        let item = CatalogItem(
            section: "buildings", category: "buildings", dataID: 1_000_008,
            base: "builder", baseMissingReason: nil, name: "错基地建筑", maxLevel: 2,
            icon: nil, levelVisual: nil,
            levels: [
                CatalogLevel(level: 1, durationSeconds: 60, upgradeCosts: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil,
                             icon: nil, levelVisual: level1Visual, missingReason: nil),
            ]
        )
        let catalog = GameCatalog(gameVersion: GameCatalog.defaultBundledVersion, items: [item])
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_008, level: 1, path: "0")]
        ])
        let state = try XCTUnwrap(
            project(village: village, catalog: catalog, base: .home).items.first
        )
        XCTAssertEqual(state.status, .unknown, "base 不匹配 → 未知状态（有目录记录但不匹配）")
        XCTAssertTrue(state.missingReason?.contains("不匹配") == true,
                      "base 不匹配应有说明原因的 missingReason")
        XCTAssertNil(state.icon, "base 不匹配不得暴露 item 级 icon")
        XCTAssertNil(state.levelVisual, "base 不匹配不得暴露 item 级 levelVisual")
        XCTAssertNil(state.currentLevelVisual, "base 不匹配不得解析等级资产")
        XCTAssertNil(state.currentLevelIcon, "base 不匹配不得解析等级资产")
        XCTAssertNil(state.maxLevel, "base 不匹配 maxLevel 保持 nil")
    }

    /// 同 (section, dataID, level) 升级记录与空闲记录并存（aggregate 的「|idle」分支）：
    /// 升级记录单独保留、空闲记录聚合为一条，两条都必须携带 currentLevelVisual
    /// （map 解析 + 聚合传播 P4 同时锁定）。
    func testMixedUpgradingAndIdleSameKeyBothResolveLevelAssets() throws {
        let bundled = try XCTUnwrap(GameCatalog.loadBundled())
        let realPaths = realRenderedPaths(bundled, count: 2)
        let level1Visual = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: realPaths[0], missingReason: nil
        )
        let level2Visual = CatalogAssetRef(
            container: nil, exportName: nil, renderedPath: realPaths[1], missingReason: nil
        )
        let item = CatalogItem(
            section: "buildings", category: "buildings", dataID: 1_000_001,
            base: "home", baseMissingReason: nil, name: "加农炮", maxLevel: 2,
            icon: nil, levelVisual: nil,
            levels: [
                CatalogLevel(level: 1, durationSeconds: 60, upgradeCosts: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil,
                             icon: nil, levelVisual: level1Visual, missingReason: nil),
                CatalogLevel(level: 2, durationSeconds: 300, upgradeCosts: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil,
                             icon: nil, levelVisual: level2Visual, missingReason: nil),
            ]
        )
        let catalog = GameCatalog(gameVersion: GameCatalog.defaultBundledVersion, items: [item])
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 2, count: 1,
                         timerSeconds: 600, remainingSeconds: 300, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "1"),
            ]
        ])
        let home = project(village: village, catalog: catalog, base: .home)
        XCTAssertEqual(home.items.count, 2,
                       "同键升级 + 空闲 → 升级记录单独保留 + 空闲聚合（|idle 分支）")
        let upgrading = try XCTUnwrap(home.items.first(where: \.isUpgrading))
        XCTAssertEqual(upgrading.currentLevelVisual, level2Visual,
                       "升级记录命中当前等级资产（P5）")
        let idle = try XCTUnwrap(home.items.first { !$0.isUpgrading })
        XCTAssertTrue(idle.id.hasPrefix("agg:"), "空闲同键记录应聚合为一条")
        XCTAssertEqual(idle.count, 1)
        XCTAssertEqual(idle.currentLevelVisual, level2Visual,
                       "聚合空闲项必须传播当前等级资产（P4）")
    }

    /// 数据锚点（Issue #39）：真实 bundled 目录中 buildings:1000000（兵营）
    /// Lv2 必须解析到 fireplace_lvl2.png、Lv14 到 fireplace_lvl14.png，
    /// 而不是固定 item-level 的 fireplace_lvl1.png。目录数据漂移立即红。
    func testBundledFireplaceResolvesLevelAppearance() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let version = catalog.gameVersion

        func stateFor(level: Int?) throws -> VillageItemState {
            let village = makeVillage(objectSections: [
                "buildings": [makeItem(section: "buildings", dataID: 1_000_000, level: level, path: "0")]
            ])
            return try XCTUnwrap(
                project(village: village, catalog: catalog, base: .home).items.first
            )
        }

        // Lv2 → 精确命中 levels[2].levelVisual（fireplace_lvl2.png）
        let lv2 = try stateFor(level: 2)
        XCTAssertEqual(lv2.currentLevelVisual?.renderedPath, "icons/buildings/fireplace_lvl2.png")
        XCTAssertEqual(
            lv2.preferredAssetURLs(version: version).first,
            try XCTUnwrap(lv2.currentLevelVisual?.bundledURL(version: version)),
            "Lv2 首选 URL 必须是 fireplace_lvl2.png 而非 lvl1"
        )

        // Lv14 → fireplace_lvl14.png
        let lv14 = try stateFor(level: 14)
        XCTAssertEqual(lv14.currentLevelVisual?.renderedPath, "icons/buildings/fireplace_lvl14.png")
        XCTAssertEqual(
            lv14.preferredAssetURLs(version: version).first,
            try XCTUnwrap(lv14.currentLevelVisual?.bundledURL(version: version)),
            "Lv14 首选 URL 必须是 fireplace_lvl14.png 而非 lvl1"
        )

        // 超范围（Lv15 > maxLevel 14）→ 不猜等级资源，回退 item-level lvl1
        let lv15 = try stateFor(level: 15)
        XCTAssertNil(lv15.currentLevelVisual, "超范围等级不得猜测资产")
        XCTAssertEqual(
            lv15.preferredAssetURLs(version: version).first,
            try XCTUnwrap(lv15.levelVisual?.bundledURL(version: version)),
            "超范围 → 回退 item-level levelVisual"
        )

        // currentLevel nil → 同样回退 item-level
        let nilState = try stateFor(level: nil)
        XCTAssertNil(nilState.currentLevelVisual)
        XCTAssertEqual(
            nilState.preferredAssetURLs(version: version).first,
            try XCTUnwrap(nilState.levelVisual?.bundledURL(version: version)),
            "currentLevel nil → 回退 item-level levelVisual"
        )
    }

    /// level 级资产缺失时的候选链行为（traps2:12000011，来自
    /// GameCatalogTests 已知数据契约）：
    /// - traps2:12000011 Lv1：level 级与 item 级的 levelVisual/icon 全部缺失
    ///   （export_not_found / nil）→ ref 原样暴露（带 missingReason）但被
    ///   候选链过滤，链为空 → UI 回退 SF Symbol（非 item-level 回退）。
    /// - buildings:1000059 Lv2：递归展开后当前等级资产可渲染，候选链必须
    ///   首选 siegeWorkshop_lvl2.png，不能回到旧的 Lv1 资产。
    func testBundledMissingLevelAssetFallbacksAreExplicit() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let version = catalog.gameVersion

        // traps2:12000011 push_trap Lv1：level 级 levelVisual 带缺失原因
        let pushTrap = try XCTUnwrap(
            catalog.item(section: "traps2", dataID: 12_000_011),
            "bundled 目录应包含 traps2:12000011"
        )
        let trapVillage = makeVillage(objectSections: [
            "traps2": [makeItem(section: "traps2", dataID: 12_000_011, level: 1, path: "0")]
        ])
        let trapState = try XCTUnwrap(
            project(village: trapVillage, catalog: catalog, base: .builder).items.first
        )
        let trapLevelVisual = try XCTUnwrap(
            pushTrap.levels.first { $0.level == 1 }?.levelVisual
        )
        XCTAssertEqual(trapState.currentLevelVisual, trapLevelVisual,
                       "level 级 ref 原样暴露（含缺失原因），由链过滤")
        XCTAssertFalse(trapLevelVisual.isRenderable,
                       "traps2:12000011 Lv1 levelVisual 应为 export_not_found（已知契约）")
        // 链过滤：item 级 levelVisual（export_not_found）与 icon（nil）同样缺失 →
        // 候选链为空 → UI 回退 SF Symbol
        let trapURLs = trapState.preferredAssetURLs(version: version)
        XCTAssertTrue(trapURLs.isEmpty,
                      "traps2:12000011 半边：level 与 item 级均不可用 → 空链（SF Symbol 兜底）")

        // buildings:1000059 siegeWorkshop Lv2 → 递归展开后命中当前等级资产
        let siege = try XCTUnwrap(
            catalog.item(section: "buildings", dataID: 1_000_059),
            "bundled 目录应包含 buildings:1000059"
        )
        let siegeVillage = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_059, level: 2, path: "0")]
        ])
        let siegeState = try XCTUnwrap(
            project(village: siegeVillage, catalog: catalog, base: .home).items.first
        )
        let siegeLevelVisual = try XCTUnwrap(
            siege.levels.first { $0.level == 2 }?.levelVisual
        )
        XCTAssertEqual(siegeState.currentLevelVisual, siegeLevelVisual)
        XCTAssertEqual(siegeLevelVisual.renderedPath,
                       "icons/buildings/siegeWorkshop_lvl2.png")
        XCTAssertTrue(siegeLevelVisual.isRenderable,
                      "buildings:1000059 Lv2 levelVisual 应可渲染")
        let siegeURLs = siegeState.preferredAssetURLs(version: version)
        XCTAssertEqual(
            siegeURLs.first,
            try XCTUnwrap(siegeLevelVisual.bundledURL(version: version)),
            "Lv2 当前等级资产可用时应优先使用 siegeWorkshop_lvl2.png"
        )
    }

    /// 类别不串线：buildings2:1000033（secondVillage_wall）Lv2 必须命中
    /// buildings2 自己的逐级路径（icons/buildings2/secondVillage_wall_lvl2.png，
    /// 数据契约），不得命中 buildings 同名资源。
    func testBundledSectionsDoNotCrossResolve() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let village = makeVillage(objectSections: [
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 2, path: "0")]
        ])
        let state = try XCTUnwrap(
            project(village: village, catalog: catalog, base: .builder).items.first
        )
        XCTAssertEqual(
            state.currentLevelVisual?.renderedPath,
            "icons/buildings2/secondVillage_wall_lvl2.png",
            "buildings2:1000033 Lv2 必须命中 buildings2 自己的逐级路径（数据契约）"
        )
    }

    /// P3 property-based（全空间穷举）：bundled 目录 buildings/buildings2/traps/traps2
    /// 的每个 item × 每个 level 组合都投影一次，断言 currentLevelVisual/currentLevelIcon
    /// 精确等于该 level 的 ref（ref 存在则相等、不存在则 nil）。
    func testPropertyEveryBundledLevelResolvesExactly() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        var checked = 0
        for section in ["buildings", "buildings2", "traps", "traps2"] {
            let base: TrackerBase = section.hasSuffix("2") ? .builder : .home
            for item in catalog.items(in: section) {
                for level in item.levels {
                    let village = makeVillage(objectSections: [
                        section: [makeItem(section: section, dataID: item.dataID,
                                           level: level.level, path: "0")]
                    ])
                    let state = try XCTUnwrap(
                        project(village: village, catalog: catalog, base: base).items.first,
                        "\(section):\(item.dataID)@Lv\(level.level) 投影应产出状态"
                    )
                    XCTAssertEqual(
                        state.currentLevelVisual?.renderedPath,
                        level.levelVisual?.renderedPath,
                        "\(section):\(item.dataID)@Lv\(level.level) currentLevelVisual 必须精确命中"
                    )
                    XCTAssertEqual(
                        state.currentLevelIcon?.renderedPath,
                        level.icon?.renderedPath,
                        "\(section):\(item.dataID)@Lv\(level.level) currentLevelIcon 必须精确命中"
                    )
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 500, "穷举应覆盖 500+ 个 item×level 组合（实际 \(checked)）")
    }

    /// P2 property-based（确定性随机）：随机 (section, dataID, level)，level 可能
    /// 为 0 / 超范围 / 目录无此等级 —— 断言绝不猜测：字段只可能等于按值匹配的
    /// CatalogLevel ref，无匹配则必为 nil。
    func testPropertyRandomLevelsNeverGuessAssets() throws {
        var rng = SeededRNG(seed: 20_260_806)
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let sections = ["buildings", "buildings2", "traps", "traps2", "units", "heroes"]
        for _ in 0..<60 {
            let section = sections[Int.random(in: 0..<sections.count, using: &rng)]
            let items = catalog.items(in: section)
            guard !items.isEmpty else {
                XCTFail("bundled 目录 section \(section) 不应为空（数据契约）")
                continue
            }
            let item = items[Int.random(in: 0..<items.count, using: &rng)]
            let level = Int.random(in: 0...(item.maxLevel + 3), using: &rng)
            let base: TrackerBase = section.hasSuffix("2") ? .builder : .home
            let village = makeVillage(objectSections: [
                section: [makeItem(section: section, dataID: item.dataID, level: level, path: "0")]
            ])
            let state = try XCTUnwrap(
                project(village: village, catalog: catalog, base: base).items.first
            )
            let matched = item.levels.first { $0.level == level }
            XCTAssertEqual(
                state.currentLevelVisual?.renderedPath, matched?.levelVisual?.renderedPath,
                "\(section):\(item.dataID)@Lv\(level) 不得猜测等级资产"
            )
            XCTAssertEqual(
                state.currentLevelIcon?.renderedPath, matched?.icon?.renderedPath,
                "\(section):\(item.dataID)@Lv\(level) 不得猜测等级资产"
            )
        }
    }

    // MARK: - Issue #17: 数组重排稳定性与 boost 非归属

    /// 模拟「重排后的 JSON 重新导入」：按新位置重建 id（与解析器规则一致：
    /// 顶层 section:index，嵌套 path.types.index / path.modules.index；
    /// id 重建规则与 AccountSnapshotImporter.normalize()（AccountSnapshot.swift L394-430）保持同步），
    /// 事实字段（dataID/lvl/cnt/timer）保持原样。
    private func shuffledSections(
        _ sections: [String: [AccountItem]],
        using rng: inout SeededRNG
    ) -> [String: [AccountItem]] {
        sections.mapValues { items in
            items.shuffled(using: &rng).enumerated().map { index, item in
                reshuffled(item, path: String(index), using: &rng)
            }
        }
    }

    private func reshuffled(
        _ item: AccountItem,
        path: String,
        using rng: inout SeededRNG
    ) -> AccountItem {
        AccountItem(
            id: item.section + ":" + path,
            section: item.section,
            dataID: item.dataID,
            level: item.level,
            count: item.count,
            timerSeconds: item.timerSeconds,
            remainingSeconds: item.remainingSeconds,
            helperTimerSeconds: item.helperTimerSeconds,
            remainingHelperSeconds: item.remainingHelperSeconds,
            helperCooldownSeconds: item.helperCooldownSeconds,
            remainingHelperCooldownSeconds: item.remainingHelperCooldownSeconds,
            helperRecurrent: item.helperRecurrent,
            gearUp: item.gearUp,
            weapon: item.weapon,
            types: item.types.shuffled(using: &rng).enumerated().map { index, child in
                reshuffled(child, path: path + ".types." + String(index), using: &rng)
            },
            modules: item.modules.shuffled(using: &rng).enumerated().map { index, child in
                reshuffled(child, path: path + ".modules." + String(index), using: &rng)
            }
        )
    }

    /// 只重建 id（自身 + 嵌套，嵌套按原顺序 enumerated），其余字段原样；
    /// 与解析器 id 规则一致：顶层 section:index、嵌套 path.types.index / path.modules.index
    /// （id 重建规则与 AccountSnapshotImporter.normalize()（AccountSnapshot.swift L394-430）保持同步）。
    private func rebuildID(_ item: AccountItem, path: String) -> AccountItem {
        AccountItem(
            id: item.section + ":" + path,
            section: item.section,
            dataID: item.dataID,
            level: item.level,
            count: item.count,
            timerSeconds: item.timerSeconds,
            remainingSeconds: item.remainingSeconds,
            helperTimerSeconds: item.helperTimerSeconds,
            remainingHelperSeconds: item.remainingHelperSeconds,
            helperCooldownSeconds: item.helperCooldownSeconds,
            remainingHelperCooldownSeconds: item.remainingHelperCooldownSeconds,
            helperRecurrent: item.helperRecurrent,
            gearUp: item.gearUp,
            weapon: item.weapon,
            types: item.types.enumerated().map { index, child in
                rebuildID(child, path: path + ".types." + String(index))
            },
            modules: item.modules.enumerated().map { index, child in
                rebuildID(child, path: path + ".modules." + String(index))
            }
        )
    }

    /// 只按新位置重建 id（不打乱顺序）；用于 reversed 等顺序保持型变体，
    /// 使「id 漂移」统一来自索引 id 重建，而非聚合组 first 项的偶然变化。
    private func rebuiltIDs(_ sections: [String: [AccountItem]]) -> [String: [AccountItem]] {
        sections.mapValues { items in
            items.enumerated().map { index, item in
                rebuildID(item, path: String(index))
            }
        }
    }

    /// 投影事实行：身份与事实字段（不含 id——id 含数组索引，重排后允许漂移）。
    /// 排序多集比较对「取首代表/丢弃」类缺陷有效，对组内事实互换（swap）形状
    /// 不敏感——后者由 testFinishedTimerGroupAggregationIsOrderIndependent 兜底。
    private func factLines(_ items: [VillageItemState]) -> [String] {
        items.map { item -> String in
            let fields: [String] = [
                item.section, String(item.dataID),
                item.currentLevel.map(String.init) ?? "nil",
                item.isNested ? "nested" : "flat",
                item.count.map(String.init) ?? "nil",
                item.timerSeconds.map(String.init) ?? "nil",
                item.remainingSeconds.map(String.init) ?? "nil",
                item.status.rawValue,
                item.nextLevel.map(String.init) ?? "nil",
                item.name,
                item.maxLevel.map(String.init) ?? "nil",
                item.nextLevelDurationSeconds.map(String.init) ?? "nil",
            ]
            return fields.joined(separator: "|")
        }.sorted()
    }

    /// JSON 数组重排不得改变项目身份与事实（issue 验收 #6）：
    /// 重排后含数组索引的 id 必须漂移（自证测试非空转），而事实集必须完全一致。
    /// 注意覆盖窗口：当前 fixture（age=0）全部 timer 记录均 remaining>0（升级中，
    /// 不聚合），本测试对聚合代表选择（first→min 修复）无鉴别力——该缺陷由
    /// testFinishedTimerGroupAggregationIsOrderIndependent 专门承担；若 fixture
    /// 更新出现已结束计时组，本测试自动获得第二道鉴别力。
    func testArrayReorderDoesNotChangeItemFacts() throws {
        let sections = try loadRealFixture()
        // 锚定：rebuiltIDs 对解析器产出的 id 应是恒等（解析器 id 本就按位置生成）。
        // 解析器 id 规则变化时此处立即红，指引同步本文件的手写重建规则
        // （与 Sources/COCHelperCore/AccountSnapshot.swift normalize() 的 path 生成保持同步）。
        XCTAssertEqual(rebuiltIDs(sections), sections)
        let village = makeVillage(objectSections: sections)
        let catalog = GameCatalog.loadBundled()

        var rng = SeededRNG(seed: 17)
        let reimportedSections = shuffledSections(sections, using: &rng)
        let reversedSections = rebuiltIDs(sections.mapValues { Array($0.reversed()) })

        let originalHome = project(village: village, catalog: catalog, base: .home)
        let originalBuilder = project(village: village, catalog: catalog, base: .builder)

        for variant in [("shuffled", reimportedSections), ("reversed", reversedSections)] {
            let variantVillage = makeVillage(objectSections: variant.1)
            let variantHome = project(village: variantVillage, catalog: catalog, base: .home)
            let variantBuilder = project(village: variantVillage, catalog: catalog, base: .builder)

            // 1. 重排确实生效（输入层自证）：变体输入 item 数组（含 id/事实，
            //    逐元素顺序比较）与原始不同。注意不能用 id 列表断言差异——
            //    id 按新位置重建后序列恒为 0..n-1（置换不变，与 Set 比较
            //    同因失效）；位置 i 上换入不同 item 才是真实信号。
            let originalInputItems = sections.keys.sorted().flatMap { key in sections[key]! }
            let variantInputItems = variant.1.keys.sorted().flatMap { key in variant.1[key]! }
            XCTAssertNotEqual(originalInputItems, variantInputItems,
                              "\(variant.0) 后输入数组应变化（重排确实生效）")

            // 2. 事实不变：按 (section,dataID,level,isNested) 身份的事实完全一致。
            XCTAssertEqual(factLines(originalHome.items), factLines(variantHome.items),
                           "\(variant.0) 后主村事实改变")
            XCTAssertEqual(factLines(originalBuilder.items), factLines(variantBuilder.items),
                           "\(variant.0) 后建筑工人基地事实改变")
        }
    }

    /// 全局 boost（clocktower_cooldown 等）只留在快照顶层，不得归属到任何项目
    /// （issue 验收 #5）。用远超真实计时的特殊值避免碰撞。
    /// 局限：本测试只守护「boost 值直接赋给计时字段」这一种归属形状，
    /// 派生归属（如 timer - boost）不在检测面内。
    func testBoostValuesNeverAttributedToProjectItems() throws {
        let boostValue: Int64 = 987_654_321
        let village = makeVillage(
            objectSections: [
                "buildings": [
                    makeItem(section: "buildings", dataID: 1_000_013, level: 17,
                             timerSeconds: 369_441, remainingSeconds: 1000, path: "0"),
                    makeItem(section: "buildings", dataID: 1_000_032, level: 12, path: "1"),
                ],
            ],
            boosts: ["clocktower_cooldown": boostValue]
        )
        let home = project(village: village, catalog: syntheticCatalog, base: .home)

        // boost 保留在快照顶层（独立来源）。
        XCTAssertEqual(village.accountSnapshot?.boosts["clocktower_cooldown"], boostValue)

        // 任何投影项目的计时/剩余字段都不得携带 boost 值。
        XCTAssertFalse(home.items.isEmpty)
        for item in home.items {
            XCTAssertNotEqual(item.timerSeconds, boostValue,
                              "\(item.name) 的计时不得来自全局 boost")
            XCTAssertNotEqual(item.remainingSeconds, boostValue,
                              "\(item.name) 的剩余时间不得来自全局 boost")
        }
    }

    /// 已结束计时重复组的聚合计时值必须与数组顺序无关（issue 验收 #6）：
    /// 组内多条已结束计时记录重排后，聚合 timerSeconds 不得改变。
    /// 当前实现用 first 选择（次序依赖）——本测试先证明该 bug，修复后用 min() 通过。
    func testFinishedTimerGroupAggregationIsOrderIndependent() throws {
        func makeFinishedItem(_ timer: Int64, path: String) -> AccountItem {
            AccountItem(
                id: "buildings:" + path,
                section: "buildings",
                dataID: 1_000_032,
                level: 12,
                timerSeconds: timer,
                remainingSeconds: 0
            )
        }
        let original = makeVillage(objectSections: [
            "buildings": [
                makeFinishedItem(357_878, path: "0"),
                makeFinishedItem(422_074, path: "1"),
            ],
        ])
        let reversed = makeVillage(objectSections: [
            "buildings": [
                makeFinishedItem(422_074, path: "1"),
                makeFinishedItem(357_878, path: "0"),
            ],
        ])

        let originalProjection = project(village: original, catalog: syntheticCatalog, base: .home)
        let reversedProjection = project(village: reversed, catalog: syntheticCatalog, base: .home)

        let originalItem = try XCTUnwrap(originalProjection.items.first { $0.dataID == 1_000_032 })
        let reversedItem = try XCTUnwrap(reversedProjection.items.first { $0.dataID == 1_000_032 })
        XCTAssertEqual(originalItem.timerSeconds, reversedItem.timerSeconds,
                       "已结束计时组的聚合计时值不得随数组顺序改变")
    }

    // MARK: - Issue #67: currentStageMaxLevel（阶段上限）与 maxed 判定

    /// 阶段上限可计算（TH=12 满足加农炮全部 TH 门槛）→ stage == 目录上限；
    /// 加农炮 level 1 < 2 → 未满级。
    func testStageMaxLevelHonorsTownHallGate() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),  // 大本营
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),   // 加农炮
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.currentStageMaxLevel, 2,
                       "TH=12 满足 lvl1(TH1)/lvl2(TH2) → 阶段上限 == 目录上限")
        XCTAssertEqual(cannon.maxLevel, 2)
        XCTAssertEqual(cannon.status, .complete, "level 1 < 阶段上限 2 → 未满级")
    }

    /// TH=2：加农炮 level 2 == 阶段上限 == 目录上限 → .maxed。
    func testStageMaxedAtGlobalCap() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 2, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 2, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.currentStageMaxLevel, 2)
        XCTAssertEqual(cannon.status, .maxed, "level 2 >= 阶段上限 2 → 满级")
    }

    /// 关键验收场景：TH=1 只解锁加农炮到 level 1；快照里 2 级加农炮 → 阶段满级
    ///（currentStageMaxLevel 1 < maxLevel 2，阶段满级与全局未满可区分——Issue #67 核心）。
    func testStageMaxedBelowGlobalCap() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 2, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.currentStageMaxLevel, 1, "TH=1 不满足 lvl2 的 TH=2 门槛")
        XCTAssertEqual(cannon.maxLevel, 2)
        XCTAssertEqual(cannon.status, .maxed, "level 2 >= 阶段上限 1 → 阶段满级")
        XCTAssertLessThan(cannon.currentStageMaxLevel ?? .max, cannon.maxLevel ?? .min,
                          "阶段满级但全局未满必须可区分")
    }

    /// 快照无大本营 → 阶段上限不可计算 → fail-closed：状态 unverified，
    /// 不判 maxed/complete（Issue #67：缺失 prerequisite 不得产生看似权威的满级
    /// 或未满级状态；P1-1 修复，取代旧的「回退全局 maxed」行为）。
    func testMissingPrerequisiteBecomesUnverified() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_002, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first)
        XCTAssertNil(cannon.currentStageMaxLevel, "快照缺大本营记录 → 阶段上限不可计算")
        XCTAssertEqual(cannon.status, .unverified, "缺 prerequisite → unverified，不判 maxed")
        XCTAssertEqual(cannon.nextLevelDurationSeconds, nil, "unverified 不推断下一级时长")
        // 完成度：unverified 不计入 known（全进 unknown 侧）。
        let total = VillageDetailProjection.totalCompletion(from: home.items)
        XCTAssertEqual(total.knownCount, 0, "unverified 不得计入完成度 known")
        XCTAssertEqual(total.unknownCount, 1)
    }

    /// 快照无大本营 + level 1 < maxLevel 2 → 同样 unverified（不伪装成 complete）。
    func testMissingPrerequisiteDoesNotOverclaimComplete() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first)
        XCTAssertNil(cannon.currentStageMaxLevel)
        XCTAssertEqual(cannon.status, .unverified, "缺 prerequisite → unverified，不判 complete")
    }

    /// 实验室门槛：Lab=1 满足野蛮人全部等级（lvl2/3 需 Lab1）→ stage == 3 == 全局。
    func testStageMaxLevelHonorsLaboratoryGate() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_007, level: 1, path: "0")],  // 实验室
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 3, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let barbarian = try XCTUnwrap(home.items.first { $0.dataID == 4_000_000 })
        XCTAssertEqual(barbarian.currentStageMaxLevel, 3, "Lab=1 满足 lvl2/lvl3 的 Lab1 门槛")
        XCTAssertEqual(barbarian.status, .maxed)
    }

    /// 快照无实验室 → 野蛮人阶段上限不可计算 → unverified（fail-closed，不判 maxed）。
    func testMissingLaboratoryBecomesUnverified() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 3, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let barbarian = try XCTUnwrap(home.items.first)
        XCTAssertNil(barbarian.currentStageMaxLevel, "快照缺实验室 → 阶段上限不可计算")
        XCTAssertEqual(barbarian.status, .unverified, "缺 prerequisite → unverified，不判 maxed")
    }

    /// 无 requirement 的 item（建筑工人小屋）→ 阶段上限恒等于全局上限（始终可计算）。
    func testNoRequirementStageEqualsGlobalMax() throws {
        let village = makeVillage(objectSections: [
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 1, path: "0")],
        ])
        let builder = project(village: village, catalog: stageCatalog, base: .builder)
        let hut = try XCTUnwrap(builder.items.first)
        XCTAssertEqual(hut.currentStageMaxLevel, 2, "无 requirement → 阶段上限 == maxLevel")
        XCTAssertEqual(hut.status, .complete, "level 1 < 2 → 未满级")
    }

    /// 英雄殿堂门槛（requiredHeroTavernLevel）：tavern=8 → 阶段上限 = tavern ≤8 的最高等级
    /// 8（lvl9 需 tavern10）；英雄 8 级 == 阶段上限 → 阶段满级。
    func testStageMaxLevelHonorsHeroHallTavernGate() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_071, level: 8, path: "0")],  // 英雄殿堂
            "heroes": [makeItem(section: "heroes", dataID: 28_000_000, level: 8, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let king = try XCTUnwrap(home.items.first { $0.dataID == 28_000_000 })
        XCTAssertEqual(king.currentStageMaxLevel, 8, "lvl1-8 tavern≤8 满足；lvl9 需 tavern10 不满足")
        XCTAssertEqual(king.maxLevel, 10)
        XCTAssertEqual(king.status, .maxed)
    }

    /// 英雄殿堂 4 级：阶段上限 4；英雄 5 级 → 阶段满级（maxLevel 10 全局未满）。
    func testHeroStageMaxedBelowGlobal() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_071, level: 4, path: "0")],
            "heroes": [makeItem(section: "heroes", dataID: 28_000_000, level: 5, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let king = try XCTUnwrap(home.items.first { $0.dataID == 28_000_000 })
        XCTAssertEqual(king.currentStageMaxLevel, 4)
        XCTAssertEqual(king.status, .maxed, "level 5 >= 阶段上限 4 → 阶段满级")
        XCTAssertLessThan(king.currentStageMaxLevel ?? .max, king.maxLevel ?? .min)
    }

    /// 快照无英雄殿堂 → 英雄阶段上限不可计算 → unverified（fail-closed，
    /// 不得把英雄判成全局满级或未满级，Issue #67 验收「缺失不伪推」）。
    func testMissingHeroHallBecomesUnverified() throws {
        let village = makeVillage(objectSections: [
            "heroes": [makeItem(section: "heroes", dataID: 28_000_000, level: 10, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let king = try XCTUnwrap(home.items.first)
        XCTAssertNil(king.currentStageMaxLevel)
        XCTAssertEqual(king.status, .unverified)
    }

    /// 建筑大师基地：BH=8 满足双管加农炮全部门槛（lvl4 需 BH6）→ stage == 4 == 全局。
    func testBuilderStageMaxLevelHonorsBuilderHallGate() throws {
        let village = makeVillage(objectSections: [
            "buildings2": [
                makeItem(section: "buildings2", dataID: 1_000_034, level: 8, path: "0"),  // 建筑大师大本营
                makeItem(section: "buildings2", dataID: 1_000_042, level: 4, path: "1"),   // 双管加农炮
            ],
        ])
        let builder = project(village: village, catalog: stageCatalog, base: .builder)
        let cannon = try XCTUnwrap(builder.items.first { $0.dataID == 1_000_042 })
        XCTAssertEqual(cannon.currentStageMaxLevel, 4)
        XCTAssertEqual(cannon.status, .maxed)
    }

    /// BH=3：阶段上限 2（lvl3 需 BH4 不满足）；双管加农炮 3 级 → 阶段满级（maxLevel 4 全局未满）。
    func testBuilderStageMaxedBelowGlobalWithLowerHall() throws {
        let village = makeVillage(objectSections: [
            "buildings2": [
                makeItem(section: "buildings2", dataID: 1_000_034, level: 3, path: "0"),
                makeItem(section: "buildings2", dataID: 1_000_042, level: 3, path: "1"),
            ],
        ])
        let builder = project(village: village, catalog: stageCatalog, base: .builder)
        let cannon = try XCTUnwrap(builder.items.first { $0.dataID == 1_000_042 })
        XCTAssertEqual(cannon.currentStageMaxLevel, 2, "BH=3 满足 lvl1(BH1)/lvl2(BH2)，lvl3 需 BH4 不满足")
        XCTAssertEqual(cannon.status, .maxed, "level 3 >= 阶段上限 2 → 阶段满级")
        XCTAssertLessThan(cannon.currentStageMaxLevel ?? .max, cannon.maxLevel ?? .min)
    }

    /// 跨基地隔离：主村大本营 12 级不能替代建筑大师大本营（builderHall 解锁缺失
    /// → 双管加农炮阶段上限不可计算 → unverified，fail-closed）。
    func testHomeTownHallDoesNotSatisfyBuilderHall() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0")],
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_042, level: 2, path: "0")],
        ])
        let builder = project(village: village, catalog: stageCatalog, base: .builder)
        let cannon = try XCTUnwrap(builder.items.first { $0.dataID == 1_000_042 })
        XCTAssertNil(cannon.currentStageMaxLevel)
        XCTAssertEqual(cannon.status, .unverified, "缺 BH 记录 → unverified，主村大本营不替代")
    }

    // MARK: - 铁匠铺门槛（Issue #97）

    /// 铁匠铺门槛（requiredBlacksmithLevel）：BS=2 → 阶段上限 = 2（lvl3 需 BS3 不满足）；
    /// 装备 2 级 == 阶段上限 → 阶段满级（maxLevel 3 全局未满）。
    func testStageMaxLevelHonorsBlacksmithGate() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_070, level: 2, path: "0")],  // 铁匠铺
            "equipment": [makeItem(section: "equipment", dataID: 90_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let puppet = try XCTUnwrap(home.items.first { $0.dataID == 90_000_000 })
        XCTAssertEqual(puppet.currentStageMaxLevel, 2, "lvl1 需 BS1/lvl2 需 BS2 满足；lvl3 需 BS3 不满足")
        XCTAssertEqual(puppet.maxLevel, 3)
        XCTAssertEqual(puppet.status, .maxed)
        XCTAssertLessThan(puppet.currentStageMaxLevel ?? .max, puppet.maxLevel ?? .min)
    }

    /// 快照无铁匠铺 → 装备阶段上限不可计算 → unverified（fail-closed，
    /// 不得把装备判成全局满级或未满级，Issue #97 验收「缺失不伪推」）。
    func testMissingBlacksmithBecomesUnverified() throws {
        let village = makeVillage(objectSections: [
            "equipment": [makeItem(section: "equipment", dataID: 90_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let puppet = try XCTUnwrap(home.items.first)
        XCTAssertNil(puppet.currentStageMaxLevel)
        XCTAssertEqual(puppet.status, .unverified)
    }

    /// 铁匠铺 3 级满足全部门槛（lvl3 需 BS3）→ stage == 3 == 全局 maxLevel。
    func testHighBlacksmithStageEqualsGlobalMax() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_070, level: 3, path: "0")],  // 铁匠铺
            "equipment": [makeItem(section: "equipment", dataID: 90_000_000, level: 3, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let puppet = try XCTUnwrap(home.items.first { $0.dataID == 90_000_000 })
        XCTAssertEqual(puppet.currentStageMaxLevel, 3)
        XCTAssertEqual(puppet.maxLevel, 3)
        XCTAssertEqual(puppet.status, .maxed)
    }

    /// 跨建筑不替代：主村大本营 12 级不能替代铁匠铺（blacksmith 解锁缺失
    /// → 装备阶段上限不可计算 → unverified，fail-closed）。
    func testHomeTownHallDoesNotSatisfyBlacksmith() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0")],
            "equipment": [makeItem(section: "equipment", dataID: 90_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let puppet = try XCTUnwrap(home.items.first { $0.dataID == 90_000_000 })
        XCTAssertNil(puppet.currentStageMaxLevel)
        XCTAssertEqual(puppet.status, .unverified, "缺铁匠铺记录 → unverified，大本营不替代")
    }

    /// 聚合传播：同键非升级记录聚合后 currentStageMaxLevel 保留 first 值（Task 4 会
    /// 在 VillageDetailProjectionTests 加专项测试，这里先锁定字段不丢）。
    func testAggregatedStatePreservesStageMaxLevel() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertTrue(cannon.id.hasPrefix("agg:"), "同键非升级记录应聚合")
        XCTAssertEqual(cannon.count, 2)
        XCTAssertEqual(cannon.currentStageMaxLevel, 2, "聚合项必须传播阶段上限")
    }

    // MARK: - Issue #67 Task 6：星空实验室（StarLab）正反例 + property-based

    /// StarLab 正例：builder 单位带 requiredLaboratoryLevel（builder 语义 = 星空实验室），
    /// 星空实验室 1000046 等级满足 → 阶段上限按 StarLab 门槛计算。
    /// 目录：units2 单位 maxLevel 3，lvl2/lvl3 需 requiredLaboratoryLevel=1（→ .starLaboratory(level: 1)）。
    func testStageMaxLevelHonorsStarLaboratoryGate() throws {
        let catalogJSON = """
        {"gameVersion":"v","items":[
          {"section":"units2","category":"troops","dataID":4000001,"base":"builder","name":"重拳野蛮人","maxLevel":3,
           "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
           "levels":[
             {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
             {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null}
           ]}
        ]}
        """
        let catalog = try makeCatalog(from: catalogJSON)
        let village = makeVillage(objectSections: [
            "buildings2": [
                makeItem(section: "buildings2", dataID: 1_000_046, level: 1, path: "0"),  // 星空实验室
            ],
            "units2": [
                makeItem(section: "units2", dataID: 4_000_001, level: 3, path: "0"),   // 重拳野蛮人
            ],
        ])
        let builder = project(village: village, catalog: catalog, expectedGameVersion: nil, base: .builder)
        let unit = try XCTUnwrap(builder.items.first { $0.dataID == 4_000_001 })
        XCTAssertEqual(unit.currentStageMaxLevel, 3, "StarLab=1 满足 lvl2/lvl3 门槛 → 阶段上限 3")
        XCTAssertEqual(unit.status, .maxed)
    }

    /// StarLab 反例 1：星空实验室缺失 → 阶段上限不可计算（nil）→ 回退全局，level 2 < 3 → complete。
    func testMissingStarLaboratoryMakesStageUncomputable() throws {
        let catalogJSON = """
        {"gameVersion":"v","items":[
          {"section":"units2","category":"troops","dataID":4000001,"base":"builder","name":"重拳野蛮人","maxLevel":3,
           "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
           "levels":[
             {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
             {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null}
           ]}
        ]}
        """
        let catalog = try makeCatalog(from: catalogJSON)
        let village = makeVillage(objectSections: [
            "units2": [
                makeItem(section: "units2", dataID: 4_000_001, level: 2, path: "0"),
            ],
        ])
        let builder = project(village: village, catalog: catalog, expectedGameVersion: nil, base: .builder)
        let unit = try XCTUnwrap(builder.items.first { $0.dataID == 4_000_001 })
        XCTAssertNil(unit.currentStageMaxLevel)
        XCTAssertEqual(unit.status, .unverified, "缺 StarLab 记录 → unverified，不判 complete")
    }

    /// StarLab 反例 2：星空实验室等级不足（lvl3 需 StarLab 2）→ 阶段上限 2，单位 3 级 → 阶段满级。
    func testStarLaboratoryBelowGateLowersStageMax() throws {
        let catalogJSON = """
        {"gameVersion":"v","items":[
          {"section":"units2","category":"troops","dataID":4000001,"base":"builder","name":"重拳野蛮人","maxLevel":3,
           "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
           "levels":[
             {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
             {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":2,"icon":null,"levelVisual":null,"missingReason":null}
           ]}
        ]}
        """
        let catalog = try makeCatalog(from: catalogJSON)
        let village = makeVillage(objectSections: [
            "buildings2": [
                makeItem(section: "buildings2", dataID: 1_000_046, level: 1, path: "0"),  // StarLab=1
            ],
            "units2": [
                makeItem(section: "units2", dataID: 4_000_001, level: 3, path: "0"),
            ],
        ])
        let builder = project(village: village, catalog: catalog, expectedGameVersion: nil, base: .builder)
        let unit = try XCTUnwrap(builder.items.first { $0.dataID == 4_000_001 })
        XCTAssertEqual(unit.currentStageMaxLevel, 2, "lvl3 需 StarLab2 不满足 → 阶段上限 2")
        XCTAssertEqual(unit.status, .maxed, "level 3 >= 阶段上限 2 → 阶段满级")
        XCTAssertLessThan(unit.currentStageMaxLevel ?? .max, unit.maxLevel ?? .min)
    }

    /// Property：currentStageMaxLevel 不变量（固定种子 SeededRNG，零依赖）。
    /// - 1) 可计算时 currentStageMaxLevel <= maxLevel；
    /// - 2) 全部门槛满足（解锁 >= 各级最大要求）→ currentStageMaxLevel == maxLevel；
    /// - 3) 解锁等级单调不减提升 → 阶段上限不减（TH/Lab 双维度分别验证）；
    /// - 4) 任一存在 requirement 类型的解锁缺失 → nil。
    func testPropertyStageMaxLevelInvariants() {
        var rng = SeededRNG(seed: 4242)
        for _ in 0..<200 {
            // 随机 levels：升序 level 1...N（目录契约），TH 门槛单调不减，随机 maxLevel。
            let levelCount = Int.random(in: 2...12, using: &rng)
            var thGate = 0
            var levels: [CatalogLevel] = []
            for level in 1...levelCount {
                // 门槛单调：30% 概率提升 1-3 级
                if Int.random(in: 0..<10, using: &rng) < 3 {
                    thGate += Int.random(in: 1...3, using: &rng)
                }
                levels.append(CatalogLevel(
                    level: level,
                    durationSeconds: nil,
                    upgradeCosts: nil,
                    requiredTownHallLevel: level == 1 ? nil : thGate, // level 1 初始无门槛
                    requiredLaboratoryLevel: nil,
                    icon: nil,
                    levelVisual: nil,
                    missingReason: nil
                ))
            }
            let item = CatalogItem(
                section: "buildings", category: "buildings", dataID: 10_000,
                base: "home", baseMissingReason: nil, name: "随机建筑", maxLevel: levelCount,
                icon: nil, levelVisual: nil, levels: levels
            )
            let maxGate = levels.map { $0.requiredTownHallLevel ?? 0 }.max() ?? 0

            // 随机解锁等级：0（缺失）或 1...maxGate+5
            let th = Int.random(in: 0...(maxGate + 5), using: &rng)
            let unlocks = PlayerUnlockLevels(
                townHall: th == 0 ? nil : th,
                builderHall: nil, laboratory: nil, starLaboratory: nil, heroHall: nil
            )

            let stageMax = VillageCatalogProjection.currentStageMaxLevel(for: item, unlocks: unlocks)

            if th == 0 {
                // 不变量 4：存在 TH requirement 且解锁缺失 → nil（level > 1 时必有门槛）
                if levels.contains(where: { $0.requiredTownHallLevel != nil }) {
                    XCTAssertNil(stageMax, "存在门槛但 TH 缺失 → 不可计算")
                }
                continue
            }
            let unwrapped = try! XCTUnwrap(stageMax)
            // 不变量 1
            XCTAssertLessThanOrEqual(unwrapped, item.maxLevel, "阶段上限不得超过全局上限")
            // 不变量 2
            if th >= maxGate {
                XCTAssertEqual(unwrapped, item.maxLevel, "门槛全满足 → 阶段上限 == 全局上限")
            }
            // 不变量 3：TH+1 → 阶段上限不减（对 th < maxGate 且 th > 0 的情形）
            let higherUnlocks = PlayerUnlockLevels(
                townHall: th + 1,
                builderHall: nil, laboratory: nil, starLaboratory: nil, heroHall: nil
            )
            let higherMax = VillageCatalogProjection.currentStageMaxLevel(for: item, unlocks: higherUnlocks)
            if let higherMax {
                XCTAssertGreaterThanOrEqual(higherMax, unwrapped, "解锁提升 → 阶段上限不减")
            }
        }
    }

    /// Property：装备 currentStageMaxLevel 铁匠铺不变量（固定种子 SeededRNG，零依赖）。
    /// - 1) 可计算时 currentStageMaxLevel <= maxLevel；
    /// - 2) 铁匠铺 >= 各级最大 BS 门槛 → currentStageMaxLevel == maxLevel；
    /// - 3) 存在 BS 门槛（> 0）且铁匠铺缺失 → nil（不可计算）；
    /// - 4) 铁匠铺等级单调不减提升 → 阶段上限不减。
    func testPropertyBlacksmithStageMaxInvariants() {
        var rng = SeededRNG(seed: 10_202_608)
        for _ in 0..<200 {
            // 随机 levels：升序 level 1...N（目录契约），BS 门槛单调不减，随机 maxLevel。
            let levelCount = Int.random(in: 2...12, using: &rng)
            var bsGate = 0
            var levels: [CatalogLevel] = []
            for level in 1...levelCount {
                // 门槛单调：30% 概率提升 1-3 级
                if Int.random(in: 0..<10, using: &rng) < 3 {
                    bsGate += Int.random(in: 1...3, using: &rng)
                }
                levels.append(CatalogLevel(
                    level: level,
                    durationSeconds: nil,
                    upgradeCosts: nil,
                    requiredTownHallLevel: nil,
                    requiredLaboratoryLevel: nil,
                    requiredHeroTavernLevel: nil,
                    // 真实数据形状：level 1 起即带 BS 门槛（实测 61 件装备 lvl1
                    // 门槛 ≥1，48 件 =1、13 件 >1 如雷电獠牙=10），与「初始等级
                    // 无门槛」的 TH 语义不同——BS 门槛覆盖所有等级。
                    requiredBlacksmithLevel: bsGate,
                    icon: nil,
                    levelVisual: nil,
                    missingReason: nil
                ))
            }
            let item = CatalogItem(
                section: "equipment", category: "equipment", dataID: 90_000_000,
                base: "home", baseMissingReason: nil, name: "随机装备", maxLevel: levelCount,
                icon: nil, levelVisual: nil, levels: levels
            )
            let maxGate = levels.map { $0.requiredBlacksmithLevel ?? 0 }.max() ?? 0

            // 随机铁匠铺等级：0（缺失）或 1...maxGate+5
            let bs = Int.random(in: 0...(maxGate + 5), using: &rng)
            let unlocks = PlayerUnlockLevels(
                townHall: nil, builderHall: nil, laboratory: nil, starLaboratory: nil, heroHall: nil,
                blacksmith: bs == 0 ? nil : bs
            )

            let stageMax = VillageCatalogProjection.currentStageMaxLevel(for: item, unlocks: unlocks)

            if bs == 0 {
                // 不变量 3：存在 BS 门槛（> 0）且铁匠铺缺失 → nil
                if levels.contains(where: { ($0.requiredBlacksmithLevel ?? 0) > 0 }) {
                    XCTAssertNil(stageMax, "存在门槛但铁匠铺缺失 → 不可计算")
                }
                continue
            }
            // bs > 0：解锁存在，但 level 1 起即带门槛（真实数据形状）——若铁匠铺
            // 等级低于第一级门槛（如 13 件装备 lvl1 门槛 > 1，雷电獠牙=10），
            // 无任何可达等级 → stageMax nil（fail-closed，不误报满级）。
            guard let unwrapped = stageMax else {
                let firstGate = levels.first?.requiredBlacksmithLevel ?? 0
                XCTAssertGreaterThan(firstGate, bs,
                                     "stageMax nil 仅当第一级门槛高于铁匠铺等级")
                continue
            }
            // 不变量 1
            XCTAssertLessThanOrEqual(unwrapped, item.maxLevel, "阶段上限不得超过全局上限")
            // 不变量 2
            if bs >= maxGate {
                XCTAssertEqual(unwrapped, item.maxLevel, "门槛全满足 → 阶段上限 == 全局上限")
            }
            // 不变量 4：BS+1 → 阶段上限不减（对 bs < maxGate 且 bs > 0 的情形）
            let higherUnlocks = PlayerUnlockLevels(
                townHall: nil, builderHall: nil, laboratory: nil, starLaboratory: nil, heroHall: nil,
                blacksmith: bs + 1
            )
            let higherMax = VillageCatalogProjection.currentStageMaxLevel(for: item, unlocks: higherUnlocks)
            if let higherMax {
                XCTAssertGreaterThanOrEqual(higherMax, unwrapped, "铁匠铺提升 → 阶段上限不减")
            }
        }
    }

    // MARK: - Issue #68: VillageNextUpgrade 下一等级可达性投影

    /// 可操作升级：加农炮 level 1 < 阶段上限 2（TH=12 满足全部门槛）→
    /// .available(level: 2, durationSeconds: 300)。
    func testNextUpgradeAvailableBelowStageMax() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),  // 大本营
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),   // 加农炮
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.currentStageMaxLevel, 2)
        XCTAssertEqual(cannon.status, .complete)
        XCTAssertEqual(cannon.nextUpgrade, .available(level: 2, durationSeconds: 300))
    }

    /// 非连续目录 levels [1,2,3,5,7]：level 3 的真实下一级是 5 而非 4——
    /// nextUpgrade 与 nextLevelDurationSeconds 都必须按真实下一级计算（旧实现
    /// durationToUpgradeLevel(level + 1) 在非连续目录下恒 nil）。
    func testNextUpgradeRealNextLevelNonContiguous() throws {
        let catalogJSON = """
        {"gameVersion":"18.400.13","items":[
          {"section":"buildings","category":"buildings","dataID":1000009,"base":"home","name":"不连续等级","maxLevel":7,
           "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
           "levels":[
             {"level":1,"durationSeconds":60,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":2,"durationSeconds":120,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":3,"durationSeconds":300,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":5,"durationSeconds":600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":7,"durationSeconds":1200,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
           ]}
        ]}
        """
        let catalog = try makeCatalog(from: catalogJSON)
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_009, level: 3, path: "0")],
        ])
        let home = project(village: village, catalog: catalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertEqual(item.status, .complete)
        XCTAssertEqual(item.nextUpgrade, .available(level: 5, durationSeconds: 600),
                       "真实下一级 = 目录第一个 > 3 的等级（5），非 4")
        XCTAssertEqual(item.nextLevelDurationSeconds, 600,
                       "非连续目录下 nextLevelDurationSeconds 必须按真实下一级（5）计算")
    }

    /// 阶段满级 → .requires：野蛮人 level 2 == 阶段上限 2（lvl2 需 Lab1 满足、
    /// lvl3 需 Lab2 不满足，lab=1）→ 真实下一级 3 的解锁条件是 [.laboratory(level: 2)]，
    /// referenceDurationSeconds 为 3 级目录时长 3600（解锁后参考，不得当可操作时长）。
    func testNextUpgradeRequiresWhenStageMaxed() throws {
        let catalogJSON = """
        {"gameVersion":"18.400.13","items":[
          {"section":"units","category":"troops","dataID":4000000,"base":"home","name":"野蛮人","maxLevel":3,
           "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
           "levels":[
             {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
             {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":2,"icon":null,"levelVisual":null,"missingReason":null}
           ]}
        ]}
        """
        let catalog = try makeCatalog(from: catalogJSON)
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "th"),  // 大本营
                makeItem(section: "buildings", dataID: 1_000_007, level: 1, path: "lab"),  // 实验室
            ],
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: catalog, base: .home)
        let barbarian = try XCTUnwrap(home.items.first { $0.dataID == 4_000_000 })
        XCTAssertEqual(barbarian.currentStageMaxLevel, 2, "Lab=1 满足 lvl2、不满足 lvl3(Lab2)")
        XCTAssertEqual(barbarian.status, .maxed)
        XCTAssertEqual(
            barbarian.nextUpgrade,
            .requires(nextLevel: 3, requirements: [.laboratory(level: 2)], referenceDurationSeconds: 3600)
        )
    }

    /// 英雄殿堂门槛：king level 8 == 阶段上限 8（heroHall=8，lvl9 需 tavern10 不满足）
    /// → .requires(nextLevel: 9, requirements: [.heroHall(level: 10)],
    /// referenceDurationSeconds: 28800)（lvl9 目录时长）。
    func testNextUpgradeHeroHallGateRequires() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_071, level: 8, path: "0")],  // 英雄殿堂
            "heroes": [makeItem(section: "heroes", dataID: 28_000_000, level: 8, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let king = try XCTUnwrap(home.items.first { $0.dataID == 28_000_000 })
        XCTAssertEqual(king.currentStageMaxLevel, 8)
        XCTAssertEqual(king.status, .maxed)
        XCTAssertEqual(
            king.nextUpgrade,
            .requires(nextLevel: 9, requirements: [.heroHall(level: 10)], referenceDurationSeconds: 28_800)
        )
    }

    /// 铁匠铺门槛：野蛮人木偶 level 2 == 阶段上限 2（铁匠铺=2，lvl3 需 BS3 不满足）
    /// → .requires(nextLevel: 3, requirements: [.blacksmith(level: 3)],
    /// referenceDurationSeconds: nil)（equipment 无时间列 → 参考时长 nil）。
    func testNextUpgradeBlacksmithGateRequires() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_070, level: 2, path: "0")],  // 铁匠铺
            "equipment": [makeItem(section: "equipment", dataID: 90_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let puppet = try XCTUnwrap(home.items.first { $0.dataID == 90_000_000 })
        XCTAssertEqual(puppet.currentStageMaxLevel, 2)
        XCTAssertEqual(puppet.status, .maxed)
        XCTAssertEqual(
            puppet.nextUpgrade,
            .requires(nextLevel: 3, requirements: [.blacksmith(level: 3)], referenceDurationSeconds: nil)
        )
    }

    /// 语义守卫（Reviewer A F1）：异常快照下当前等级可能超过阶段上限（快照 10 级、
    /// 阶段上限 8——版本不匹配已被 .unknown 拦截，仅损坏/过时数据可达）。此时目录
    /// 真实下一级（9）小于当前等级（10），不得输出倒挂的「下一级 9级」：
    /// fail-closed 为 .unknown。
    func testRequiresAnomalousLevelBeyondStageMaxIsUnknown() throws {
        // 目录：maxLevel 15，lvl1-8 门槛 TH 1..8、lvl9 门槛 TH 9（超过 9 的等级
        // 无需收录——守卫只需「首个超过 stageMax 的等级」）。
        let catalogJSON = """
        {"gameVersion":"18.400.13","items":[
          {"section":"units","category":"troops","dataID":4000001,"base":"home","name":"异常单位","maxLevel":15,
           "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
           "levels":[
             {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
             {"level":2,"durationSeconds":1800,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":3,"durationSeconds":3600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":3,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":4,"durationSeconds":5400,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":4,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":5,"durationSeconds":7200,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":5,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":6,"durationSeconds":9000,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":6,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":7,"durationSeconds":10800,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":7,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":8,"durationSeconds":12600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":8,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":9,"durationSeconds":28800,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":9,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
           ]}
        ]}
        """
        let catalog = try makeCatalog(from: catalogJSON)
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 8, path: "th")],
            "units": [makeItem(section: "units", dataID: 4_000_001, level: 10, path: "0")],
        ])
        let home = project(village: village, catalog: catalog, base: .home)
        let unit = try XCTUnwrap(home.items.first { $0.dataID == 4_000_001 })
        XCTAssertEqual(unit.currentStageMaxLevel, 8, "TH=8 满足 lvl1-8 门槛（TH 1..8），lvl9 需 TH9 不满足")
        XCTAssertEqual(unit.status, .maxed, "level 10 >= 阶段上限 8 → 满级（现有语义，level >= stageMax）")
        XCTAssertNil(unit.nextLevelDurationSeconds, "已满级不推断下一级时长")
        XCTAssertEqual(unit.nextUpgrade, .unknown,
                       "realNext(9) < currentLevel(10) → 不得输出倒挂的 .requires，fail-closed 为 .unknown")
    }

    /// 相等边（评审 nit）：快照 level 9 == 阶段上限 8 + 1，连续目录 realNext == 9 ==
    /// currentLevel → `<=` 守卫同样 fail-closed 为 .unknown（自指「下一级 9级」不得输出）。
    func testRequiresAnomalousLevelEqualToRealNextIsUnknown() throws {
        let catalogJSON = """
        {"gameVersion":"18.400.13","items":[
          {"section":"units","category":"troops","dataID":4000001,"base":"home","name":"异常单位","maxLevel":15,
           "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
           "levels":[
             {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
             {"level":2,"durationSeconds":1800,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":3,"durationSeconds":3600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":3,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":4,"durationSeconds":5400,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":4,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":5,"durationSeconds":7200,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":5,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":6,"durationSeconds":9000,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":6,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":7,"durationSeconds":10800,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":7,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":8,"durationSeconds":12600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":8,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
             {"level":9,"durationSeconds":28800,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":9,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
           ]}
        ]}
        """
        let catalog = try makeCatalog(from: catalogJSON)
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 8, path: "th")],
            "units": [makeItem(section: "units", dataID: 4_000_001, level: 9, path: "0")],
        ])
        let home = project(village: village, catalog: catalog, base: .home)
        let unit = try XCTUnwrap(home.items.first { $0.dataID == 4_000_001 })
        XCTAssertEqual(unit.currentStageMaxLevel, 8)
        XCTAssertEqual(unit.status, .maxed)
        XCTAssertNil(unit.nextLevelDurationSeconds)
        XCTAssertEqual(unit.nextUpgrade, .unknown,
                       "realNext(9) == currentLevel(9) → 自指「下一级 9级」不得输出，`<=` 守卫 fail-closed 为 .unknown")
    }

    /// 全局满级：level == maxLevel → .globalMaxed；level > maxLevel（目录过时/数据
    /// 异常）→ 同样 .globalMaxed，不得推断可升级。
    func testNextUpgradeGlobalMaxed() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 2, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.status, .maxed)
        XCTAssertEqual(cannon.nextUpgrade, .globalMaxed)

        let stale = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 5, path: "1"),
            ],
        ])
        let home2 = project(village: stale, catalog: stageCatalog, base: .home)
        let cannon5 = try XCTUnwrap(home2.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon5.nextUpgrade, .globalMaxed, "level > maxLevel 不得推断可升级")
    }

    /// 升级中：目标等级是快照事实（currentLevel + 1，#14 契约），时长来自目录目标等级。
    func testNextUpgradeInProgressFact() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1,
                         timerSeconds: 600, remainingSeconds: 300, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertTrue(cannon.isUpgrading)
        XCTAssertEqual(cannon.nextUpgrade, .inProgressFact(level: 2, durationSeconds: 300))
    }

    /// 升级中 + 目标等级超过目录上限（Reviewer B minor 1，验收 7「升级中目标超过
    /// 目录」）：加农炮 level 2 → 3，目录 maxLevel 2 无 3 级记录 → 目标等级是快照
    /// 事实（.inProgressFact(level: 3)），但时长不得伪造（durationSeconds nil）。
    /// 版本不匹配变体同样：事实保留、时长 nil、missingReason 标注版本不匹配。
    func testNextUpgradeInProgressTargetBeyondCatalogMax() throws {
        // 正常版本：目标 3 级超出目录 maxLevel 2。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 2,
                         timerSeconds: 600, remainingSeconds: 300, path: "0"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertTrue(cannon.isUpgrading)
        XCTAssertEqual(cannon.nextUpgrade, .inProgressFact(level: 3, durationSeconds: nil),
                       "目录无 3 级记录 → 目标事实保留但时长不得伪造")
        XCTAssertNil(cannon.nextLevelDurationSeconds)

        // 版本不匹配变体：旧目录（9.9.9）+ 目标 3 级 → 事实保留、时长 nil、原因标注。
        let staleCatalog = try makeCatalog(from: Self.stageCatalogJSON
            .replacingOccurrences(of: "\"gameVersion\": \"18.400.13\"", with: "\"gameVersion\": \"9.9.9\""))
        let home2 = project(village: village, catalog: staleCatalog,
                             expectedGameVersion: GameCatalog.defaultBundledVersion, base: .home)
        let cannon2 = try XCTUnwrap(home2.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon2.status, .upgrading)
        XCTAssertEqual(cannon2.nextUpgrade, .inProgressFact(level: 3, durationSeconds: nil),
                       "版本不匹配 → 目标事实保留、旧目录时长不得泄漏")
        XCTAssertNil(cannon2.nextLevelDurationSeconds)
        let reason = try XCTUnwrap(cannon2.missingReason)
        XCTAssertTrue(reason.contains("版本不匹配"),
                      "升级中 + 版本不匹配必须显式标注缺失原因，got: \(reason)")
    }

    /// 升级中 + 目录版本不匹配：目标等级事实保留，但时长不得泄漏旧目录值
    ///（durationSeconds nil），且 missingReason 必须显式标注版本不匹配（旧实现泄漏）。
    func testNextUpgradeUpgradingVersionMismatchNoDuration() throws {
        let staleCatalog = try makeCatalog(from: Self.stageCatalogJSON
            .replacingOccurrences(of: "\"gameVersion\": \"18.400.13\"", with: "\"gameVersion\": \"9.9.9\""))
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1,
                         timerSeconds: 600, remainingSeconds: 300, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: staleCatalog,
                           expectedGameVersion: GameCatalog.defaultBundledVersion, base: .home)
        let cannon = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(cannon.status, .upgrading)
        XCTAssertEqual(cannon.nextUpgrade, .inProgressFact(level: 2, durationSeconds: nil),
                       "版本不匹配 → 目标等级事实保留但时长不得泄漏旧目录值")
        XCTAssertNil(cannon.nextLevelDurationSeconds)
        let reason = try XCTUnwrap(cannon.missingReason)
        XCTAssertTrue(reason.contains("版本不匹配"),
                      "升级中 + 版本不匹配必须显式标注缺失原因，got: \(reason)")
    }

    /// 升级中 + 快照缺大本营（stageMax == nil）：进行中事实不因阶段上限不可计算而
    /// 隐藏——.inProgressFact 保留，时长来自目录目标等级（非 nil）。
    func testNextUpgradeUpgradingMissingPrerequisiteKeepsFact() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_002, level: 1,
                         timerSeconds: 600, remainingSeconds: 300, path: "0"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first)
        XCTAssertTrue(cannon.isUpgrading)
        XCTAssertNil(cannon.currentStageMaxLevel)
        XCTAssertEqual(cannon.nextUpgrade, .inProgressFact(level: 2, durationSeconds: 300),
                       "缺 prereq 不得隐藏进行中的升级事实")
    }

    /// 非升级 + 缺大本营（stageMax == nil）→ .unverified（fail-closed，不推断可升级）。
    func testNextUpgradeUnverifiedWhenPrerequisiteMissing() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let cannon = try XCTUnwrap(home.items.first)
        XCTAssertNil(cannon.currentStageMaxLevel)
        XCTAssertEqual(cannon.status, .unverified)
        XCTAssertEqual(cannon.nextUpgrade, .unverified)
    }

    /// 非升级 + 目录版本不匹配 → .unknown（fail-closed，旧目录不得支撑可升级推断）。
    func testNextUpgradeUnknownWhenVersionMismatchIdle() throws {
        let staleCatalog = try makeCatalog(from: Self.stageCatalogJSON
            .replacingOccurrences(of: "\"gameVersion\": \"18.400.13\"", with: "\"gameVersion\": \"9.9.9\""))
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: staleCatalog,
                           expectedGameVersion: GameCatalog.defaultBundledVersion, base: .home)
        let cannon = try XCTUnwrap(home.items.first)
        XCTAssertEqual(cannon.status, .unknown)
        XCTAssertEqual(cannon.nextUpgrade, .unknown)
        XCTAssertNil(cannon.nextLevelDurationSeconds)
    }

    /// 嵌套项与不支持类别（helpers/decos）→ nextUpgrade == nil
    ///（不参与目录 join / 不参与升级追踪）。
    func testNextUpgradeNilForNestedAndUnavailable() throws {
        let module = makeItem(section: "units", dataID: 4_000_000, level: 1, path: "0.modules.0")
        let village = makeVillage(objectSections: [
            "helpers": [makeItem(section: "helpers", dataID: 93_000_000, level: 1, path: "0")],
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2, modules: [module], path: "0"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let helper = try XCTUnwrap(home.items.first { $0.section == "helpers" })
        XCTAssertEqual(helper.status, .unavailable)
        XCTAssertNil(helper.nextUpgrade, "不支持类别 → nextUpgrade nil")
        let nested = try XCTUnwrap(home.items.first(where: \.isNested))
        XCTAssertNil(nested.nextUpgrade, "嵌套项 → nextUpgrade nil")
    }

    /// 聚合传播：同键非升级记录聚合后 nextUpgrade 保留 first 的语义
    ///（.available 与 .requires 两组分别验证）。
    func testAggregatePropagatesNextUpgrade() throws {
        // 组 A：TH=12 满足全部门槛 → 两个 level 1 加农炮聚合 → .available(level: 2, 300)
        let villageA = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let homeA = project(village: villageA, catalog: stageCatalog, base: .home)
        let aggA = try XCTUnwrap(homeA.items.first { $0.dataID == 1_000_002 })
        XCTAssertTrue(aggA.id.hasPrefix("agg:"))
        XCTAssertEqual(aggA.count, 2)
        XCTAssertEqual(aggA.nextUpgrade, .available(level: 2, durationSeconds: 300))

        // 组 B：TH=1 → 阶段上限 1，level 1 == 阶段上限 → 聚合项保留 .requires 语义
        let villageB = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let homeB = project(village: villageB, catalog: stageCatalog, base: .home)
        let aggB = try XCTUnwrap(homeB.items.first { $0.dataID == 1_000_002 })
        XCTAssertTrue(aggB.id.hasPrefix("agg:"))
        XCTAssertEqual(aggB.count, 2)
        XCTAssertEqual(
            aggB.nextUpgrade,
            .requires(nextLevel: 2, requirements: [.townHall(level: 2)], referenceDurationSeconds: 300)
        )
    }

    /// Property：VillageNextUpgrade 不变量（SeededRNG 固定种子，300 轮随机
    /// levels/门槛/解锁/当前等级/升级中）。
    /// - (a) .available 的 level 必须 ∈ 目录等级集；
    /// - (b) .requires 的 nextLevel 必须 > currentStageMaxLevel；
    /// - (c) .inProgressFact 的 level == currentLevel + 1（#14 事实契约）；
    /// - (d) stageMax 可计算时 status == .maxed ⟺ nextUpgrade ∈ {.requires, .globalMaxed}
///   （评审 F1 倒挂守卫例外：realNext ≤ currentLevel 的异常快照 → .maxed 配 .unknown）；
    /// - (e) nextUpgrade nil ⟺ 嵌套/unavailable/目录未命中（命中项恒非 nil）；
    /// - (f) .requires 的 requirements 恒非空（数据异常兜底为 .globalMaxed）。
    func testPropertyNextUpgradeInvariants() throws {
        var rng = SeededRNG(seed: 68_202_608)
        for iteration in 0..<300 {
            // 随机等级：升序、30% 概率跳级（非连续），TH 门槛 25% 概率提升 1-3（单调不减）。
            let levelCount = Int.random(in: 2...10, using: &rng)
            var nextLevel = 1
            var thGate = 0
            var levels: [CatalogLevel] = []
            for index in 0..<levelCount {
                if index > 0, Int.random(in: 0..<10, using: &rng) < 3 {
                    nextLevel += Int.random(in: 1...3, using: &rng)
                }
                if index > 0, Int.random(in: 0..<10, using: &rng) < 3 {
                    thGate += Int.random(in: 1...3, using: &rng)
                }
                levels.append(CatalogLevel(
                    level: nextLevel,
                    durationSeconds: Int64(nextLevel * 60),
                    upgradeCosts: nil,
                    requiredTownHallLevel: index == 0 ? nil : thGate,
                    requiredLaboratoryLevel: nil,
                    icon: nil,
                    levelVisual: nil,
                    missingReason: nil
                ))
                nextLevel += 1
            }
            let maxLevel = levels.last?.level ?? levelCount
            let item = CatalogItem(
                section: "buildings", category: "buildings", dataID: 999_000_001,
                base: "home", baseMissingReason: nil, name: "随机建筑", maxLevel: maxLevel,
                icon: nil, levelVisual: nil, levels: levels
            )
            let catalog = GameCatalog(gameVersion: "18.400.13", items: [item])
            let maxGate = levels.map { $0.requiredTownHallLevel ?? 0 }.max() ?? 0
            let th = Int.random(in: 0...(maxGate + 3), using: &rng)
            let currentLevel = Int.random(in: 1...(maxLevel + 2), using: &rng)
            let upgrading = Bool.random(using: &rng)

            var objectSections: [String: [AccountItem]] = [
                "buildings": [makeItem(
                    section: "buildings", dataID: 999_000_001, level: currentLevel,
                    timerSeconds: upgrading ? 1000 : nil,
                    remainingSeconds: upgrading ? 500 : nil,
                    path: "0"
                )],
            ]
            if th > 0 {
                objectSections["buildings"]?.append(
                    makeItem(section: "buildings", dataID: 1_000_001, level: th, path: "th")
                )
            }
            let village = makeVillage(objectSections: objectSections)
            let home = project(village: village, catalog: catalog, base: .home)

            let state = try XCTUnwrap(home.items.first { $0.dataID == 999_000_001 },
                                     "迭代 \(iteration) 应产出目标项")
            let upgrade = try XCTUnwrap(state.nextUpgrade,
                                        "迭代 \(iteration): 目录命中平铺项 nextUpgrade 恒非 nil")
            let catalogLevels = Set(levels.map(\.level))

            if case .available(let level, _) = upgrade {
                XCTAssertTrue(catalogLevels.contains(level),
                              "迭代 \(iteration): .available 等级 \(level) 必须 ∈ 目录等级")
            } else if case .requires(let requiresLevel, let requirements, _) = upgrade {
                XCTAssertFalse(requirements.isEmpty,
                               "迭代 \(iteration): .requires 不得携带空 requirements（数据异常兜底）")
                let stageMax = try XCTUnwrap(state.currentStageMaxLevel,
                                             "迭代 \(iteration): .requires 时阶段上限必须可计算")
                XCTAssertGreaterThan(requiresLevel, stageMax,
                                     "迭代 \(iteration): .requires nextLevel 必须超过阶段上限")
            } else if case .inProgressFact(let factLevel, _) = upgrade {
                XCTAssertEqual(factLevel, currentLevel + 1,
                               "迭代 \(iteration): .inProgressFact 目标 = currentLevel + 1（#14 事实）")
            }

            if let stageMax = state.currentStageMaxLevel {
                let isMaxed = state.status == .maxed
                let nextIsMaxed: Bool
                switch upgrade {
                case .requires, .globalMaxed: nextIsMaxed = true
                default: nextIsMaxed = false
                }
                if nextIsMaxed {
                    // 原等价方向：.requires/.globalMaxed ⟹ status .maxed。
                    XCTAssertTrue(isMaxed,
                                  "迭代 \(iteration): nextUpgrade ∈ {.requires, .globalMaxed} 时 status 必须 .maxed")
                } else if isMaxed {
                    // 评审 F1 倒挂守卫例外：异常快照（currentLevel > stageMax 且目录
                    // 首个超过 stageMax 的真实等级 < currentLevel）时 .maxed 合法地配
                    // .unknown——不产生可操作/倒挂的下一级。守卫之外没有其他
                    // .maxed + 非满级投影的组合。
                    XCTAssertEqual(upgrade, .unknown,
                                   "迭代 \(iteration): .maxed 且非 .requires/.globalMaxed 时必须是倒挂守卫 .unknown")
                    let firstAboveStage = levels.sorted(by: { $0.level < $1.level })
                        .first { $0.level > stageMax }?.level
                    XCTAssertLessThanOrEqual(firstAboveStage ?? .min, currentLevel,
                                      "迭代 \(iteration): .maxed + .unknown 必须是 realNext < currentLevel 的倒挂场景")
                }
            }

            // (e) 目录未命中项（大本营 1000001 不在自定义目录中）→ nil
            if let thState = home.items.first(where: { $0.dataID == 1_000_001 }) {
                XCTAssertNil(thState.nextUpgrade,
                             "迭代 \(iteration): 目录未命中项 nextUpgrade 必须为 nil")
            }
        }
    }

    // MARK: - Issue #74b: nextLevelDurationState 透传

    func testNextLevelDurationStateTimedForReachableLevel() throws {
        // 非升级未满级：stageCatalog 加农炮 level 1 → 真实下一级 level 2 = 300s。
        // 数据约定（Issue #67）：村庄必须带大本营 1000001 记录，且加农炮必须用
        // 1000002（1000001 是真实大本营 dataID，会被 PlayerUnlockLevels 误读）。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first { $0.dataID == 1_000_002 })
        XCTAssertEqual(item.nextLevelDurationState, .timed(seconds: 300))
        XCTAssertEqual(item.nextLevelDurationSeconds, 300,
                       "nextLevelDurationSeconds 与 state 必须同源一致")
    }

    func testNextLevelDurationStateUnknownReasonTransparent() throws {
        // 装备目录命中但 level 时长为 nil（合成 reason no_direct_upgrade_time）：
        // state 原样透传（防御分支），seconds 保持 nil。
        let village = makeVillage(objectSections: [
            "equipment": [makeItem(section: "equipment", dataID: 90_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertNil(item.nextLevelDurationSeconds)
        XCTAssertEqual(item.nextLevelDurationState, .unknownReason("no_direct_upgrade_time"))
    }

    func testNextLevelDurationStateNilForMaxedAndUnmatched() throws {
        // 满级：无下一级，不推状态（stageCatalog 加农炮 level 2 = 满级）。
        let villageMaxed = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 2, path: "1"),
            ],
        ])
        let maxed = try XCTUnwrap(
            project(village: villageMaxed, catalog: stageCatalog, base: .home)
                .items.first { $0.dataID == 1_000_002 })
        XCTAssertNil(maxed.nextLevelDurationState)
        // 目录未命中：不推状态。
        let villageMiss = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 3_999_999_999, level: 2, path: "0")],
        ])
        let miss = try XCTUnwrap(
            project(village: villageMiss, catalog: syntheticCatalog, base: .home).items.first)
        XCTAssertNil(miss.nextLevelDurationState)
    }

    func testNextLevelDurationStateNilWhenVersionMismatch() throws {
        // 版本不匹配（catalogIsUsable == false）：不得泄漏旧目录时长/状态。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 12, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: stageCatalog,
                           expectedGameVersion: "99.0.0", base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertNil(item.nextLevelDurationSeconds)
        XCTAssertNil(item.nextLevelDurationState)
    }


    // MARK: - Issue #74a: 兼容性状态 + deprecated 透传

    func testCompatibilityUnverifiedByDefault() throws {
        // 默认（无玩家 build）：显式 unverified，不得伪装已匹配。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.compatibility, .unverified(gameVersion: "18.400.13"))
        XCTAssertTrue(home.catalogIsUsable, "unverified 不阻断完成度（玩家 build 数据源不存在）")
        // info 级诊断明确「未验证」
        XCTAssertTrue(home.diagnostics.contains {
            $0.severity == .info && $0.message.contains("未验证")
        }, "默认路径必须有未验证诊断")
    }

    func testCompatibilityVerifiedWhenExplicitlyMatched() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog,
                           expectedGameVersion: "18.400.13", base: .home)
        XCTAssertEqual(home.compatibility, .verified(gameVersion: "18.400.13"))
        XCTAssertTrue(home.catalogIsUsable)
        XCTAssertFalse(home.diagnostics.contains { $0.message.contains("未验证") })
    }

    func testCompatibilityMismatchBlocksCompleteness() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog,
                           expectedGameVersion: "99.0.0", base: .home)
        XCTAssertEqual(home.compatibility, .mismatch(catalogVersion: "18.400.13", expectedVersion: "99.0.0"))
        XCTAssertFalse(home.catalogIsUsable, "mismatch 必须阻断完成度（fail-closed）")
        XCTAssertTrue(home.diagnostics.contains { $0.severity == .warning && $0.message.contains("不匹配") })
    }

    func testCompatibilityUnavailableWhenCatalogNil() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: nil, base: .home)
        XCTAssertEqual(home.compatibility, .unavailable)
        XCTAssertFalse(home.catalogIsUsable)
    }

    func testResolveHelperFourStates() {
        let catalog = syntheticCatalog
        XCTAssertEqual(
            CatalogCompatibility.resolve(catalog: catalog, expectedGameVersion: nil),
            .unverified(gameVersion: "18.400.13"))
        XCTAssertEqual(
            CatalogCompatibility.resolve(catalog: catalog, expectedGameVersion: "18.400.13"),
            .verified(gameVersion: "18.400.13"))
        XCTAssertEqual(
            CatalogCompatibility.resolve(catalog: catalog, expectedGameVersion: "99.0.0"),
            .mismatch(catalogVersion: "18.400.13", expectedVersion: "99.0.0"))
        XCTAssertEqual(
            CatalogCompatibility.resolve(catalog: nil, expectedGameVersion: nil),
            .unavailable)
    }

    func testCatalogItemMissingReasonTransparent() throws {
        // 合成目录加 deprecated item：catalogItemMissingReason 透传；普通 item nil。
        let json = """
        {"gameVersion":"18.400.13","items":[
          {"section":"pets","category":"pets","dataID":73000000,"base":"home","name":"a","maxLevel":1,"icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":"deprecated_in_source","levels":[
            {"level":1,"durationSeconds":60,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
          ]},
          {"section":"units","category":"troops","dataID":4000000,"base":"home","name":"野蛮人","maxLevel":3,"icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,"levels":[
            {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
            {"level":2,"durationSeconds":1800,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
          ]}
        ]}
        """
        let catalog = try makeCatalog(from: json)
        let village = makeVillage(objectSections: [
            "pets": [makeItem(section: "pets", dataID: 73_000_000, level: 1, path: "0")],
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 1, path: "1")],
        ])
        let home = project(village: village, catalog: catalog, base: .home)
        let deprecated = try XCTUnwrap(home.items.first { $0.dataID == 73_000_000 })
        XCTAssertEqual(deprecated.catalogItemMissingReason, "deprecated_in_source")
        XCTAssertNil(deprecated.missingReason, "join 语义 missingReason 不受影响")
        let normal = try XCTUnwrap(home.items.first { $0.dataID == 4_000_000 })
        XCTAssertNil(normal.catalogItemMissingReason)
    }

    // MARK: - Issue #74a: property-based（聚合透传不变量 + 兼容性确定性）

    func testPropertyAggregationPreservesCatalogItemMissingReason() throws {
        // 聚合不变量：非升级同键聚合后 catalogItemMissingReason 双向保持——
        // 正向：deprecated 标记聚合后保留；反向：普通 item 聚合后不凭空产生。
        //（同 (section,dataID,level) 的记录来自同一 CatalogItem，透传必须一致。）
        let json = """
        {"gameVersion":"18.400.13","items":[
          {"section":"pets","category":"pets","dataID":73000000,"base":"home","name":"a","maxLevel":1,"icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":"deprecated_in_source","levels":[
            {"level":1,"durationSeconds":60,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
          ]},
          {"section":"units","category":"troops","dataID":4000000,"base":"home","name":"野蛮人","maxLevel":3,"icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,"levels":[
            {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
            {"level":2,"durationSeconds":1800,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
          ]}
        ]}
        """
        let catalog = try makeCatalog(from: json)
        var rng = SeededRNG(seed: 42)
        for iteration in 0..<50 {
            let n = Int.random(in: 1...4, using: &rng)
            let useDeprecated = Bool.random(using: &rng)
            let section = useDeprecated ? "pets" : "units"
            let dataID: Int64 = useDeprecated ? 73_000_000 : 4_000_000
            var items: [AccountItem] = []
            for j in 0..<n {
                items.append(makeItem(section: section, dataID: dataID, level: 2, path: String(j)))
            }
            let village = makeVillage(objectSections: [section: items])
            let home = project(village: village, catalog: catalog, base: .home)
            let aggregated = try XCTUnwrap(home.items.first { $0.dataID == dataID })
            XCTAssertEqual(
                aggregated.isCatalogDeprecated, useDeprecated,
                "迭代 \(iteration): 聚合后 deprecated 标记必须保留（n=\(n)）")
        }
    }


    // MARK: - Issue #74 seasonal: availability 投影

    private func makeAvailabilityPhases() -> SeasonalPhaseTable {
        SeasonalPhaseTable(schemaVersion: 1, phases: [
            SeasonalPhase(
                phaseID: "crafted-defenses-1", name: "精制防御第一季",
                from: Date(timeIntervalSince1970: 1_000), until: Date(timeIntervalSince1970: 2_000),
                itemKeys: ["buildings:103000000"]),
        ])
    }

    private func projectWithAvailability(
        _ village: VillageProfile,
        table: SeasonalPhaseTable,
        now: Date
    ) -> VillageCatalogProjection {
        projectWithAvailability(village, catalog: syntheticCatalog, table: table, now: now)
    }

    /// Issue #98：指定目录的 availability 投影（lifecycle 用例注入带声明的目录）。
    /// `craftTableCatalog` 默认 nil（旧调用点零破坏）——嵌套防御回查用例显式传入。
    private func projectWithAvailability(
        _ village: VillageProfile,
        catalog: GameCatalog?,
        table: SeasonalPhaseTable,
        now: Date,
        craftTableCatalog: CraftTableCatalog? = nil
    ) -> VillageCatalogProjection {
        VillageCatalogProjection.project(
            village: village, catalog: catalog,
            seasonalPhases: table, craftTableCatalog: craftTableCatalog,
            base: .home, now: now)
    }

    func testAvailabilityUnconfiguredByDefault() throws {
        // 空表（默认）：全部条目 unconfigured——不推断、不编造。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertEqual(item.availability, .unconfigured)
    }

    func testAvailabilitySeasonalActiveWithInjectedNow() throws {
        // 阶段表命中 + now 在活动期 → seasonal(status: .active)。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 103_000_000, level: 1, path: "0")],
        ])
        let home = projectWithAvailability(
            village, table: makeAvailabilityPhases(),
            now: Date(timeIntervalSince1970: 1_500))
        let item = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
        XCTAssertEqual(
            item.availability,
            .seasonal(phaseID: "crafted-defenses-1", phaseName: "精制防御第一季", status: .active))
    }

    func testAvailabilitySeasonalEndedWithInjectedNow() throws {
        // now 在结束期后 → seasonal(status: .ended)——历史存在、当前不可用。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 103_000_000, level: 1, path: "0")],
        ])
        let home = projectWithAvailability(
            village, table: makeAvailabilityPhases(),
            now: Date(timeIntervalSince1970: 3_000))
        let item = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
        XCTAssertEqual(
            item.availability,
            .seasonal(phaseID: "crafted-defenses-1", phaseName: "精制防御第一季", status: .ended))
    }

    func testAvailabilityDeterministicWithInjectedNow() throws {
        // 同一输入不同 now → 结果确定（无 Date() 隐式依赖）。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 103_000_000, level: 1, path: "0")],
        ])
        let active = projectWithAvailability(
            village, table: makeAvailabilityPhases(), now: Date(timeIntervalSince1970: 1_500))
        let ended = projectWithAvailability(
            village, table: makeAvailabilityPhases(), now: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(active.items.first { $0.dataID == 103_000_000 }?.availability,
                       .seasonal(phaseID: "crafted-defenses-1", phaseName: "精制防御第一季", status: .active))
        XCTAssertEqual(ended.items.first { $0.dataID == 103_000_000 }?.availability,
                       .seasonal(phaseID: "crafted-defenses-1", phaseName: "精制防御第一季", status: .ended))
    }

    func testAvailabilityMalformedPhaseIsUnconfigured() throws {
        // P2-1 对抗测试：from >= until 的畸形阶段不得进入投影（→ unconfigured）。
        let bad = SeasonalPhaseTable(schemaVersion: 1, phases: [
            SeasonalPhase(
                phaseID: "bad", name: nil,
                from: Date(timeIntervalSince1970: 2_000), until: Date(timeIntervalSince1970: 1_000),
                itemKeys: ["buildings:103000000"]),
        ])
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 103_000_000, level: 1, path: "0")],
        ])
        let home = projectWithAvailability(
            village, table: bad, now: Date(timeIntervalSince1970: 1_500))
        let item = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
        XCTAssertEqual(item.availability, .unconfigured,
                       "畸形阶段必须被过滤，不得标 notStarted/ended")
    }

    func testAvailabilityStatusBoundariesDeterministic() throws {
        // 状态级边界锚定（确定性，不依赖随机命中）：阶段 1000..<2000，
        // now = 999/1000/1999/2000 四点 → notStarted/active/active/ended。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 103_000_000, level: 1, path: "0")],
        ])
        let cases: [(Double, SeasonalStatus)] = [
            (999, .notStarted), (1_000, .active), (1_999, .active), (2_000, .ended),
        ]
        for (seconds, expected) in cases {
            let home = projectWithAvailability(
                village, table: makeAvailabilityPhases(),
                now: Date(timeIntervalSince1970: seconds))
            let item = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
            XCTAssertEqual(
                item.availability,
                .seasonal(phaseID: "crafted-defenses-1", phaseName: "精制防御第一季", status: expected),
                "now=\(seconds) 状态必须确定")
        }
    }

    func testPropertyAvailabilityPreservedThroughAggregation() throws {
        // 聚合不变量：availability 同组透传一致（同 dataID → 同阶段判定）。
        var rng = SeededRNG(seed: 7)
        for iteration in 0..<50 {
            let n = Int.random(in: 1...4, using: &rng)
            let now = Date(timeIntervalSince1970: Double(Int.random(in: 500...3_500, using: &rng)))
            var items: [AccountItem] = []
            for j in 0..<n {
                items.append(makeItem(
                    section: "buildings", dataID: 103_000_000, level: 1, path: String(j)))
            }
            let village = makeVillage(objectSections: ["buildings": items])
            let home = projectWithAvailability(village, table: makeAvailabilityPhases(), now: now)
            let aggregated = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
            // 三态期望：<1000 未开始、<2000 活动、>=2000 已结束（阶段 1000..<2000）。
            let expectedStatus: SeasonalStatus
            if now < Date(timeIntervalSince1970: 1_000) {
                expectedStatus = .notStarted
            } else if now < Date(timeIntervalSince1970: 2_000) {
                expectedStatus = .active
            } else {
                expectedStatus = .ended
            }
            if case .seasonal(_, _, let status) = aggregated.availability {
                XCTAssertEqual(status, expectedStatus,
                               "迭代 \(iteration): 聚合后状态必须与注入 now 一致（n=\(n)）")
            } else {
                XCTFail("迭代 \(iteration): 阶段命中条目聚合后必须是 seasonal")
            }
        }
    }

    // MARK: - Issue #98 lifecycle: availability 投影接线

    /// Issue #98：带 lifecycle 声明的合成目录。syntheticCatalogJSON 无 lifecycle 键
    ///（默认 nil = 旧目录语义，既有用例不变）；本 helper 供生命周期用例显式声明。
    private func makeLifecycleCatalog(items: [CatalogItem]) -> GameCatalog {
        GameCatalog(gameVersion: "18.400.13", items: items)
    }

    /// 单条目生命周期目录 item（home 建筑语义；dataID 避开 1000001 大本营读表冲突）。
    private func makeLifecycleItem(
        section: String,
        dataID: Int64,
        lifecycle: CatalogLifecycle?
    ) -> CatalogItem {
        CatalogItem(
            section: section, category: "buildings", dataID: dataID, base: "home",
            baseMissingReason: nil, name: "测试条目", maxLevel: 1,
            icon: nil, levelVisual: nil, missingReason: nil,
            lifecycle: lifecycle,
            levels: [CatalogLevel(
                level: 1, durationSeconds: 60, upgradeCosts: nil,
                requiredTownHallLevel: nil, requiredLaboratoryLevel: nil,
                icon: nil, levelVisual: nil, missingReason: nil
            )]
        )
    }

    /// 验收 1：目录条目声明 permanent → 空表也返回 .permanent（不因阶段表缺失降级）。
    func testAvailabilityPermanentItemReturnsPermanent() throws {
        let catalog = makeLifecycleCatalog(items: [
            makeLifecycleItem(section: "buildings", dataID: 7_700_000, lifecycle: .permanent),
        ])
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 7_700_000, level: 1, path: "0")],
        ])
        let home = projectWithAvailability(
            village, catalog: catalog, table: .empty, now: Date(timeIntervalSince1970: 1_500))
        let item = try XCTUnwrap(home.items.first { $0.dataID == 7_700_000 })
        XCTAssertEqual(item.availability, .permanent)
    }

    /// Issue #113：permanent + 阶段表命中 → .conflict（fail-closed，不再静默选边）；
    /// 诊断字段（phaseID/phaseName/lifecycle）从命中阶段透传，sourceURL nil 合法。
    func testAvailabilityPermanentWithPhaseHitReturnsConflict() throws {
        let catalog = makeLifecycleCatalog(items: [
            makeLifecycleItem(section: "buildings", dataID: 103_000_000, lifecycle: .permanent),
        ])
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 103_000_000, level: 1, path: "0")],
        ])
        // makeAvailabilityPhases：阶段 1000..<2000 活动期，now=1500 命中。
        let home = projectWithAvailability(
            village, catalog: catalog, table: makeAvailabilityPhases(),
            now: Date(timeIntervalSince1970: 1_500))
        let item = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
        XCTAssertEqual(
            item.availability,
            .conflict(
                phaseID: "crafted-defenses-1", phaseName: "精制防御第一季",
                lifecycle: .permanent, sourceURL: nil),
            "permanent 与阶段表冲突必须显式 .conflict，不静默返回 .permanent")
    }

    /// 验收 2：seasonalCandidate + 阶段命中 → 三态边界
    ///（复用 makeAvailabilityPhases：1000..<2000，now=999/1500/3000 → notStarted/active/ended）。
    func testAvailabilitySeasonalCandidateThreeBoundaries() throws {
        let catalog = makeLifecycleCatalog(items: [
            makeLifecycleItem(section: "buildings", dataID: 103_000_000, lifecycle: .seasonalCandidate),
        ])
        let cases: [(Double, SeasonalStatus)] = [
            (999, .notStarted), (1_500, .active), (3_000, .ended),
        ]
        for (seconds, expected) in cases {
            let village = makeVillage(objectSections: [
                "buildings": [makeItem(section: "buildings", dataID: 103_000_000, level: 1, path: "0")],
            ])
            let home = projectWithAvailability(
                village, catalog: catalog, table: makeAvailabilityPhases(),
                now: Date(timeIntervalSince1970: seconds))
            let item = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
            guard case .seasonal(let phaseID, _, let status) = item.availability else {
                XCTFail("now=\(seconds): seasonalCandidate 命中阶段必须是 seasonal")
                continue
            }
            XCTAssertEqual(phaseID, "crafted-defenses-1", "now=\(seconds)")
            XCTAssertEqual(status, expected, "now=\(seconds)")
        }
    }

    /// 验收 3：seasonalCandidate + 阶段表未命中 → .unconfigured（已知限时但数据缺失，
    /// 不得误报永久）。
    func testAvailabilitySeasonalCandidatePhaseMissingReturnsUnconfigured() throws {
        let catalog = makeLifecycleCatalog(items: [
            makeLifecycleItem(section: "buildings", dataID: 7_700_001, lifecycle: .seasonalCandidate),
        ])
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 7_700_001, level: 1, path: "0")],
        ])
        let home = projectWithAvailability(
            village, catalog: catalog, table: makeAvailabilityPhases(),
            now: Date(timeIntervalSince1970: 1_500))
        let item = try XCTUnwrap(home.items.first { $0.dataID == 7_700_001 })
        XCTAssertEqual(item.availability, .unconfigured)
    }

    /// 回归保护：嵌套模组（.types. 路径）不参与目录 join → lifecycle nil；阶段表
    /// 命中其 itemKey → .seasonal（主目录不 join 不得丢失限时标注）。
    func testAvailabilityNestedModulePhaseHitReturnsSeasonal() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(
                section: "buildings", dataID: 103_000_000, level: 1, path: "0.types.0")],
        ])
        let home = projectWithAvailability(
            village, table: makeAvailabilityPhases(), now: Date(timeIntervalSince1970: 1_500))
        let item = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
        XCTAssertEqual(
            item.availability,
            .seasonal(phaseID: "crafted-defenses-1", phaseName: "精制防御第一季", status: .active),
            "嵌套项不 join（lifecycle nil），阶段命中仍必须 seasonal")
    }

    // MARK: - Issue #98 审核 F1：嵌套防御生命周期回查精制台目录（防两投影漂移）

    /// 单防御精制台目录（lifecycle 由用例注入；dataID 与主投影快照嵌套项对应）。
    /// 显式 init：合成 memberwise init 对 let 默认值省略参数，无法显式传 lifecycle
    ///（与 CraftTableProjectionTests.makeDefenseCatalog 同一模式）。
    private func makeCraftDefenseCatalog(dataID: Int64, lifecycle: CatalogLifecycle?) -> CraftTableCatalog {
        CraftTableCatalog(
            schemaVersion: 1, gameVersion: "18.400.13", buildTag: "test",
            defenses: [CraftTableDefenseSpec(
                dataID: dataID, name: "测试防御", sourceName: "test",
                specialAbility: "", moduleIDs: [], totalModuleLevelThresholds: [],
                lifecycle: lifecycle
            )],
            modules: []
        )
    }

    /// 审核 F1：嵌套精工防御（.types. 路径）在主投影回查精制台目录 lifecycle 声明
    /// → .permanent——与精制台投影（CraftTableProjection）同口径，同一防御不再
    /// 两投影漂移（验收 6：主投影详情页也显示 permanent，而非「阶段信息未配置」）。
    func testNestedDefenseLifecycleFromCraftTableCatalog() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(
                section: "buildings", dataID: 103_000_000, level: 1, path: "0.types.0")],
        ])
        let craft = makeCraftDefenseCatalog(dataID: 103_000_000, lifecycle: .permanent)
        let home = projectWithAvailability(
            village, catalog: syntheticCatalog, table: .empty,
            now: Date(timeIntervalSince1970: 1_500), craftTableCatalog: craft)
        let item = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
        XCTAssertEqual(item.availability, .permanent,
                       "嵌套防御须回查精制台目录声明，与精制台投影同口径")
    }

    /// 审核 F1：不传 craftTableCatalog（默认 nil = 旧调用点零破坏）→ 嵌套项
    /// lifecycle nil → 阶段表未命中 → .unconfigured（旧行为保持）。
    func testNestedDefenseWithoutCraftTableCatalogStaysUnconfigured() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(
                section: "buildings", dataID: 103_000_000, level: 1, path: "0.types.0")],
        ])
        let home = projectWithAvailability(
            village, table: .empty, now: Date(timeIntervalSince1970: 1_500))
        let item = try XCTUnwrap(home.items.first { $0.dataID == 103_000_000 })
        XCTAssertEqual(item.availability, .unconfigured)
    }

    /// 审核 F1 边界：嵌套模组（102M 段 dataID）即使传入 craftTableCatalog 也查不到
    /// defense（defense 列表只有 103M 段）→ lifecycle nil → 阶段表命中仍 .seasonal
    ///（模组限时标注不得被回查误伤）。
    func testNestedModuleIgnoresCraftDefenseLookup() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(
                section: "buildings", dataID: 102_000_033, level: 1, path: "0.types.0.modules.0")],
        ])
        let craft = makeCraftDefenseCatalog(dataID: 103_000_000, lifecycle: .permanent)
        let table = SeasonalPhaseTable(schemaVersion: 1, phases: [
            SeasonalPhase(
                phaseID: "crafted-defenses-1", name: "精制防御第一季",
                from: Date(timeIntervalSince1970: 1_000), until: Date(timeIntervalSince1970: 2_000),
                itemKeys: ["buildings:102000033"]),
        ])
        let home = projectWithAvailability(
            village, catalog: syntheticCatalog, table: table,
            now: Date(timeIntervalSince1970: 1_500), craftTableCatalog: craft)
        let item = try XCTUnwrap(home.items.first { $0.dataID == 102_000_033 })
        XCTAssertEqual(
            item.availability,
            .seasonal(phaseID: "crafted-defenses-1", phaseName: "精制防御第一季", status: .active),
            "102M 模组不在 defense 列表 → 回查命中 nil → 纯阶段表驱动")
    }

    /// 验收 4：旧目录（lifecycle nil）+ 阶段表未命中 → .unconfigured（保守降级，
    /// 与 testAvailabilityUnconfiguredByDefault 同语义、显式标注 lifecycle nil 路径）。
    func testAvailabilityLegacyCatalogWithoutLifecycleReturnsUnconfigured() throws {
        // syntheticCatalog 条目全部无 lifecycle 声明（旧目录语义）。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])
        let home = projectWithAvailability(
            village, table: .empty, now: Date(timeIntervalSince1970: 1_500))
        let item = try XCTUnwrap(home.items.first { $0.dataID == 1_000_001 })
        XCTAssertEqual(item.availability, .unconfigured)
    }

    // MARK: - Issue #70 阶段 2：宇宙差集（.available 合成项）

    /// 圣水收集器（buildings:1000002，Elixir Collector；审核 B-6 更正：真加农炮
    /// 是 buildings:1000008）18 个大本营等级的实例数量（index = TH-1，值来自
    /// 真实 bundled 目录 18.400.13：TH1=1、TH18=7）。
    private let cannonUniverseCounts = [1, 2, 3, 4, 5, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]
    /// 陷阱（traps:12000000）宇宙：TH1 不可建造（count 0）→ 差集不产出；
    /// TH18 count=2。
    private let trapUniverseCounts = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]

    /// 宇宙目录 fixture：圣水收集器（数量型 buildings:1000002）+ 炸弹（数量型
    /// traps:12000000）+ 野蛮人（解锁型 units:4000000，宇宙表无 units 键）。
    /// manifest 必须非 nil（外部评审 P1-1：hasUniverseData 的完整性信任标记）。
    /// 注意：init 键存在性校验（P1-1）要求每个宇宙键都有目录 item——本 fixture
    /// 全部满足；「宇宙键无目录 item」场景由 GameCatalogTests 的拒绝测试覆盖，
    /// universeSupplement 的对应防御分支是纵深防御（init 后不可达）。
    private func makeUniverseCatalog() -> GameCatalog {
        func levels(_ max: Int) -> [CatalogLevel] {
            (1...max).map {
                CatalogLevel(
                    level: $0, durationSeconds: nil, upgradeCosts: nil,
                    requiredTownHallLevel: nil, requiredLaboratoryLevel: nil,
                    icon: nil, levelVisual: nil, missingReason: nil
                )
            }
        }
        let collector = CatalogItem(
            section: "buildings", category: "buildings", dataID: 1_000_002, base: "home",
            baseMissingReason: nil, name: "圣水收集器", maxLevel: 17, icon: nil, levelVisual: nil,
            levels: levels(17)
        )
        let trap = CatalogItem(
            section: "traps", category: "traps", dataID: 12_000_000, base: "home",
            baseMissingReason: nil, name: "炸弹", maxLevel: 3, icon: nil, levelVisual: nil,
            levels: levels(3)
        )
        let barbarian = CatalogItem(
            section: "units", category: "troops", dataID: 4_000_000, base: "home",
            baseMissingReason: nil, name: "野蛮人", maxLevel: 3, icon: nil, levelVisual: nil,
            levels: levels(3)
        )
        return GameCatalog(
            gameVersion: "18.400.13",
            items: [collector, trap, barbarian],
            manifest: makeUniverseManifestStub(),
            instanceCounts: [
                "buildings:1000002": cannonUniverseCounts,
                "traps:12000000": trapUniverseCounts,
            ]
        )
    }

    /// Issue #96 正例 fixture：9 个追踪类别每类至少一个宇宙键 + 对应目录 item。
    /// 生产目录当前只有 buildings/traps 宇宙——本 fixture 表达「未来目录全类别
    /// 建模」形态（解锁型类别的宇宙 count 仅为存在性标记，语义不深究）。
    private func makeCompleteUniverseCatalog() -> GameCatalog {
        func levels(_ max: Int) -> [CatalogLevel] {
            (1...max).map {
                CatalogLevel(level: $0, durationSeconds: nil, upgradeCosts: nil,
                             requiredTownHallLevel: nil, requiredLaboratoryLevel: nil,
                             icon: nil, levelVisual: nil, missingReason: nil)
            }
        }
        let specs: [(section: String, category: String, dataID: Int64, name: String)] = [
            ("buildings", "buildings", 1_000_002, "圣水收集器"),
            ("traps", "traps", 12_000_000, "炸弹"),
            ("units", "troops", 4_000_000, "野蛮人"),
            ("spells", "spells", 4_000_001, "闪电法术"),
            ("siege_machines", "siegeMachines", 4_000_010, "攻城战车"),
            ("heroes", "heroes", 4_000_100, "野蛮人之王"),
            ("equipment", "equipment", 4_001_000, "狂暴药水瓶"),
            ("pets", "pets", 4_000_200, "独角兽"),
            ("guardians", "guardians", 4_000_300, "守护者"),
        ]
        let items = specs.map { spec in
            CatalogItem(section: spec.section, category: spec.category, dataID: spec.dataID,
                        base: "home", baseMissingReason: nil, name: spec.name, maxLevel: 5,
                        icon: nil, levelVisual: nil, levels: levels(5))
        }
        var instanceCounts: [String: [Int]] = [:]
        for spec in specs {
            instanceCounts["\(spec.section):\(spec.dataID)"] = Array(repeating: 1, count: 18)
        }
        return GameCatalog(
            gameVersion: "18.400.13",
            items: items,
            manifest: makeUniverseManifestStub(),
            instanceCounts: instanceCounts
        )
    }

    /// 宇宙目录的 manifest stub（V3 四字段；hasUniverseData 只看业务校验
    /// 通过的 instanceCounts）。
    private func makeUniverseManifestStub() -> CatalogManifest {
        CatalogManifest(
            schemaVersion: 3, gameVersion: "18.400.13", buildTag: "test",
            locale: "zh-CN"
        )
    }

    // MARK: - Issue #96：progressCoverage（覆盖契约）

    /// 四态之一：unavailable——TH 缺失 / 旧目录 / BB / TH 越界（与旧 universeComplete
    /// false 的四种原因一一对应）。
    func testProgressCoverageUnavailableStates() throws {
        let noTH = makeVillage(objectSections: [:])
        XCTAssertEqual(project(village: noTH, catalog: makeUniverseCatalog(), base: .home).progressCoverage, .unavailable)
        let withTH = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
        ])
        XCTAssertEqual(project(village: withTH, catalog: stageCatalog, base: .home).progressCoverage, .unavailable,
                       "旧目录（无宇宙）→ unavailable")
        XCTAssertEqual(project(village: withTH, catalog: makeUniverseCatalog(), base: .builder).progressCoverage, .unavailable,
                       "BB 恒 unavailable（决策 5）")
        let th19 = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 19, path: "th")],
        ])
        XCTAssertEqual(project(village: th19, catalog: makeUniverseCatalog(), base: .home).progressCoverage, .unavailable,
                       "TH=19 超出宇宙表范围（1...18）→ unavailable")
    }

    /// 四态之二：partial(missingSections)——快照缺失追踪 section（键不存在；
    /// 空数组不算缺失）。
    func testProgressCoveragePartialWhenSectionsMissing() throws {
        // 只有 buildings（TH）+ units：缺 traps/spells/siege_machines/heroes/
        // equipment/pets/guardians 七个 section
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let coverage = project(village: village, catalog: makeCompleteUniverseCatalog(), base: .home).progressCoverage
        guard case .partial(let missing, let unmodeled) = coverage else {
            return XCTFail("期望 .partial，实际 \(coverage)")
        }
        XCTAssertEqual(missing, ["traps", "spells", "siege_machines", "heroes", "equipment", "pets", "guardians"])
        XCTAssertTrue(unmodeled.isEmpty, "全类别宇宙 fixture → unmodeled 为空")
    }

    /// 四态之三：空数组 section 不算缺失（键存在即 present）。
    func testProgressCoverageEmptyArraySectionIsPresent() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
            "traps": [], "units": [], "spells": [], "siege_machines": [],
            "heroes": [], "equipment": [], "pets": [], "guardians": [],
        ])
        XCTAssertEqual(project(village: village, catalog: makeCompleteUniverseCatalog(), base: .home).progressCoverage, .complete,
                       "空数组键存在 → present，不产生 missingSections")
    }

    /// 四态之四：partial(unmodeledCategories)——目录对追踪类别无宇宙数据
    ///（生产目录形态：仅 buildings/traps 有宇宙）。
    func testProgressCoveragePartialWhenCategoriesUnmodeled() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
            "traps": [], "units": [], "spells": [], "siege_machines": [],
            "heroes": [], "equipment": [], "pets": [], "guardians": [],
        ])
        let coverage = project(village: village, catalog: makeUniverseCatalog(), base: .home).progressCoverage
        guard case .partial(let missing, let unmodeled) = coverage else {
            return XCTFail("期望 .partial，实际 \(coverage)")
        }
        XCTAssertTrue(missing.isEmpty, "快照 section 全 → missing 为空")
        XCTAssertEqual(unmodeled, [.troops, .spells, .siegeMachines, .heroes, .equipment, .pets, .guardians])
    }

    /// 正例：9 个追踪 section 全 + 9 类别宇宙全 → .complete（isComplete true）。
    func testProgressCoverageCompleteRequiresAllSectionsAndAllCategoryUniverses() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
            "traps": [], "units": [], "spells": [], "siege_machines": [],
            "heroes": [], "equipment": [], "pets": [], "guardians": [],
        ])
        let projection = project(village: village, catalog: makeCompleteUniverseCatalog(), base: .home)
        XCTAssertEqual(projection.progressCoverage, .complete)
        XCTAssertTrue(projection.progressCoverage.isComplete)
    }

    /// 真实 fixture（section 全）+ 生产 bundled 目录 → partial（7 类未建模）。
    func testProgressCoverageRealFixtureWithBundledCatalogIsPartial() throws {
        let sections = try loadRealFixture()
        let village = makeVillage(objectSections: sections)
        let coverage = project(village: village, catalog: GameCatalog.loadBundled(), base: .home).progressCoverage
        guard case .partial(_, let unmodeled) = coverage else {
            return XCTFail("生产目录 + 真实快照期望 .partial，实际 \(coverage)")
        }
        XCTAssertEqual(unmodeled, [.troops, .spells, .siegeMachines, .heroes, .equipment, .pets, .guardians])
    }

    /// 边界：TH=1 与 TH=18（宇宙表闭区间端点）→ 覆盖判定不受影响。
    func testProgressCoverageAtTownHallBoundaries() throws {
        let sections: [String: [AccountItem]] = [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "th")],
            "traps": [], "units": [], "spells": [], "siege_machines": [],
            "heroes": [], "equipment": [], "pets": [], "guardians": [],
        ]
        let th1 = makeVillage(objectSections: sections)
        XCTAssertEqual(project(village: th1, catalog: makeCompleteUniverseCatalog(), base: .home).progressCoverage, .complete,
                       "TH=1 闭区间端点 → 宇宙可用")
        let th18 = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
            "traps": [], "units": [], "spells": [], "siege_machines": [],
            "heroes": [], "equipment": [], "pets": [], "guardians": [],
        ])
        XCTAssertEqual(project(village: th18, catalog: makeCompleteUniverseCatalog(), base: .home).progressCoverage, .complete,
                       "TH=18 闭区间端点 → 宇宙可用")
    }

    /// 突变守护：宇宙键含 BB 段（"buildings2" 等）→ home 形态过滤生效，
    /// 不得把「仅 BB 建模」误判为 home 类别已建模（Issue #96 评审修复项）。
    func testProgressCoverageIgnoresBuilderUniverseSections() throws {
        // 目录宇宙键 = home traps + BB buildings2（BB 段不贡献 home 建模）；
        // 快照 9 section 全 → 过滤后只认 traps → unmodeled 8 类（含 buildings）。
        // 若 "2" 后缀过滤失效，buildings2 会被 TrackerCategory.from dropLast
        // 映射成 .buildings → unmodeled 变 7 类且不含 buildings，两条断言都红。
        func levels(_ max: Int) -> [CatalogLevel] {
            (1...max).map {
                CatalogLevel(level: $0, durationSeconds: nil, upgradeCosts: nil,
                             requiredTownHallLevel: nil, requiredLaboratoryLevel: nil,
                             icon: nil, levelVisual: nil, missingReason: nil)
            }
        }
        let builderArmyCamp = CatalogItem(
            section: "buildings2", category: "buildings", dataID: 1_000_100, base: "builder",
            baseMissingReason: nil, name: "建筑大师兵营", maxLevel: 10, icon: nil, levelVisual: nil,
            levels: levels(10)
        )
        let trap = CatalogItem(
            section: "traps", category: "traps", dataID: 12_000_000, base: "home",
            baseMissingReason: nil, name: "炸弹", maxLevel: 3, icon: nil, levelVisual: nil,
            levels: levels(3)
        )
        let catalog = GameCatalog(
            gameVersion: "18.400.13",
            items: [builderArmyCamp, trap],
            manifest: makeUniverseManifestStub(),
            instanceCounts: [
                "traps:12000000": cannonUniverseCounts,
                "buildings2:1000100": Array(repeating: 1, count: 18),
            ]
        )
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
            "traps": [], "units": [], "spells": [], "siege_machines": [],
            "heroes": [], "equipment": [], "pets": [], "guardians": [],
        ])
        let coverage = project(village: village, catalog: catalog, base: .home).progressCoverage
        guard case .partial(_, let unmodeled) = coverage else {
            return XCTFail("BB 宇宙不应使 home 覆盖变 complete，实际 \(coverage)")
        }
        XCTAssertTrue(unmodeled.contains(.buildings),
                      "buildings2（BB 段）不得被当作 home buildings 已建模")
        XCTAssertEqual(unmodeled.count, 8, "只有 home traps 建模 → 其余 8 类未建模")
    }

    /// 快照含 BB 段（units2 等）不满足 home 的 units 缺失——home 检查只看
    /// home 形态键（progressSections 无 "2" 后缀）。
    func testProgressCoverageHomeMissingIgnoresBuilderSections() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
            "units2": [makeItem(section: "units2", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let coverage = project(village: village, catalog: makeCompleteUniverseCatalog(), base: .home).progressCoverage
        guard case .partial(let missing, _) = coverage else {
            return XCTFail("期望 .partial（缺 home 追踪 section），实际 \(coverage)")
        }
        XCTAssertTrue(missing.contains("units"), "BB 段 units2 不能补 home 的 units 缺失")
        XCTAssertFalse(missing.contains("buildings"), "buildings 存在（TH）→ 不缺失")
    }

    /// .available 产出：快照无圣水收集器 + TH18 宇宙 count 7 → 合成项
    /// id = "universe:buildings:1000002"、currentLevel 0、count 7、status .available、
    /// maxLevel/currentStageMaxLevel 从目录 join；解锁型（units）不产出；
    /// 宇宙键无目录 item → 防御跳过。
    func testUniverseSupplementProducesAvailableItems() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
        ])
        let home = project(village: village, catalog: makeUniverseCatalog(), base: .home)
        XCTAssertNotEqual(home.progressCoverage, .unavailable, "宇宙可用（合成门禁 buildingUniverseAvailable 打开）")

        let collector = try XCTUnwrap(home.items.first { $0.id == "universe:buildings:1000002" })
        XCTAssertEqual(collector.status, .available)
        XCTAssertEqual(collector.currentLevel, 0, "宇宙差集项恒为 level 0（未观测）")
        XCTAssertEqual(collector.count, 7, "TH18 圣水收集器宇宙 count")
        XCTAssertEqual(collector.maxLevel, 17, "maxLevel 从目录 join")
        XCTAssertEqual(collector.currentStageMaxLevel, 17, "无 requirement → 阶段上限 == 全局上限")
        XCTAssertNil(collector.nextLevel)
        XCTAssertNil(collector.nextLevelDurationSeconds)
        XCTAssertNil(collector.missingReason)
        XCTAssertFalse(collector.isNested)

        // 陷阱 TH18 count=2 → 同样产出
        let trap = try XCTUnwrap(home.items.first { $0.id == "universe:traps:12000000" })
        XCTAssertEqual(trap.status, .available)
        XCTAssertEqual(trap.count, 2)

        // 解锁型（units 段无宇宙键）→ 不产出
        XCTAssertNil(home.items.first { $0.id == "universe:units:4000000" })
    }

    /// 宇宙 count == 0（该 TH 不可建造）不产出；实例级差集（审核 B1）：
    /// 已观测未满配 → 产出 C - 观测；已满配（C ≤ 观测）→ 无差集。
    func testUniverseSupplementSkipsZeroCountAndObserved() throws {
        // TH=1：圣水收集器 count=1（产出）、陷阱 count=0（不产出）
        let villageTH1 = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "th")],
        ])
        let home1 = project(village: villageTH1, catalog: makeUniverseCatalog(), base: .home)
        XCTAssertNotNil(home1.items.first { $0.id == "universe:buildings:1000002" },
                        "TH1 圣水收集器宇宙 count=1 → 产出")
        XCTAssertNil(home1.items.first { $0.id == "universe:traps:12000000" },
                     "TH1 陷阱宇宙 count=0（不可建造）→ 不产出")

        // 实例级差集：快照 1 门（count nil → 权重 1）+ TH18 宇宙 7 → 差集 6
        //（审核 B1：部分建造不得静默消失）
        let villagePartial = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 5, path: "collector"),
            ],
        ])
        let home2 = project(village: villagePartial, catalog: makeUniverseCatalog(), base: .home)
        let partialDiff = try XCTUnwrap(home2.items.first { $0.id == "universe:buildings:1000002" })
        XCTAssertEqual(partialDiff.count, 6, "已观测 1 个 + 宇宙 7 → 差集 6（部分建造补差）")

        // 已满配（快照 count 7 == 宇宙 7）→ 无差集
        let villageFull = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 5, count: 7, path: "collector"),
            ],
        ])
        let home3 = project(village: villageFull, catalog: makeUniverseCatalog(), base: .home)
        XCTAssertNil(home3.items.first { $0.id == "universe:buildings:1000002" },
                     "已满配（C ≤ 观测）→ 无差集")
    }

    /// 实例级差集（审核 B1）：城墙部分建造 200/300（真实 bundled TH13 宇宙
    /// = 300）→ 差集 100 个未建造实例不得消失。
    /// 注：审核示例「200/250」为示意值，真实 18.400.13 城墙 TH13=300。
    func testPartialBuildUniverseDiff() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        XCTAssertEqual(
            catalog.universeCount(section: "buildings", dataID: 1_000_010, townHallLevel: 13), 300,
            "bundled 目录已升级：城墙 TH13 宇宙应为 300，请更新本用例锚点"
        )
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 13, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_010, level: 19, count: 200, path: "wall"),
            ],
        ])
        let home = project(village: village, catalog: catalog, base: .home)
        XCTAssertNotEqual(home.progressCoverage, .unavailable, "宇宙可用（合成门禁 buildingUniverseAvailable 打开）")
        let wallDiff = try XCTUnwrap(home.items.first { $0.id == "universe:buildings:1000010" },
                                     "城墙部分建造应产出差集项")
        XCTAssertEqual(wallDiff.status, .available)
        XCTAssertEqual(wallDiff.count, 100, "城墙 200/300 → 差集 100（审核 B1 实例级）")
    }

    /// metrics 完整分母（审核 B1）：观测 200 + 差集 100（TH13 城墙宇宙 300）→
    /// stage ratio = 200/300 正确（差集实例计入分母、分子贡献 0）。
    /// cap 用目录真实阶段上限（城墙 levels 带 TH 门槛，TH13 非 19）——动态读取
    /// 同时验证差集项 stageMax 与观测项同规则。
    func testPartialBuildMetricsCompleteDenominator() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 13, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_010, level: 19, count: 200, path: "wall"),
            ],
        ])
        let home = project(village: village, catalog: catalog, base: .home)
        // 只对城墙口径计算（TH 记录与其它差集项不参与本断言）。
        let wallItems = home.items.filter { $0.dataID == 1_000_010 }
        let wallItem = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_010))
        let stageMax = try XCTUnwrap(
            VillageCatalogProjection.currentStageMaxLevel(
                for: wallItem, unlocks: PlayerUnlockLevels(townHall: 13)
            ),
            "TH13 城墙阶段上限应可计算（门槛逐级单调）"
        )
        let metrics = VillageProgressProjection.metrics(
            from: wallItems,
            catalogIsUsable: home.catalogIsUsable,
            compatibility: home.compatibility,
            coverage: .complete
        )
        XCTAssertEqual(metrics.currentStageProgress.denominator, 300 * stageMax,
                       "分母 = (观测 200 + 差集 100) × cap \(stageMax)")
        XCTAssertEqual(metrics.currentStageProgress.numerator, 200 * stageMax)
        XCTAssertEqual(metrics.currentStageProgress.ratio ?? -1, 200.0 / 300.0, accuracy: 1e-9)
    }

    /// TH 超出宇宙表范围（评审 B-1/I2：TH19 上线后旧目录窗口期）→
    /// progressCoverage .unavailable、无差集（完整分母不得建立在空宇宙上）。
    func testUniverseCompleteOffWhenTHBeyondRange() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 19, path: "th")],
        ])
        let home = project(village: village, catalog: makeUniverseCatalog(), base: .home)
        XCTAssertEqual(home.progressCoverage, .unavailable, "TH=19 超出宇宙表范围（1...18）→ 不得声称宇宙完整")
        XCTAssertTrue(home.items.allSatisfy { $0.status != .available },
                      "TH 越界不得产出宇宙差集项")
    }

    /// 超配（观测 > 宇宙，外部评审 P1-2）：不得静默吞掉——产 .unknown 异常项
    /// 进入未知侧触发降级（快照 8 个 / 宇宙 7 → .unknown 项 count 1、
    /// currentLevel nil 防误入 known、无 .available 差集项）。
    func testUniverseSupplementOvercapacityProducesUnknown() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 5, count: 8, path: "collector"),
            ],
        ])
        let home = project(village: village, catalog: makeUniverseCatalog(), base: .home)
        XCTAssertNotEqual(home.progressCoverage, .unavailable, "宇宙可用（合成门禁 buildingUniverseAvailable 打开）")

        // 超配项：.unknown、count = 8 - 7 = 1、level nil、missingReason 明确
        let overcapacity = try XCTUnwrap(home.items.first { $0.id == "universe:buildings:1000002" },
                                         "超配应产出 .unknown 异常项")
        XCTAssertEqual(overcapacity.status, .unknown)
        XCTAssertEqual(overcapacity.count, 1, "超配差额 = 观测 8 - 宇宙 7")
        XCTAssertNil(overcapacity.currentLevel, "差额实例无对应观测等级，防误入 known")
        XCTAssertEqual(overcapacity.maxLevel, 17, "maxLevel 从目录 join")
        XCTAssertTrue(overcapacity.missingReason?.contains("超过宇宙上限") == true,
                      overcapacity.missingReason ?? "nil")

        // 同 key 不产 .available 差集项（三态互斥）
        XCTAssertNil(home.items.first { $0.id == "universe:buildings:1000002" && $0.status == .available })

        // metrics：超配项进未知侧 → partial + 降级文案（完整分母下不得伪装 ready）
        let metrics = VillageProgressProjection.metrics(
            from: home.items.filter { $0.status != .unavailable },
            catalogIsUsable: home.catalogIsUsable,
            compatibility: home.compatibility,
            coverage: home.progressCoverage
        )
        XCTAssertEqual(metrics.currentStageProgress.state, .partial)
        XCTAssertTrue(
            metrics.currentStageProgress.degradedReason?.contains("未知或待重新导入") == true
                || metrics.currentStageProgress.degradedReason?.contains("宇宙差集") == true,
            metrics.currentStageProgress.degradedReason ?? "nil"
        )
    }

    /// 旧目录（无 instanceCounts）→ 行为与阶段 1 完全一致：不产出 .available、
    /// progressCoverage .unavailable。
    func testUniverseSupplementOffForLegacyCatalog() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
        ])
        let home = project(village: village, catalog: stageCatalog, base: .home)
        XCTAssertEqual(home.progressCoverage, .unavailable)
        XCTAssertTrue(home.items.allSatisfy { $0.status != .available },
                      "旧目录不得产出宇宙差集项")
    }

    /// 目录版本不匹配（catalogIsUsable false）+ 有宇宙数据 → progressCoverage
    /// .unavailable、不产出 .available（评审 I1：差集项基于不可信目录的
    /// maxLevel/count 会污染投影，与 map() 的 fail-closed 对齐）。
    func testUniverseSupplementOffWhenCatalogMismatch() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")],
        ])
        let home = project(
            village: village, catalog: makeUniverseCatalog(),
            expectedGameVersion: "99.0.0", base: .home
        )
        XCTAssertFalse(home.catalogIsUsable, "版本不匹配 → 目录不可用")
        XCTAssertEqual(home.progressCoverage, .unavailable,
                       "目录不可信时不得宣称宇宙完整")
        XCTAssertTrue(home.items.allSatisfy { $0.status != .available },
                      "目录不可信时不得合成宇宙差集项")
    }

}
