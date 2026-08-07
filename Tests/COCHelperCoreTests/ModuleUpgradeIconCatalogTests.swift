import XCTest
@testable import COCHelperCore

final class ModuleUpgradeIconCatalogTests: XCTestCase {
    private let expected: [(Int64, ModuleUpgradeIconKind, String)] = [
        (102_000_033, .health, "info_icon_hp"),
        (102_000_034, .damage, "info_icon_damage"),
        (102_000_035, .effect, "info_icon_time_boosted"),
        (102_000_036, .health, "info_icon_hp"),
        (102_000_037, .damage, "info_icon_damage"),
        (102_000_038, .effect, "info_icon_time_boosted"),
        (102_000_039, .health, "info_icon_hp"),
        (102_000_040, .damage, "info_icon_damage"),
        (102_000_041, .effect, "info_icon_time_boosted"),
    ]

    private let expectedCraftTableTypes: [(Int64, String)] = [
        (103_000_011, "inferno_candle_tower_lvl1"),
        (103_000_012, "headhunter_tower_lvl1"),
        (103_000_013, "cake_thrower_lvl1"),
    ]

    func testCraftModuleIDsMapToTheThreeAPKUpgradeIcons() throws {
        XCTAssertEqual(ModuleUpgradeIconCatalog.mappings.count, expected.count)

        for (dataID, kind, exportName) in expected {
            XCTAssertEqual(ModuleUpgradeIconCatalog.kind(for: dataID), kind,
                           "dataID \(dataID) 的模组属性图标映射错误")
            XCTAssertEqual(kind.exportName, exportName)
            XCTAssertEqual(kind.renderedPath, "icons/ui/\(exportName).png")

            let asset = try XCTUnwrap(ModuleUpgradeIconCatalog.asset(for: dataID))
            XCTAssertEqual(asset.container, "sc/ui.sc")
            XCTAssertEqual(asset.exportName, exportName)
            XCTAssertTrue(asset.isRenderable)
            XCTAssertEqual(asset.renderedPath, kind.renderedPath)
        }
    }

    func testBundledAPKUpgradeIconsResolveToPNGFiles() throws {
        let version = GameCatalog.defaultBundledVersion
        let urls = try expected.map { dataID, _, _ in
            try XCTUnwrap(
                ModuleUpgradeIconCatalog.bundledURL(for: dataID, version: version),
                "dataID \(dataID) 的 APK 升级图标未打入 Bundle"
            )
        }

        XCTAssertEqual(Set(urls.map(\.lastPathComponent)).count, 3,
                       "9 个模组应复用 3 个属性图标")
        for url in urls {
            let data = try Data(contentsOf: url)
            XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
                          "\(url.lastPathComponent) 应为 PNG")
        }
    }

    func testCraftTableTypeIDsMapToAPKBuildingIcons() throws {
        XCTAssertEqual(CraftTableTypeIconCatalog.mappings.count, expectedCraftTableTypes.count)

        for (dataID, exportName) in expectedCraftTableTypes {
            XCTAssertEqual(CraftTableTypeIconCatalog.exportName(for: dataID), exportName)

            let asset = try XCTUnwrap(CraftTableTypeIconCatalog.asset(for: dataID))
            XCTAssertEqual(asset.container, "sc/buildings.sc")
            XCTAssertEqual(asset.exportName, exportName)
            XCTAssertTrue(asset.isRenderable)
            XCTAssertEqual(asset.renderedPath, "icons/buildings/\(exportName).png")
        }
    }

    func testBundledCraftTableTypeIconsResolveToPNGFiles() throws {
        let version = GameCatalog.defaultBundledVersion
        let urls = try expectedCraftTableTypes.map { dataID, _ in
            try XCTUnwrap(
                CraftTableTypeIconCatalog.bundledURL(for: dataID, version: version),
                "dataID \(dataID) 的精制台父级建筑图标未打入 Bundle"
            )
        }

        XCTAssertEqual(Set(urls.map(\.lastPathComponent)).count, expectedCraftTableTypes.count)
        for url in urls {
            let data = try Data(contentsOf: url)
            XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
                          "\(url.lastPathComponent) 应为 PNG")
        }
    }

    func testUnknownDataIDDoesNotGuessAnUpgradeIcon() {
        XCTAssertNil(ModuleUpgradeIconCatalog.kind(for: 102_000_042))
        XCTAssertNil(ModuleUpgradeIconCatalog.asset(for: 102_000_042))
        XCTAssertNil(ModuleUpgradeIconCatalog.bundledURL(for: 102_000_042))
        XCTAssertNil(CraftTableTypeIconCatalog.exportName(for: 103_000_014))
        XCTAssertNil(CraftTableTypeIconCatalog.asset(for: 103_000_014))
        XCTAssertNil(CraftTableTypeIconCatalog.bundledURL(for: 103_000_014))
    }

    func testNestedVillageStatePrefersTheMappedModuleIcon() throws {
        let state = VillageItemState(
            id: "buildings:0.types.0.modules.0",
            section: "buildings",
            dataID: 102_000_034,
            base: .home,
            name: "火热蜡烛攻击力模组",
            category: .buildings,
            currentLevel: 1,
            count: nil,
            timerSeconds: nil,
            remainingSeconds: nil,
            nextLevel: nil,
nextLevelDurationSeconds: nil,
            nextLevelDurationState: nil,
            maxLevel: nil,
            status: .unknown,
            missingReason: "嵌套模块/类型不参与静态目录 join",
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: true
        )

        XCTAssertEqual(
            state.preferredAssetURLs(version: GameCatalog.defaultBundledVersion).first,
            try XCTUnwrap(ModuleUpgradeIconCatalog.bundledURL(for: 102_000_034)),
            "嵌套模组应优先使用 APK 属性图标，而不是 SF Symbol"
        )
    }

    func testNestedVillageStatePrefersTheMappedCraftTableTypeIcon() throws {
        let state = VillageItemState(
            id: "buildings:0.types.0",
            section: "buildings",
            dataID: 103_000_011,
            base: .home,
            name: "火热蜡烛",
            category: .buildings,
            currentLevel: nil,
            count: nil,
            timerSeconds: nil,
            remainingSeconds: nil,
            nextLevel: nil,
nextLevelDurationSeconds: nil,
            nextLevelDurationState: nil,
            maxLevel: nil,
            status: .unknown,
            missingReason: "嵌套模块/类型不参与静态目录 join",
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: true
        )

        XCTAssertEqual(
            state.preferredAssetURLs(version: GameCatalog.defaultBundledVersion).first,
            try XCTUnwrap(CraftTableTypeIconCatalog.bundledURL(for: 103_000_011)),
            "嵌套精制台父级应优先使用 APK 建筑图标，而不是 SF Symbol"
        )
    }
}
