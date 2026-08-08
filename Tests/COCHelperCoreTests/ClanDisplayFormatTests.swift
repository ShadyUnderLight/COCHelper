import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

/// 联赛/段位展示格式化（Issue #71 Task 3）：playerLeagueTierLabel 新逻辑 +
/// 现有 league 标签迁移到 LeagueTierCatalog 后的回归保护。
final class ClanDisplayFormatTests: XCTestCase {
    // MARK: - playerLeagueTierLabel（排位段位，2026 新增）

    func testPlayerLeagueTierLabelKnownID() {
        let tier = PlayerLeague(id: 29000022, name: "Champion League II", iconUrls: nil)
        XCTAssertEqual(ClanDisplayFormat.playerLeagueTierLabel(tier), "传奇联赛")
    }

    func testPlayerLeagueTierLabelNil() {
        XCTAssertNil(ClanDisplayFormat.playerLeagueTierLabel(nil))
        XCTAssertNil(
            ClanDisplayFormat.playerLeagueTierLabel(
                PlayerLeague(id: nil, name: nil, iconUrls: nil)
            )
        )
    }

    func testPlayerLeagueTierLabelUnknownID() {
        // 2026 新增段位 ID（超出已审计目录）：降级文案，不显示英文名。
        // 注意：29000023 是"未知段位"样例（目录外）。若官方目录后续收录
        // 29000023（如传奇杯 1/2/3 真身），本测试须同步改为断言中文名。
        let tier = PlayerLeague(id: 29000023, name: "Legend League III", iconUrls: nil)
        XCTAssertEqual(ClanDisplayFormat.playerLeagueTierLabel(tier), "待本地化（ID: 29000023）")
    }

    // MARK: - 迁移回归保护（手写字典 → LeagueTierCatalog，输出不得漂移）

    func testPlayerLeagueLabelRegression() {
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 29000000, name: "Unranked", iconUrls: nil)),
            "未定级"
        )
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 29000010, name: "Crystal League III", iconUrls: nil)),
            "水晶联赛 III"
        )
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 29000022, name: "Champion League II", iconUrls: nil)),
            "传奇联赛"
        )
        XCTAssertNil(ClanDisplayFormat.playerLeagueLabel(nil))
    }

    func testBuilderBaseLeagueLabelRegression() {
        XCTAssertEqual(
            ClanDisplayFormat.builderBaseLeagueLabel(PlayerLeague(id: 44000013, name: "Legend League", iconUrls: nil)),
            "传奇联赛"
        )
        XCTAssertNil(ClanDisplayFormat.builderBaseLeagueLabel(nil))
    }

    func testCapitalLeagueLabelRegression() {
        XCTAssertEqual(
            ClanDisplayFormat.capitalLeagueLabel(ClanLeague(id: 85000006, name: "Titan League I")),
            "泰坦联赛 I"
        )
        XCTAssertNil(ClanDisplayFormat.capitalLeagueLabel(nil))
    }

    func testRequiredLeagueTierLabelRegression() {
        XCTAssertEqual(
            ClanDisplayFormat.requiredLeagueTierLabel(ClanLeagueTier(id: 105000028, name: "Titan League I")),
            "泰坦联赛 I"
        )
        XCTAssertNil(ClanDisplayFormat.requiredLeagueTierLabel(nil))
    }

    // MARK: - 未知 ID 降级文案

    func testUnknownIDFallbackText() {
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 99999999, name: "x", iconUrls: nil)),
            "未本地化联赛（ID: 99999999）"
        )
        XCTAssertEqual(
            ClanDisplayFormat.builderBaseLeagueLabel(PlayerLeague(id: 99999999, name: "x", iconUrls: nil)),
            "未本地化联赛（ID: 99999999）"
        )
        XCTAssertEqual(
            ClanDisplayFormat.capitalLeagueLabel(ClanLeague(id: 99999999, name: "x")),
            "未本地化联赛（ID: 99999999）"
        )
        XCTAssertEqual(
            ClanDisplayFormat.requiredLeagueTierLabel(ClanLeagueTier(id: 99999999, name: "x")),
            "未本地化联赛（ID: 99999999）"
        )
    }
}
