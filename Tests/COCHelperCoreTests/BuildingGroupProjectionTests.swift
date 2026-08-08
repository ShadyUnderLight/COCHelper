import XCTest
@testable import COCHelperCore

/// SeededRNG 复用模块级声明（VillageCatalogProjectionTests.swift 顶部，同模块 internal）：
/// 与 UpgradeOverviewProjectionTests 等文件一致的既有模式，不重复声明。
final class BuildingGroupProjectionTests: XCTestCase {
    // MARK: - Helpers

    private var syntheticCatalog: GameCatalog!

    override func setUpWithError() throws {
        syntheticCatalog = try makeCatalog(items: Self.syntheticCatalogItems)
    }

    /// 目录 JSON 载荷的最小编码形态（缺失字段在 CatalogItem/CatalogLevel 解码时按 Optional 缺省）。
    /// Issue #73：升级费用改为多资源数组 upgradeCosts（旧 upgradeResource/upgradeCost 键已从模型移除）。
    private struct SpecCost: Encodable {
        var resource: String
        var amount: Int64?
        var rawResource: String?
        var rawAmount: String?
        var parseFailed: Bool
    }

    private struct SpecLevel: Encodable {
        var level: Int
        var durationSeconds: Int64?
        var upgradeCosts: [SpecCost]?
    }

    /// 单个成功费用项；parseFailed 项用 `cost(resource, nil)` 表达（金额缺失 → 解析失败）。
    private static func cost(_ resource: String, _ amount: Int64?) -> SpecCost {
        SpecCost(resource: resource, amount: amount, rawResource: resource,
                 rawAmount: nil, parseFailed: amount == nil)
    }

    private struct SpecItem: Encodable {
        var section: String
        var category: String
        var dataID: Int64
        var base: String
        var name: String
        var maxLevel: Int
        var levels: [SpecLevel]
    }

    /// 1...maxLevel 每级：duration = level × 60、cost = level × 100、默认资源 Elixir。
    private static func standardLevels(_ maxLevel: Int, resource: String = "Elixir") -> [SpecLevel] {
        (1...maxLevel).map {
            SpecLevel(level: $0, durationSeconds: Int64($0 * 60),
                      upgradeCosts: [Self.cost(resource, Int64($0 * 100))])
        }
    }

    /// 合成目录 fixture：dataID/名称仅为测试内部一致性，与真实 bundled 目录的
    /// dataID 映射无关（如 1000008 在真实目录是加农炮，此处仅作「城墙」测试用）。
    private static let syntheticCatalogItems: [SpecItem] = [
        SpecItem(section: "buildings", category: "buildings", dataID: 1_000_001, base: "home", name: "加农炮", maxLevel: 16, levels: standardLevels(16)),
        SpecItem(section: "buildings", category: "buildings", dataID: 1_000_008, base: "home", name: "城墙", maxLevel: 12, levels: standardLevels(12)),
        SpecItem(section: "buildings", category: "buildings", dataID: 1_000_013, base: "home", name: "防空火箭", maxLevel: 16, levels: standardLevels(16, resource: "Gold")),
        SpecItem(section: "buildings2", category: "buildings", dataID: 1_000_033, base: "builder", name: "建筑工人小屋", maxLevel: 10, levels: standardLevels(10)),
        SpecItem(section: "buildings", category: "buildings", dataID: 1_000_097, base: "home", name: "精制台", maxLevel: 9, levels: standardLevels(9)),
    ]

    private func makeCatalog(items: [SpecItem], gameVersion: String = "18.400.13") throws -> GameCatalog {
        struct Payload: Encodable {
            let gameVersion: String
            let items: [SpecItem]
        }
        struct DecodedPayload: Decodable {
            let gameVersion: String
            let items: [CatalogItem]
        }
        let data = try JSONEncoder().encode(Payload(gameVersion: gameVersion, items: items))
        let payload = try JSONDecoder().decode(DecodedPayload.self, from: data)
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

    private func project(
        village: VillageProfile,
        catalog: GameCatalog?,
        base: TrackerBase,
        // 默认 now == importedAt（elapsed = 0）：计时记录保持原样，不被快照年龄消耗。
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> [BuildingGroup] {
        BuildingGroupProjection.project(village: village, catalog: catalog, base: base, now: now)
    }

    // MARK: - T1: 同 dataID 不同 base 不合并

    func testT1SameDataIDDifferentBaseDoNotMerge() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 5, path: "0")],
            "buildings2": [makeItem(section: "buildings2", dataID: 1_000_033, level: 3, path: "0")],
        ])

        let home = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(home.count, 1, "主村投影只产出 home 组")
        XCTAssertEqual(home.first?.base, .home)
        XCTAssertEqual(home.first?.section, "buildings")
        XCTAssertEqual(home.first?.dataID, 1_000_001)
        XCTAssertEqual(home.first?.id, "home:buildings:1000001", "组 id 必须含 base 段")
        XCTAssertFalse(home.contains { $0.section == "buildings2" }, "buildings2 数据被 base 过滤")

        let builder = project(village: village, catalog: syntheticCatalog, base: .builder)
        XCTAssertEqual(builder.count, 1)
        XCTAssertEqual(builder.first?.id, "builder:buildings2:1000033")
        XCTAssertFalse(builder.contains { $0.section == "buildings" })
    }

    // MARK: - T2: 同名不同 section/dataID 不合并

    func testT2DifferentDataIDProduceSeparateGroups() throws {
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 5, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_008, level: 5, path: "1"),
            ],
        ])

        let groups = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.id), ["home:buildings:1000001", "home:buildings:1000008"])
        XCTAssertEqual(groups.map(\.name), ["加农炮", "城墙"])
        XCTAssertEqual(Set(groups.map(\.id)).count, 2, "组 id 互不相同")
    }

    // MARK: - T3: count 乘入汇总

    func testT3CountMultipliesIntoSummary() throws {
        // 城墙 ×325、currentLevel 5、maxLevel 12 → 剩余 7 级；duration = Σ(6..12)×60 = 3780s；
        // cost = Σ(6..12)×100 = 6300 Elixir，均 ×325。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_008, level: 5, count: 325, path: "0")],
        ])

        let group = try XCTUnwrap(project(village: village, catalog: syntheticCatalog, base: .home).first)
        XCTAssertEqual(group.instances.count, 1, "count 是数量属性，不得伪造实例")
        let instance = try XCTUnwrap(group.instances.first)
        XCTAssertEqual(instance.steps.count, 7)
        XCTAssertEqual(instance.steps.first?.level, 6)
        XCTAssertEqual(instance.steps.last?.level, 12)
        XCTAssertEqual(group.summary.remainingLevelCount, 7 * 325)
        XCTAssertEqual(group.summary.totalDurationSeconds, 1_228_500, "3780s × 325")
        XCTAssertEqual(group.summary.costByResource, [BuildingResourceTotal(resource: "Elixir", totalCost: 2_047_500)])
    }

    // MARK: - T4: 多等级记录各自阶梯

    func testT4MultiLevelRecordsGetOwnLadders() throws {
        // 同 dataID 两条不同 currentLevel 记录 → 两个实例、各自阶梯从 currentLevel + 1 起。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 3, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_001, level: 5, path: "1"),
            ],
        ])

        let group = try XCTUnwrap(project(village: village, catalog: syntheticCatalog, base: .home).first)
        XCTAssertEqual(group.instances.count, 2)
        let byLevel = Dictionary(group.instances.map { ($0.item.currentLevel ?? -1, $0) }) { $1 }
        let lvl3 = try XCTUnwrap(byLevel[3])
        let lvl5 = try XCTUnwrap(byLevel[5])
        XCTAssertEqual(lvl3.id, "buildings:0", "实例 id 保留原始快照记录 id（非 agg: 前缀）")
        XCTAssertEqual(lvl5.id, "buildings:1")
        XCTAssertEqual(lvl3.steps.first?.level, 4, "阶梯起点 = currentLevel + 1")
        XCTAssertEqual(lvl3.steps.count, 13)
        XCTAssertEqual(lvl5.steps.first?.level, 6)
        XCTAssertEqual(lvl5.steps.count, 11)
    }

    // MARK: - T5: 满级无阶梯

    func testT5MaxedInstanceHasEmptyStepsAndCompleteSummary() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 16, path: "0")],
        ])

        let group = try XCTUnwrap(project(village: village, catalog: syntheticCatalog, base: .home).first)
        XCTAssertEqual(group.instances.count, 1)
        XCTAssertTrue(group.instances.first?.steps.isEmpty == true, "满级（currentLevel == maxLevel）无阶梯")
        XCTAssertEqual(group.summary.remainingLevelCount, 0)
        XCTAssertEqual(group.summary.totalDurationSeconds, 0)
        XCTAssertEqual(group.summary.completeness, .complete)
    }

    // MARK: - T8: 升级中记录保留计时状态

    func testT8UpgradingRecordRetainsTimerAndLadderStart() throws {
        // now 默认 == importedAt（elapsed = 0），remainingSeconds 不被快照年龄消耗。
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 3,
                         timerSeconds: 3600, remainingSeconds: 3000, path: "0"),
            ],
        ])

        let group = try XCTUnwrap(project(village: village, catalog: syntheticCatalog, base: .home).first)
        let instance = try XCTUnwrap(group.instances.first)
        XCTAssertTrue(instance.item.isUpgrading)
        XCTAssertEqual(instance.item.remainingSeconds, 3000, "实时剩余时间保留")
        XCTAssertEqual(instance.item.timerSeconds, 3600)
        XCTAssertEqual(instance.item.status, .upgrading)
        XCTAssertEqual(instance.steps.first?.level, 4, "升级中实例阶梯起点同为 currentLevel + 1")
    }

    // MARK: - T9: 嵌套项不出现在组卡输出

    func testT9NestedItemsExcludedFromGroupOutput() throws {
        let nested = makeItem(section: "buildings", dataID: 103_000_011, level: 1, path: "0.types.0")
        let village = makeVillage(objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_097, level: 3, types: [nested], path: "0"),
            ],
        ])

        let groups = project(village: village, catalog: syntheticCatalog, base: .home)
        XCTAssertFalse(groups.isEmpty)
        let instances = groups.flatMap(\.instances)
        XCTAssertTrue(instances.allSatisfy { !$0.item.isNested }, "嵌套项不得出现在组卡实例中")
        XCTAssertFalse(instances.contains { $0.item.dataID == 103_000_011 })

        let craft = try XCTUnwrap(groups.first { $0.dataID == 1_000_097 })
        XCTAssertEqual(craft.instances.count, 1, "精制台父项保留、嵌套子项被排除")
        XCTAssertEqual(craft.displayCategory, .craftTable, "Core 不按 displayCategory 过滤，UI 层防御")
    }

    // MARK: - T6: currentLevel == nil / 未知 dataID 不崩溃、降级 partialMissing

    func testT6NilLevelOrUnknownDataIDKeepsInstanceWithPartialMissing() throws {
        // currentLevel == nil（目录命中但无法生成阶梯）。
        let nilLevelVillage = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: nil, path: "0")],
        ])
        let nilLevelGroup = try XCTUnwrap(
            project(village: nilLevelVillage, catalog: syntheticCatalog, base: .home).first
        )
        XCTAssertEqual(nilLevelGroup.instances.count, 1, "currentLevel 缺失的实例必须保留")
        XCTAssertTrue(nilLevelGroup.instances.first?.steps.isEmpty == true)
        XCTAssertEqual(nilLevelGroup.summary.completeness, .partialMissing)

        // 未知 dataID：实例保留、steps 空、category/displayCategory 仍保留。
        let unknownVillage = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 9_999_999, level: 5, path: "0")],
        ])
        let unknownGroup = try XCTUnwrap(
            project(village: unknownVillage, catalog: syntheticCatalog, base: .home).first
        )
        XCTAssertEqual(unknownGroup.instances.count, 1, "未知 dataID 的实例必须保留")
        XCTAssertTrue(unknownGroup.instances.first?.steps.isEmpty == true)
        XCTAssertEqual(unknownGroup.instances.first?.item.category, .buildings, "未知 dataID 仍保留类别")
        XCTAssertNil(unknownGroup.instances.first?.item.displayCategory, "未知 dataID 无展示分类（按原分类兜底）")
        XCTAssertEqual(unknownGroup.summary.completeness, .partialMissing)
    }

    // MARK: - T7: 缺失某级费用或时长 → partialMissing

    func testT7MissingStepCostOrDurationDegradesCompleteness() throws {
        // 自定义目录：level 6 时长缺失、level 7 费用缺失、其余正常。实例 level 5 →
        // 阶梯 6/7/8 中两格带 nil 字段 → .partialMissing。
        let t7Catalog = try makeCatalog(items: [
            SpecItem(
                section: "buildings", category: "buildings", dataID: 1_000_001,
                base: "home", name: "加农炮", maxLevel: 8,
                levels: [
                    SpecLevel(level: 1, durationSeconds: 60, upgradeCosts: [Self.cost("Elixir", 100)]),
                    SpecLevel(level: 2, durationSeconds: 120, upgradeCosts: [Self.cost("Elixir", 200)]),
                    SpecLevel(level: 3, durationSeconds: 180, upgradeCosts: [Self.cost("Elixir", 300)]),
                    SpecLevel(level: 4, durationSeconds: 240, upgradeCosts: [Self.cost("Elixir", 400)]),
                    SpecLevel(level: 5, durationSeconds: 300, upgradeCosts: [Self.cost("Elixir", 500)]),
                    SpecLevel(level: 6, durationSeconds: nil, upgradeCosts: [Self.cost("Elixir", 600)]),
                    SpecLevel(level: 7, durationSeconds: 420, upgradeCosts: nil),
                    SpecLevel(level: 8, durationSeconds: 480, upgradeCosts: [Self.cost("Elixir", 800)]),
                ]
            ),
        ])
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 5, path: "0")],
        ])

        let group = try XCTUnwrap(project(village: village, catalog: t7Catalog, base: .home).first)
        let steps = try XCTUnwrap(group.instances.first?.steps)
        XCTAssertEqual(steps.count, 3)
        XCTAssertFalse(steps[0].hasDuration, "level 6 时长缺失")
        XCTAssertFalse(steps[1].hasCost, "level 7 费用缺失")
        XCTAssertEqual(group.summary.completeness, .partialMissing)
    }

    // MARK: - T10: durationSeconds == 0 即时升级

    func testT10InstantUpgradeCountsZeroSecondsWithoutDegrading() throws {
        // 自定义目录：level 2 为即时升级（durationSeconds == 0）。
        let t10Catalog = try makeCatalog(items: [
            SpecItem(
                section: "buildings", category: "buildings", dataID: 1_000_001,
                base: "home", name: "加农炮", maxLevel: 3,
                levels: [
                    SpecLevel(level: 1, durationSeconds: 60, upgradeCosts: [Self.cost("Elixir", 100)]),
                    SpecLevel(level: 2, durationSeconds: 0, upgradeCosts: [Self.cost("Elixir", 200)]),
                    SpecLevel(level: 3, durationSeconds: 300, upgradeCosts: [Self.cost("Elixir", 300)]),
                ]
            ),
        ])
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])

        let group = try XCTUnwrap(project(village: village, catalog: t10Catalog, base: .home).first)
        let steps = try XCTUnwrap(group.instances.first?.steps)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].durationSeconds, 0)
        XCTAssertTrue(steps[0].hasDuration, "0 是有效即时升级，hasDuration 必须为 true")
        XCTAssertTrue(steps[0].isInstant)
        XCTAssertEqual(group.summary.totalDurationSeconds, 300, "即时升级计入 0 秒，仅 level 3 的 300s 生效")
        XCTAssertEqual(group.summary.completeness, .complete, "即时升级不降级")
    }

    // MARK: - T11: 多资源费用取「首个成功项」（Issue #73 派生语义）

    func testT11MultiResourceTakesFirstSuccessfulEntry() throws {
        // 旧格式「资源缺失但费用存在 → 未知资源桶」在新模型下不可表达（resource 恒非空，
        // validate.py 不变量），"未知资源" 兜底保留为防御代码（Task 3 投影层重审）。
        // 新语义：阶梯费用从 upgradeCosts 首个成功项（parseFailed == false 且 amount != nil）派生。
        let t11Catalog = try makeCatalog(items: [
            SpecItem(
                section: "buildings", category: "buildings", dataID: 1_000_001,
                base: "home", name: "加农炮", maxLevel: 4,
                levels: [
                    SpecLevel(level: 1, durationSeconds: 60, upgradeCosts: [Self.cost("Elixir", 100)]),
                    SpecLevel(level: 2, durationSeconds: 120, upgradeCosts: [Self.cost("Elixir", 100)]),
                    SpecLevel(level: 3, durationSeconds: 180, upgradeCosts: [Self.cost("Gold", nil), Self.cost("Elixir", 200)]),
                    SpecLevel(level: 4, durationSeconds: 240, upgradeCosts: [Self.cost("RareOre", nil), Self.cost("Gold", nil), Self.cost("Elixir", 300)]),
                ]
            ),
        ])
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0")],
        ])

        let group = try XCTUnwrap(project(village: village, catalog: t11Catalog, base: .home).first)
        let steps = try XCTUnwrap(group.instances.first?.steps)
        XCTAssertEqual(steps[1].upgradeCost, 200, "level 3：跳过 parseFailed Gold 取首个成功项 Elixir 200")
        XCTAssertEqual(steps[1].upgradeResource, "Elixir")
        XCTAssertEqual(steps[2].upgradeCost, 300, "level 4：跳过两个 parseFailed 项取 Elixir 300")
        XCTAssertEqual(group.summary.costByResource, [
            BuildingResourceTotal(resource: "Elixir", totalCost: 600),
        ], "仅首个成功项计入汇总")
        XCTAssertEqual(group.summary.completeness, .complete,
                       "parseFailed 项静默跳过（Task 2 兼容语义，不影响完整性；Task 3 重审）")
    }

    // MARK: - T12: currentLevel > maxLevel（目录过时）→ versionMismatch

    func testT12CurrentLevelAboveMaxLevelReportsVersionMismatch() throws {
        // 城墙目录 maxLevel 12，快照记录 level 19 → 目录过时，不得误报完成。
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_008, level: 19, path: "0")],
        ])

        let group = try XCTUnwrap(project(village: village, catalog: syntheticCatalog, base: .home).first)
        XCTAssertEqual(group.instances.count, 1, "目录过时实例必须保留")
        XCTAssertTrue(group.instances.first?.steps.isEmpty == true)
        XCTAssertEqual(group.summary.remainingLevelCount, 0, "max(0, maxLevel - currentLevel) = 0")
        XCTAssertEqual(group.summary.completeness, .versionMismatch)
        XCTAssertNotEqual(group.summary.completeness, .complete, "不得误报完成")
    }

    // MARK: - T13: catalog == nil 不崩溃

    func testT13CatalogNilDoesNotCrash() throws {
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 5, path: "0")],
        ])

        let groups = project(village: village, catalog: nil, base: .home)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.id, "home:buildings:1000001")
        XCTAssertEqual(group.instances.count, 1, "catalog == nil 时实例保留")
        XCTAssertTrue(group.instances.first?.steps.isEmpty == true)
        XCTAssertEqual(group.summary.completeness, .partialMissing)
    }

    // MARK: - P1: shuffle 不变量（同组实例重排 → summary 完全相等）

    /// 1...8 级 Elixir、9...16 级 Gold 的混合资源目录（费用/时长逐级递增）。
    private func mixedResourceCatalog() throws -> GameCatalog {
        let levels = (1...16).map { level -> SpecLevel in
            let resource = level <= 8 ? "Elixir" : "Gold"
            return SpecLevel(
                level: level,
                durationSeconds: Int64(level * 60),
                upgradeCosts: [Self.cost(resource, Int64(level * 100))]
            )
        }
        return try makeCatalog(items: [
            SpecItem(section: "buildings", category: "buildings", dataID: 1_000_001,
                     base: "home", name: "加农炮", maxLevel: 16, levels: levels),
        ])
    }

    func testP1ShuffleInvariantSummaryUnchanged() throws {
        let catalog = try mixedResourceCatalog()
        let items = [
            makeItem(section: "buildings", dataID: 1_000_001, level: 2, count: 3, path: "0"),
            makeItem(section: "buildings", dataID: 1_000_001, level: 5, count: 1, path: "1"),
            makeItem(section: "buildings", dataID: 1_000_001, level: 9, count: 2, path: "2"),
            makeItem(section: "buildings", dataID: 1_000_001, level: 12, count: 1, path: "3"),
        ]
        let baseline = try XCTUnwrap(
            project(village: makeVillage(objectSections: ["buildings": items]), catalog: catalog, base: .home).first
        ).summary

        for seed: UInt64 in [11, 22, 33, 44, 55] {
            var rng = SeededRNG(seed: seed)
            let shuffled = items.shuffled(using: &rng)
            let group = try XCTUnwrap(
                project(village: makeVillage(objectSections: ["buildings": shuffled]), catalog: catalog, base: .home).first
            )
            XCTAssertEqual(group.instances.count, 4)
            XCTAssertEqual(group.summary, baseline,
                           "seed \(seed)：同组实例随机重排后 summary 必须完全相等（costByResource 字典序保证）")
        }
    }

    // MARK: - P2: 组顺序稳定（随机重排 → 按首现顺序输出、组内容不变）

    func testP2GroupOrderStableUnderShuffle() throws {
        let items = [
            makeItem(section: "buildings", dataID: 1_000_013, level: 4, path: "0"),  // 防空火箭（Gold）
            makeItem(section: "buildings", dataID: 1_000_008, level: 5, path: "1"),  // 城墙
            makeItem(section: "buildings", dataID: 1_000_001, level: 3, path: "2"),  // 加农炮
            makeItem(section: "buildings", dataID: 1_000_008, level: 7, path: "3"),  // 城墙第二条
            makeItem(section: "buildings", dataID: 1_000_097, level: 2, path: "4"),  // 精制台
        ]
        let baseline = project(
            village: makeVillage(objectSections: ["buildings": items]),
            catalog: syntheticCatalog,
            base: .home
        )
        XCTAssertEqual(baseline.map(\.id), [
            "home:buildings:1000013", "home:buildings:1000008",
            "home:buildings:1000001", "home:buildings:1000097",
        ])
        let baselineByID = Dictionary(baseline.map { ($0.id, $0) }) { $1 }

        for seed: UInt64 in [101, 202, 303, 404, 505] {
            var rng = SeededRNG(seed: seed)
            let shuffled = items.shuffled(using: &rng)
            // 首现顺序 oracle：按重排后的数组顺序记录每个组 id 的首次出现。
            var expectedOrder: [String] = []
            for item in shuffled {
                let id = "home:\(item.section):\(item.dataID)"
                if !expectedOrder.contains(id) { expectedOrder.append(id) }
            }
            let groups = project(
                village: makeVillage(objectSections: ["buildings": shuffled]),
                catalog: syntheticCatalog,
                base: .home
            )
            XCTAssertEqual(groups.map(\.id), expectedOrder, "seed \(seed)：组必须按首现顺序输出")
            for group in groups {
                let baseGroup = try XCTUnwrap(baselineByID[group.id])
                XCTAssertEqual(group.name, baseGroup.name)
                XCTAssertEqual(group.displayCategory, baseGroup.displayCategory)
                XCTAssertEqual(group.category, baseGroup.category)
                XCTAssertEqual(group.summary, baseGroup.summary, "seed \(seed)：组汇总与基准完全一致")
                XCTAssertEqual(Set(group.instances), Set(baseGroup.instances),
                               "seed \(seed)：组内实例集合不变（顺序允许不同）")
            }
        }
    }

    // MARK: - P3: 阶梯界内升序（随机记录 + 随机稀疏目录，20 轮）

    func testP3LadderStrictlyAscendingAndBounded() throws {
        var rng = SeededRNG(seed: 0x4A_CE)
        for round in 0..<20 {
            let maxLevel = Int.random(in: 8...20, using: &rng)
            // 随机稀疏目录：每个等级以 50% 概率收录（等级号不连续）。
            let catalogLevels = (1...maxLevel).compactMap { level -> SpecLevel? in
                guard Bool.random(using: &rng) else { return nil }
                return SpecLevel(level: level, durationSeconds: Int64(level * 60),
                                 upgradeCosts: [Self.cost("Elixir", Int64(level * 100))])
            }
            let catalog = try makeCatalog(items: [
                SpecItem(section: "buildings", category: "buildings", dataID: 1_000_001,
                         base: "home", name: "加农炮", maxLevel: maxLevel, levels: catalogLevels),
            ])
            let items = (0..<5).map { index in
                makeItem(section: "buildings", dataID: 1_000_001,
                         level: Int.random(in: 1...(maxLevel - 1), using: &rng),
                         count: 1, path: String(index))
            }
            let group = try XCTUnwrap(
                project(village: makeVillage(objectSections: ["buildings": items]), catalog: catalog, base: .home).first
            )
            XCTAssertEqual(group.instances.count, 5)
            for instance in group.instances {
                let stepLevels = instance.steps.map(\.level)
                XCTAssertEqual(stepLevels, stepLevels.sorted(), "round \(round)：阶梯必须升序")
                XCTAssertEqual(Set(stepLevels).count, stepLevels.count, "round \(round)：阶梯不得重复")
                let currentLevel = instance.item.currentLevel ?? -1
                let upper = instance.item.maxLevel ?? 0
                for level in stepLevels {
                    XCTAssertTrue(level > currentLevel, "round \(round)：阶梯等级必须 > currentLevel")
                    XCTAssertTrue(level <= upper, "round \(round)：阶梯等级必须 <= maxLevel")
                }
            }
        }
    }

    // MARK: - T14/T15: 全局目录版本不匹配（Review 反馈 P1-2）

    /// 目录 gameVersion 与期望版本不匹配：即使实例 currentLevel 全部正常、阶梯
    /// 完整，组卡也不得输出权威汇总（Issue #45「版本不匹配：不能把旧目录的汇总
    /// 结果当成确定事实」）——completeness 必须降级为 versionMismatch。
    func testT14GlobalCatalogVersionMismatchDowngradesCompleteness() throws {
        let catalog = try makeCatalog(items: Self.syntheticCatalogItems, gameVersion: "18.400.12")
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 5, path: "0")],
        ])

        let groups = BuildingGroupProjection.project(
            village: village, catalog: catalog, base: .home,
            expectedGameVersion: "18.400.13"
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups.first?.summary.completeness,
            .versionMismatch,
            "全局版本不匹配必须降级为 versionMismatch（即使实例级检查全过）"
        )
    }

    /// expectedGameVersion == nil：不做版本校验（与 VillageCatalogProjection 同语义），
    /// 实例级检查正常时 completeness 保持 .complete。
    func testT15NilExpectedGameVersionSkipsVersionCheck() throws {
        let catalog = try makeCatalog(items: Self.syntheticCatalogItems, gameVersion: "18.400.12")
        let village = makeVillage(objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 5, path: "0")],
        ])

        let groups = BuildingGroupProjection.project(
            village: village, catalog: catalog, base: .home,
            expectedGameVersion: nil
        )
        XCTAssertEqual(groups.first?.summary.completeness, .complete)
    }
}
