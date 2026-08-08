import Foundation
import XCTest
@testable import COCHelperCore

/// 联赛/段位本地化目录（Issue #71）：bundled 加载、按 context+ID 查中文名、
/// 未知 ID 返回 nil、版本不匹配返回 nil。
/// 数据来源：clashy.py 官方静态数据（2026-08，assets.clashk.ing 派生），
/// 官方简中术语（铜杯联赛3 / 石头联赛2 / 飞龙联赛28 / 传奇杯1-3）。
final class LeagueTierCatalogTests: XCTestCase {
    private struct FuzzRand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    // MARK: - bundled 加载

    func testBundledCatalogLoadsWithExpectedShape() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())

        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(catalog.gameVersion, GameCatalog.defaultBundledVersion)
        XCTAssertEqual(catalog.locale, "zh-CN")
        XCTAssertEqual(catalog.source, "clashy-static-2026-08")
        // 4 个 context 全覆盖：home / builderBase / capital / leagueTier
        XCTAssertEqual(
            Set(catalog.contexts.map(\.context)),
            Set(LeagueTierContext.allCases)
        )
        // 全量收录：home 23（29000000 未定级 ~ 29000022 传奇杯联赛）、
        // builderBase 42（木头联赛5 ~ 钻石联赛）、capital 23（未排名 ~ 传奇杯联赛）、
        // leagueTier 37（未进入联赛 ~ 传奇杯1）
        XCTAssertEqual(catalog.contexts.first { $0.context == .home }?.tiers.count, 23)
        XCTAssertEqual(catalog.contexts.first { $0.context == .builderBase }?.tiers.count, 42)
        XCTAssertEqual(catalog.contexts.first { $0.context == .capital }?.tiers.count, 23)
        XCTAssertEqual(catalog.contexts.first { $0.context == .leagueTier }?.tiers.count, 37)
    }

    // MARK: - 已知 ID 查询（官方术语）

    func testKnownHomeIDsMapToOfficialChinese() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())
        XCTAssertEqual(catalog.name(forID: 29_000_000, context: .home), "未定级")
        XCTAssertEqual(catalog.name(forID: 29_000_001, context: .home), "铜杯联赛3")
        XCTAssertEqual(catalog.name(forID: 29_000_003, context: .home), "铜杯联赛1")
        XCTAssertEqual(catalog.name(forID: 29_000_010, context: .home), "水晶杯联赛3")
        XCTAssertEqual(catalog.name(forID: 29_000_018, context: .home), "冠军杯联赛1")
        XCTAssertEqual(catalog.name(forID: 29_000_021, context: .home), "泰坦杯联赛1")
        XCTAssertEqual(catalog.name(forID: 29_000_022, context: .home), "传奇杯联赛")
    }

    func testKnownBuilderBaseIDsMapToOfficialChinese() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())
        XCTAssertEqual(catalog.name(forID: 44_000_000, context: .builderBase), "木头联赛5")
        XCTAssertEqual(catalog.name(forID: 44_000_013, context: .builderBase), "石头联赛2")
        XCTAssertEqual(catalog.name(forID: 44_000_019, context: .builderBase), "红铜联赛1")
        XCTAssertEqual(catalog.name(forID: 44_000_041, context: .builderBase), "钻石联赛")
    }

    func testKnownCapitalIDsMapToOfficialChinese() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())
        XCTAssertEqual(catalog.name(forID: 85_000_000, context: .capital), "未排名")
        XCTAssertEqual(catalog.name(forID: 85_000_006, context: .capital), "银杯联赛1")
        XCTAssertEqual(catalog.name(forID: 85_000_015, context: .capital), "大师杯联赛1")
        XCTAssertEqual(catalog.name(forID: 85_000_022, context: .capital), "传奇杯联赛")
    }

    func testKnownLeagueTierIDsMapToOfficialChinese() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())
        XCTAssertEqual(catalog.name(forID: 105_000_000, context: .leagueTier), "未进入联赛")
        XCTAssertEqual(catalog.name(forID: 105_000_001, context: .leagueTier), "骷髅兵联赛1")
        XCTAssertEqual(catalog.name(forID: 105_000_028, context: .leagueTier), "飞龙联赛28")
        XCTAssertEqual(catalog.name(forID: 105_000_033, context: .leagueTier), "雷龙联赛33")
        // 传奇杯 1/2/3（Supercell 公告术语；105000036=传奇杯1 最高、105000034=传奇杯3 最低）
        XCTAssertEqual(catalog.name(forID: 105_000_036, context: .leagueTier), "传奇杯1")
        XCTAssertEqual(catalog.name(forID: 105_000_035, context: .leagueTier), "传奇杯2")
        XCTAssertEqual(catalog.name(forID: 105_000_034, context: .leagueTier), "传奇杯3")
    }

    // MARK: - 未知 ID

    func testUnknownIDReturnsNil() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())
        XCTAssertNil(catalog.name(forID: 29_000_023, context: .home)) // 超出已审计范围
        XCTAssertNil(catalog.name(forID: 29_000_022, context: .builderBase)) // ID 存在但 context 不符
        XCTAssertNil(catalog.name(forID: 105_000_028, context: .home)) // 其他 context 的 ID
        XCTAssertNil(catalog.name(forID: 0, context: .home))
        XCTAssertNil(catalog.name(forID: 105_000_037, context: .leagueTier)) // 超出 37 个段位
    }

    func testCatalogVersionMismatchIsUnavailable() {
        XCTAssertNil(LeagueTierCatalog.loadBundled(version: "18.999.99"))
    }

    // MARK: - 内联 JSON 解码结构

    func testInlineJSONDecodesContextGrouping() throws {
        let json = """
        {
          "schemaVersion": 1,
          "gameVersion": "18.400.13",
          "locale": "zh-CN",
          "source": "test",
          "contexts": [
            {
              "context": "home",
              "tiers": [
                { "id": 29000000, "name": "未定级" },
                { "id": 29000022, "name": "传奇杯联赛" }
              ]
            },
            { "context": "leagueTier", "tiers": [ { "id": 105000036, "name": "传奇杯1" } ] }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try JSONDecoder().decode(LeagueTierCatalog.self, from: json)
        XCTAssertEqual(catalog.contexts.count, 2)
        XCTAssertEqual(catalog.contexts[0].context, .home)
        XCTAssertEqual(catalog.contexts[0].tiers.count, 2)
        XCTAssertEqual(catalog.contexts[0].tiers[1].id, 29_000_022)
        XCTAssertEqual(catalog.contexts[0].tiers[1].name, "传奇杯联赛")
        XCTAssertEqual(catalog.contexts[1].context, .leagueTier)
        XCTAssertEqual(catalog.name(forID: 105_000_036, context: .leagueTier), "传奇杯1")
    }

    // MARK: - fuzz（fixed seed）：已知 ID 恒命中且中文正确、未知 ID 恒 nil

    func testFuzzLookupsKnownHitUnknownNil() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())
        var r = FuzzRand(state: 0xA11E_0000_0000_0000)
        for i in 0..<200 {
            let context = LeagueTierContext.allCases[Int(r.next() % UInt64(LeagueTierContext.allCases.count))]
            let id: Int
            if i % 10 == 0 {
                // 每 10 轮强制命中已审计 ID，保证「已知命中」分支被真实执行
                guard let spec = catalog.contexts.first(where: { $0.context == context }),
                      !spec.tiers.isEmpty else {
                    XCTFail("iteration \(i): context \(context) 缺失或 tiers 为空")
                    continue
                }
                id = spec.tiers[Int(r.next() % UInt64(spec.tiers.count))].id
            } else {
                id = Int(r.next() % 200_000_000)
            }
            let known = catalog.contexts.first { $0.context == context }?.tiers.first { $0.id == id }
            let got = catalog.name(forID: id, context: context)
            if let known {
                XCTAssertEqual(got, known.name, "iteration \(i): 已知 ID \(id) 必须命中且中文正确")
            } else {
                XCTAssertNil(got, "iteration \(i): 未知 ID \(id) 必须为 nil")
            }
        }
    }
}
