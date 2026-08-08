import XCTest
@testable import COCHelperCore

/// Issue #70：三指标 property 测试（守恒/边界/状态完备）。
final class VillageProgressMetricsPropertyTests: XCTestCase {
    // MARK: - Helpers

    /// 断言失败时先打印复现上下文，再报失败；成功时静默（本地惯例，同 CoAPIPropertyTests）。
    private func assertOrFail(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !condition() {
            let contextText = context()
            print(contextText)
            XCTFail("\(message) | \(contextText)", file: file, line: line)
        }
    }

    /// 断言复现摘要：item 总数与 known/unknown 分布。
    private func itemsSummary(_ items: [VillageItemState]) -> String {
        let known = items.filter { VillageDetailProjection.isKnown($0) }.count
        return "count=\(items.count) known=\(known) unknown=\(items.count - known)"
    }

    // MARK: - 随机 item 生成

    /// 合法状态池：known 侧（complete/maxed/upgrading）与 unknown 侧（unknown/unverified）。
    /// 故意排除 .unavailable/.available：二者与 .unknown 同属 unknown 侧（isKnown == false，
    /// 见 VillageDetailProjection.isKnown），行为一致，无需重复覆盖。
    private static let knownStatuses: [VillageItemStatus] = [.complete, .maxed, .upgrading]
    private static let unknownStatuses: [VillageItemStatus] = [.unknown, .unverified]

    /// `levelLimitedToStage == true` 时 level 限定在 1...stageMax（用于
    /// stageRatio ≥ globalRatio 的专门生成器；聚合不变量只在全部 level ≤ stageMax
    /// 时成立——设计评审 Important-1）。
    /// level 允许 overhang（1...maxLevel+5，即 level 可超出 stageMax/maxLevel cap）：
    /// 专门探索实现里的 `min(level, cap)` 钳制路径（鉴别力来源）——无钳制实现会在
    /// level > cap 时产出 > 1 的 ratio 而被本测试捕获。
    private func randomItem(_ g: inout SeededGenerator, levelLimitedToStage: Bool = false) -> VillageItemState {
        let isKnownSide = g.bool()
        let status = isKnownSide
            ? Self.knownStatuses[g.int(in: 0...(Self.knownStatuses.count - 1))]
            : Self.unknownStatuses[g.int(in: 0...(Self.unknownStatuses.count - 1))]
        let maxLevel = g.int(in: 1...20)
        let stageMax = g.int(in: 1...maxLevel)
        let level: Int?
        if isKnownSide {
            let bound = levelLimitedToStage ? stageMax : (maxLevel + 5)
            level = g.int(in: 1...bound)
        } else {
            level = nil
        }
        let count = g.bool() ? g.int(in: 1...8) : 1
        return VillageItemState(
            id: "i\(g.int(in: 0...100_000))",
            section: "buildings",
            dataID: 1,
            base: .home,
            name: "item",
            category: .buildings,
            currentLevel: level,
            count: count,
            timerSeconds: status == .upgrading ? 3600 : nil,
            remainingSeconds: status == .upgrading ? 1800 : nil,
            nextLevel: status == .upgrading ? level.map { $0 + 1 } : nil,
            nextLevelDurationSeconds: status == .upgrading ? 3600 : nil,
            nextLevelDurationState: status == .upgrading ? .timed(seconds: 3600) : nil,
            maxLevel: isKnownSide ? maxLevel : nil,
            currentStageMaxLevel: isKnownSide ? stageMax : nil,
            status: status,
            missingReason: nil,
            catalogItemMissingReason: nil,
            availability: .unconfigured,
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: false,
            displayCategory: nil
        )
    }

    /// 随机 items；固定种子 70 可复现。iteration 从 0 起传入 body，供断言复现上下文。
    private func run(_ rounds: Int = 300, body: (Int, inout SeededGenerator) -> Void) {
        var g = SeededGenerator(seed: 70)
        for iteration in 0..<rounds { body(iteration, &g) }
    }

    // MARK: - Properties

    func testRatioWithinZeroOne() {
        run { iteration, g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items))"
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"), completeDenominator: g.bool())
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                if let ratio = metric.ratio {
                    assertOrFail(ratio >= 0 && ratio <= 1, "ratio \(ratio) out of [0,1]", context: context)
                }
                assertOrFail(metric.numerator >= 0, "numerator \(metric.numerator) < 0", context: context)
                assertOrFail(metric.denominator >= 0, "denominator \(metric.denominator) < 0", context: context)
            }
        }
    }

    func testConservationKnownPlusUnknownEqualsTotal() {
        run { iteration, g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items))"
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"), completeDenominator: g.bool())
            // 覆盖指标守恒（无饱和时）：已知 + 未知 == 观测总数。
            if !m.snapshotCoverage.saturated {
                let total = items.reduce(0) { $0 + ($1.instanceWeight) }
                let unknownWeight = VillageDetailProjection.instanceCountAndOverflow(
                    of: items.filter { !VillageDetailProjection.isKnown($0) }
                ).count
                assertOrFail(m.snapshotCoverage.denominator == total,
                             "coverage denominator \(m.snapshotCoverage.denominator) != total \(total)",
                             context: context)
                assertOrFail(m.snapshotCoverage.numerator <= total,
                             "coverage numerator \(m.snapshotCoverage.numerator) > total \(total)",
                             context: context)
                assertOrFail(m.snapshotCoverage.numerator + unknownWeight == total,
                             "coverage numerator \(m.snapshotCoverage.numerator) + unknownWeight \(unknownWeight) != total \(total)",
                             context: context)
            }
        }
    }

    func testStageRatioAtLeastGlobalRatioWhenLevelsWithinStage() {
        // 聚合不变量只在全部 level ≤ stageMax 时成立（设计评审 Important-1）：
        // 此时 stage = Σlevel/ΣstageMax ≥ Σlevel/ΣmaxLevel = global（分母小）。
        run { iteration, g in
            let items = (0..<g.int(in: 1...10)).map { _ in randomItem(&g, levelLimitedToStage: true) }
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items))"
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"), completeDenominator: g.bool())
            if !m.currentStageProgress.saturated && !m.globalProgress.saturated,
               let stage = m.currentStageProgress.ratio, let global = m.globalProgress.ratio {
                assertOrFail(stage >= global, "stage \(stage) < global \(global)", context: context)
            }
        }
    }

    func testUnusableCatalogAlwaysUnavailable() {
        run { iteration, g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items))"
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: false, compatibility: .unverified(gameVersion: "18.400.13"), completeDenominator: g.bool())
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                assertOrFail(metric.state == .unavailable, "state \(metric.state) != .unavailable", context: context)
                assertOrFail(metric.ratio == nil, "ratio \(String(describing: metric.ratio)) != nil", context: context)
            }
        }
    }

    func testStateCompletenessAndConsistency() {
        run { iteration, g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items))"
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: g.bool(),
                                                      compatibility: g.bool() ? .verified(gameVersion: "x") : .unverified(gameVersion: "x"),
                                                      completeDenominator: g.bool())
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                assertOrFail(ProgressMetricState.allCases.contains(metric.state),
                             "state \(metric.state) not in allCases", context: context)
                switch metric.state {
                case .ready, .partial:
                    assertOrFail(metric.denominator > 0,
                                 "denominator \(metric.denominator) <= 0 for state \(metric.state)", context: context)
                    // 未饱和的可计算状态必须产出 ratio（fail-open 是假精度，fail-closed 才是异常）。
                    if !metric.saturated {
                        assertOrFail(metric.ratio != nil,
                                     "ratio nil while state \(metric.state) not saturated", context: context)
                    }
                case .unavailable, .unknown:
                    assertOrFail(metric.ratio == nil,
                                 "ratio \(String(describing: metric.ratio)) != nil for state \(metric.state)", context: context)
                }
            }
        }
    }

    func testSaturationFailsClosed() {
        run(200) { iteration, g in
            // 混入两条 count = Int.max 的恶意数据（currentLevel=3/maxLevel=10/stageMax=6）：
            // - 等级式指标（currentStage/global）：3×Int.max 乘法溢出 → 恒饱和；
            // - coverage 纯加法：2×Int.max 也必溢出 → 恒饱和。
            // 固定为两条而不是随机数量，保证 coverage 加法溢出与随机种子无关（不 flaky）。
            let malicious = (0..<2).map { i in
                VillageItemState(
                    id: "mal\(i)",
                    section: "buildings", dataID: 2, base: .home, name: "mal",
                    category: .buildings, currentLevel: 3, count: Int.max,
                    timerSeconds: nil, remainingSeconds: nil, nextLevel: nil,
                    nextLevelDurationSeconds: nil, nextLevelDurationState: nil,
                    maxLevel: 10, currentStageMaxLevel: 6, status: .complete,
                    missingReason: nil, catalogItemMissingReason: nil,
                    availability: .unconfigured, icon: nil, levelVisual: nil,
                    currentLevelIcon: nil, currentLevelVisual: nil,
                    isNested: false, displayCategory: nil
                )
            }
            let items = malicious + (0..<g.int(in: 0...3)).map { _ in randomItem(&g) }
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items))"
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"), completeDenominator: g.bool())
            // fail-closed：饱和 → ratio 恒 nil，UI 显示异常而非假精度。
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                assertOrFail(metric.saturated,
                             "metric \(metric.kind.rawValue) not saturated", context: context)
                assertOrFail(metric.ratio == nil,
                             "metric \(metric.kind.rawValue) ratio \(String(describing: metric.ratio)) != nil", context: context)
            }
        }
    }
}
