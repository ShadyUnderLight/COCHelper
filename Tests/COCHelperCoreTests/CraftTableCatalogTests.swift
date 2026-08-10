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

    // MARK: - Issue #98 审核 P1-2：craft 目录运行时完整性门禁（fail-closed）

    /// 真实 bundle：manifest 对账 craft_table_catalog.json 的 sha256/size 通过。
    func testIntegrityOKPassesForBundledData() throws {
        let version = GameCatalog.defaultBundledVersion
        let resources = try XCTUnwrap(CraftTableCatalog.bundledResourceData(version: version))
        let manifestData = resources.manifest
        let craftData = resources.craft
        XCTAssertTrue(CraftTableCatalog.integrityOK(manifestData: manifestData, craftData: craftData))
    }

    /// tampered 负例：篡改 craft 数据任意字节 → sha256 失配 → 不通过
    ///（篡改数据不得静默把季节内容判为 permanent）。
    func testIntegrityOKFailsForTamperedCraftData() throws {
        let version = GameCatalog.defaultBundledVersion
        let resources = try XCTUnwrap(CraftTableCatalog.bundledResourceData(version: version))
        let manifestData = resources.manifest
        let craftData = resources.craft
        var tampered = craftData
        tampered[tampered.count / 2] ^= 0xFF  // 翻转一个字节
        XCTAssertFalse(CraftTableCatalog.integrityOK(manifestData: manifestData, craftData: tampered))
    }

    /// mismatch 负例：manifest 无 craft_table_catalog.json 条目 → 不通过
    ///（无完整性证明即 fail-closed）。
    func testIntegrityOKFailsWhenManifestEntryMissing() throws {
        let manifestJSON = """
        {
          "schemaVersion": 2,
          "gameVersion": "18.400.13",
          "buildTag": "18_400_7",
          "locale": "zh-CN",
          "sourceFingerprint": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "generatedFiles": [
            {"path": "catalog.json", "sha256": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "size": 1}
          ],
          "counts": {"items": 0, "levels": 0}
        }
        """
        let craftData = Data("{\"schemaVersion\":1}".utf8)
        XCTAssertFalse(CraftTableCatalog.integrityOK(
            manifestData: Data(manifestJSON.utf8), craftData: craftData))
    }

    /// 损坏 manifest（非 JSON）→ 解码失败 → 不通过（fail-closed）。
    func testIntegrityOKFailsForCorruptManifest() {
        let craftData = Data("{\"schemaVersion\":1}".utf8)
        XCTAssertFalse(CraftTableCatalog.integrityOK(
            manifestData: Data("{not json".utf8), craftData: craftData))
    }

    /// size 失配（hash 相同但长度不同）→ 不通过。
    func testIntegrityOKFailsForSizeMismatch() throws {
        let version = GameCatalog.defaultBundledVersion
        let resources = try XCTUnwrap(CraftTableCatalog.bundledResourceData(version: version))
        let manifestData = resources.manifest
        let craftData = resources.craft
        // 同 hash 不可能构造，这里用「长度差 1 但内容同源」验证 size 维度独立校验：
        // 取真实数据去掉尾部一个字节 → hash 必变 → 不通过（同时覆盖 hash+size）。
        let truncated = craftData.dropLast()
        XCTAssertFalse(CraftTableCatalog.integrityOK(manifestData: manifestData, craftData: truncated))
    }

    /// 复审 P2 负例：manifest 含重复 craft 条目 → 不通过（与 validator
    /// 「恰好一个」契约一致，不得被 first(where:) 放行）。
    func testIntegrityOKFailsForDuplicateCraftEntries() throws {
        let version = GameCatalog.defaultBundledVersion
        let resources = try XCTUnwrap(CraftTableCatalog.bundledResourceData(version: version))
        let manifest = try JSONDecoder().decode(
            CatalogManifest.self, from: resources.manifest)
        var entries = manifest.generatedFiles
        entries.append(entries.first { $0.path == "craft_table_catalog.json" }!)
        let encoder = JSONEncoder()
        let entriesJSON = String(data: try encoder.encode(entries), encoding: .utf8)!
        let duplicateManifest = """
        {"schemaVersion": 2, "gameVersion": "18.400.13", "buildTag": "18_400_7",
         "locale": "zh-CN", "sourceFingerprint": "sha256:\(String(repeating: "a", count: 64))",
         "generatedFiles": \(entriesJSON),
         "counts": {"items": 0, "levels": 0}}
        """
        XCTAssertFalse(CraftTableCatalog.integrityOK(
            manifestData: Data(duplicateManifest.utf8), craftData: resources.craft))
    }
}
