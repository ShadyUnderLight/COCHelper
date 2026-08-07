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

    override func setUpWithError() throws {
        syntheticCatalog = try makeCatalog(from: Self.syntheticCatalogJSON)
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
        expectedGameVersion: String? = GameCatalog.defaultBundledVersion,
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
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 3600, remainingSeconds: 500, path: "0"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertEqual(item.status, .upgrading)
        XCTAssertEqual(item.nextLevel, 3)
        // 野蛮人 2→3 的目录时长 = levels[2].durationSeconds
        XCTAssertEqual(item.nextLevelDurationSeconds, 3600)
    }

    func testNextLevelNilWhenNotUpgrading() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
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
        // 旧版本目录仍能 join（maxLevel 可用），但不得用于可确认完成度。
        let staleCatalog = try makeCatalog(from: Self.syntheticCatalogJSON
            .replacingOccurrences(of: "\"gameVersion\": \"18.400.13\"", with: "\"gameVersion\": \"9.9.9\""))
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])
        let projection = project(village: village, catalog: staleCatalog, base: .home)
        XCTAssertFalse(projection.catalogIsUsable)
        XCTAssertTrue(projection.diagnostics.contains { $0.severity == .warning })
        // join 仍发生（旧 maxLevel 用于展示），但调用方必须用 catalogIsUsable 阻断完成度
        XCTAssertEqual(projection.items.first?.maxLevel, 2)
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
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 3600, remainingSeconds: 0, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.count, 1)
        let item = try XCTUnwrap(home.items.first)
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
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 600, remainingSeconds: nil, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.count, 1)
        let item = try XCTUnwrap(home.items.first)
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
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 3600, remainingSeconds: 0, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 600, remainingSeconds: nil, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.count, 1)
        let item = try XCTUnwrap(home.items.first)
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
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2, count: 1,
                         timerSeconds: 3600, remainingSeconds: 300, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 600, remainingSeconds: nil, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.items.count, 2,
                       "升级记录与 |idle 聚合项必须各自保留")
        let upgrading = try XCTUnwrap(home.items.first(where: \.isUpgrading))
        XCTAssertEqual(upgrading.count, 1)
        XCTAssertTrue(upgrading.isUpgrading)
        XCTAssertEqual(upgrading.status, .upgrading)
        XCTAssertEqual(upgrading.remainingSeconds, 300)
        XCTAssertEqual(upgrading.timerSeconds, 3600)
        XCTAssertFalse(upgrading.needsReimport)

        let idle = try XCTUnwrap(home.items.first { !$0.isUpgrading })
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
        // syntheticCatalog 加农炮 buildings:1000001 maxLevel=2，level 1 未满级 → 推下一级（2 级）时长 300s。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
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
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "1"),
            ],
        ])
        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        let item = try XCTUnwrap(home.items.first)
        XCTAssertTrue(item.id.hasPrefix("agg:"), "非升级重复项应聚合")
        XCTAssertEqual(item.count, 2)
        XCTAssertEqual(item.nextLevelDurationSeconds, 300, "聚合项应保留下一级时长")
    }

    func testPropertyStatusAssignmentIsExhaustiveAndExclusive() throws {
        var rng = SeededRNG(seed: 99)
        let sections = ["units", "buildings", "helpers", "traps2", "equipment"]
        let pool: [Int64] = [4_000_000, 1_000_001, 93_000_000, 12_000_010, 90_000_000]
        // 合成目录收录键（section, dataID, base）：oracle 独立于输出状态计算。
        // 合成目录仅有 4 项：units 4000000(home)、buildings 1000001(home)、
        // buildings2 1000033(builder)、equipment 90000000(home)。
        let catalogHits: Set<String> = [
            "units:4000000:home", "buildings:1000001:home",
            "buildings2:1000033:builder", "equipment:90000000:home",
        ]
        for _ in 0..<20 {
            let snapshot = makeRandomSnapshot(
                rng: &rng, count: 40, dataIDPool: pool, sections: sections
            )
            let village = makeVillage(objectSections: snapshot)
            for base in TrackerBase.allCases {
                let projection = project(village: village, catalog: syntheticCatalog, base: base)
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
                    } else if item.currentLevel ?? -1 >= (item.maxLevel ?? .max) {
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

    // MARK: - 完成度全链路（issue #66：投影聚合 × count 加权）

    /// 真实 bundled 目录（加农炮 buildings:1000008 maxLevel=21）全链路：
    /// 6 条 21 级（count 各 1）+ 1 条 20 级 → 聚合 2 行（count 6/1）→
    /// totalCompletion (7, 6, 0)、ratio 6/7。锁住 bug 根因「行数 ≠ 实例数」。
    func testFullChainCompletionWeightedByCount() throws {
        let cannon21 = (0..<6).map { i in
            makeItem(section: "buildings", dataID: 1_000_008, level: 21, count: 1, path: "c\(i)")
        }
        let cannon20 = makeItem(section: "buildings", dataID: 1_000_008, level: 20, count: 1, path: "c6")
        let village = makeVillage(objectSections: ["buildings": cannon21 + [cannon20]])
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let home = project(village: village, catalog: catalog, base: .home)

        XCTAssertTrue(home.catalogIsUsable)
        // 投影聚合形态：7 条实例记录 → 2 行（行数 < 实例数，聚合真实发生）。
        let cannons = home.items.filter { $0.dataID == 1_000_008 }
        XCTAssertEqual(cannons.count, 2, "6 条 21 级 + 1 条 20 级应聚合为 2 行")
        let maxedRow = try XCTUnwrap(cannons.first { $0.currentLevel == 21 })
        XCTAssertEqual(maxedRow.count, 6, "21 级聚合行 count = 6")
        XCTAssertEqual(maxedRow.status, .maxed)
        let lowerRow = try XCTUnwrap(cannons.first { $0.currentLevel == 20 })
        XCTAssertEqual(lowerRow.count, 1)
        XCTAssertEqual(lowerRow.status, .complete)

        // 加权统计：实例口径 7 = 6 + 1（行数口径只有 2，必错）。
        let total = VillageDetailProjection.totalCompletion(from: home.items)
        XCTAssertEqual(total.knownCount, 7, "got known=\(total.knownCount)")
        XCTAssertEqual(total.completedCount, 6, "got completed=\(total.completedCount)")
        XCTAssertEqual(total.unknownCount, 0)
        XCTAssertEqual(total.completionRatio ?? -1, 6.0 / 7.0, accuracy: 0.0001)
        XCTAssertFalse(total.isFullyMaxed, "1 条未满级实例 → 不得判满级")
    }

    /// 300 条满级城墙（buildings:1000010 maxLevel=19）+ 25 条 18 级 →
    /// 聚合 2 行（count 300/25）→ (325, 300, 0)、ratio 300/325。
    func testFullChainWalls300Maxed25Lower() throws {
        let walls19 = (0..<300).map { i in
            makeItem(section: "buildings", dataID: 1_000_010, level: 19, count: 1, path: "w\(i)")
        }
        let walls18 = (0..<25).map { i in
            makeItem(section: "buildings", dataID: 1_000_010, level: 18, count: 1, path: "l\(i)")
        }
        let village = makeVillage(objectSections: ["buildings": walls19 + walls18])
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let home = project(village: village, catalog: catalog, base: .home)

        XCTAssertTrue(home.catalogIsUsable)
        let walls = home.items.filter { $0.dataID == 1_000_010 }
        XCTAssertEqual(walls.count, 2, "325 条实例记录应聚合为 2 行（行数 < 实例数）")
        let maxedRow = try XCTUnwrap(walls.first { $0.currentLevel == 19 })
        XCTAssertEqual(maxedRow.count, 300)
        XCTAssertEqual(maxedRow.status, .maxed)
        let lowerRow = try XCTUnwrap(walls.first { $0.currentLevel == 18 })
        XCTAssertEqual(lowerRow.count, 25)
        XCTAssertEqual(lowerRow.status, .complete)

        let total = VillageDetailProjection.totalCompletion(from: home.items)
        XCTAssertEqual(total.knownCount, 325, "got known=\(total.knownCount)")
        XCTAssertEqual(total.completedCount, 300, "got completed=\(total.completedCount)")
        XCTAssertEqual(total.unknownCount, 0)
        XCTAssertEqual(total.completionRatio ?? -1, 300.0 / 325.0, accuracy: 0.0001)
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
            maxLevel: 3,
            status: .complete,
            missingReason: nil,
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
                CatalogLevel(level: 1, durationSeconds: 60, upgradeResource: nil,
                             upgradeCost: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil,
                             icon: nil, levelVisual: level1Visual, missingReason: nil),
                CatalogLevel(level: 2, durationSeconds: 300, upgradeResource: nil,
                             upgradeCost: nil, requiredTownHallLevel: nil,
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
                CatalogLevel(level: 1, durationSeconds: 60, upgradeResource: nil,
                             upgradeCost: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil, icon: nil,
                             levelVisual: makeRef(0), missingReason: nil),
                CatalogLevel(level: 5, durationSeconds: 300, upgradeResource: nil,
                             upgradeCost: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil, icon: nil,
                             levelVisual: makeRef(1), missingReason: nil),
                CatalogLevel(level: 9, durationSeconds: 600, upgradeResource: nil,
                             upgradeCost: nil, requiredTownHallLevel: nil,
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
                CatalogLevel(level: 1, durationSeconds: 60, upgradeResource: nil,
                             upgradeCost: nil, requiredTownHallLevel: nil,
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
                CatalogLevel(level: 1, durationSeconds: 60, upgradeResource: nil,
                             upgradeCost: nil, requiredTownHallLevel: nil,
                             requiredLaboratoryLevel: nil,
                             icon: nil, levelVisual: level1Visual, missingReason: nil),
                CatalogLevel(level: 2, durationSeconds: 300, upgradeResource: nil,
                             upgradeCost: nil, requiredTownHallLevel: nil,
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
}
