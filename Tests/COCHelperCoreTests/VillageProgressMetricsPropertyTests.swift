import XCTest
@testable import COCHelperCore

/// Issue #70：三指标 property 测试（守恒/边界/状态完备）。
final class VillageProgressMetricsPropertyTests: XCTestCase {
    // MARK: - 随机 item 生成

    /// 合法状态池：known 侧（complete/maxed/upgrading）与 unknown 侧（unknown/unverified）。
    private static let knownStatuses: [VillageItemStatus] = [.complete, .maxed, .upgrading]
    private static let unknownStatuses: [VillageItemStatus] = [.unknown, .unverified]

    /// `levelLimitedToStage == true` 时 level 限定在 1...stageMax（用于
    /// stageRatio ≥ globalRatio 的专门生成器；聚合不变量只在全部 level ≤ stageMax
    /// 时成立——设计评审 Important-1）。
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

    /// 随机 items；固定种子 70 可复现。
    private func run(_ rounds: Int = 300, body: (inout SeededGenerator) -> Void) {
        var g = SeededGenerator(seed: 70)
        for _ in 0..<rounds { body(&g) }
    }

    // MARK: - Properties

    func testRatioWithinZeroOne() {
        run { g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"))
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                if let ratio = metric.ratio {
                    XCTAssertTrue(ratio >= 0 && ratio <= 1, "ratio \(ratio) out of [0,1]")
                }
                XCTAssertGreaterThanOrEqual(metric.numerator, 0)
                XCTAssertGreaterThanOrEqual(metric.denominator, 0)
            }
        }
    }

    func testConservationKnownPlusUnknownEqualsTotal() {
        run { g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"))
            // 覆盖指标守恒：已知 + 未知 == 观测总数（无饱和时）
            if !m.snapshotCoverage.saturated {
                let total = items.reduce(0) { $0 + ($1.instanceWeight) }
                XCTAssertEqual(m.snapshotCoverage.denominator, total)
                XCTAssertLessThanOrEqual(m.snapshotCoverage.numerator, total)
            }
        }
    }

    func testStageRatioAtLeastGlobalRatioWhenLevelsWithinStage() {
        // 聚合不变量只在全部 level ≤ stageMax 时成立（设计评审 Important-1）：
        // 此时 stage = Σlevel/ΣstageMax ≥ Σlevel/ΣmaxLevel = global（分母小）。
        run { g in
            let items = (0..<g.int(in: 1...10)).map { _ in randomItem(&g, levelLimitedToStage: true) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"))
            if !m.currentStageProgress.saturated && !m.globalProgress.saturated,
               let stage = m.currentStageProgress.ratio, let global = m.globalProgress.ratio {
                XCTAssertGreaterThanOrEqual(stage, global)
            }
        }
    }

    func testUnusableCatalogAlwaysUnavailable() {
        run { g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: false, compatibility: .unverified(gameVersion: "18.400.13"))
            XCTAssertEqual(m.currentStageProgress.state, .unavailable)
            XCTAssertEqual(m.globalProgress.state, .unavailable)
            XCTAssertEqual(m.snapshotCoverage.state, .unavailable)
            XCTAssertNil(m.currentStageProgress.ratio)
        }
    }

    func testStateCompletenessAndConsistency() {
        run { g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: g.bool(),
                                                      compatibility: g.bool() ? .verified(gameVersion: "x") : .unverified(gameVersion: "x"))
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                XCTAssertTrue(ProgressMetricState.allCases.contains(metric.state))
                switch metric.state {
                case .ready, .partial:
                    XCTAssertGreaterThan(metric.denominator, 0)
                case .unavailable:
                    XCTAssertNil(metric.ratio)
                case .unknown:
                    XCTAssertNil(metric.ratio)
                }
            }
        }
    }

    func testSaturationNeverCrashes() {
        run(200) { g in
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
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"))
            // 三条指标全部饱和（fail-closed：饱和 → ratio 恒 nil，UI 显示异常而非假精度）
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                XCTAssertTrue(metric.saturated)
                XCTAssertNil(metric.ratio)
            }
        }
    }
}
