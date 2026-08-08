import XCTest
@testable import COCHelperCore

/// Issue #73 Task 3：矿石本地化映射（CommonOre/RareOre/EpicOre → 官方简中）。
///
/// 映射下沉到 Core（`CatalogResourceLocalization`）以便单元测试；
/// COCHelper 侧 `ClanDisplayFormat.resourceLabel` 委托于此（单一来源）。
final class CatalogResourceLocalizationTests: XCTestCase {
    // MARK: - 矿石映射（Issue #73 Task 3 新增）

    func testOreResourcesLocalizeToOfficialNames() {
        XCTAssertEqual(CatalogResourceLocalization.label("CommonOre"), "闪亮矿石")
        XCTAssertEqual(CatalogResourceLocalization.label("RareOre"), "璀璨矿石")
        XCTAssertEqual(CatalogResourceLocalization.label("EpicOre"), "星辉矿石")
    }

    func testOreMatchingIsCaseAndWhitespaceInsensitive() {
        // 与既有资源映射同规则：trim + lowercased 后匹配（switch 已 lowercased）。
        XCTAssertEqual(CatalogResourceLocalization.label("commonore"), "闪亮矿石")
        XCTAssertEqual(CatalogResourceLocalization.label("COMMONORE"), "闪亮矿石")
        XCTAssertEqual(CatalogResourceLocalization.label(" RareOre "), "璀璨矿石")
        XCTAssertEqual(CatalogResourceLocalization.label("epicore"), "星辉矿石")
    }

    // MARK: - 既有资源映射回归（不得因下沉/新增矿石而漂移）

    func testExistingResourceMappingsUnchanged() {
        XCTAssertEqual(CatalogResourceLocalization.label("Gold"), "金币")
        XCTAssertEqual(CatalogResourceLocalization.label("Elixir"), "圣水")
        XCTAssertEqual(CatalogResourceLocalization.label("DarkElixir"), "暗黑重油")
        XCTAssertEqual(CatalogResourceLocalization.label("dark_elixir"), "暗黑重油")
        XCTAssertEqual(CatalogResourceLocalization.label("CapitalResource"), "都城金币")
        XCTAssertEqual(CatalogResourceLocalization.label("RaidCapitalGold"), "都城金币")
        XCTAssertEqual(CatalogResourceLocalization.label("BuilderGold"), "建筑大师基地金币")
        XCTAssertEqual(CatalogResourceLocalization.label("BuilderBaseElixir"), "建筑大师基地圣水")
    }

    // MARK: - 交叉审核补充：真实 bundle 使用的资源键（此前映射从未命中）

    func testActualBundleResourceKeysLocalize() {
        // 18.400.13 目录实际使用 Gold2/Elixir2（建筑大师基地，502 条）与
        // Diamonds（宝石，2 条）——旧映射只有 buildergold 等未命中键，导致
        // builder base 费用一直显示「未知资源」（交叉审核 O-1）。
        XCTAssertEqual(CatalogResourceLocalization.label("Gold2"), "建筑大师基地金币")
        XCTAssertEqual(CatalogResourceLocalization.label("Elixir2"), "建筑大师基地圣水")
        XCTAssertEqual(CatalogResourceLocalization.label("Diamonds"), "宝石")
    }

    // MARK: - 未知值兜底（不泄漏英文标识到 UI 主文本）

    func testUnknownResourceFallsBackToUnknownLabel() {
        XCTAssertEqual(CatalogResourceLocalization.label("StarOre"), "未知资源")
        XCTAssertEqual(CatalogResourceLocalization.label(""), "未知资源")
        XCTAssertEqual(CatalogResourceLocalization.label("   "), "未知资源")
    }

    func testNilFallsBackToUnknownLabel() {
        XCTAssertEqual(CatalogResourceLocalization.label(nil), "未知资源")
    }
}
