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
    /// `allowsNeedsReimport == false` 时已知侧 upgrading 项固定为进行中形态
    ///（性质 3「ready ⟺ 覆盖率 100%」用：该性质依赖 unknown/available 与
    /// unknownWeight 的一一对应，needsReimport 项会破坏判别，见性质 3 注释）。
    private func randomItem(
        _ g: inout SeededGenerator,
        levelLimitedToStage: Bool = false,
        allowsNeedsReimport: Bool = true
    ) -> VillageItemState {
        let isKnownSide = g.bool()
        let status = isKnownSide
            ? Self.knownStatuses[g.int(in: 0...(Self.knownStatuses.count - 1))]
            : Self.unknownStatuses[g.int(in: 0...(Self.unknownStatuses.count - 1))]
        // 评审 B：小概率（~15%）把 known 侧 upgrading 项改为 needsReimport 形态
        //（timer 存在 + remaining 0，计时结束待重新导入）。该形态 isKnown 为
        // true（status/maxLevel/level 均满足）但实现按 !needsReimport 过滤归
        // unknown 侧（VillageProgressMetrics known 过滤）——生成器必须覆盖，
        // 否则该过滤在 property 套件无守卫。
        let isNeedsReimport = allowsNeedsReimport && isKnownSide && status == .upgrading
            && g.double(in: 0...1) < 0.15
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
            remainingSeconds: status == .upgrading ? (isNeedsReimport ? 0 : 1800) : nil,
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

    /// 宇宙差集项生成器（Issue #70 阶段 2）：每个候选键随机 TH（1...18）与
    /// 宇宙 count（0...10，模拟宇宙表 [TH-1] 取值）；count == 0 不产出
    ///（该 TH 不可建造，与 universeSupplement 语义一致）。产出项形态与投影
    /// 合成一致：status .available、currentLevel 0、count = 宇宙数、
    /// maxLevel/currentStageMaxLevel 随机（目录 join 值）。
    private func randomUniverseDiff(_ g: inout SeededGenerator, keyCount: Int) -> [VillageItemState] {
        var items: [VillageItemState] = []
        for index in 0..<keyCount {
            let townHall = g.int(in: 1...18)
            let universeCount = g.int(in: 0...10)
            guard universeCount > 0 else { continue }
            let maxLevel = g.int(in: 1...20)
            let stageMax = g.int(in: 1...maxLevel)
            items.append(VillageItemState(
                id: "u\(townHall).\(index)",
                section: "buildings",
                dataID: 2,
                base: .home,
                name: "universe",
                category: .buildings,
                currentLevel: 0,
                count: universeCount,
                timerSeconds: nil,
                remainingSeconds: nil,
                nextLevel: nil,
                nextLevelDurationSeconds: nil,
                nextLevelDurationState: nil,
                maxLevel: maxLevel,
                currentStageMaxLevel: stageMax,
                status: .available,
                missingReason: nil,
                catalogItemMissingReason: nil,
                availability: .unconfigured,
                icon: nil,
                levelVisual: nil,
                currentLevelIcon: nil,
                currentLevelVisual: nil,
                isNested: false,
                displayCategory: nil
            ))
        }
        return items
    }

    /// 差集权重（独立计算，供守恒断言对照实现口径——ProgressMetric 不暴露
    /// 该字段，只折叠进 degradedReason）。
    private func availableWeight(of items: [VillageItemState]) -> Int {
        VillageDetailProjection.instanceCountAndOverflow(
            of: items.filter { $0.status == .available }
        ).count
    }

    /// Issue #96：coverage 三态生成器。partial 随机携带一个非空诊断集合
    ///（不变量：至少一个集合非空）。
    private func randomCoverage(_ g: inout SeededGenerator) -> ProgressUniverseCoverage {
        switch g.int(in: 0...2) {
        case 0: return .unavailable
        case 1: return .complete
        default:
            let missing: Set<String> = g.bool()
                ? ["units", "spells"] : []
            let unmodeled: Set<TrackerCategory> = g.bool()
                ? [.troops, .heroes] : []
            if missing.isEmpty && unmodeled.isEmpty {
                return .partial(missingSections: ["units"], unmodeledCategories: [])
            }
            return .partial(missingSections: missing, unmodeledCategories: unmodeled)
        }
    }

    // MARK: - Properties

    func testRatioWithinZeroOne() {
        run { iteration, g in
            let items = (0..<g.int(in: 0...20)).map { _ in randomItem(&g) }
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items))"
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"), coverage: randomCoverage(&g))
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
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"), coverage: randomCoverage(&g))
            // 覆盖指标守恒（无饱和时）：已知 + 未知 == 观测总数。
            // unknown 口径与实现一致：!isKnown **或** needsReimport（needsReimport
            // 项 isKnown 为 true 但实现归 unknown 侧，VillageProgressMetrics 过滤）。
            if !m.snapshotCoverage.saturated {
                let total = items.reduce(0) { $0 + ($1.instanceWeight) }
                let unknownWeight = VillageDetailProjection.instanceCountAndOverflow(
                    of: items.filter { !VillageDetailProjection.isKnown($0) || $0.needsReimport }
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
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"), coverage: randomCoverage(&g))
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
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: false, compatibility: .unverified(gameVersion: "18.400.13"), coverage: randomCoverage(&g))
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
                                                      coverage: randomCoverage(&g))
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
            let m = VillageProgressProjection.metrics(from: items, catalogIsUsable: true, compatibility: .verified(gameVersion: "18.400.13"), coverage: randomCoverage(&g))
            // fail-closed：饱和 → ratio 恒 nil，UI 显示异常而非假精度。
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                assertOrFail(metric.saturated,
                             "metric \(metric.kind.rawValue) not saturated", context: context)
                assertOrFail(metric.ratio == nil,
                             "metric \(metric.kind.rawValue) ratio \(String(describing: metric.ratio)) != nil", context: context)
            }
        }
    }

    // MARK: - Issue #70 阶段 2：宇宙差集（.available）混入

    /// 性质 1（含差集）：ratio 恒在 [0,1]——available 项 level 0 分子贡献恒 0，
    /// 只撑大分母，任何计数/上限组合不得产出越界 ratio；numerator/denominator 非负。
    func testRatioWithinZeroOneWithUniverseDiff() {
        run { iteration, g in
            let observed = (0..<g.int(in: 0...15)).map { _ in randomItem(&g) }
            let diff = randomUniverseDiff(&g, keyCount: g.int(in: 0...8))
            let items = observed + diff
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items)) diff=\(diff.count)"
            let m = VillageProgressProjection.metrics(
                from: items, catalogIsUsable: true,
                compatibility: .verified(gameVersion: "18.400.13"),
                coverage: randomCoverage(&g)
            )
            for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
                if let ratio = metric.ratio {
                    assertOrFail(ratio >= 0 && ratio <= 1, "ratio \(ratio) out of [0,1]", context: context)
                }
                assertOrFail(metric.numerator >= 0, "numerator \(metric.numerator) < 0", context: context)
                assertOrFail(metric.denominator >= 0, "denominator \(metric.denominator) < 0", context: context)
            }
        }
    }

    /// 性质 2（覆盖守恒，含差集）：known + unknown(非差集) + available(差集) ==
    /// 全部实例权重——差集项与 unknown 各自独立计入分母（各自独立降级文案），
    /// 互不混算、不遗漏（无饱和时）。
    func testCoverageConservationWithUniverseDiff() {
        run { iteration, g in
            let observed = (0..<g.int(in: 0...15)).map { _ in randomItem(&g) }
            let diff = randomUniverseDiff(&g, keyCount: g.int(in: 0...8))
            let items = observed + diff
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items)) diff=\(diff.count)"
            let m = VillageProgressProjection.metrics(
                from: items, catalogIsUsable: true,
                compatibility: .verified(gameVersion: "18.400.13"),
                coverage: randomCoverage(&g)
            )
            let coverage = m.snapshotCoverage
            guard !coverage.saturated else { return }
            let total = items.reduce(0) { $0 + $1.instanceWeight }
            // 口径与实现一致：!isKnown || needsReimport（needsReimport 项 isKnown
            // 为 true 但实现归 unknown 侧）——差集项（.available）单独计入。
            let unknownWeight = VillageDetailProjection.instanceCountAndOverflow(
                of: items.filter {
                    $0.status != .available
                        && (!VillageDetailProjection.isKnown($0) || $0.needsReimport)
                }
            ).count
            let diffWeight = availableWeight(of: items)
            assertOrFail(coverage.denominator == total,
                         "coverage denominator \(coverage.denominator) != total \(total)",
                         context: context)
            assertOrFail(coverage.numerator <= total,
                         "coverage numerator \(coverage.numerator) > total \(total)",
                         context: context)
            assertOrFail(coverage.numerator + unknownWeight + diffWeight == total,
                         "coverage \(coverage.numerator) + unknown \(unknownWeight) + diff \(diffWeight) != total \(total)",
                         context: context)
        }
    }

    /// 性质 3（验收 2/决策 5）：coverage .complete 时 stage/global 只有
    /// 覆盖率 100%（无 unknown、无宇宙差集）才可达 ready；任一未观测/差集存在
    /// → 覆盖率 < 100% 且 stage/global 不伪装 ready（partial 或 unknown）。
    /// 反向：覆盖率 100% 时必然无 unknown 无 available。
    /// 生成器固定不产 needsReimport（allowsNeedsReimport: false）：needsReimport
    /// 项 isKnown 为 true 但实现归 unknown 侧（unknownWeight > 0 → partial）——
    /// 若混入，测试的「无 unknown 无 available」判别会与实现口径错位（无 unknown
    /// 无 available 却 partial），性质 3 的 ready ⟺ 100% 判别失效。needsReimport
    /// 的降级语义由性质 2 守恒断言与单元测试 testNeedsReimportExcludedFromKnownAndDegrades 覆盖。
    func testReadyOnlyWhenCoverageComplete() {
        run { iteration, g in
            let observed = (0..<g.int(in: 0...15)).map { _ in randomItem(&g, allowsNeedsReimport: false) }
            let diff = randomUniverseDiff(&g, keyCount: g.int(in: 0...8))
            let items = observed + diff
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items)) diff=\(diff.count)"
            let m = VillageProgressProjection.metrics(
                from: items, catalogIsUsable: true,
                compatibility: .verified(gameVersion: "18.400.13"),
                coverage: .complete
            )
            guard let coverageRatio = m.snapshotCoverage.ratio else { return }  // 空集/饱和：无可断言
            let hasUnknown = items.contains { $0.status != .available && !VillageDetailProjection.isKnown($0) }
            let hasDiff = items.contains { $0.status == .available }
            if !hasUnknown && !hasDiff {
                assertOrFail(coverageRatio == 1.0, "coverage \(coverageRatio) != 1 但无 unknown/差集", context: context)
                assertOrFail(m.currentStageProgress.state == .ready,
                             "stage \(m.currentStageProgress.state) != .ready 当覆盖率 100%", context: context)
                assertOrFail(m.globalProgress.state == .ready,
                             "global \(m.globalProgress.state) != .ready 当覆盖率 100%", context: context)
            } else {
                assertOrFail(coverageRatio < 1.0, "coverage \(coverageRatio) 未随 unknown/差集下降", context: context)
                // 覆盖不全 → 不得伪装 ready：有可计算分母时为 partial（unknown/
                // 差集降级文案），全 unknown 无分母时为 unknown（空 denominator）。
                assertOrFail(m.currentStageProgress.state != .ready,
                             "stage \(m.currentStageProgress.state) == .ready 当覆盖率 < 100%", context: context)
                assertOrFail(m.globalProgress.state != .ready,
                             "global \(m.globalProgress.state) == .ready 当覆盖率 < 100%", context: context)
            }
        }
    }

    /// 性质 4（阶段 1 数值一致性）：coverage 非 complete（partial，unmodeled
    /// 非空 → 覆盖诊断存在，但不影响本性质数值）时 available 不进
    /// stage/global 分母——数值必须与「去掉差集项后的完整
    /// 口径计算」完全一致（对照纯 known/unknown 计算；state 允许不同：
    /// 非 complete 强制 partial）。
    func testIncompleteDenominatorIgnoresAvailableNumerics() {
        run { iteration, g in
            let observed = (0..<g.int(in: 0...15)).map { _ in randomItem(&g) }
            let diff = randomUniverseDiff(&g, keyCount: g.int(in: 0...8))
            let items = observed + diff
            let context = "seed=70 iteration=\(iteration) \(itemsSummary(items)) diff=\(diff.count)"
            let incomplete = VillageProgressProjection.metrics(
                from: items, catalogIsUsable: true,
                compatibility: .verified(gameVersion: "18.400.13"),
                coverage: .partial(missingSections: [], unmodeledCategories: [.troops])
            )
            let knownOnly = items.filter { $0.status != .available }
            let completeKnownOnly = VillageProgressProjection.metrics(
                from: knownOnly, catalogIsUsable: true,
                compatibility: .verified(gameVersion: "18.400.13"),
                coverage: .complete
            )
            for (name, lhs, rhs) in [
                ("stage", incomplete.currentStageProgress, completeKnownOnly.currentStageProgress),
                ("global", incomplete.globalProgress, completeKnownOnly.globalProgress),
            ] {
                if lhs.saturated || rhs.saturated { continue }
                assertOrFail(lhs.numerator == rhs.numerator,
                             "\(name) numerator \(lhs.numerator) != 去差集计算 \(rhs.numerator)", context: context)
                assertOrFail(lhs.denominator == rhs.denominator,
                             "\(name) denominator \(lhs.denominator) != 去差集计算 \(rhs.denominator)", context: context)
            }
        }
    }

    /// Issue #96 property：coverage 非 complete 时 stage/global 绝无 .ready
    ///（分母为已观测项目 → 强制 partial；unknown/unavailable 由既有规则）。
    func testNonCompleteCoverageNeverReady() {
        for seed in 0..<500 {
            var g = SeededGenerator(seed: UInt32(seed))
            var items: [VillageItemState] = []
            let n = g.int(in: 1...8)
            for _ in 0..<n {
                items.append(randomItem(&g, allowsNeedsReimport: false))
            }
            for coverage in [
                ProgressUniverseCoverage.unavailable,
                .partial(missingSections: ["units"], unmodeledCategories: []),
                .partial(missingSections: [], unmodeledCategories: [.troops]),
            ] {
                let m = VillageProgressProjection.metrics(
                    from: items, catalogIsUsable: true,
                    compatibility: .verified(gameVersion: "18.400.13"),
                    coverage: coverage
                )
                assertOrFail(
                    m.currentStageProgress.state != .ready,
                    "非 complete coverage 不得 ready",
                    context: "seed=\(seed) coverage=\(coverage) \(itemsSummary(items))"
                )
                assertOrFail(
                    m.globalProgress.state != .ready,
                    "非 complete coverage 不得 ready",
                    context: "seed=\(seed) coverage=\(coverage) \(itemsSummary(items))"
                )
            }
        }
    }
}
