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
        XCTAssertNil(summary.districts[1].attackCount)
        XCTAssertNil(summary.districts[1].totalLooted)
        XCTAssertEqual(summary.totalLooted, 5000)
    }

    // MARK: - destroyedDistrictCount

    func testDestroyedCountPrefersOfficialField() {
        // 官方字段存在时优先，即使与明细不一致（0 也是官方事实）
        XCTAssertEqual(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: 2,
            districts: [district(name: "A", destruction: 100), district(name: "B", destruction: 40)]), 2)
        XCTAssertEqual(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: 0,
            districts: [district(name: "A", destruction: 100)]), 0)
    }

    func testDestroyedCountDerivesFromDistrictsWhenOfficialMissing() {
        // 官方缺失 → 摧毁率 ≥100 才计数
        XCTAssertEqual(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil,
            districts: [district(name: "A", destruction: 100), district(name: "B", destruction: 100), district(name: "C", destruction: 40)]), 2)
        // 任一未知（nil）→ 无法确定精确数，fail-closed 省略
        XCTAssertNil(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil,
            districts: [district(name: "A", destruction: 100), district(name: "B", destruction: nil)]))
        // 浮点噪声容忍：100.0001 也算摧毁
        XCTAssertEqual(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil,
            districts: [district(name: "A", destruction: 100.0001)]), 1)
    }

    func testDestroyedCountUnknownWhenNoEvidence() {
        // 存在未知摧毁率且无明确摧毁 → nil（调用方省略分句，不编造 0）
        XCTAssertNil(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil, districts: [district(name: "A", destruction: nil), district(name: "B", destruction: nil)]))
        XCTAssertNil(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil, districts: [district(name: "A", destruction: 40), district(name: "B", destruction: nil)]))
        XCTAssertNil(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil, districts: []))
    }

    func testDestroyedCountAllKnownUndestroyedIsZero() {
        // 全部已知且未摧毁 → 0 是事实（与官方字段 0 路径一致，显示"摧毁 0 座子城"）
        XCTAssertEqual(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil, districts: [district(name: "A", destruction: 40)]), 0)
        XCTAssertEqual(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil, districts: [district(name: "A", destruction: 0), district(name: "B", destruction: 99.9)]), 0)
    }

    func testDestroyedCountNonFiniteIsUnknown() {
        // NaN/Inf 视为未知摧毁率 → 无法确定精确数 → nil（与 P2 显示端一致）
        XCTAssertNil(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil, districts: [district(name: "A", destruction: Double.infinity)]))
        XCTAssertNil(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil, districts: [district(name: "A", destruction: Double.nan)]))
        XCTAssertNil(ClanCombatSummary.destroyedDistrictCount(
            districtsDestroyed: nil, districts: [district(name: "A", destruction: 100), district(name: "B", destruction: Double.nan)]))
    }

    // MARK: - displayDestructionPercent

    func testDisplayDestructionPercentUnknownForMissingOrNonFinite() {
        XCTAssertNil(ClanCombatSummary.displayDestructionPercent(nil))
        XCTAssertNil(ClanCombatSummary.displayDestructionPercent(Double.nan))
        XCTAssertNil(ClanCombatSummary.displayDestructionPercent(Double.infinity))
        XCTAssertNil(ClanCombatSummary.displayDestructionPercent(-Double.infinity))
    }

    func testDisplayDestructionPercentClampsFinite() {
        XCTAssertEqual(ClanCombatSummary.displayDestructionPercent(0), 0)
        XCTAssertEqual(ClanCombatSummary.displayDestructionPercent(100), 100)
        XCTAssertEqual(ClanCombatSummary.displayDestructionPercent(50.5), 50.5)
        XCTAssertEqual(ClanCombatSummary.displayDestructionPercent(-5), 0)
        XCTAssertEqual(ClanCombatSummary.displayDestructionPercent(150), 100)
    }

    // MARK: - clampedPercent

    func testClampedPercentBounds() {
        XCTAssertEqual(ClanCombatSummary.clampedPercent(-1), 0)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(101), 100)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(0), 0)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(100), 100)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(50.5), 50.5)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(Double.nan), 0)  // NaN → 0 防御
        XCTAssertEqual(ClanCombatSummary.clampedPercent(Double.infinity), 0)
        XCTAssertEqual(ClanCombatSummary.clampedPercent(-Double.infinity), 0)
    }

    // MARK: - durationText（Issue #127）

    func testDurationTextFormatsMinutesAndSeconds() {
        XCTAssertEqual(ClanCombatSummary.durationText(0), "0:00")
        XCTAssertEqual(ClanCombatSummary.durationText(59), "0:59")
        XCTAssertEqual(ClanCombatSummary.durationText(60), "1:00")
        XCTAssertEqual(ClanCombatSummary.durationText(65), "1:05")
        XCTAssertEqual(ClanCombatSummary.durationText(145), "2:25")
        XCTAssertEqual(ClanCombatSummary.durationText(3661), "61:01")
    }

    func testDurationTextNilAndNegativeIsUnknown() {
        XCTAssertNil(ClanCombatSummary.durationText(nil))
        XCTAssertNil(ClanCombatSummary.durationText(-1))
        XCTAssertNil(ClanCombatSummary.durationText(Int.min))
    }
}
