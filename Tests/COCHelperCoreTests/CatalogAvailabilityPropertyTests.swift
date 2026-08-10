import XCTest
@testable import COCHelperCore

/// Issue #98：availability 三态判定的 property-based 测试（确定性、无第三方依赖）。
///
/// 固定 seed LCG 伪随机（seed 0x9E3779B97F4A7C15，参数与任务规格一致）：
/// 随机输入全部由 seed 派生，每次运行结果确定，无 flaky 风险。
final class CatalogAvailabilityPropertyTests: XCTestCase {
    /// 固定 seed LCG（PCG 风格参数；首值锚定见 testPropertySeedSequenceDeterministic）。
    private struct SeededLCG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    // MARK: - 随机输入生成（全部由 seed 派生，确定性）

    private func randomKey(_ rng: inout SeededLCG) -> String {
        "s\(rng.next() % 5):\(rng.next() % 1000)"
    }

    private func randomDate(_ rng: inout SeededLCG) -> Date {
        Date(timeIntervalSince1970: Double(rng.next() % 5_000_000_000) - 1_000_000_000)
    }

    private func randomLifecycle(_ rng: inout SeededLCG) -> CatalogLifecycle? {
        switch rng.next() % 3 {
        case 0: return nil
        case 1: return .permanent
        default: return .seasonalCandidate
        }
    }

    /// 随机阶段表：0...3 个阶段，from < until 强制合法（畸形阶段不得进入随机宇宙）。
    private func randomTable(_ rng: inout SeededLCG) -> SeasonalPhaseTable {
        let phaseCount = Int(rng.next() % 4)
        var phases: [SeasonalPhase] = []
        for _ in 0..<phaseCount {
            let from = Date(timeIntervalSince1970: Double(rng.next() % 4_000_000_000) - 2_000_000_000)
            let until = from.addingTimeInterval(Double(rng.next() % 3_000_000_000) + 1)
            let keyCount = Int(rng.next() % 3) + 1
            var keys: [String] = []
            for _ in 0..<keyCount { keys.append(randomKey(&rng)) }
            phases.append(SeasonalPhase(
                phaseID: "p\(rng.next())", name: nil,
                from: from, until: until, itemKeys: keys))
        }
        return SeasonalPhaseTable(schemaVersion: 1, phases: phases)
    }

    // MARK: - seed 确定性

    /// seed 序列确定性锚定：同 seed 生成的序列逐值相等，且首值固定
    ///（首值 0x2CEAEE21BF46BC00 = 3236661110929538048 由固定参数计算得出；
    /// 漂移 → 全部性质用例不可复现，立即暴露）。
    func testPropertySeedSequenceDeterministic() {
        var first = SeededLCG()
        var second = SeededLCG()
        for _ in 0..<10 {
            XCTAssertEqual(first.next(), second.next(), "同 seed 序列必须逐值一致")
        }
        var probe = SeededLCG()
        XCTAssertEqual(probe.next(), 3_236_661_110_929_538_048,
                       "seed 序列首值漂移（LCG 参数被改）")
    }

    // MARK: - 性质

    /// 性质 1：permanent 声明恒 .permanent——任意表/任意日期（500 组随机输入）。
    func testPropertyPermanentIsInvariant() {
        var rng = SeededLCG()
        for _ in 0..<500 {
            let table = randomTable(&rng)
            let key = randomKey(&rng)
            let date = randomDate(&rng)
            XCTAssertEqual(
                table.availability(forItemKey: key, lifecycle: .permanent, at: date),
                .permanent,
                "permanent 声明不得被任何阶段表/日期覆盖")
        }
    }

    /// 性质 2：纯函数确定性——同输入两次调用结果相等（500 组）。
    func testPropertyDeterministic() {
        var rng = SeededLCG()
        for _ in 0..<500 {
            let table = randomTable(&rng)
            let key = randomKey(&rng)
            let date = randomDate(&rng)
            let lifecycle = randomLifecycle(&rng)
            XCTAssertEqual(
                table.availability(forItemKey: key, lifecycle: lifecycle, at: date),
                table.availability(forItemKey: key, lifecycle: lifecycle, at: date),
                "同输入两次调用必须相等")
        }
    }

    /// 性质 3：结果值域闭——{permanent, seasonal, unconfigured}；
    /// seasonal.status ∈ {notStarted, active, ended}（500 组全随机输入）。
    func testPropertyResultDomain() {
        var rng = SeededLCG()
        for _ in 0..<500 {
            let table = randomTable(&rng)
            let key = randomKey(&rng)
            let date = randomDate(&rng)
            let lifecycle = randomLifecycle(&rng)
            let result = table.availability(forItemKey: key, lifecycle: lifecycle, at: date)
            switch result {
            case .permanent, .unconfigured:
                break
            case .seasonal(_, _, let status):
                XCTAssertTrue(
                    status == .notStarted || status == .active || status == .ended,
                    "非法 seasonal status: \(status)")
            }
        }
    }

    /// 性质 4：时间边界一致性——单阶段（from < until 强制）五点采样：
    /// from-1s / from / until-1s / until / until+1s → notStarted/active/active/ended/ended
    ///（100 个随机阶段，每阶段独立 key 防多阶段干扰）。
    func testPropertyTimeBoundaryConsistency() {
        var rng = SeededLCG()
        for i in 0..<100 {
            let from = Date(timeIntervalSince1970: Double(rng.next() % 4_000_000_000) - 2_000_000_000)
            let until = from.addingTimeInterval(Double(rng.next() % 3_000_000_000) + 1)
            let key = "boundary:\(i)"
            let table = SeasonalPhaseTable(schemaVersion: 1, phases: [
                SeasonalPhase(phaseID: "b\(i)", name: nil,
                              from: from, until: until, itemKeys: [key]),
            ])
            let samples: [(Date, SeasonalStatus)] = [
                (from.addingTimeInterval(-1), .notStarted),
                (from, .active),
                (until.addingTimeInterval(-1), .active),
                (until, .ended),
                (until.addingTimeInterval(1), .ended),
            ]
            for (date, expected) in samples {
                guard case .seasonal(_, _, let status) = table.availability(
                    forItemKey: key, lifecycle: .seasonalCandidate, at: date) else {
                    XCTFail("i=\(i) date=\(date.timeIntervalSince1970): 阶段必须命中并返回 seasonal")
                    continue
                }
                XCTAssertEqual(
                    status, expected,
                    "i=\(i) date=\(date.timeIntervalSince1970)（from=\(from.timeIntervalSince1970) until=\(until.timeIntervalSince1970)）")
            }
        }
    }

    /// 性质 5：seasonal 的 phaseID 必须来自该 key 的候选阶段（不得引入表外阶段；
    /// 500 组随机表/随机 key/随机日期）。
    func testPropertySeasonalPhaseIDComesFromTable() {
        var rng = SeededLCG()
        for _ in 0..<500 {
            let table = randomTable(&rng)
            let key = randomKey(&rng)
            let date = randomDate(&rng)
            let result = table.availability(forItemKey: key, lifecycle: .seasonalCandidate, at: date)
            guard case .seasonal(let phaseID, _, _) = result else { continue }
            let candidates = table.phases.filter { $0.itemKeys.contains(key) }.map(\.phaseID)
            XCTAssertTrue(
                candidates.contains(phaseID),
                "phaseID \(phaseID) 不在 key \(key) 的候选阶段集 \(candidates)")
        }
    }
}
