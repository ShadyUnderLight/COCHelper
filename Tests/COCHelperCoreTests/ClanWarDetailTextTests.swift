import XCTest
@testable import COCHelperCore

/// Issue #127：攻击明细/最佳防守文案纯函数（从 UI 迁入 Core，可测）。
/// 契约：字段独立降级；星数 clamp [0,3]；摧毁率经 displayDestructionPercent；
/// 时长经 durationText；不补目标名称。
final class ClanWarDetailTextTests: XCTestCase {

    // MARK: - attackLineText

    func testAttackLineFull() {
        let line = ClanWarAttackLine(order: 1, stars: 2, destructionPercentage: 80,
                                     defenderTag: "#DEF", duration: 145)
        XCTAssertEqual(ClanWarDetailText.attackLine(line),
                       "1号进攻 · 目标 #DEF · ⭐2 · 摧毁率 80% · 耗时 2:25")
    }

    func testAttackLineAllFieldsMissing() {
        let line = ClanWarAttackLine(order: nil, stars: nil, destructionPercentage: nil,
                                     defenderTag: nil, duration: nil)
        XCTAssertEqual(ClanWarDetailText.attackLine(line),
                       "?号进攻 · 目标未知 · ⭐? · 摧毁率未知 · 耗时未知")
    }

    func testAttackLineClampsAndDegrades() {
        // 星数越界 clamp [0,3]；摧毁率 NaN → 未知；负时长 → 未知
        let line = ClanWarAttackLine(order: 2, stars: 99, destructionPercentage: .nan,
                                     defenderTag: nil, duration: -5)
        XCTAssertEqual(ClanWarDetailText.attackLine(line),
                       "2号进攻 · 目标未知 · ⭐3 · 摧毁率未知 · 耗时未知")
        let neg = ClanWarAttackLine(order: 2, stars: -3, destructionPercentage: 150,
                                    defenderTag: "#D", duration: 0)
        XCTAssertEqual(ClanWarDetailText.attackLine(neg),
                       "2号进攻 · 目标 #D · ⭐0 · 摧毁率 100% · 耗时 0:00")
    }

    // MARK: - bestDefenseText

    func testBestDefenseFull() {
        let best = ClanWarAttackLine(stars: 2, destructionPercentage: 75, duration: 120)
        XCTAssertEqual(ClanWarDetailText.bestDefense(best),
                       "最佳防守 · ⭐2 · 摧毁率 75% · 耗时 2:00")
    }

    func testBestDefenseAllFieldsMissing() {
        let best = ClanWarAttackLine(stars: nil, destructionPercentage: nil, duration: nil)
        XCTAssertEqual(ClanWarDetailText.bestDefense(best),
                       "最佳防守 · ⭐? · 摧毁率未知 · 耗时未知")
    }
}
