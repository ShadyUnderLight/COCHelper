import Foundation
import XCTest
@testable import COCHelperCore

/// 联赛/段位本地化目录（Issue #71）：bundled 加载、按 context+ID 查中文名、
/// 未知 ID 返回 nil、版本不匹配返回 nil。
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
        XCTAssertEqual(catalog.source, "audited-from-existing-code-2026-08")
        // 4 个 context 全覆盖
        XCTAssertEqual(
            Set(catalog.contexts.map(\.context)),
            Set(LeagueTierContext.allCases)
        )
        // home 23 个 ID（29000000 未定级 ~ 29000022 传奇联赛）
        let home = catalog.contexts.first { $0.context == .home }
        XCTAssertEqual(home?.tiers.count, 23)
    }

    // MARK: - 已知 ID 查询

    func testKnownHomeIDsMapToChinese() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())
        XCTAssertEqual(catalog.name(forID: 29_000_000, context: .home), "未定级")
        XCTAssertEqual(catalog.name(forID: 29_000_001, context: .home), "青铜联赛 III")
        XCTAssertEqual(catalog.name(forID: 29_000_010, context: .home), "水晶联赛 III")
        XCTAssertEqual(catalog.name(forID: 29_000_022, context: .home), "传奇联赛")
    }

    func testKnownIDsInOtherContexts() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())
        XCTAssertEqual(catalog.name(forID: 44_000_013, context: .builderBase), "传奇联赛")
        XCTAssertEqual(catalog.name(forID: 85_000_006, context: .capital), "泰坦联赛 I")
        XCTAssertEqual(catalog.name(forID: 105_000_028, context: .requiredTier), "泰坦联赛 I")
    }

    // MARK: - 未知 ID

    func testUnknownIDReturnsNil() throws {
        let catalog = try XCTUnwrap(LeagueTierCatalog.loadBundled())
        XCTAssertNil(catalog.name(forID: 29_000_023, context: .home)) // 超出已审计范围
        XCTAssertNil(catalog.name(forID: 29_000_022, context: .builderBase)) // ID 存在但 context 不符
        XCTAssertNil(catalog.name(forID: 105_000_028, context: .home)) // 其他 context 的 ID
        XCTAssertNil(catalog.name(forID: 0, context: .home))
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
                { "id": 29000022, "name": "传奇联赛" }
              ]
            },
            { "context": "capital", "tiers": [ { "id": 85000006, "name": "泰坦联赛 I" } ] }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try JSONDecoder().decode(LeagueTierCatalog.self, from: json)
        XCTAssertEqual(catalog.contexts.count, 2)
        XCTAssertEqual(catalog.contexts[0].context, .home)
        XCTAssertEqual(catalog.contexts[0].tiers.count, 2)
        XCTAssertEqual(catalog.contexts[0].tiers[1].id, 29_000_022)
        XCTAssertEqual(catalog.contexts[0].tiers[1].name, "传奇联赛")
        XCTAssertEqual(catalog.contexts[1].context, .capital)
        XCTAssertEqual(catalog.name(forID: 85_000_006, context: .capital), "泰坦联赛 I")
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
