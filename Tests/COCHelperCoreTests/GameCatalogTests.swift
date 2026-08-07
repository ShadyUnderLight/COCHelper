import XCTest
@testable import COCHelperCore

final class GameCatalogTests: XCTestCase {
    func testLoadBundledDecodesRealCatalog() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        XCTAssertEqual(catalog.gameVersion, "18.400.13")
        XCTAssertGreaterThan(catalog.items(in: "buildings").count, 0)
        XCTAssertNotNil(catalog.item(section: "units", dataID: 4_000_000)) // 野蛮人
        XCTAssertNotNil(catalog.item(section: "buildings", dataID: 1_000_000)) // 兵营
    }

    func testLoadBundledUnknownVersionReturnsNil() {
        XCTAssertNil(GameCatalog.loadBundled(version: "99.0.0"))
    }

    func testBundledLoadPerformanceIsReasonable() throws {
        // 2.9MB 目录解码必须在可接受范围内（启动路径），CI 慢机器留 5s 余量。
        let start = Date()
        XCTAssertNotNil(GameCatalog.loadBundled())
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0, "目录解码耗时 \(elapsed)s 超出启动预算")
    }

    func testItemLookupUsesExactSectionAndDataID() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        XCTAssertNil(catalog.item(section: "units", dataID: 1_000_000))
        XCTAssertNil(catalog.item(section: "buildings2", dataID: 1_000_000))
    }

    func testBuildingDurationIsBuildToLevelSemantics() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barracks = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_000))
        // 兵营 level 2 dur=300s：从 1 升 2 的完整时长 = levels[nextLevel=2]
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 2, for: barracks), 300)
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 3, for: barracks), 1800)
    }

    func testUnitDurationIsUpgradeFromLevelSemantics() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barbarian = try XCTUnwrap(catalog.item(section: "units", dataID: 4_000_000))
        // 目录生成时已统一：levels[N] = 升级到 N 级。野蛮人升到 2 级 = 1800s（从 1 升 2）。
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 2, for: barbarian), 1800)
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 3, for: barbarian), 3600)
        // 满级 13 级时长 = 1,080,000s（#13 验收值：从 12 升 13）。
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 13, for: barbarian), 1_080_000)
    }

    func testDurationNilWhenLevelRecordMissing() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barracks = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_000))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 999, for: barracks))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 0, for: barracks))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: -1, for: barracks))
    }

    func testLevelOneDurationReturnsBuildTimeForBuildings() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barracks = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_000))
        // 建筑系 levels[1] = 0→1 初始建造时长（非 nil）；快照可能出现 level=0 的新建建筑。
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 1, for: barracks), 60)
        // 单位系 levels[1] 恒为初始等级 nil。
        let barbarian = try XCTUnwrap(catalog.item(section: "units", dataID: 4_000_000))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 1, for: barbarian))
    }

    func testEquipmentDurationStaysNil() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let puppet = try XCTUnwrap(catalog.item(section: "equipment", dataID: 90_000_000))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 4, for: puppet))
    }

    func testCatalogItemIDAndLevelIDsAreStable() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let item = try XCTUnwrap(catalog.item(section: "heroes", dataID: 28_000_000))
        XCTAssertEqual(item.id, "heroes:28000000")
        XCTAssertEqual(item.levels.map(\.id).first, "1")
    }

    func testMaxLevelAndNameFromCatalog() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barbarian = try XCTUnwrap(catalog.item(section: "units", dataID: 4_000_000))
        XCTAssertEqual(barbarian.name, "野蛮人")
        XCTAssertEqual(barbarian.maxLevel, 13)
    }

    // MARK: - AssetRef

    func testAssetRefIsRenderableTruthTable() throws {
        // P2-2：isRenderable 真值表——renderedPath 存在且无 missingReason 才可渲染。
        // 当前 bundled 目录（18.400.13）所有 icon ref 均为 icons_not_rendered
        // （renderedPath nil）→ 全部 false；#13 图标管线产出真实渲染图后为 true。
        func ref(renderedPath: String?, missingReason: String?) -> CatalogAssetRef {
            CatalogAssetRef(
                container: nil,
                exportName: nil,
                renderedPath: renderedPath,
                missingReason: missingReason
            )
        }
        XCTAssertTrue(ref(renderedPath: "icons/barbarian.png", missingReason: nil).isRenderable,
                      "renderedPath 存在且无缺失原因 → 可渲染")
        XCTAssertFalse(ref(renderedPath: nil, missingReason: nil).isRenderable,
                       "renderedPath 缺失 → 不可渲染")
        XCTAssertFalse(ref(renderedPath: "", missingReason: nil).isRenderable,
                       "renderedPath 为空串 → 不可渲染（契约 R2.2/R5.3）")
        XCTAssertFalse(ref(renderedPath: "icons/barbarian.png", missingReason: "icons_not_rendered").isRenderable,
                       "有缺失原因（即使 renderedPath 存在）→ 不可渲染")
        XCTAssertFalse(ref(renderedPath: nil, missingReason: "icons_not_rendered").isRenderable,
                       "renderedPath 缺失且有缺失原因 → 不可渲染")
    }

    // MARK: - Property-based

    /// 随机物品 × 随机目标等级的查表一致性（不承担语义锚点，见下两个测试）。
    func testPropertyDurationLookupMatchesLevelRecords() throws {
        var rng = SeededRNG(seed: 555)
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let sections = ["buildings", "buildings2", "traps", "traps2", "units", "units2",
                        "spells", "heroes", "heroes2", "pets", "equipment", "guardians",
                        "siege_machines"]
        let allItems = sections.flatMap { catalog.items(in: $0) }
        XCTAssertFalse(allItems.isEmpty)
        for _ in 0..<300 {
            let item = allItems[Int.random(in: 0..<allItems.count, using: &rng)]
            let nextLevel = Int.random(in: 1...20, using: &rng)
            let actual = catalog.durationToUpgradeLevel(nextLevel: nextLevel, for: item)
            let expected = item.levels.first(where: { $0.level == nextLevel })?.durationSeconds
            XCTAssertEqual(actual, expected, "\(item.section) \(item.dataID) nextLevel=\(nextLevel)")
        }
    }

    /// 语义锚点：跨 section 硬编码已知真实值（来自 18.400.13 目录，含 #13 验收值）。
    func testDurationKnownValuesAcrossSections() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        func duration(_ section: String, _ dataID: Int64, _ nextLevel: Int) -> Int64? {
            guard let item = catalog.item(section: section, dataID: dataID) else { return nil }
            return catalog.durationToUpgradeLevel(nextLevel: nextLevel, for: item)
        }
        // 建筑系（BuildTime）：levels[N] = 升级到 N 级，levels[1] = 0→1 建造时长。
        XCTAssertEqual(duration("buildings", 1_000_000, 1), 60)      // 兵营 0→1
        XCTAssertEqual(duration("buildings", 1_000_000, 2), 300)      // 兵营 1→2
        XCTAssertEqual(duration("buildings", 1_000_000, 3), 1800)     // 兵营 2→3
        // 单位系（UpgradeTime 已映射）：野蛮人 1→2 = 1800s，满级 12→13 = 1,080,000s（#13 验收值）。
        XCTAssertEqual(duration("units", 4_000_000, 2), 1800)
        XCTAssertEqual(duration("units", 4_000_000, 3), 3600)
        XCTAssertEqual(duration("units", 4_000_000, 13), 1_080_000)
        XCTAssertNil(duration("units", 4_000_000, 1))                  // 初始等级
        // 建筑工人基地（BuildTime 系同样语义）。
        XCTAssertEqual(duration("buildings2", 1_000_033, 1), 0)       // BB 城墙 0→1 = 0s（CSV 空值=0）
        // 装备：所有等级无直接升级时长，必须保持 nil。
        XCTAssertNil(duration("equipment", 90_000_000, 2))
        XCTAssertNil(duration("equipment", 90_000_000, 3))
    }

    /// 非连续等级：等级号保留源表原值（#13 约定），按 level 值查找而非下标。
    /// 战斗直升机（heroes2 28000005）等级 15..35：下标式实现（levels[nextLevel-1]）
    /// 会返回错误值，此用例可鉴别。
    func testDurationHandlesNonContiguousLevels() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let copter = try XCTUnwrap(catalog.item(section: "heroes2", dataID: 28_000_005))
        XCTAssertEqual(copter.levels.first?.level, 15, "等级号从 15 开始，无 1..14 记录")
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 1, for: copter))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 14, for: copter))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 15, for: copter),
                     "15 级是初始等级（min_level_initial）")
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 16, for: copter), 432_000)
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 26, for: copter), 518_400)
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 36, for: copter),
                     "超出 maxLevel 35")
    }

    /// 部落都城（capital_*，base=nil）：所有等级无直接升级时长，必须保持 nil（issue 数据边界）。
    func testCapitalDurationsStayNil() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let hq = try XCTUnwrap(catalog.item(section: "capital_buildings", dataID: 110_000_000))
        XCTAssertTrue(hq.levels.allSatisfy { $0.durationSeconds == nil },
                      "都城大本营时长应为 nil")
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 2, for: hq))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 10, for: hq))
    }

    // MARK: - RenderedPath bundle（Issue #30 Task 9）

    /// 目录 18.400.13 的全部 section（含 capital_*；GameCatalog 未暴露全量遍历 API）。
    private static let bundledSections = [
        "buildings", "buildings2", "traps", "traps2", "units", "units2",
        "spells", "heroes", "heroes2", "pets", "equipment", "guardians",
        "siege_machines", "capital_buildings", "capital_characters",
        "capital_spells", "capital_traps",
    ]

    /// 收集目录中所有 icon/levelVisual 引用（item 级 + level 级，slot 用于失败信息定位）。
    private func allAssetRefs(in catalog: GameCatalog)
        -> [(ref: CatalogAssetRef, item: CatalogItem, level: CatalogLevel?, slot: String)] {
        var refs: [(ref: CatalogAssetRef, item: CatalogItem, level: CatalogLevel?, slot: String)] = []
        for section in Self.bundledSections {
            for item in catalog.items(in: section) {
                if let icon = item.icon { refs.append((icon, item, nil, "icon")) }
                if let visual = item.levelVisual { refs.append((visual, item, nil, "levelVisual")) }
                for level in item.levels {
                    if let icon = level.icon { refs.append((icon, item, level, "level.icon")) }
                    if let visual = level.levelVisual { refs.append((visual, item, level, "level.levelVisual")) }
                }
            }
        }
        return refs
    }

    /// COCHelperCore 资源 bundle 的 URL。测试 target 的 `Bundle.module` 指向
    /// 测试 bundle（只有 Fixtures），而 GameCatalog 资源在 Core bundle 中；
    /// 两者同级，按 SwiftPM 固定命名 `<package>_<target>.bundle` 定位。
    private func coreBundle() -> Bundle? {
        let dir = Bundle.module.bundleURL.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let name = names.first(where: { $0.hasSuffix("_COCHelperCore.bundle") }) else {
            return nil
        }
        return Bundle(url: dir.appendingPathComponent(name))
    }

    /// bundle 中 renderedPath 对应文件是否存在（.copy 保留目录结构，与 loadBundled 同一解析模式）。
    /// 注：Bundle.url(forResource: nil, withExtension: nil, subdirectory:) 对 SPM bundle
    /// 的目录返回 nil，必须用「文件名 + 扩展名」解析文件本身。
    private func bundledFileExists(renderedPath: String) -> Bool {
        guard let core = coreBundle() else { return false }
        let nsPath = renderedPath as NSString
        let subdirectory = "GameCatalog/" + GameCatalog.defaultBundledVersion
            + "/" + nsPath.deletingLastPathComponent
        let last = nsPath.lastPathComponent as NSString
        return core.url(
            forResource: last.deletingPathExtension,
            withExtension: last.pathExtension,
            subdirectory: subdirectory
        ) != nil
    }

    /// 存在断言：bundled 目录必须含真实渲染 PNG 引用（#13 管线产出前全为
    /// icons_not_rendered，此测试用于锁定「渲染资源已就位」的状态）。
    func testBundledRenderableRefCountIsNonZero() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let renderable = allAssetRefs(in: catalog).filter { $0.ref.isRenderable }
        XCTAssertGreaterThan(renderable.count, 0, "bundled 目录应含真实渲染 PNG 引用")
        // Issue #25 全量渲染后：4 个固定样本仍是子集，唯一路径数大幅增长。
        let known = [
            "icons/buildings/blacksmith_lvl1.png",
            "icons/buildings/fireplace_lvl1.png",
            "icons/ui/icon_spell_rage.png",
            "icons/ui/icon_unit_barbarian.png",
        ]
        let uniquePaths = Set(renderable.map(\.ref.renderedPath).compactMap { $0 })
        for path in known {
            XCTAssertTrue(uniquePaths.contains(path), "\(path) 应仍被引用（跨等级/跨 item 复用）")
        }
        // 2026-08-06 实测：18.400.13 递归展开 MovieClip 后唯一 renderedPath 1258 个。
        // 下限取 500（远小于实测值，容忍未来少量失败键波动）。
        XCTAssertGreaterThan(uniquePaths.count, 500, "全量渲染后唯一 renderedPath 应远超固定样本数")
    }

    /// 文件存在断言：全部 renderable ref 指向的 PNG 都真实存在于 bundle（.copy 打包验证）。
    func testBundledRenderableRefsPointToExistingFiles() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let renderable = allAssetRefs(in: catalog).filter { $0.ref.isRenderable }
        XCTAssertGreaterThan(renderable.count, 0)
        for entry in renderable {
            let path = try XCTUnwrap(entry.ref.renderedPath)
            XCTAssertTrue(bundledFileExists(renderedPath: path),
                          "\(entry.item.section) \(entry.item.dataID) \(entry.slot) → \(path) 在 bundle 中不存在")
        }
    }

    /// 缺失语义断言（契约 R2.2/R5.3）：missingReason 非空的引用必须不可渲染且无 renderedPath。
    func testMissingRefIsNotRenderableAndHasNoPath() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let missing = allAssetRefs(in: catalog).filter { $0.ref.missingReason != nil }
        XCTAssertGreaterThan(missing.count, 0, "目录应保留缺失引用（render_failed/export_not_found）")
        for entry in missing {
            XCTAssertNil(entry.ref.renderedPath,
                         "\(entry.item.section) \(entry.item.dataID) \(entry.slot) 有 missingReason 却仍带 renderedPath")
            XCTAssertFalse(entry.ref.isRenderable)
        }
        // 具体锚点（2026-08-06 实测：递归展开 MovieClip 后 11 个唯一缺失键，
        // export_not_found 10 + render_failed 1；兵营/攻城机器等此前误判的
        // 资源已恢复为可渲染）。各取一个稳定锚点覆盖两种 missingReason：
        // 1. traps2 12000011（push_trap）lv1 levelVisual → export_not_found
        // 2. capital_buildings 110000003（部落营房）levelVisual → render_failed
        let pushTrap = try XCTUnwrap(catalog.item(section: "traps2", dataID: 12_000_011))
        let pushTrapLv1 = try XCTUnwrap(pushTrap.levels.first(where: { $0.level == 1 })?.levelVisual)
        XCTAssertEqual(pushTrapLv1.missingReason, "export_not_found")
        XCTAssertNil(pushTrapLv1.renderedPath)
        XCTAssertFalse(pushTrapLv1.isRenderable)

        let playerHouse = try XCTUnwrap(catalog.item(section: "capital_buildings", dataID: 110_000_003))
        let playerHouseVisual = try XCTUnwrap(playerHouse.levelVisual)
        XCTAssertEqual(playerHouseVisual.missingReason, "render_failed")
        XCTAssertNil(playerHouseVisual.renderedPath)
        XCTAssertFalse(playerHouseVisual.isRenderable)
    }

    /// 共享路径断言（契约 R2.4）：铁匠铺 blacksmith_lvl1 被顶层 + lv1 + lv2
    /// 三处引用，renderedPath 相同——跨等级复用不复制资源。
    func testSharedRenderedPathAcrossLevels() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let blacksmith = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_070))
        let top: CatalogAssetRef = try XCTUnwrap(blacksmith.levelVisual)
        let levelRefs = blacksmith.levels.filter { $0.level == 1 || $0.level == 2 }
            .compactMap(\.levelVisual)
        XCTAssertEqual(levelRefs.count, 2, "lv1/lv2 均应有 levelVisual")
        let renderable = ([top] + levelRefs).filter(\.isRenderable)
        XCTAssertEqual(renderable.count, 3, "顶层 + lv1 + lv2 均应可渲染")
        XCTAssertEqual(Set(renderable.map(\.renderedPath)),
                       ["icons/buildings/blacksmith_lvl1.png"],
                       "跨等级应共享同一 renderedPath，不复制资源")
    }

    // MARK: - bundledURL resolver（Issue #25）

    /// R1.1/R5.3：isRenderable 的引用必须解析出 Bundle 内 URL，且文件真实存在。
    func testBundledURLResolvesRenderableRefsToExistingFiles() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let renderable = allAssetRefs(in: catalog).filter { $0.ref.isRenderable }
        XCTAssertGreaterThan(renderable.count, 0)
        for entry in renderable {
            let url = try XCTUnwrap(entry.ref.bundledURL(),
                                    "\(entry.item.section) \(entry.item.dataID) \(entry.slot) 应解析出 URL")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(entry.item.section) \(entry.item.dataID) \(entry.slot) → \(url.path) 不存在")
        }
    }

    /// 缺失引用（missingReason != nil）不得解析出 URL（UI 回退 SF Symbol）。
    func testBundledURLIsNilForMissingRefs() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let missing = allAssetRefs(in: catalog).filter { $0.ref.missingReason != nil }
        XCTAssertGreaterThan(missing.count, 0)
        for entry in missing {
            XCTAssertNil(entry.ref.bundledURL(),
                         "\(entry.item.section) \(entry.item.dataID) \(entry.slot) 有 missingReason 不应解析出 URL")
        }
    }

    /// 版本参数：不存在的版本目录 → nil（UI 回落 SF Symbol，静默安全）；
    /// 明确版本（18.400.13）→ 与默认版本解析一致。
    func testBundledURLVersionParameter() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let renderable = try XCTUnwrap(allAssetRefs(in: catalog)
            .map(\.ref).first { $0.isRenderable })
        // 不存在的版本：资源子目录不存在 → nil（不崩溃、不回退到默认版本）
        XCTAssertNil(renderable.bundledURL(version: "0.0.0-no-such-version"),
                     "不存在的版本目录不应解析出 URL")
        // 显式指定 bundled 版本：与默认参数一致
        XCTAssertNotNil(renderable.bundledURL(version: GameCatalog.defaultBundledVersion))
        // 默认解析的 URL 必须含版本段（证明版本参数确实参与路径拼接）
        let defaultURL = try XCTUnwrap(renderable.bundledURL())
        XCTAssertTrue(defaultURL.path.contains(GameCatalog.defaultBundledVersion),
                      "URL 应包含版本段（\(defaultURL.path)）")
    }

// MARK: - Issue #74b: duration state 语义

// MARK 段测试用 Payload（GameCatalogTests 私有；RequirementTests 另有同名
// private struct，词法作用域隔离，互不冲突）。
private struct Payload: Decodable { let gameVersion: String; let items: [CatalogItem] }

private let durationStateCatalogJSON = """
{"gameVersion":"18.400.13","items":[
  {"section":"units","category":"troops","dataID":1,"base":"home","name":"a","maxLevel":8,"icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,"levels":[
    {"level":1,"durationSeconds":3600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
    {"level":2,"durationSeconds":0,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
    {"level":3,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
    {"level":4,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_time_source"},
    {"level":5,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"time_invalid"},
    {"level":6,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"time_missing"},
    {"level":7,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"upgrade_data_missing"},
    {"level":8,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
  ]}
]}
"""

func testDurationStateMappingAllBuckets() throws {
    let data = Data(durationStateCatalogJSON.utf8)
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    let catalog = GameCatalog(gameVersion: payload.gameVersion, items: payload.items)
    let item = try XCTUnwrap(catalog.item(section: "units", dataID: 1))
    let states = Dictionary(uniqueKeysWithValues: item.levels.map { ($0.level, $0.durationState) })
    XCTAssertEqual(states[1], .timed(seconds: 3600))
    XCTAssertEqual(states[2], .instant)
    XCTAssertEqual(states[3], .initialLevel)
    XCTAssertEqual(states[4], .notApplicable)
    XCTAssertEqual(states[5], .parseFailed)
    XCTAssertEqual(states[6], .sourceMissing)
    XCTAssertEqual(states[7], .sourceMissing, "upgrade_data_missing 归入 sourceMissing")
    // nil duration + nil reason → nil（UI 兜底「暂无目录数据」，未知场景）。
    // 注意 states 字典值本身是 Optional，需 flatMap 拍平后再断言。
    XCTAssertNil(states[8].flatMap { $0 })
}

func testDurationStateRealCatalog() throws {
    let catalog = try XCTUnwrap(GameCatalog.loadBundled())
    // 单位系 level 1 = 初始等级
    let barbarian = try XCTUnwrap(catalog.item(section: "units", dataID: 4_000_000))
    XCTAssertEqual(barbarian.levels.first { $0.level == 1 }?.durationState, .initialLevel)
    XCTAssertEqual(barbarian.levels.first { $0.level == 2 }?.durationState, .timed(seconds: 1800))
    // 装备：no_time_source → notApplicable（1032 个 level）
    let equipment = try XCTUnwrap(catalog.item(section: "equipment", dataID: 90_000_000))
    XCTAssertEqual(equipment.levels.first?.durationState, .notApplicable)
    // 真实目录存在 0 秒即时升级（城墙 buildings:1000010 level 1）
    let walls = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_010))
    XCTAssertEqual(walls.levels.first { $0.level == 1 }?.durationState, .instant)
    // 真实目录存在 time_missing（units 系 843 个 level）
    let anySourceMissing = catalog.items(in: "units").contains {
        $0.levels.contains { $0.missingReason == "time_missing" }
    }
    XCTAssertTrue(anySourceMissing, "真实目录应存在 time_missing 锚点")
}

func testDurationStateLabel() {
    XCTAssertEqual(CatalogDurationState.timed(seconds: 3600).durationLabel, "1小时 0分钟")
    XCTAssertEqual(CatalogDurationState.instant.durationLabel, "即时")
    XCTAssertEqual(CatalogDurationState.initialLevel.durationLabel, "初始等级，无升级时长")
    XCTAssertEqual(CatalogDurationState.notApplicable.durationLabel, "该类别无时长数据")
    XCTAssertEqual(CatalogDurationState.sourceMissing.durationLabel, "目录缺失")
    XCTAssertEqual(CatalogDurationState.parseFailed.durationLabel, "目录解析失败")
    XCTAssertEqual(CatalogDurationState.unknownReason("future").durationLabel, "暂无目录数据")
}

func testCatalogItemMissingReasonDecodes() throws {
    // 有字段：deprecated_in_source 保留
    let withReason = """
    {"gameVersion":"18.400.13","items":[
      {"section":"pets","category":"pets","dataID":73000000,"base":"home","name":"a","maxLevel":1,"icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":"deprecated_in_source","levels":[
        {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"}
      ]}
    ]}
    """
    let payload = try JSONDecoder().decode(Payload.self, from: Data(withReason.utf8))
    let item = try XCTUnwrap(payload.items.first)
    XCTAssertEqual(item.missingReason, "deprecated_in_source")
    // 无字段：旧目录向后兼容
    let withoutReason = """
    {"gameVersion":"18.400.13","items":[
      {"section":"pets","category":"pets","dataID":73000000,"base":"home","name":"a","maxLevel":1,"icon":null,"levelVisual":null,"baseMissingReason":null,"levels":[
        {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
      ]}
    ]}
    """
    let payload2 = try JSONDecoder().decode(Payload.self, from: Data(withoutReason.utf8))
    let oldItem = try XCTUnwrap(payload2.items.first)
    XCTAssertNil(oldItem.missingReason)
}

func testCatalogCountsDecodesNewFields() throws {
    let withNew = """
    {"items":1,"levels":1,"missingIcons":0,"missingTime":0,"timed":1,"instant":0,"notApplicable":0,"initialLevel":0,"sourceMissing":0,"parseFailed":0}
    """
    let counts = try JSONDecoder().decode(CatalogCounts.self, from: Data(withNew.utf8))
    XCTAssertEqual(counts.timed, 1)
    XCTAssertEqual(counts.instant, 0)
    // 旧 manifest：新字段缺键 → nil（向后兼容）
    let old = """
    {"items":1,"levels":1,"missingIcons":0,"missingTime":0}
    """
    let oldCounts = try JSONDecoder().decode(CatalogCounts.self, from: Data(old.utf8))
    XCTAssertNil(oldCounts.timed)
    XCTAssertNil(oldCounts.parseFailed)
}

}

// MARK: - UpgradeRequirement（Issue #67）

final class RequirementTests: XCTestCase {
    /// 按 base 解析 village 语义：home → townHall/laboratory/heroHall。
    func testHomeBaseRequirementsParseVillageSemantics() {
        let item = makeRequirementItem(base: "home",
            th: 12, lab: nil, tavern: 8)
        XCTAssertEqual(item.requirements, [
            .townHall(level: 12), .heroHall(level: 8)
        ])
    }

    /// builder → builderHall/starLaboratory（数据源字段复用但语义不同）。
    func testBuilderBaseRequirementsParseBuilderSemantics() {
        let item = makeRequirementItem(base: "builder",
            th: 10, lab: 8, tavern: nil)
        XCTAssertEqual(item.requirements, [
            .builderHall(level: 10), .starLaboratory(level: 8)
        ])
    }

    /// 无 requirement 的 item（equipment 等）→ 空数组。
    func testNoRequirementsYieldsEmpty() {
        let item = makeRequirementItem(base: "home", th: nil, lab: nil, tavern: nil)
        XCTAssertEqual(item.requirements, [])
    }

    /// 旧目录（无 requiredHeroTavernLevel 键）仍可解码（Codable 向后兼容）。
    func testLegacyLevelDecodesWithoutHeroTavernField() throws {
        let json = """
        {"gameVersion":"v","items":[
          {"section":"heroes","category":"heroes","dataID":28000000,"base":"home",
           "name":"野蛮人之王","maxLevel":2,"icon":null,"levelVisual":null,
           "baseMissingReason":null,"missingReason":null,
           "levels":[
             {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,
              "requiredTownHallLevel":4,"requiredLaboratoryLevel":null,
              "icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"}
           ]}
        ]}
        """
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        XCTAssertNil(payload.items[0].levels[0].requiredHeroTavernLevel)
        XCTAssertEqual(payload.items[0].requirements, [.townHall(level: 4)])
    }

    /// tavern == 0（heroes2 建筑大师基地英雄源数据）→ 不产生 heroHall requirement（0 级门槛恒满足）。
    func testZeroTavernYieldsNoHeroHallRequirement() {
        let item = makeRequirementItem(base: "home", th: 12, lab: nil, tavern: 0)
        XCTAssertEqual(item.requirements, [.townHall(level: 12)])
    }

    // MARK: - displayLabel / displayLabels（Issue #68 Task 3）

    /// home/其他 base：townHall → 大本营、laboratory → 实验室、heroHall → 英雄殿堂；
    /// builderHall/starLaboratory 自身语义恒为建筑大师大本营/星空实验室。
    /// 与 LevelDetailSheet.unlockLabel 措辞逐字一致。
    func testRequirementDisplayLabelHome() {
        XCTAssertEqual(UpgradeRequirement.townHall(level: 12).displayLabel(base: "home"), "所需大本营等级 12级")
        XCTAssertEqual(UpgradeRequirement.laboratory(level: 8).displayLabel(base: "home"), "所需实验室等级 8级")
        XCTAssertEqual(UpgradeRequirement.heroHall(level: 10).displayLabel(base: "home"), "所需英雄殿堂等级 10级")
        XCTAssertEqual(UpgradeRequirement.builderHall(level: 12).displayLabel(base: "home"), "所需建筑大师大本营等级 12级")
        XCTAssertEqual(UpgradeRequirement.starLaboratory(level: 8).displayLabel(base: "home"), "所需星空实验室等级 8级")
    }

    /// builder base：townHall 语义映射到建筑大师大本营、laboratory 映射到星空实验室
    ///（与 unlockLabel 的 builder 分支逐字一致：requiredTownHallLevel →
    /// 建筑大师大本营、requiredLaboratoryLevel → 星空实验室）。
    func testRequirementDisplayLabelBuilderBase() {
        XCTAssertEqual(UpgradeRequirement.townHall(level: 12).displayLabel(base: "builder"), "所需建筑大师大本营等级 12级")
        XCTAssertEqual(UpgradeRequirement.laboratory(level: 8).displayLabel(base: "builder"), "所需星空实验室等级 8级")
        XCTAssertEqual(UpgradeRequirement.builderHall(level: 12).displayLabel(base: "builder"), "所需建筑大师大本营等级 12级")
        XCTAssertEqual(UpgradeRequirement.starLaboratory(level: 8).displayLabel(base: "builder"), "所需星空实验室等级 8级")
        XCTAssertEqual(UpgradeRequirement.heroHall(level: 10).displayLabel(base: "builder"), "所需英雄殿堂等级 10级")
    }

    /// 多条件数组 → 「A · B」连接（与 unlockLabel 措辞一致）；空数组 → 空串；
    /// nil base 走 home 语义。
    func testRequirementDisplayLabelsJoin() {
        XCTAssertEqual(
            [UpgradeRequirement.townHall(level: 12), .laboratory(level: 8)].displayLabels(base: "home"),
            "所需大本营等级 12级 · 所需实验室等级 8级"
        )
        XCTAssertEqual(
            [UpgradeRequirement.builderHall(level: 10), .starLaboratory(level: 8)].displayLabels(base: "builder"),
            "所需建筑大师大本营等级 10级 · 所需星空实验室等级 8级"
        )
        XCTAssertEqual([UpgradeRequirement]().displayLabels(base: "home"), "")
        XCTAssertEqual(UpgradeRequirement.townHall(level: 12).displayLabel(base: nil), "所需大本营等级 12级")
    }

    private struct Payload: Decodable { let gameVersion: String; let items: [CatalogItem] }

    private func makeRequirementItem(base: String?, th: Int?, lab: Int?, tavern: Int?) -> CatalogItem {
        CatalogItem(
            section: "heroes", category: "heroes", dataID: 1, base: base,
            baseMissingReason: nil, name: "测试", maxLevel: 2, icon: nil, levelVisual: nil,
            levels: [CatalogLevel(
                level: 2, durationSeconds: nil, upgradeResource: nil, upgradeCost: nil,
                requiredTownHallLevel: th, requiredLaboratoryLevel: lab,
                requiredHeroTavernLevel: tavern, icon: nil, levelVisual: nil, missingReason: nil
            )]
        )
    }

    // MARK: - 真实目录阶段上限锚点（Issue #67 契约硬化）

    /// 真实 bundled 目录：12 本玩家加农炮阶段上限 15（全局 17）——目录升级时锚点
    /// 主动红，防「阶段上限被全局上限替代」回归（审核 B important-2）。
    func testBundledCannonStageMaxAtTH12() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let cannon = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_002))
        let unlocks = PlayerUnlockLevels(townHall: 12)
        XCTAssertEqual(cannon.maxLevel, 17, "全局上限锚点")
        XCTAssertEqual(
            VillageCatalogProjection.currentStageMaxLevel(for: cannon, unlocks: unlocks),
            15,
            "TH=12 时加农炮阶段上限应为 15（lvl16 需 TH14）"
        )
    }

    /// 真实 bundled 目录：野蛮人之王 TH18 + 英雄殿堂 8 → 阶段上限 86（全局 110）。
    /// 英雄殿堂门槛（tavern）真实生效锚点。
    func testBundledKingStageMaxAtTH18Tavern8() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let king = try XCTUnwrap(catalog.item(section: "heroes", dataID: 28_000_000))
        let unlocks = PlayerUnlockLevels(townHall: 18, heroHall: 8)
        XCTAssertEqual(king.maxLevel, 110, "全局上限锚点")
        XCTAssertEqual(
            VillageCatalogProjection.currentStageMaxLevel(for: king, unlocks: unlocks),
            86,
            "tavern=8 时英雄阶段上限应为 86（tavern 门槛 9+ 不满足）"
        )
    }
}
