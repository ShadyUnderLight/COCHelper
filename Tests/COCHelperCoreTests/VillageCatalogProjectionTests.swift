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
        objectSections: [String: [AccountItem]] = [:]
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
                boosts: [:],
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
        let snapshot = try AccountSnapshotImporter.parse(
            String(data: data, encoding: .utf8) ?? ""
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
}
