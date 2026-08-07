import XCTest
@testable import COCHelperCore

/// Issue #15 展示聚合层测试：`UpgradeOverviewProjection.activeRecords`。
///
/// fixture 构造与 VillageCatalogProjectionTests 保持一致（合成目录 + AccountSnapshot 直构）；
/// property-based 复用该文件顶部的 `SeededRNG`（同模块 internal，固定种子可复现）。
final class UpgradeOverviewProjectionTests: XCTestCase {
    // MARK: - Helpers

    private var syntheticCatalog: GameCatalog!

    override func setUpWithError() throws {
        syntheticCatalog = try makeCatalog(from: Self.syntheticCatalogJSON)
    }

    /// 小型合成目录：加农炮(建筑语义)、野蛮人(单位语义)、建筑工人小屋(builder)、野蛮人木偶(装备无时长)。
    /// 基线与 VillageCatalogProjectionTests 的合成目录一致；唯一差异：units:4000000
    /// Lv2 带 levelVisual 资产（供升级总览「记录携带当前等级资产」集成断言使用）。
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
           {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":{"renderedPath":"icons/units/barbarian_lvl2.png","missingReason":null},"missingReason":null},
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
        name: String = "测试村庄",
        tag: String? = "#TEST",
        objectSections: [String: [AccountItem]] = [:]
    ) -> VillageProfile {
        VillageProfile(
            name: name,
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

    /// 直接构造展示记录（成员初始化器，@testable 可访问），用于验证 guard 语义。
    private func makeRecord(remainingSeconds: Int64?) -> UpgradeDisplayRecord {
        UpgradeDisplayRecord(
            id: "test-record",
            villageID: UUID(),
            villageName: "测试村庄",
            villageTag: nil,
            base: .home,
            item: makeItemState(remainingSeconds: remainingSeconds),
            catalogVersion: nil
        )
    }

    private func makeItemState(remainingSeconds: Int64?) -> VillageItemState {
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
            remainingSeconds: remainingSeconds,
            nextLevel: 3,
            nextLevelDurationSeconds: 3600,
            nextLevelDurationState: nil,
            maxLevel: 3,
            status: .upgrading,
            missingReason: nil,
            catalogItemMissingReason: nil,
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: false
        )
    }

    /// 投影入口便捷包装；now 默认 == importedAt（elapsed = 0），计时记录保持原样。
    private func activeRecords(
        _ villages: [VillageProfile],
        catalog: GameCatalog?,
        at now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> [UpgradeDisplayRecord] {
        UpgradeOverviewProjection.activeRecords(from: villages, catalog: catalog, at: now)
    }

    /// `pendingReimportRecords` 便捷包装；now 默认 == importedAt。
    private func pendingReimportRecords(
        _ villages: [VillageProfile],
        catalog: GameCatalog?,
        at now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> [UpgradeDisplayRecord] {
        UpgradeOverviewProjection.pendingReimportRecords(from: villages, catalog: catalog, at: now)
    }

    // MARK: - Filtering

    func testFiltersOutNonUpgradingItems() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                // 升级中：保留
                makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                         timerSeconds: 600, remainingSeconds: 300, path: "0"),
                // 已完成（无计时）：过滤
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "1"),
                // 计时已结束（remaining 归零）：过滤
                makeItem(section: "buildings", dataID: 1_000_001, level: 2,
                         timerSeconds: 600, remainingSeconds: 0, path: "2"),
            ],
        ])
        let records = activeRecords([village], catalog: syntheticCatalog)
        XCTAssertEqual(records.count, 1, "非升级项（remaining 为 nil 或 0）不得出现")
        XCTAssertEqual(records.first?.item.id, "buildings:0")
        XCTAssertEqual(records.first?.item.remainingSeconds, 300)
        XCTAssertTrue(records.allSatisfy { $0.item.isUpgrading })
    }

    // MARK: - Aggregation across villages and bases

    func testAggregatesAcrossVillagesAndBases() throws {
        let villageA = makeVillage(name: "A村", tag: "#AAAA", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                                   timerSeconds: 600, remainingSeconds: 100, path: "0")],
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 1,
                                    timerSeconds: 600, remainingSeconds: 200, path: "0")],
        ])
        let villageB = makeVillage(name: "B村", tag: "#BBBB", objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 3600, remainingSeconds: 300, path: "0")],
        ])
        let records = activeRecords([villageA, villageB], catalog: syntheticCatalog)
        XCTAssertEqual(records.count, 3, "两个村庄 × home+builder 共 3 条升级记录")

        let aHome = try XCTUnwrap(records.first { $0.villageID == villageA.id && $0.base == .home })
        XCTAssertEqual(aHome.villageName, "A村")
        XCTAssertEqual(aHome.villageTag, "#AAAA")
        XCTAssertEqual(aHome.item.remainingSeconds, 100)

        let aBuilder = try XCTUnwrap(records.first { $0.villageID == villageA.id && $0.base == .builder })
        XCTAssertEqual(aBuilder.item.remainingSeconds, 200)
        XCTAssertEqual(aBuilder.item.section, "buildings2")

        let bHome = try XCTUnwrap(records.first { $0.villageID == villageB.id && $0.base == .home })
        XCTAssertEqual(bHome.villageName, "B村")
        XCTAssertEqual(bHome.villageTag, "#BBBB")
        XCTAssertEqual(bHome.item.remainingSeconds, 300)
    }

    func testVillageWithoutSnapshotContributesNoRecords() throws {
        let empty = VillageProfile(id: UUID(), name: "空村")
        let records = activeRecords([empty], catalog: syntheticCatalog)
        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - Sorting

    func testSortsByRemainingThenVillageNameThenBaseThenID() throws {
        let villageA = makeVillage(name: "A村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                                   timerSeconds: 1000, remainingSeconds: 500, path: "0")],
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 1,
                                    timerSeconds: 1000, remainingSeconds: 500, path: "0")],
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 1000, remainingSeconds: 100, path: "1")],
        ])
        let villageB = makeVillage(name: "B村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                                   timerSeconds: 1000, remainingSeconds: 500, path: "0")],
        ])
        let villageC = makeVillage(name: "C村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                                   timerSeconds: 1000, remainingSeconds: 900, path: "0")],
        ])
        // 故意乱序传入，验证排序稳定。
        let records = activeRecords([villageB, villageC, villageA], catalog: syntheticCatalog)

        let expected: [(Int64, String, TrackerBase, String)] = [
            (100, "A村", .home, "units:1"),     // 剩余时间最短
            (500, "A村", .builder, "buildings2:0"), // 同 500s：villageName → base.rawValue("builder" < "home")
            (500, "A村", .home, "buildings:0"),
            (500, "B村", .home, "buildings:0"),  // 同 500s：villageName "A村" < "B村"
            (900, "C村", .home, "buildings:0"),
        ]
        XCTAssertEqual(records.count, expected.count)
        for (record, want) in zip(records, expected) {
            XCTAssertEqual(record.item.remainingSeconds, want.0)
            XCTAssertEqual(record.villageName, want.1)
            XCTAssertEqual(record.base, want.2)
            XCTAssertEqual(record.item.id, want.3)
        }
    }

    func testSortsChineseVillageNamesByLocalizedStandardCompare() throws {
        // 回归（review fix）：村庄名排序必须与旧层 UpgradeTracker.activeRecords(from:)
        // 一致——localizedStandardCompare（中文拼音序），而非码点序。
        // 拼音 er < yi →「二村」在前；码点序「一」(U+4E00) <「二」(U+4E8C) →「一村」在前。
        // 断言「二村」在前即证明实现走拼音序，与旧层一致。
        let villageYi = makeVillage(name: "一村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                                   timerSeconds: 1000, remainingSeconds: 500, path: "0")],
        ])
        let villageEr = makeVillage(name: "二村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                                   timerSeconds: 1000, remainingSeconds: 500, path: "0")],
        ])
        let records = activeRecords([villageYi, villageEr], catalog: syntheticCatalog)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].villageName, "二村",
                       "拼音序 er < yi：「二村」应排在「一村」前（与旧层一致）")
        XCTAssertEqual(records[1].villageName, "一村")
    }

    func testNilOrZeroRemainingNeverAppearsInOutput() throws {
        // isUpgrading 过滤（remaining ?? 0 > 0）保证输出恒为「非 nil 且 > 0」，
        // 因此排序键 `?? .max` 的「nil 排最后」在公开 API 上不可直接观测，
        // 由 property 测试 testPropertyOutputSortedByRemainingThenVillageThenBaseThenID
        // 以 `?? .max` 作为排序键断言覆盖。
        let village = makeVillage(objectSections: [
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 1000, remainingSeconds: 200, path: "0"),
                makeItem(section: "units", dataID: 4_000_000, level: 1, path: "1"),
                makeItem(section: "units", dataID: 4_000_000, level: 3,
                         timerSeconds: 1000, remainingSeconds: 0, path: "2"),
            ],
        ])
        let records = activeRecords([village], catalog: syntheticCatalog)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records.allSatisfy {
            $0.item.remainingSeconds != nil && $0.item.remainingSeconds! > 0
        })
    }

    // MARK: - Identity

    func testIDsUniqueAcrossVillagesBasesAndItems() throws {
        // 两个村庄快照中的 item id 故意相同（"buildings:0"），且同一村庄跨 base，
        // 输出 id 仍必须唯一。
        let villageA = makeVillage(name: "A村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                                   timerSeconds: 600, remainingSeconds: 100, path: "0")],
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 1,
                                    timerSeconds: 600, remainingSeconds: 100, path: "0")],
        ])
        let villageB = makeVillage(name: "B村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                                   timerSeconds: 600, remainingSeconds: 100, path: "0")],
        ])
        let records = activeRecords([villageA, villageB], catalog: syntheticCatalog)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Set(records.map(\.id)).count, records.count,
                       "不同村庄/不同 base/不同 item 的输出 id 不得冲突")

        let aHome = try XCTUnwrap(records.first { $0.villageID == villageA.id && $0.base == .home })
        XCTAssertEqual(aHome.id, villageA.id.uuidString + ":home:" + aHome.item.id)
        let aBuilder = try XCTUnwrap(records.first { $0.villageID == villageA.id && $0.base == .builder })
        XCTAssertEqual(aBuilder.id, villageA.id.uuidString + ":builder:" + aBuilder.item.id)
    }

    // MARK: - Catalog integration

    func testCatalogVersionPassthrough() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 1000, remainingSeconds: 500, path: "0")],
        ])

        let withCatalog = activeRecords([village], catalog: syntheticCatalog)
        XCTAssertFalse(withCatalog.isEmpty)
        XCTAssertTrue(withCatalog.allSatisfy { $0.catalogVersion == "18.400.13" },
                      "catalog 非 nil 时记录应携带版本号")

        let withoutCatalog = activeRecords([village], catalog: nil)
        XCTAssertEqual(withoutCatalog.count, 1)
        XCTAssertNil(withoutCatalog.first?.catalogVersion, "catalog 为 nil 时版本号应为 nil")
    }

    func testNextLevelDurationPassthrough() throws {
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 3600, remainingSeconds: 500, path: "0")],
        ])
        let records = activeRecords([village], catalog: syntheticCatalog)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.item.nextLevel, 3)
        XCTAssertEqual(record.item.nextLevelDurationSeconds, 3600,
                       "目录完整升级时长必须保留在 item 上")
        XCTAssertEqual(record.item.remainingSeconds, 500)
    }

    // MARK: - completionDate

    func testCompletionDateAddsRemainingToNow() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 1000, remainingSeconds: 500, path: "0")],
        ])
        let records = activeRecords([village], catalog: syntheticCatalog, at: now)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.completionDate(from: now), now.addingTimeInterval(500))
    }

    func testCompletionDateNilWhenRemainingMissingOrNonPositive() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 展示层输出恒为「非 nil 正数」，guard 的 nil/非正分支只能直接构造记录验证。
        XCTAssertNil(makeRecord(remainingSeconds: nil).completionDate(from: now))
        XCTAssertNil(makeRecord(remainingSeconds: 0).completionDate(from: now))
        XCTAssertEqual(
            makeRecord(remainingSeconds: 500).completionDate(from: now),
            now.addingTimeInterval(500)
        )
    }

    // MARK: - pendingReimportRecords

    func testPendingReimportOnlyFinishedTimerItems() throws {
        // 过滤语义（Issue #15 验收：「计时结束的项目显示重新导入提示」）：
        // 只含 timerSeconds != nil && remainingSeconds == 0 的项。
        // - upgrading 项（remaining > 0）：不含
        // - 普通完成项（无计时）：不含
        // - 目录未收录且仍在升级的项（remaining > 0）：不含
        //   （重新导入信号与目录收录无关：只要计时结束就该提示；目录未收录
        //   只影响名称/等级展示，不影响过滤条件本身。）
        let village = makeVillage(objectSections: [
            "buildings": [
                // 升级中：不含
                makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                         timerSeconds: 600, remainingSeconds: 300, path: "0"),
                // 计时已结束：含
                makeItem(section: "buildings", dataID: 1_000_001, level: 2,
                         timerSeconds: 600, remainingSeconds: 0, path: "1"),
                // 普通完成（无计时）：不含
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "2"),
            ],
            "units": [
                // 目录未收录（dataID 不在合成目录）且仍在升级：不含
                makeItem(section: "units", dataID: 12_000_010, level: 3,
                         timerSeconds: 600, remainingSeconds: 120, path: "3"),
                // 目录未收录且计时已结束：含（计时信号与目录无关）
                makeItem(section: "units", dataID: 12_000_010, level: 3,
                         timerSeconds: 600, remainingSeconds: 0, path: "4"),
            ],
        ])
        let records = pendingReimportRecords([village], catalog: syntheticCatalog)
        XCTAssertEqual(records.count, 2, "只保留计时结束的两条，其余全部排除")
        XCTAssertTrue(records.allSatisfy {
            $0.item.timerSeconds != nil && $0.item.remainingSeconds == 0
        })
        // 聚合层会把非升级记录 id 重写为 agg: 前缀（见 VillageCatalogProjection.aggregate）。
        XCTAssertEqual(Set(records.map(\.item.id)), ["agg:buildings:1", "agg:units:4"])
        XCTAssertFalse(records.contains { $0.item.id == "agg:buildings:0" }, "升级中项不得出现")
        XCTAssertFalse(records.contains { $0.item.id == "agg:buildings:2" }, "普通完成项不得出现")
        XCTAssertFalse(records.contains { $0.item.id == "agg:units:3" }, "目录未收录且未结束的项不得出现")
    }

    func testPendingReimportAggregatesAcrossVillagesAndBases() throws {
        // 跨村庄 × 跨 base 聚合正确；同键多条计时结束记录聚合为一条并保留 count。
        let villageA = makeVillage(name: "A村", tag: "#AAAA", objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                         timerSeconds: 600, remainingSeconds: 0, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                         timerSeconds: 600, remainingSeconds: 0, path: "1"),
            ],
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 1,
                                    timerSeconds: 600, remainingSeconds: 0, path: "0")],
        ])
        let villageB = makeVillage(name: "B村", tag: "#BBBB", objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 3600, remainingSeconds: 0, path: "0")],
        ])
        let records = pendingReimportRecords([villageA, villageB], catalog: syntheticCatalog)
        XCTAssertEqual(records.count, 3, "A村 home 聚合 1 条 + A村 builder 1 条 + B村 home 1 条")

        let aHome = try XCTUnwrap(records.first { $0.villageID == villageA.id && $0.base == .home })
        XCTAssertEqual(aHome.villageName, "A村")
        XCTAssertEqual(aHome.villageTag, "#AAAA")
        XCTAssertEqual(aHome.item.count, 2, "同键两条计时结束记录应聚合 count")
        XCTAssertEqual(aHome.item.timerSeconds, 600, "聚合不得丢失计时结束信号")
        XCTAssertEqual(aHome.item.remainingSeconds, 0)

        let aBuilder = try XCTUnwrap(records.first { $0.villageID == villageA.id && $0.base == .builder })
        XCTAssertEqual(aBuilder.item.section, "buildings2")

        let bHome = try XCTUnwrap(records.first { $0.villageID == villageB.id && $0.base == .home })
        XCTAssertEqual(bHome.item.dataID, 4_000_000)
        XCTAssertEqual(bHome.item.timerSeconds, 3600)
    }

    func testPendingReimportSortsByVillageThenBaseThenName() throws {
        // 排序：villageName（localizedStandardCompare）→ base.rawValue → item.name。
        // 村庄名用中文名（拼音序，与现有 activeRecords 测试同一 idiom）：
        // 二村(er) < 一村(yi)；base："builder" < "home"；名称：加农炮(jia) < 野蛮人(ye)。
        let villageEr = makeVillage(name: "二村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                                   timerSeconds: 600, remainingSeconds: 0, path: "0")],
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 1,
                                    timerSeconds: 600, remainingSeconds: 0, path: "0")],
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 600, remainingSeconds: 0, path: "1")],
        ])
        let villageYi = makeVillage(name: "一村", objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 600, remainingSeconds: 0, path: "0")],
        ])
        // 故意乱序传入，验证排序稳定。
        let records = pendingReimportRecords([villageYi, villageEr], catalog: syntheticCatalog)

        let expected: [(String, TrackerBase, String)] = [
            // 二村 builder（"builder" < "home"）
            ("二村", .builder, "建筑工人小屋"),
            // 二村 home：加农炮（"加农炮" < "野蛮人"，拼音序 jia < ye）
            ("二村", .home, "加农炮"),
            ("二村", .home, "野蛮人"),
            // 一村 home（拼音序 er < yi）
            ("一村", .home, "野蛮人"),
        ]
        XCTAssertEqual(records.count, expected.count)
        for (record, want) in zip(records, expected) {
            XCTAssertEqual(record.villageName, want.0, "villageName 排序不符")
            XCTAssertEqual(record.base, want.1, "base 排序不符")
            XCTAssertEqual(record.item.name, want.2, "item.name 排序不符")
        }
    }

    func testPendingReimportDisjointFromActiveRecords() throws {
        // 同一快照下：升级中项进 activeRecords，计时结束项进 pendingReimportRecords，
        // 两个列表按 id 无重叠（同一 item 不可能同时满足两种状态）。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                         timerSeconds: 600, remainingSeconds: 300, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_001, level: 2,
                         timerSeconds: 600, remainingSeconds: 0, path: "1"),
            ],
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 3600, remainingSeconds: 0, path: "0")],
        ])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let active = activeRecords([village], catalog: syntheticCatalog, at: now)
        let pending = pendingReimportRecords([village], catalog: syntheticCatalog, at: now)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(pending.count, 2)

        let activeIDs = Set(active.map(\.id))
        let pendingIDs = Set(pending.map(\.id))
        XCTAssertTrue(activeIDs.isDisjoint(with: pendingIDs),
                      "升级中项与计时结束项不得出现在同一列表")
    }

    func testPendingReimportCarriesCatalogVersionAndLevelFallback() throws {
        // 目录版本透传 + 计时结束项无 nextLevel（聚合层语义：不自动 +1）。
        let village = makeVillage(objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 3600, remainingSeconds: 0, path: "0")],
        ])

        let withCatalog = pendingReimportRecords([village], catalog: syntheticCatalog)
        XCTAssertFalse(withCatalog.isEmpty)
        XCTAssertTrue(withCatalog.allSatisfy { $0.catalogVersion == "18.400.13" })
        let record = try XCTUnwrap(withCatalog.first)
        XCTAssertEqual(record.item.currentLevel, 2)
        // Issue #39：升级总览记录携带投影的当前等级资产——record.item 即
        // VillageCatalogProjection 的 state（与村庄详情同一 resolver 数据源）。
        XCTAssertEqual(
            record.item.currentLevelVisual,
            try XCTUnwrap(syntheticCatalog.item(section: record.item.section, dataID: record.item.dataID)?
                .levels.first { $0.level == record.item.currentLevel }?.levelVisual),
            "升级总览记录必须携带 currentLevel 对应的等级资产"
        )
        XCTAssertNil(record.item.nextLevel, "计时结束项不得自动推断下一等级（等重新导入确认）")

        let withoutCatalog = pendingReimportRecords([village], catalog: nil)
        XCTAssertEqual(withoutCatalog.count, 1, "目录缺失不影响计时结束信号")
        XCTAssertNil(withoutCatalog.first?.catalogVersion)
    }

    func testMalformedTimerWithoutRemainingNeverInPending() throws {
        // 回归（P2-1）：malformed 记录（有 timer 无 remaining：timerSeconds=600、
        // remainingSeconds=nil）不得进入 pendingReimportRecords，也不得进入
        // activeRecords——聚合层曾把它强制写成 remainingSeconds = 0，使其满足
        // needsReimport 而误报「待重新导入确认」。
        let village = makeVillage(objectSections: [
            "units": [
                makeItem(section: "units", dataID: 4_000_000, level: 2,
                         timerSeconds: 600, remainingSeconds: nil, path: "0"),
            ],
        ])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let active = activeRecords([village], catalog: syntheticCatalog, at: now)
        let pending = pendingReimportRecords([village], catalog: syntheticCatalog, at: now)
        XCTAssertTrue(active.isEmpty, "malformed 记录（remaining nil）不得进入 activeRecords")
        XCTAssertTrue(pending.isEmpty, "malformed 记录不得误报「待重新导入」")
    }

    // MARK: - overviewRecords（单趟投影）

    // 注意：不再断言 overviewRecords 与 activeRecords/pendingReimportRecords 的等价性——
    // 后两者实现上就是委托 overviewRecords 取字段（同义反复，零验证力）。
    // active/pending 各自的行为与互斥已由上方专门测试及 property 测试覆盖。

    func testOverviewRecordsActiveAndPendingAreDisjoint() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 1,
                         timerSeconds: 600, remainingSeconds: 300, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_001, level: 2,
                         timerSeconds: 600, remainingSeconds: 0, path: "1"),
            ],
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 3600, remainingSeconds: 500, path: "2")],
        ])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let combined = UpgradeOverviewProjection.overviewRecords(
            from: [village], catalog: syntheticCatalog, at: now
        )
        XCTAssertFalse(combined.active.isEmpty)
        XCTAssertFalse(combined.pending.isEmpty)
        XCTAssertTrue(Set(combined.active.map(\.id)).isDisjoint(with: Set(combined.pending.map(\.id))),
                      "active 与 pending 不得重叠（同一项目不可能同时升级中且计时结束）")
    }

    // MARK: - unavailable 项过滤（等价旧层 supportedSections 白名单）

    func testUnavailableItemsExcludedFromActiveAndPending() throws {
        // helpers 等不支持类别（category == nil → status == .unavailable）即使带计时
        // 也不得进入升级总览——等价旧层 UpgradeTracker.supportedSections 白名单行为，
        // 保证 sidebar 计数（旧层）与总览（新层）一致。
        let village = makeVillage(objectSections: [
            "helpers": [
                // 升级中但类别不支持：不得进 active
                makeItem(section: "helpers", dataID: 93_000_000, level: 1,
                         timerSeconds: 600, remainingSeconds: 300, path: "0"),
                // 计时结束但类别不支持：不得进 pending
                makeItem(section: "helpers", dataID: 93_000_001, level: 1,
                         timerSeconds: 600, remainingSeconds: 0, path: "1"),
            ],
            // 正常项不受影响
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2,
                               timerSeconds: 3600, remainingSeconds: 300, path: "2")],
        ])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let combined = UpgradeOverviewProjection.overviewRecords(
            from: [village], catalog: syntheticCatalog, at: now
        )
        XCTAssertEqual(combined.active.map(\.item.id), ["units:2"],
                       "unavailable 项（helpers）不得进入 active，正常项保留")
        XCTAssertTrue(combined.pending.isEmpty,
                      "unavailable 项即使计时结束也不得进入 pending")
        XCTAssertEqual(combined.active.first?.item.status, .upgrading)
    }

    // MARK: - VillageItemState.needsReimport 谓词

    private func makeState(timerSeconds: Int64?, remainingSeconds: Int64?) -> VillageItemState {
        VillageItemState(
            id: "units:0",
            section: "units",
            dataID: 4_000_000,
            base: .home,
            name: "野蛮人",
            category: .troops,
            currentLevel: 2,
            count: nil,
            timerSeconds: timerSeconds,
            remainingSeconds: remainingSeconds,
            nextLevel: 3,
            nextLevelDurationSeconds: 3600,
            nextLevelDurationState: nil,
            maxLevel: 3,
            status: .upgrading,
            missingReason: nil,
            catalogItemMissingReason: nil,
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: false
        )
    }

    func testNeedsReimportTruthTable() throws {
        // 公共谓词真值表：timer 存在 + remaining 归零才为 true。
        // remainingSeconds 为 Int64?：`== 0` 覆盖 nil ≠ 0 的情况（nil 直接 false）。
        XCTAssertTrue(makeState(timerSeconds: 600, remainingSeconds: 0).needsReimport,
                      "timer 存在 + remaining 0 → true")
        XCTAssertFalse(makeState(timerSeconds: 600, remainingSeconds: 300).needsReimport,
                       "timer 存在 + remaining > 0 → false")
        XCTAssertFalse(makeState(timerSeconds: nil, remainingSeconds: 0).needsReimport,
                       "timer nil + remaining 0 → false")
        XCTAssertFalse(makeState(timerSeconds: nil, remainingSeconds: 500).needsReimport,
                       "timer nil → false")
    }

    // MARK: - Property-based tests

    /// 随机生成多个村庄的快照；升级概率约 50%，path 按村庄编号保证全局唯一。
    private func makeRandomVillages(
        rng: inout SeededRNG,
        count: Int,
        itemCountPerVillage: Int,
        dataIDPool: [Int64],
        sections: [String],
        names: [String]
    ) -> [VillageProfile] {
        var villages: [VillageProfile] = []
        for v in 0..<count {
            var objectSections: [String: [AccountItem]] = [:]
            for index in 0..<itemCountPerVillage {
                let section = sections[Int.random(in: 0..<sections.count, using: &rng)]
                let dataID = dataIDPool[Int.random(in: 0..<dataIDPool.count, using: &rng)]
                let level = Int.random(in: 1...5, using: &rng)
                let upgrading = Bool.random(using: &rng)
                let item = makeItem(
                    section: section,
                    dataID: dataID,
                    level: level,
                    count: Bool.random(using: &rng) ? Int.random(in: 1...5, using: &rng) : nil,
                    timerSeconds: upgrading ? 1000 : nil,
                    remainingSeconds: upgrading ? Int64(Int.random(in: 1...999, using: &rng)) : nil,
                    path: "v\(v).\(index)"
                )
                objectSections[section, default: []].append(item)
            }
            villages.append(makeVillage(
                name: names[Int.random(in: 0..<names.count, using: &rng)],
                tag: "#V\(v)",
                objectSections: objectSections
            ))
        }
        return villages
    }

    func testPropertyAllOutputRecordsAreUpgrading() throws {
        var rng = SeededRNG(seed: 11)
        let pool: [Int64] = [1_000_001, 4_000_000, 1_000_033, 12_000_010]
        let sections = ["buildings", "units", "buildings2", "units2"]
        for _ in 0..<50 {
            let villages = makeRandomVillages(
                rng: &rng, count: 3, itemCountPerVillage: 25,
                dataIDPool: pool, sections: sections, names: ["A村", "B村", "A村", "C村"]
            )
            let records = activeRecords(villages, catalog: syntheticCatalog)
            XCTAssertTrue(records.allSatisfy { $0.item.isUpgrading },
                          "性质 1：输出必须全部是升级中项")
            XCTAssertTrue(records.allSatisfy { $0.item.remainingSeconds ?? 0 > 0 })
        }
    }

    func testPropertyOutputSortedByRemainingThenVillageThenBaseThenID() throws {
        var rng = SeededRNG(seed: 22)
        let pool: [Int64] = [1_000_001, 4_000_000, 1_000_033, 12_000_010]
        let sections = ["buildings", "units", "buildings2", "units2"]
        for _ in 0..<50 {
            let villages = makeRandomVillages(
                rng: &rng, count: 3, itemCountPerVillage: 25,
                dataIDPool: pool, sections: sections, names: ["A村", "B村", "A村", "C村"]
            )
            let records = activeRecords(villages, catalog: syntheticCatalog)
            for (lhs, rhs) in zip(records, records.dropFirst()) {
                let lhsRemaining = lhs.item.remainingSeconds ?? .max
                let rhsRemaining = rhs.item.remainingSeconds ?? .max
                if lhsRemaining != rhsRemaining {
                    XCTAssertLessThanOrEqual(lhsRemaining, rhsRemaining,
                                             "性质 2：剩余时间必须升序（nil 视为最大排最后）")
                } else if lhs.villageName != rhs.villageName {
                    XCTAssertLessThanOrEqual(lhs.villageName, rhs.villageName,
                                             "性质 2：相同剩余时间按 villageName 升序")
                } else if lhs.base.rawValue != rhs.base.rawValue {
                    XCTAssertLessThanOrEqual(lhs.base.rawValue, rhs.base.rawValue,
                                             "性质 2：相同村庄按 base.rawValue 升序")
                } else {
                    XCTAssertLessThanOrEqual(lhs.id, rhs.id,
                                             "性质 2：相同村庄相同 base 按 id 升序")
                }
            }
        }
    }

    func testPropertyEveryUpgradingRecordAppearsOncePerVillageAndBase() throws {
        var rng = SeededRNG(seed: 33)
        let pool: [Int64] = [1_000_001, 4_000_000, 1_000_033, 12_000_010]
        let sections = ["buildings", "units", "buildings2", "units2"]
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<50 {
            let villages = makeRandomVillages(
                rng: &rng, count: 3, itemCountPerVillage: 25,
                dataIDPool: pool, sections: sections, names: ["A村", "B村", "C村"]
            )
            let records = activeRecords(villages, catalog: syntheticCatalog, at: now)
            for village in villages {
                let villageRecords = records.filter { $0.villageID == village.id }
                let snapshot = village.accountSnapshot?.objectSections ?? [:]
                for base in TrackerBase.allCases {
                    // 输入 oracle：该 base 下升级中的快照记录（按 section 后缀归属 base）。
                    var expected: [String: Int] = [:]
                    for record in snapshot.values.flatMap({ $0 })
                        where (record.remainingSeconds ?? 0) > 0
                            && record.section.hasSuffix("2") == (base == .builder) {
                        let key = "\(record.section):\(record.dataID):\(record.level.map(String.init) ?? "nil")"
                        expected[key, default: 0] += 1
                    }
                    var actual: [String: Int] = [:]
                    for record in villageRecords where record.base == base {
                        let key = "\(record.item.section):\(record.item.dataID):\(record.item.currentLevel.map(String.init) ?? "nil")"
                        actual[key, default: 0] += 1
                    }
                    XCTAssertEqual(actual, expected,
                                   "性质 3：村庄 \(village.name) base \(base.rawValue) 的升级记录不得遗漏或多余")
                }
            }
        }
    }

    func testPropertyOutputIDsGloballyUnique() throws {
        var rng = SeededRNG(seed: 44)
        let pool: [Int64] = [1_000_001, 4_000_000, 1_000_033, 12_000_010]
        let sections = ["buildings", "units", "buildings2", "units2"]
        for _ in 0..<50 {
            let villages = makeRandomVillages(
                rng: &rng, count: 3, itemCountPerVillage: 25,
                dataIDPool: pool, sections: sections, names: ["A村", "B村", "C村"]
            )
            let records = activeRecords(villages, catalog: syntheticCatalog)
            let ids = records.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "性质 4：输出 id 必须全局唯一")
        }
    }
}
