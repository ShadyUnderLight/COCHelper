import XCTest
@testable import COCHelperCore

// SeededGenerator（LCG：m = 2^32, a = 1664525, c = 1013904223）已在
// CoAPIPropertyTests.swift 中声明（测试模块共享命名空间），此处复用同一类型。

final class ClanCombatSummaryPropertyTests: XCTestCase {

    private static let iterationCount = 500

    private func assertOrFail(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !condition() {
            print(context())
            XCTFail("\(message) | \(context())", file: file, line: line)
        }
    }

    /// 随机攻击数组：长度 0-10；每字段 25% 概率缺失；摧毁率值域 [0, 150]。
    /// 缺失判定用 `g.int(in: 0...3) == 0`（mod-4 周期无系统偏差），不用 `g.bool()`——
    /// 本 LCG（a、c 均奇）的 LSB 严格交替，bool 会固定隔次为真，叠加固定抽签顺序后
    /// destructionPercentage 的 nil 路径实测 0% 覆盖。
    private func randomAttacks(_ g: inout SeededGenerator) -> [ClanWarAttack] {
        (0..<g.int(in: 0...10)).map { order in
            ClanWarAttack(
                order: g.int(in: 0...3) == 0 ? nil : order + 1,
                attackerTag: nil, defenderTag: nil,
                stars: g.int(in: 0...3) == 0 ? nil : g.int(in: 0...3),
                destructionPercentage: g.int(in: 0...3) == 0 ? nil : g.double(in: 0...150),
                duration: nil
            )
        }
    }

    private func randomDistricts(_ g: inout SeededGenerator) -> [CapitalRaidDistrict] {
        (0..<g.int(in: 0...10)).map { i in
            CapitalRaidDistrict(
                name: g.int(in: 0...3) == 0 ? nil : "D\(i)",
                id: nil, districtHallLevel: nil,
                stars: g.int(in: 0...3) == 0 ? nil : g.int(in: 0...3),
                destructionPercent: g.int(in: 0...3) == 0 ? nil : g.double(in: 0...150),
                attackCount: g.int(in: 0...3) == 0 ? nil : g.int(in: 1...8),
                totalLooted: g.int(in: 0...3) == 0 ? nil : g.int(in: 0...50000)
            )
        }
    }

    // MARK: - warMember 属性

    func testWarMemberLinesMirrorInput() {
        var g = SeededGenerator(seed: 11)
        for _ in 0..<Self.iterationCount {
            let attacks = randomAttacks(&g)
            let summary = ClanCombatSummary.warMember(attacks: attacks)
            assertOrFail(summary.lines.count == attacks.count,
                         "lines 必须与输入一一对应",
                         context: "seed=11 n=\(attacks.count)")
            for (line, attack) in zip(summary.lines, attacks) {
                assertOrFail(line.order == attack.order && line.stars == attack.stars
                             && line.destructionPercentage == attack.destructionPercentage,
                             "逐行字段必须原样保留（含 nil）",
                             context: "seed=11 line=\(line) attack=\(attack)")
            }
        }
    }

    func testWarMemberAttackCountAndStarSum() {
        var g = SeededGenerator(seed: 22)
        for _ in 0..<Self.iterationCount {
            let attacks = randomAttacks(&g)
            let summary = ClanCombatSummary.warMember(attacks: attacks)
            let expectedStars = attacks.reduce(0) { $0 + ($1.stars ?? 0) }
            assertOrFail(summary.attackCount == attacks.count,
                         "attackCount == 数组长度",
                         context: "seed=22 count=\(attacks.count) got=\(summary.attackCount)")
            assertOrFail(summary.totalStars == expectedStars,
                         "totalStars == Σ 有值星数（缺失记 0）",
                         context: "seed=22 expected=\(expectedStars) got=\(summary.totalStars)")
        }
    }

    /// 反回归：摧毁率聚合绝不能出现（否则百分比可 >100）。
    /// 双向映射：输入有值摧毁率集合 == 行摧毁率集合——任何"求和/丢失/篡改"都破坏该不变量。
    /// 反例：输入 [100, 80] → 聚合 [180] 或 [100] 均不满足；退化例 [0, 100] → 聚合 [100] 丢 0 也不满足。
    func testWarMemberDestructionValuesAreBidirectionalWithInput() {
        var g = SeededGenerator(seed: 33)
        for _ in 0..<Self.iterationCount {
            let attacks = randomAttacks(&g)
            let summary = ClanCombatSummary.warMember(attacks: attacks)
            let inputValues = attacks.compactMap(\.destructionPercentage)
            let lineValues = summary.lines.compactMap(\.destructionPercentage)
            assertOrFail(Set(inputValues) == Set(lineValues),
                         "摧毁率必须与输入双向一致（无聚合、无丢失、无篡改）",
                         context: "seed=33 input=\(inputValues) lines=\(lineValues)")
        }
    }

    // MARK: - raidDistricts 属性

    func testRaidDistrictsMirrorInput() {
        var g = SeededGenerator(seed: 44)
        for _ in 0..<Self.iterationCount {
            let districts = randomDistricts(&g)
            let summary = ClanCombatSummary.raidDistricts(districts)
            assertOrFail(summary.districts.count == districts.count,
                         "districts 必须与输入一一对应",
                         context: "seed=44 n=\(districts.count)")
            for (line, district) in zip(summary.districts, districts) {
                assertOrFail(line.name == district.name && line.stars == district.stars
                             && line.destructionPercent == district.destructionPercent
                             && line.attackCount == district.attackCount
                             && line.totalLooted == district.totalLooted,
                             "逐行字段必须原样保留（含 nil）",
                             context: "seed=44 line=\(line) district=\(district)")
            }
        }
    }

    func testRaidDistrictsLootSum() {
        var g = SeededGenerator(seed: 55)
        for _ in 0..<Self.iterationCount {
            let districts = randomDistricts(&g)
            let summary = ClanCombatSummary.raidDistricts(districts)
            let expected = districts.reduce(0) { $0 + ($1.totalLooted ?? 0) }
            assertOrFail(summary.totalLooted == expected,
                         "totalLooted == Σ 有值金币（缺失记 0）",
                         context: "seed=55 expected=\(expected) got=\(summary.totalLooted)")
        }
    }

    // MARK: - clampedPercent 属性

    func testClampedPercentAlwaysInDomainAndIdempotent() {
        var g = SeededGenerator(seed: 66)
        for _ in 0..<Self.iterationCount {
            let raw = g.double(in: -500...500)
            let clamped = ClanCombatSummary.clampedPercent(raw)
            assertOrFail(clamped >= 0 && clamped <= 100,
                         "钳制结果必须落在 [0, 100]",
                         context: "seed=66 raw=\(raw) got=\(clamped)")
            assertOrFail(ClanCombatSummary.clampedPercent(clamped) == clamped,
                         "钳制必须幂等",
                         context: "seed=66 clamped=\(clamped)")
            if raw >= 0 && raw <= 100 {
                assertOrFail(clamped == raw,
                             "域内值必须原样保留",
                             context: "seed=66 raw=\(raw) got=\(clamped)")
            }
        }
    }
}
