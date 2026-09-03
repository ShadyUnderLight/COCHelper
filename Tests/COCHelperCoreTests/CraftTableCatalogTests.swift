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

    // MARK: - Issue #98 审核 F4：CraftTableDefenseSpec 旧格式解码兼容（M2）

    /// 无 lifecycle 键的旧 craft_table_catalog.json 条目 → 解码成功且 lifecycle == nil
    ///（Codable 合成解码缺键 → nil；老数据不因新字段拒绝解码）。
    func testDecodeDefenseSpecWithoutLifecycleKeyYieldsNil() throws {
        let json = """
        {
          "dataID": 103000008,
          "name": "史莱姆巨炮",
          "sourceName": "slime_cannon",
          "specialAbility": "",
          "moduleIDs": [102000033],
          "totalModuleLevelThresholds": []
        }
        """
        let spec = try JSONDecoder().decode(
            CraftTableDefenseSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.dataID, 103_000_008)
        XCTAssertNil(spec.lifecycle, "旧格式缺 lifecycle 键必须解码为 nil 而非失败")
    }

    /// 含 "lifecycle": "permanent" 的新格式 → 解码成功且值正确（声明值域映射）。
    func testDecodeDefenseSpecWithLifecyclePermanent() throws {
        let json = """
        {
          "dataID": 103000011,
          "name": "火热蜡烛",
          "sourceName": "candle",
          "specialAbility": "",
          "moduleIDs": [102000033, 102000034, 102000035],
          "totalModuleLevelThresholds": [],
          "lifecycle": "permanent"
        }
        """
        let spec = try JSONDecoder().decode(
            CraftTableDefenseSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.lifecycle, .permanent)
    }

    // MARK: - E0-03/Issue #303：版本门（schemaVersion/gameVersion 一致性）

    /// 真实 bundle：V3 manifest + 版本一致 → loadBundled 成功（无 hash 对账）。
    func testLoadBundledPassesForV3Manifest() throws {
        let version = GameCatalog.defaultBundledVersion
        let resources = try XCTUnwrap(CraftTableCatalog.bundledResourceData(version: version))
        let manifest = try JSONDecoder().decode(CatalogManifest.self, from: resources.manifest)
        XCTAssertEqual(manifest.schemaVersion, 3)
        XCTAssertEqual(manifest.gameVersion, version)
        XCTAssertNotNil(CraftTableCatalog.loadBundled(version: version))
    }

    /// 损坏 manifest（非 JSON）→ loadBundled 返回 nil（fail-closed）。
    func testLoadBundledFailsForCorruptManifest() {
        // manifest 解码失败即不可用；craft 内容损坏同样返回 nil。
        XCTAssertNil(CraftTableCatalog.loadBundled(version: "9.9.9"))
    }
}
