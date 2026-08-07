import XCTest
@testable import COCHelperCore

final class ClanCombatSummaryTests: XCTestCase {

    private func attack(_ order: Int, stars: Int? = nil, destruction: Double? = nil) -> ClanWarAttack {
        ClanWarAttack(order: order, attackerTag: nil, defenderTag: nil,
                      stars: stars, destructionPercentage: destruction, duration: nil)
    }

    private func district(name: String? = nil, stars: Int? = nil, destruction: Double? = nil,
                          attacks: Int? = nil, loot: Int? = nil) -> CapitalRaidDistrict {
        CapitalRaidDistrict(name: name, id: nil, districtHallLevel: nil, stars: stars,
                            destructionPercent: destruction, attackCount: attacks, totalLooted: loot)
    }

    // MARK: - warMember

    func testWarMemberSumsStarsAndKeepsPerAttackLines() {
        let summary = ClanCombatSummary.warMember(attacks: [
            attack(1, stars: 3, destruction: 100),
            attack(2, stars: 2, destruction: 80),
        ])
        XCTAssertEqual(summary.attackCount, 2)
        XCTAssertEqual(summary.totalStars, 5)
        XCTAssertEqual(summary.lines.map(\.order), [1, 2])
        XCTAssertEqual(summary.lines.map(\.stars), [3, 2])
        // 摧毁率逐行保留，绝无聚合百分比（180% 不可能再被构造出来）
        XCTAssertEqual(summary.lines.map(\.destructionPercentage), [100, 80])
    }

    func testWarMemberEmptyAttacks() {
        let summary = ClanCombatSummary.warMember(attacks: [])
        XCTAssertEqual(summary.attackCount, 0)
        XCTAssertEqual(summary.totalStars, 0)
        XCTAssertTrue(summary.lines.isEmpty)
    }

    func testWarMemberSingleAttack() {
        let summary = ClanCombatSummary.warMember(attacks: [attack(1, stars: 3, destruction: 100)])
        XCTAssertEqual(summary.attackCount, 1)
        XCTAssertEqual(summary.totalStars, 3)
        XCTAssertEqual(summary.lines.count, 1)
    }

    func testWarMemberMissingDestructionIsNilNotZero() {
        let summary = ClanCombatSummary.warMember(attacks: [
            attack(1, stars: 3, destruction: 100),
            attack(2, stars: 2, destruction: nil),   // 缺失
        ])
        // 关键：缺失摧毁率必须保持 nil，不能悄悄变成 0 参与任何聚合
        XCTAssertNil(summary.lines[1].destructionPercentage)
        XCTAssertEqual(summary.lines[0].destructionPercentage, 100)
    }

    func testWarMemberMissingStarsCountedAsZeroInTotal() {
        let summary = ClanCombatSummary.warMember(attacks: [
            attack(1, stars: 3, destruction: 100),
            attack(2, stars: nil, destruction: 80),
        ])
        XCTAssertEqual(summary.totalStars, 3)  // 星数缺失记 0（旧语义锁定）
    }

    // MARK: - raidDistricts

    func testRaidDistrictsKeepsPerDistrictLinesAndSumsLoot() {
        let summary = ClanCombatSummary.raidDistricts([
            district(name: "A", stars: 3, destruction: 100, attacks: 1, loot: 5000),
            district(name: "B", stars: 2, destruction: 100, attacks: 2, loot: 3000),
        ])
        // 两个 100% 子城：摧毁率逐行保留 100/100，绝不产出 200%
        XCTAssertEqual(summary.districts.map(\.destructionPercent), [100, 100])
        XCTAssertEqual(summary.districts.map(\.name), ["A", "B"])
        XCTAssertEqual(summary.totalLooted, 8000)
    }

    func testRaidDistrictsEmpty() {
        let summary = ClanCombatSummary.raidDistricts([])
        XCTAssertTrue(summary.districts.isEmpty)
        XCTAssertEqual(summary.totalLooted, 0)
    }

    func testRaidDistrictsMissingFieldsPreserved() {
        let summary = ClanCombatSummary.raidDistricts([
            district(name: "A", stars: 3, destruction: 100, attacks: 1, loot: 5000),
            district(name: "B"),  // 全缺失
        ])
        XCTAssertNil(summary.districts[1].destructionPercent)
        XCTAssertNil(summary.districts[1].stars)
        XCTAssertEqual(summary.totalLooted, 5000)
    }

    // MARK: - clampedPercent

    func testClampedPercentBounds() {
        XCTAssertEqual(ClanCombatSummary.clampedPercent(-1), 0)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(101), 100)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(0), 0)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(100), 100)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(50.5), 50.5)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(Double.nan), 0)  // NaN → 0 防御
    }
}
