import XCTest
@testable import COCHelperCore

final class CraftTableCatalogTests: XCTestCase {
    func testBundledCatalogContainsVersionedDefenseModuleData() throws {
        let catalog = try XCTUnwrap(CraftTableCatalog.loadBundled())

        XCTAssertEqual(catalog.gameVersion, GameCatalog.defaultBundledVersion)
        XCTAssertEqual(catalog.buildTag, "18_400_7")
        XCTAssertEqual(catalog.defenses.count, 14)
        XCTAssertEqual(catalog.modules.count, 42)

        let defense = try XCTUnwrap(catalog.defense(dataID: 103_000_013))
        XCTAssertEqual(defense.name, "蛋糕投掷器")
        XCTAssertEqual(defense.moduleIDs, [102_000_039, 102_000_040, 102_000_041])

        let attackModule = try XCTUnwrap(catalog.module(dataID: 102_000_040))
        XCTAssertEqual(attackModule.maxLevel, 10)
        XCTAssertEqual(attackModule.statTypes, ["DamagePerHit", "DamagePerSecond"])
        XCTAssertEqual(attackModule.attributeLabel, "每次伤害、每秒伤害")
        XCTAssertEqual(attackModule.levels.count, 10)
        XCTAssertEqual(attackModule.levels.first?.durationSeconds, 0)

        let effectModule = try XCTUnwrap(catalog.module(dataID: 102_000_041))
        XCTAssertEqual(effectModule.attributeLabel, "投射物命中爆炸伤害")
        XCTAssertNotEqual(effectModule.attributeLabel, "战斗中效果持续时间")
    }

    func testCatalogVersionMismatchIsUnavailable() {
        XCTAssertNil(CraftTableCatalog.loadBundled(version: "18.999.99"))
    }
}
