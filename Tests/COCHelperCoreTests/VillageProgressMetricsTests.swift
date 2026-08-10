import XCTest
@testable import COCHelperCore

/// Issue #70：三指标（当前阶段进度/全局养成进度/观测数据完整性）。
final class VillageProgressMetricsTests: XCTestCase {
    // MARK: - Helpers（与 VillageDetailProjectionTests 同构）

    private func item(
        id: String = "id",
        status: VillageItemStatus = .complete,
        level: Int? = 3,
        maxLevel: Int? = 10,
        stageMax: Int? = 6,
        count: Int? = 1,
        isUpgrading: Bool = false,
        nextLevel: Int? = nil,
        countOverflowed: Bool = false
    ) -> VillageItemState {
        let effectiveNext = nextLevel ?? (isUpgrading ? level.map { $0 + 1 } : nil)
        return VillageItemState(
            id: id,
            section: "buildings",
            dataID: 1,
            base: .home,
            name: "item-" + id,
            category: .buildings,
            currentLevel: level,
            count: count,
            timerSeconds: isUpgrading ? 3600 : nil,
            remainingSeconds: isUpgrading ? 1800 : nil,
            nextLevel: effectiveNext,
            nextLevelDurationSeconds: isUpgrading ? 3600 : nil,
            nextLevelDurationState: isUpgrading ? .timed(seconds: 3600) : nil,
            maxLevel: maxLevel,
            currentStageMaxLevel: stageMax,
            status: status,
            missingReason: nil,
            catalogItemMissingReason: nil,
            availability: .unconfigured,
            icon: nil,
            levelVisual: nil,
            currentLevelIcon: nil,
            currentLevelVisual: nil,
            isNested: false,
            displayCategory: nil,
            countOverflowed: countOverflowed
        )
    }

    /// 直接构造「计时已结束待重新导入」形态（`item()` 的 timer 由 isUpgrading
    /// 硬编码无法表达 timerSeconds 非 nil + remainingSeconds == 0），仿
    /// VillageDetailProjectionTests.needsReimportRow：status .upgrading 但
    /// remainingSeconds == 0 → isUpgrading false → isKnown 放行（旧逻辑误入
    /// known 的形态），needsReimport 谓词为 true。
    private func needsReimportItem(
        id: String = "id",
        level: Int = 3,
        maxLevel: Int = 10,
        stageMax: Int? = 6,
        count: Int? = 1
    ) -> VillageItemState {
        VillageItemState(
            id: id,
            section: "buildings",
            dataID: 1,
            base: .home,
            name: "item-" + id,
            category: .buildings,
            currentLevel: level,
            count: count,
            timerSeconds: 3600,
            remainingSeconds: 0,
            nextLevel: level + 1,
            nextLevelDurationSeconds: 3600,
            nextLevelDurationState: .timed(seconds: 3600),
            maxLevel: maxLevel,
            currentStageMaxLevel: stageMax,
            status: .upgrading,
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

    private func metrics(_ items: [VillageItemState],
                         usable: Bool = true,
                         compatibility: CatalogCompatibility? = .verified(gameVersion: "18.400.13"),
                         coverage: ProgressUniverseCoverage = .complete) -> VillageProgressMetrics {
        VillageProgressProjection.metrics(
            from: items,
            catalogIsUsable: usable,
            compatibility: compatibility,
            coverage: coverage
        )
    }

    // MARK: - currentStageProgress

    func testStageProgressReadyComputesLevelRatio() {
        // 2 个实例：level 3/6、level 5/6 → (3+5)/(6+6) = 8/12
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6),
        ]
        let m = metrics(items).currentStageProgress
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.numerator, 8)
        XCTAssertEqual(m.denominator, 12)
        XCTAssertEqual(m.ratio ?? -1, 8.0 / 12.0, accuracy: 1e-9)
        XCTAssertNil(m.degradedReason)
        XCTAssertEqual(m.units, "级")
    }

    func testStageProgressCapsLevelAtStageMax() {
        // level 8 > stageMax 6 → 分子贡献 min(8,6)=6（封顶）
        let m = metrics([item(id: "a", level: 8, maxLevel: 10, stageMax: 6)]).currentStageProgress
        XCTAssertEqual(m.numerator, 6)
        XCTAssertEqual(m.denominator, 6)
        XCTAssertEqual(m.ratio, 1.0)
    }

    func testStageProgressPartialWhenUnknownExists() {
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "u", status: .unknown, level: nil, maxLevel: nil, stageMax: nil),
        ]
        let m = metrics(items).currentStageProgress
        XCTAssertEqual(m.state, .partial)
        XCTAssertEqual(m.numerator, 3)
        XCTAssertEqual(m.denominator, 6)
        XCTAssertEqual(m.ratio, 0.5)
        XCTAssertNotNil(m.degradedReason)
    }

    func testStageProgressExcludesUnverifiedFromDenominator() {
        // unverified 项不计入 known（#67 fail-closed）→ 分母只有 known 项
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "v", status: .unverified, level: 4, maxLevel: 10, stageMax: nil),
        ]
        let m = metrics(items).currentStageProgress
        XCTAssertEqual(m.denominator, 6)
        XCTAssertEqual(m.state, .partial) // unverified 归未知侧 → partial
    }

    func testStageProgressUnavailableWhenCatalogNotUsable() {
        let m = metrics([item(id: "a", level: 3, maxLevel: 10, stageMax: 6)], usable: false)
        XCTAssertEqual(m.currentStageProgress.state, .unavailable)
        XCTAssertNil(m.currentStageProgress.ratio)
        XCTAssertEqual(m.globalProgress.state, .unavailable)
        XCTAssertEqual(m.snapshotCoverage.state, .unavailable)
    }

    func testStageProgressUnknownWhenNoEligible() {
        let m = metrics([item(id: "u", status: .unknown, level: nil, maxLevel: nil, stageMax: nil)])
        XCTAssertEqual(m.currentStageProgress.state, .unknown)
        XCTAssertNil(m.currentStageProgress.ratio)
    }

    func testEmptyItemsAllUnknown() {
        let m = metrics([])
        XCTAssertEqual(m.currentStageProgress.state, .unknown)
        XCTAssertEqual(m.globalProgress.state, .unknown)
        XCTAssertEqual(m.snapshotCoverage.state, .unknown)
    }

    // MARK: - globalProgress

    func testGlobalProgressReady() {
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6),
        ]
        let m = metrics(items).globalProgress
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.numerator, 8)
        XCTAssertEqual(m.denominator, 20)
        XCTAssertEqual(m.ratio, 0.4)
    }

    func testGlobalProgressCapsLevelAtMaxLevel() {
        // 版本不匹配遗留：level 12 > maxLevel 10（非 upgrading 时 isKnown 放行）→ 封顶
        let m = metrics([item(id: "a", level: 12, maxLevel: 10, stageMax: 6)]).globalProgress
        XCTAssertEqual(m.numerator, 10)
        XCTAssertEqual(m.denominator, 10)
        XCTAssertEqual(m.ratio, 1.0)
    }

    func testStageRatioIsAtLeastGlobalRatio() {
        // 单实例 stageRatio ≥ globalRatio（stageMax ≤ maxLevel 时恒成立）
        for (level, stageMax, maxLevel) in [(3, 6, 10), (6, 6, 10), (9, 6, 10), (12, 6, 10)] {
            let items = [item(id: "a", level: level, maxLevel: maxLevel, stageMax: stageMax)]
            let m = metrics(items)
            let stage = m.currentStageProgress.ratio!
            let global = m.globalProgress.ratio!
            XCTAssertGreaterThanOrEqual(stage, global, "level=\(level) stageMax=\(stageMax) maxLevel=\(maxLevel)")
        }
    }

    // MARK: - snapshotCoverage

    func testCoverageCountsKnownOverObserved() {
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),          // known
            item(id: "u", status: .unknown, level: nil, maxLevel: nil, stageMax: nil), // unknown
        ]
        let m = metrics(items).snapshotCoverage
        XCTAssertEqual(m.state, .partial)
        XCTAssertEqual(m.numerator, 1)
        XCTAssertEqual(m.denominator, 2)
        XCTAssertEqual(m.ratio, 0.5)
        XCTAssertEqual(m.units, "实例")
    }

    func testCoverageReadyWhenAllKnown() {
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6),
        ]
        let m = metrics(items).snapshotCoverage
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.numerator, 2)
        XCTAssertEqual(m.denominator, 2)
        XCTAssertEqual(m.ratio, 1.0)
    }

    // MARK: - 实例权重（#66）

    func testMetricsUseInstanceWeight() {
        // count = 6 → 权重 6：分子 3×6=18，分母 6×6=36
        let items = [item(id: "a", level: 3, maxLevel: 10, stageMax: 6, count: 6)]
        let m = metrics(items)
        XCTAssertEqual(m.currentStageProgress.denominator, 36)  // 6 × 6
        XCTAssertEqual(m.currentStageProgress.numerator, 18)   // 3 × 6
        XCTAssertEqual(m.snapshotCoverage.numerator, 6)
        XCTAssertEqual(m.snapshotCoverage.denominator, 6)
    }

    // MARK: - unverified 目录（决策 2：显式映射 partial）

    func testUnverifiedCatalogDegradesToPartial() {
        let items = [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)]
        let m = metrics(items, compatibility: .unverified(gameVersion: "18.400.13"))
        XCTAssertEqual(m.currentStageProgress.state, .partial)
        XCTAssertEqual(m.globalProgress.state, .partial)
        XCTAssertEqual(m.snapshotCoverage.state, .partial)
        XCTAssertNotNil(m.currentStageProgress.degradedReason)
        XCTAssertEqual(m.currentStageProgress.ratio, 0.5)
    }

    func testVerifiedCatalogKeepsReady() {
        let items = [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)]
        let m = metrics(items, compatibility: .verified(gameVersion: "18.400.13"))
        XCTAssertEqual(m.currentStageProgress.state, .ready)
    }

    // MARK: - 饱和（#66 fail-closed）

    func testSaturatedFailsClosed() {
        let items = [item(id: "a", level: 3, maxLevel: 10, stageMax: 6, count: Int.max)]
        let m = metrics(items)
        XCTAssertTrue(m.currentStageProgress.saturated)
        XCTAssertNil(m.currentStageProgress.ratio)
        // 单条 count=Int.max 求和恰为 Int.max 无溢出（#66 第 7 轮契约：
        // 「恰好 Int.max 是精确算术」不算饱和）——coverage 饱和只由求和溢出
        // 或链路饱和标志触发，与 currentStage（6 × Int.max 乘法溢出）不同。
        XCTAssertFalse(m.snapshotCoverage.saturated)
    }

    func testSaturatedDoesNotCrash() {
        // 两条 Int.max 相加溢出 → 饱和不崩溃
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6, count: Int.max),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6, count: Int.max),
        ]
        let m = metrics(items)
        XCTAssertTrue(m.currentStageProgress.saturated)
        XCTAssertTrue(m.globalProgress.saturated)
        XCTAssertTrue(m.snapshotCoverage.saturated)
    }

    // MARK: - countOverflowed 传播（评审修复）

    func testCountOverflowedPropagatesToSaturated() {
        // 聚合行 countOverflowed=true 且 value 贡献 1×Int.max 无算术溢出（1×Int.max
        // 恰好 Int.max），但原始多条记录权重和已超上限——必须由链路标志补位上报
        // 饱和（#66 第 7 轮契约），否则分母 Int.max 会展示出假精度。
        let items = [item(id: "a", level: 1, maxLevel: 1, stageMax: 1, count: Int.max, countOverflowed: true)]
        let m = metrics(items)
        XCTAssertTrue(m.currentStageProgress.saturated)
        XCTAssertTrue(m.globalProgress.saturated)
        XCTAssertNil(m.currentStageProgress.ratio)
        XCTAssertNil(m.globalProgress.ratio)
    }

    // MARK: - 负等级防御（评审修复）

    func testNegativeLevelContributesZero() {
        // level -5 → max(0, -5)=0 → 分子贡献 0，ratio ≥ 0 恒成立
        let m = metrics([item(id: "a", level: -5, maxLevel: 10, stageMax: 6)])
        XCTAssertEqual(m.currentStageProgress.numerator, 0)
        XCTAssertEqual(m.currentStageProgress.denominator, 6)
        XCTAssertEqual(m.currentStageProgress.ratio ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(m.globalProgress.numerator, 0)
        XCTAssertEqual(m.globalProgress.denominator, 10)
        XCTAssertEqual(m.globalProgress.ratio ?? -1, 0.0, accuracy: 1e-9)
    }

    // MARK: - 降级文案（评审补测）

    func testUnavailableMetricsAllNilRatioWithReason() {
        let m = metrics([item(id: "a", level: 3, maxLevel: 10, stageMax: 6)], usable: false)
        XCTAssertNil(m.currentStageProgress.ratio)
        XCTAssertNil(m.globalProgress.ratio)
        XCTAssertNil(m.snapshotCoverage.ratio)
        for metric in [m.currentStageProgress, m.globalProgress, m.snapshotCoverage] {
            XCTAssertEqual(metric.degradedReason, "目录不可用或版本不匹配，暂无法计算该指标。")
        }
    }

    func testUnknownDegradedReasonText() {
        let m = metrics([])
        XCTAssertEqual(m.currentStageProgress.degradedReason, "无可确认项目，暂无法计算")
        XCTAssertEqual(m.globalProgress.degradedReason, "无可确认项目，暂无法计算")
        XCTAssertEqual(m.snapshotCoverage.degradedReason, "尚未导入快照")
    }

    func testDegradedReasonsConcatenatedWhenUnknownAndUnverified() {
        // 未知项权重 > 0 与未验证目录并存 → 两条原因拼接展示
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "u", status: .unknown, level: nil, maxLevel: nil, stageMax: nil),
        ]
        let m = metrics(items, compatibility: .unverified(gameVersion: "18.400.13")).currentStageProgress
        XCTAssertEqual(m.state, .partial)
        let reason = m.degradedReason!
        XCTAssertTrue(reason.contains("1 项未知或待重新导入，结果仅为已观测项目。"), reason)
        XCTAssertTrue(reason.contains("目录与玩家版本未验证，百分比可能过时。"), reason)
    }

    func testSaturatedAndPartialKeepsStatePartialRatioNil() {
        // 1 条 count=Int.max 的 known 项（stage 乘法溢出饱和）+ 1 条 unknown 项 →
        // state 仍 .partial（饱和不改变 state，UI 层饱和优先），ratio 恒 nil
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6, count: Int.max),
            item(id: "u", status: .unknown, level: nil, maxLevel: nil, stageMax: nil),
        ]
        let m = metrics(items).currentStageProgress
        XCTAssertEqual(m.state, .partial)
        XCTAssertTrue(m.saturated)
        XCTAssertNil(m.ratio)
    }

    // MARK: - needsReimport（实现要求 4：降级而非假精度）

    func testNeedsReimportExcludedFromKnownAndDegrades() {
        // 计时结束待重新导入：等级为最后记录值，不得计入 known 分母（#70 实现要求 4）
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            needsReimportItem(id: "r", level: 4, maxLevel: 10, stageMax: 6),
        ]
        let m = metrics(items)
        XCTAssertEqual(m.currentStageProgress.denominator, 6) // 只含 known 项
        XCTAssertEqual(m.globalProgress.denominator, 10)
        XCTAssertEqual(m.snapshotCoverage.numerator, 1)
        XCTAssertEqual(m.currentStageProgress.state, .partial)
        XCTAssertNotNil(m.currentStageProgress.degradedReason)
    }

    func testNeedsReimportAllItemsUnknown() {
        let m = metrics([needsReimportItem(id: "r", level: 4, maxLevel: 10, stageMax: 6)])
        XCTAssertEqual(m.currentStageProgress.state, .unknown)
        XCTAssertEqual(m.snapshotCoverage.numerator, 0)
        XCTAssertEqual(m.snapshotCoverage.denominator, 1)
    }

    // MARK: - 跨基地隔离（验收标准 6）

    func testMetricsArePureAndIsolated() {
        // 不同基地的投影各自独立：同一输入重复计算幂等，不同基地互不污染
        let homeItems = [item(id: "h", level: 3, maxLevel: 10, stageMax: 6)]
        let builderItems = [item(id: "b", level: 8, maxLevel: 12, stageMax: 8)]
        let homeOnce = metrics(homeItems)
        let homeTwice = metrics(homeItems)
        let builder = metrics(builderItems)
        XCTAssertEqual(homeOnce.currentStageProgress, homeTwice.currentStageProgress) // 幂等
        XCTAssertNotEqual(homeOnce.currentStageProgress, builder.currentStageProgress) // 无串扰
        XCTAssertEqual(homeOnce.currentStageProgress.numerator, 3)
        XCTAssertEqual(builder.currentStageProgress.numerator, 8)
    }

    // MARK: - 负 cap 钳制（交叉审核 F1：fail-closed）

    func testNegativeCapContributesZero() {
        // 恶意目录：cap 为负 → 贡献 0，不产生负 ratio（审核 B F1）
        let m = metrics([item(id: "a", level: 3, maxLevel: -5, stageMax: -5)])
        XCTAssertEqual(m.currentStageProgress.numerator, 0)
        XCTAssertEqual(m.currentStageProgress.denominator, 0)
        XCTAssertEqual(m.globalProgress.numerator, 0)
        XCTAssertEqual(m.globalProgress.denominator, 0)
        XCTAssertNil(m.currentStageProgress.ratio)
    }

    func testNegativeCapWithMaxIntCountDoesNotCrash() {
        // 审核 B F1 崩溃复现路径：cap=-1 + count=Int.max → UI Int(ratio*100) 不得 SIGTRAP
        let items = [item(id: "a", level: 3, maxLevel: -1, stageMax: -1, count: Int.max)]
        let m = metrics(items)
        XCTAssertNil(m.currentStageProgress.ratio)  // den==0 → unknown
        XCTAssertNotEqual(m.currentStageProgress.state, .ready)
    }

    // MARK: - 升级中缺阶段上限（交叉审核 A-1/F3：不静默丢分母）

    func testStageMissingMaxLevelDegradesWhenUpgrading() {
        // 升级中 + 快照缺解锁记录（stageMax nil）：不得静默丢分母（审核 A 漏洞 1）
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "u", status: .upgrading, level: 4, maxLevel: 10, stageMax: nil, isUpgrading: true),
        ]
        let m = metrics(items, compatibility: .verified(gameVersion: "18.400.13"))
        XCTAssertEqual(m.currentStageProgress.denominator, 6) // 只含可算项
        XCTAssertEqual(m.currentStageProgress.state, .partial)
        XCTAssertNotNil(m.currentStageProgress.degradedReason)
        // global 不受影响（maxLevel 非 nil 即可算）
        XCTAssertEqual(m.globalProgress.denominator, 20)
    }

    func testNegativeCapItemWithNormalItemDegradesStage() {
        // 恶意目录负 cap 项不得静默归 0 贡献：与正常项混合时 stage 必须 partial（审核 A nit）
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "m", level: 9, maxLevel: -1, stageMax: -5),
        ]
        let m = metrics(items, compatibility: .verified(gameVersion: "18.400.13"))
        XCTAssertEqual(m.currentStageProgress.denominator, 6) // 只有正常项
        XCTAssertEqual(m.currentStageProgress.state, .partial)
        XCTAssertNotNil(m.currentStageProgress.degradedReason)
    }

    // MARK: - 已观测分母（外部评审 P1-1：验收 3）

    func testIncompleteDenominatorForcesPartial() {
        // 覆盖契约非 complete（partial，unmodeled 非空 → 覆盖诊断透传）：
        // 全 known 也无 unknown 项 → stage/global 仍 partial（验收 3，
        // 不得误称全村庄进度）。
        // Issue #110：snapshotCoverage 同样降级 partial——覆盖诊断透传，
        // 原「覆盖率不受影响」注释已过时（partial 快照下即使
        // numerator == denominator 也不得显示无 scope 的裸 100%，验收 3）。
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6),
        ]
        let m = metrics(items, coverage: .partial(missingSections: [], unmodeledCategories: [.troops]))
        XCTAssertEqual(m.currentStageProgress.state, .partial)
        XCTAssertEqual(m.globalProgress.state, .partial)
        XCTAssertNotNil(m.currentStageProgress.degradedReason)
        XCTAssertEqual(m.snapshotCoverage.state, .partial)
        XCTAssertTrue(m.snapshotCoverage.degradedReason?.contains("目录未对") == true)
        XCTAssertEqual(m.currentStageProgress.ratio, 8.0 / 12.0) // 数值仍可展示
    }

    func testIncompleteDenominatorReasonText() {
        let m = metrics([item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
                        coverage: .partial(missingSections: [], unmodeledCategories: [.troops]))
        let reason = m.currentStageProgress.degradedReason!
        XCTAssertTrue(reason.contains("分母为已观测项目，非村庄全部实例，无法计算完整村庄进度。"), reason)
    }

    // MARK: - Issue #110：snapshotCoverage 携带覆盖诊断（验收 2/3）

    /// 验收 2 防回归：complete coverage + 全 known → snapshotCoverage 仍
    /// `.ready`（覆盖诊断只在 partial 时透传，complete 不得误伤 ready）。
    func testCompleteCoverageKeepsSnapshotCoverageReady() {
        let m = metrics(
            [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
            coverage: .complete
        )
        XCTAssertEqual(m.snapshotCoverage.state, .ready)
        XCTAssertNil(m.snapshotCoverage.degradedReason)
        XCTAssertEqual(m.snapshotCoverage.ratio, 1.0)
    }

    /// 验收 3：partial 快照 + numerator == denominator（单建筑全 known，
    /// ratio 恰为 100%）→ 不得显示无 scope 的裸 100%——state 降级 .partial
    /// 且 degradedReason 含缺失类别诊断。
    func testPartialSnapshotCoverageRatioStill100WithDiagnostic() {
        let m = metrics(
            [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
            coverage: .partial(missingSections: ["units"], unmodeledCategories: [])
        )
        XCTAssertEqual(m.snapshotCoverage.numerator, 1)
        XCTAssertEqual(m.snapshotCoverage.denominator, 1)
        XCTAssertEqual(m.snapshotCoverage.ratio, 1.0) // 数值口径不变，仍是 100%
        XCTAssertEqual(m.snapshotCoverage.state, .partial) // 但必须带 scope 降级
        XCTAssertTrue(m.snapshotCoverage.degradedReason?.contains("快照缺少类别数据") == true)
    }

    /// partial unmodeled → snapshotCoverage 诊断含「目录未对」（与
    /// stage/global 同口径，未建模类别不产生假精度）。
    func testSnapshotCoverageDiagnosticIncludesUnmodeledCategory() {
        let m = metrics(
            [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
            coverage: .partial(missingSections: [], unmodeledCategories: [.troops, .heroes])
        )
        XCTAssertEqual(m.snapshotCoverage.state, .partial)
        XCTAssertTrue(m.snapshotCoverage.degradedReason?.contains("目录未对") == true)
        XCTAssertTrue(m.snapshotCoverage.degradedReason?.contains("兵种") == true)
        XCTAssertTrue(m.snapshotCoverage.degradedReason?.contains("英雄") == true)
    }

    // MARK: - Issue #96：coverage 参数与诊断

    func testPartialCoverageAddsSectionDiagnostic() {
        let m = metrics(
            [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
            coverage: .partial(missingSections: ["units", "spells"], unmodeledCategories: [])
        )
        XCTAssertEqual(m.globalProgress.state, .partial)
        XCTAssertTrue(m.globalProgress.degradedReason?.contains("快照缺少类别数据") == true)
        // 评审修复：missing 段先映射中文类别名再排序（与 unmodeled 分支同口径，
        // 两条诊断的类别顺序一致，避免中英混排）。
        XCTAssertTrue(m.globalProgress.degradedReason?.contains("法术") == true)
        // sorted() 确定性：title 序 "兵种"(U+5175) < "法术"(U+6CD5) → 兵种、法术
        //（非调用方传参顺序）。断言精确子串锁顺序，防排序回归。
        XCTAssertTrue(m.globalProgress.degradedReason?.contains("兵种、法术") == true)
    }

    func testPartialCoverageAddsUnmodeledDiagnostic() {
        let m = metrics(
            [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
            coverage: .partial(missingSections: [], unmodeledCategories: [.troops, .heroes])
        )
        XCTAssertTrue(m.globalProgress.degradedReason?.contains("目录未对") == true)
        XCTAssertTrue(m.globalProgress.degradedReason?.contains("兵种") == true)
        XCTAssertTrue(m.globalProgress.degradedReason?.contains("英雄") == true)
    }

    /// Issue #96 P1 契约：覆盖率分母 = 全部追踪类别观测实例 ∪ 已建模类别
    ///（建筑/陷阱）宇宙差集——未建模类别（units 等）只计观测、无差集补充。
    /// UI help 文案必须与之一致（不得宣称「已建模可建造数量」，该称谓要求
    /// 分母只含已建模类别的宇宙量）。
    func testCoverageDenominatorMixesAllObservedWithBuildingsTrapsDiff() {
        let observedBuilding = item(id: "b", level: 18, maxLevel: 18, stageMax: 18, count: 1)
        let observedUnit = item(id: "u", level: 3, maxLevel: 10, stageMax: 6, count: 2)
        let diff = item(id: "universe:buildings:1000002", status: .available,
                        level: nil, maxLevel: 1, stageMax: nil, count: 7)
        let m = metrics([observedBuilding, observedUnit, diff],
                        coverage: .partial(missingSections: [], unmodeledCategories: [.troops]))
        // 分母 = 观测(1 + 2) + 建筑差集(7) = 10；分子 = known(1 + 2) = 3。
        // 若分母只含「已建模可建造」（建筑宇宙），值应为 8——契约锁定现状。
        XCTAssertEqual(m.snapshotCoverage.denominator, 10)
        XCTAssertEqual(m.snapshotCoverage.numerator, 3)
    }

    func testUnknownStateCarriesCoverageDiagnostic() {
        // 分母为 0（无可确认项目）+ partial 覆盖 → unknown 态也透出覆盖诊断
        //（Task 3 行为回归锁：makeMetric unknown 分支同样拼接 coverageDiagnostic，
        // 不得因 unknown 无百分比可展示而静默丢失覆盖告警）。
        let m = metrics([], coverage: .partial(missingSections: ["units"], unmodeledCategories: []))
        XCTAssertEqual(m.globalProgress.state, .unknown)
        XCTAssertTrue(m.globalProgress.degradedReason?.contains("快照缺少类别数据") == true)
    }

    func testCompleteCoverageAllowsReady() {
        let m = metrics(
            [item(id: "a", level: 3, maxLevel: 10, stageMax: 6)],
            coverage: .complete
        )
        XCTAssertEqual(m.globalProgress.state, .ready)
        XCTAssertNil(m.globalProgress.degradedReason)
    }

    /// partial 时差集项不进 stage/global 分母（available 过滤 = coverage.isComplete）。
    func testPartialCoverageExcludesAvailableFromEligible() {
        // 注意：差集项必须给 maxLevel 才能进 eligible（maxLevel ?? 0 > 0 过滤），
        // 且 eligible 贡献 = maxLevel × instanceWeight（count=7 → 权重 7）。
        let available = item(id: "u:1", status: .available, level: nil, maxLevel: 1, stageMax: nil,
                             count: 7)
        let known = item(id: "a", level: 3, maxLevel: 10, stageMax: 6)
        let partial = metrics([known, available], coverage: .partial(missingSections: ["units"], unmodeledCategories: []))
        XCTAssertEqual(partial.globalProgress.denominator, 10, "partial → 差集不进分母")
        XCTAssertEqual(partial.globalProgress.state, .partial)
        let complete = metrics([known, available], coverage: .complete)
        XCTAssertEqual(complete.globalProgress.denominator, 17, "complete → 差集进分母（10 + 1×7）")
    }

    // MARK: - 全局非法上限（外部评审 P2-2）

    func testGlobalNegativeMaxLevelDegrades() {
        // 恶意目录负 maxLevel 项 → global 降级 partial（P2-2 对称处理）
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "m", level: 9, maxLevel: -1, stageMax: 6),
        ]
        let m = metrics(items)
        XCTAssertEqual(m.globalProgress.denominator, 10) // 只含正常项
        XCTAssertEqual(m.globalProgress.state, .partial)
        XCTAssertNotNil(m.globalProgress.degradedReason)
    }

    // MARK: - aggregateCoverage（升级总览消费同一投影，复审修复）

    /// 村庄 fixture（参考 UpgradeOverviewProjectionTests.makeVillage 惯例）。
    private func makeVillage(
        name: String = "测试村庄",
        tag: String? = "#TEST",
        objectSections: [String: [AccountItem]] = [:]
    ) -> VillageProfile {
        VillageProfile(
            name: name,
            accountSnapshot: AccountSnapshot(
                tag: tag,
                capturedAt: nil,
                importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                ageSeconds: nil,
                originalText: "",
                objectSections: objectSections,
                numericSections: [:],
                boosts: [:],
                unknownTopLevelKeys: [],
                diagnostics: []
            )
        )
    }

    private func makeItem(
        section: String,
        dataID: Int64,
        level: Int? = nil,
        count: Int? = nil,
        path: String = "0"
    ) -> AccountItem {
        AccountItem(
            id: section + ":" + path,
            section: section,
            dataID: dataID,
            level: level,
            count: count,
            timerSeconds: nil,
            remainingSeconds: nil,
            types: [],
            modules: []
        )
    }

    /// 最小合成目录：加农炮（buildings，无 requirement）+ 野蛮人（units）。
    private func makeCatalog() throws -> GameCatalog {
        let json = """
        {
          "gameVersion": "18.400.13",
          "items": [
            {"section":"buildings","category":"buildings","dataID":1000001,"base":"home","name":"加农炮","maxLevel":2,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[
               {"level":1,"durationSeconds":60,"upgradeResource":"Elixir","upgradeCost":200,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
               {"level":2,"durationSeconds":300,"upgradeResource":"Elixir","upgradeCost":2000,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
             ]},
            {"section":"units","category":"troops","dataID":4000000,"base":"home","name":"野蛮人","maxLevel":3,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[
               {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
               {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null},
               {"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null}
             ]}
          ]
        }
        """
        struct Payload: Decodable {
            let gameVersion: String
            let items: [CatalogItem]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        return GameCatalog(gameVersion: payload.gameVersion, items: payload.items)
    }

    /// 宇宙目录 fixture（Issue #110 聚合 scope 测试）：圣水收集器
    ///（buildings:1000002，数量型、宇宙键 TH1=1…TH18=7）+ 弹簧陷阱
    ///（traps:12000000，宇宙键）+ 野蛮人（units:4000000，解锁型无宇宙键）
    /// ——与 UpgradeOverviewProjectionTests 的 universeCatalogJSON 同构
    ///（GameCatalog init 校验：有宇宙键的 section 必须全量覆盖其 home 可计数
    /// item，本目录恰满足）。traps 建模使快照缺 traps 时 missing 诊断可达
    ///（traps → .traps ∉ unmodeled，去重后保留——测试 missing 侧诊断）。
    private static let universeCatalogJSON = """
    {
      "gameVersion": "18.400.13",
      "instanceCounts": {
        "buildings:1000002": [1,2,3,4,5,6,6,6,7,7,7,7,7,7,7,7,7,7],
        "traps:12000000": [1,1,1,2,2,2,2,2,3,3,3,3,3,3,3,3,3,3]
      },
      "items": [
        {"section":"buildings","category":"buildings","dataID":1000002,"base":"home","name":"圣水收集器","maxLevel":2,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":60,"upgradeResource":"Elixir","upgradeCost":200,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":2,"durationSeconds":300,"upgradeResource":"Elixir","upgradeCost":2000,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
         ]},
        {"section":"traps","category":"traps","dataID":12000000,"base":"home","name":"弹簧陷阱","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"instant"},
           {"level":2,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"instant"},
           {"level":3,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"instant"}
         ]},
        {"section":"units","category":"troops","dataID":4000000,"base":"home","name":"野蛮人","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[
           {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
           {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null},
           {"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null}
         ]}
      ]
    }
    """

    /// 全类别宇宙目录 fixture（聚合 .complete 场景）：9 个追踪 section 各一个
    /// 可计数 home item + 对应宇宙键 → universeSections 覆盖全部 TrackerCategory。
    /// dataID 避开 nonCountableDataIDs（TH 1_000_001 / 英雄神坛 / 装饰 / 单机
    /// 陷阱变体等）；GameCatalog init 的正向完整 key 契约每 section 恰覆盖
    /// 其唯一 item。
    private static let fullUniverseCatalogJSON = """
    {
      "gameVersion": "18.400.13",
      "instanceCounts": {
        "buildings:1000002": [1,2,3,4,5,6,6,6,7,7,7,7,7,7,7,7,7,7],
        "traps:12000000": [1,1,1,2,2,2,2,2,3,3,3,3,3,3,3,3,3,3],
        "units:4000000": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        "spells:5000000": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        "siege_machines:6000000": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        "heroes:7000000": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        "equipment:90000000": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        "pets:8000000": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        "guardians:10000000": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]
      },
      "items": [
        {"section":"buildings","category":"buildings","dataID":1000002,"base":"home","name":"圣水收集器","maxLevel":2,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[{"level":1,"durationSeconds":60,"upgradeResource":"Elixir","upgradeCost":200,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}]},
        {"section":"traps","category":"traps","dataID":12000000,"base":"home","name":"弹簧陷阱","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[{"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"instant"}]},
        {"section":"units","category":"troops","dataID":4000000,"base":"home","name":"野蛮人","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[{"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"}]},
        {"section":"spells","category":"spells","dataID":5000000,"base":"home","name":"闪电法术","maxLevel":9,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[{"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"}]},
        {"section":"siege_machines","category":"siege_machines","dataID":6000000,"base":"home","name":"攻城车","maxLevel":4,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[{"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"}]},
        {"section":"heroes","category":"heroes","dataID":7000000,"base":"home","name":"野蛮人之王","maxLevel":5,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[{"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"}]},
        {"section":"equipment","category":"equipment","dataID":90000000,"base":"home","name":"野蛮人木偶","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[{"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"}]},
        {"section":"pets","category":"pets","dataID":8000000,"base":"home","name":"独角兽","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[{"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"}]},
        {"section":"guardians","category":"guardians","dataID":10000000,"base":"home","name":"莱西","maxLevel":3,
         "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
         "levels":[{"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"}]}
      ]
    }
    """

    /// 宇宙目录的 manifest 信任标记 stub（hasUniverseData 要求 catalog.json
    /// 条目 + sha256 声明；测试注入路径不调用 validate，值任意合法格式即可）。
    private func makeUniverseManifestStub() -> CatalogManifest {
        CatalogManifest(
            schemaVersion: 1, gameVersion: "18.400.13", buildTag: "test",
            locale: "zh-CN",
            sourceFingerprint: "sha256:" + String(repeating: "a", count: 64),
            generatedFiles: [
                CatalogGeneratedFile(
                    path: "catalog.json",
                    sha256: "sha256:" + String(repeating: "b", count: 64),
                    size: nil, kind: nil, entries: nil
                ),
            ],
            counts: CatalogCounts(
                items: 2, levels: 5, missingIcons: nil, missingTime: nil,
                timed: nil, instant: nil, notApplicable: nil, initialLevel: nil,
                sourceMissing: nil, parseFailed: nil
            )
        )
    }

    private func makeUniverseCatalog() throws -> GameCatalog {
        struct Payload: Decodable {
            let gameVersion: String
            let items: [CatalogItem]
            let instanceCounts: [String: [Int]]?
        }
        let payload = try JSONDecoder().decode(
            Payload.self, from: Data(Self.universeCatalogJSON.utf8)
        )
        return GameCatalog(
            gameVersion: payload.gameVersion,
            items: payload.items,
            manifest: makeUniverseManifestStub(),
            instanceCounts: payload.instanceCounts
        )
    }

    private func makeFullUniverseCatalog() throws -> GameCatalog {
        struct Payload: Decodable {
            let gameVersion: String
            let items: [CatalogItem]
            let instanceCounts: [String: [Int]]?
        }
        let payload = try JSONDecoder().decode(
            Payload.self, from: Data(Self.fullUniverseCatalogJSON.utf8)
        )
        return GameCatalog(
            gameVersion: payload.gameVersion,
            items: payload.items,
            manifest: makeUniverseManifestStub(),
            instanceCounts: payload.instanceCounts
        )
    }

    /// 9 个追踪 section 键（键存在即 present，空数组不算缺失——Issue #96
    /// 快照完整性契约）。
    private static let fullSections: [String: [AccountItem]] = [
        "buildings": [], "traps": [], "units": [], "spells": [],
        "siege_machines": [], "heroes": [], "equipment": [],
        "pets": [], "guardians": [],
    ]

    func testAggregateCoverageAcrossVillagesAndBases() throws {
        let catalog = try makeCatalog()
        // 村庄 A（home）：加农炮 level 1 → known，coverage 1/1
        let villageA = makeVillage(name: "A村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1)],
        ])
        // 村庄 B（home）：加农炮 level 1（known）+ 目录未收录项（unknown）→ coverage 1/2
        let villageB = makeVillage(name: "B村", objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0"),
                makeItem(section: "buildings", dataID: 999_999_999, level: 3, path: "1"),
            ],
        ])
        let result = try XCTUnwrap(
            VillageProgressProjection.aggregateCoverage(
                from: [villageA, villageB], catalog: catalog, seasonalPhases: .empty
            )
        )
        XCTAssertEqual(result.numerator, 2)
        XCTAssertEqual(result.denominator, 3)
        // Issue #110：旧目录（无宇宙数据）→ 全部 home 对 coverage .unavailable
        // → 合并结果 .unavailable、无诊断（纯已观测口径，不误报缺失）。
        XCTAssertEqual(result.coverage, .unavailable)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testAggregateCoverageEmptyOrNoSnapshotReturnsNil() throws {
        let catalog = try makeCatalog()
        XCTAssertNil(VillageProgressProjection.aggregateCoverage(
            from: [], catalog: catalog, seasonalPhases: .empty
        ))
        // 无快照村庄（hasImportedData false）→ 无可观测实例 → nil
        let bareVillage = makeVillage(name: "空村")
        let bare = VillageProfile(
            name: "空村",
            accountSnapshot: nil
        )
        XCTAssertNil(VillageProgressProjection.aggregateCoverage(
            from: [bare], catalog: catalog, seasonalPhases: .empty
        ))
        XCTAssertNil(VillageProgressProjection.aggregateCoverage(
            from: [bareVillage], catalog: catalog, seasonalPhases: .empty
        ))
    }

    func testAggregateCoverageSaturatedFailsClosed() throws {
        // 同键两条 count=Int.max 记录：聚合层饱和（countOverflowed 传播）→
        // coverage saturated → 聚合整体 nil（fail-closed，不静默跳过饱和项）
        let catalog = try makeCatalog()
        let saturatedVillage = makeVillage(name: "饱和村", objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, count: Int.max, path: "0"),
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, count: Int.max, path: "1"),
            ],
        ])
        XCTAssertNil(VillageProgressProjection.aggregateCoverage(
            from: [saturatedVillage], catalog: catalog, seasonalPhases: .empty
        ))
    }

    // MARK: - Issue #110：聚合携带 coverage scope（验收 4）

    /// 验收 4：聚合返回 AggregateCoverage 结构——数值与旧 tuple 口径一致
    ///（跨全部村庄 × 全部基地累加），coverage 按 home 对合并。
    /// 本用例 = 正常村庄（makeCatalog 无宇宙 → home/BB 对均 .unavailable）→
    /// merged .unavailable + 无诊断：纯已观测口径，不误报缺失。
    func testAggregateCoverageReturnsScopeObject() throws {
        let catalog = try makeCatalog()
        let villageA = makeVillage(name: "A村", objectSections: [
            "buildings": [makeItem(section: "buildings", dataID: 1_000_001, level: 1)],
        ])
        let villageB = makeVillage(name: "B村", objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 1, path: "0"),
                makeItem(section: "buildings", dataID: 999_999_999, level: 3, path: "1"),
            ],
        ])
        let result = try XCTUnwrap(
            VillageProgressProjection.aggregateCoverage(
                from: [villageA, villageB], catalog: catalog, seasonalPhases: .empty
            )
        )
        XCTAssertEqual(result.numerator, 2) // 与旧 (known: 2, observed: 3) 逐位一致
        XCTAssertEqual(result.denominator, 3)
        XCTAssertEqual(result.coverage, .unavailable)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    /// 回归锁定：BB base 恒 .unavailable（决策 5）不得污染 scope 合并——
    /// 村庄 home 对 .partial（快照缺 units 等 section、目录宇宙仅 buildings）
    /// → 聚合 coverage 必须仍为 .partial（不是 unavailable），否则任何已导入
    /// 村庄都自带 unavailable 对 → 聚合恒降级（fail-useless，候选 A 否决）。
    func testAggregateCoverageBBPairDoesNotPoisonScope() throws {
        let catalog = try makeUniverseCatalog()
        // 快照仅 buildings（TH18 + 圣水收集器 level 1）：home 对 coverage
        // .partial（8 个 missing section + 8 类未建模）；BB 对恒 .unavailable。
        let village = makeVillage(name: "部分村", objectSections: [
            "buildings": [
                makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th"),
                makeItem(section: "buildings", dataID: 1_000_002, level: 1, path: "0"),
            ],
        ])
        let result = try XCTUnwrap(
            VillageProgressProjection.aggregateCoverage(
                from: [village], catalog: catalog, seasonalPhases: .empty
            )
        )
        // 数值口径（仅 home 对）：圣水收集器 known 1 + TH(1000001 目录未收录
        // → unknown) 1 + 建筑差集 7-1 + 陷阱差集 3 = 12；BB 对 0/0 不贡献。
        // 差集数耦合宇宙表数值，不锁具体分母（数值口径已由
        // testAggregateCoverageReturnsScopeObject 锁定 2/3）。
        XCTAssertEqual(result.numerator, 1)
        XCTAssertTrue(result.denominator > 0)
        guard case .partial(let missing, let unmodeled) = result.coverage else {
            return XCTFail("home 对 partial → 聚合必须 .partial，实际 \(result.coverage)")
        }
        // 去重后 missing 保留「目录已建模但快照缺失」的类别：traps 建模 →
        // .traps ∉ unmodeled → 保留；units → .troops ∈ unmodeled → 让位
        //（只在 unmodeled 侧报一次）。
        XCTAssertTrue(missing.contains("traps"), "快照缺 traps section: \(missing)")
        XCTAssertFalse(missing.contains("units"), "units → .troops 已去重给 unmodeled 侧: \(missing)")
        XCTAssertTrue(unmodeled.contains(.troops), "目录未对兵种建模: \(unmodeled)")
        // 聚合诊断（partial 专属）：「部分村庄」前缀 + 未建模类别
        let joined = result.diagnostics.joined(separator: " ")
        XCTAssertTrue(joined.contains("部分村庄快照缺少类别数据（陷阱）"), joined)
        XCTAssertTrue(joined.contains("目录未对"), joined)
    }

    /// 全部 home 对 .unavailable（目录有宇宙但 TH 未知 → 差集能力不可用）→
    /// 合并 .unavailable + 无诊断（无差集，纯已观测口径）。
    func testAggregateCoverageAllUnavailableWhenNoHomeUniverse() throws {
        let catalog = try makeUniverseCatalog()
        // 快照仅 units（无 buildings → TH 未知）→ buildingUniverseAvailable
        // false → home 对 .unavailable；BB 对恒 .unavailable。
        let village = makeVillage(name: "无TH村", objectSections: [
            "units": [makeItem(section: "units", dataID: 4_000_000, level: 2)],
        ])
        let result = try XCTUnwrap(
            VillageProgressProjection.aggregateCoverage(
                from: [village], catalog: catalog, seasonalPhases: .empty
            )
        )
        // 数值：无 TH → 野蛮人 prerequisite（实验室）无法验证 → .unverified
        // → 不进 known（fail-closed）→ 0/1。
        XCTAssertEqual(result.numerator, 0)
        XCTAssertEqual(result.denominator, 1)
        XCTAssertEqual(result.coverage, .unavailable)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    /// 全部 home 对 .complete（9 section 全 present + 目录全类别建模）→
    /// 合并 .complete + 无诊断。
    func testAggregateCoverageCompleteWhenAllComplete() throws {
        let catalog = try makeFullUniverseCatalog()
        let makeFullVillage = { [self] (name: String) in
            var sections = Self.fullSections
            sections["buildings"] = [
                makeItem(section: "buildings", dataID: 1_000_001, level: 18, path: "th")
            ]
            return makeVillage(name: name, objectSections: sections)
        }
        let result = try XCTUnwrap(
            VillageProgressProjection.aggregateCoverage(
                from: [makeFullVillage("A村"), makeFullVillage("B村")],
                catalog: catalog, seasonalPhases: .empty
            )
        )
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertTrue(result.denominator > 0, "聚合必须有观测实例")
    }

    /// mergedCoverage 纯函数：两村庄不同 missing section → 并集；
    /// missing∩unmodeled 去重——同一类别既缺失又未建模只报一次
    ///（units → .troops 同时出现在另一村庄的 unmodeled 侧 → 从 missing 移除，
    /// 类别保留在 unmodeled 侧报告）。
    func testAggregateCoverageMergesMissingSectionsAndUnmodeled() {
        let merged = VillageProgressProjection.mergedCoverage(of: [
            .partial(missingSections: ["units"], unmodeledCategories: [.troops]),
            .partial(missingSections: ["spells", "units"], unmodeledCategories: []),
        ])
        XCTAssertEqual(
            merged,
            .partial(missingSections: ["spells"], unmodeledCategories: [.troops])
        )
    }

    // MARK: - Issue #110：mergedCoverage property 测试（确定性 LCG）

    /// 随机 coverage 生成：unavailable / complete / partial（missing 与
    /// unmodeled 各自随机子集，允许空集合——.partial([], []) 是合法输入，
    /// 合并结果仍必须保持 partial 语义）。
    private func randomCoverage(_ generator: inout Issue110LCG) -> ProgressUniverseCoverage {
        switch generator.int(in: 0...2) {
        case 0: return .unavailable
        case 1: return .complete
        default:
            let allSections = ["buildings", "traps", "units", "spells",
                               "siege_machines", "heroes", "equipment", "pets", "guardians"]
            return .partial(
                missingSections: Set(allSections.filter { _ in generator.bool() }),
                unmodeledCategories: Set(TrackerCategory.allCases.filter { _ in generator.bool() })
            )
        }
    }

    /// 合并的交换律与结合律：merge(a,b) == merge(b,a)；
    /// merge(merge(a,b),c) == merge(a,merge(b,c))。
    func testMergedCoverageIsCommutativeAndAssociative() {
        var generator = Issue110LCG(seed: 42)
        for _ in 0..<100 {
            let a = randomCoverage(&generator)
            let b = randomCoverage(&generator)
            let c = randomCoverage(&generator)
            XCTAssertEqual(
                VillageProgressProjection.mergedCoverage(of: [a, b]),
                VillageProgressProjection.mergedCoverage(of: [b, a])
            )
            XCTAssertEqual(
                VillageProgressProjection.mergedCoverage(of: [
                    VillageProgressProjection.mergedCoverage(of: [a, b]), c
                ]),
                VillageProgressProjection.mergedCoverage(of: [
                    a, VillageProgressProjection.mergedCoverage(of: [b, c])
                ])
            )
        }
    }

    /// 任意数量全 complete 输入 → 恒 .complete。
    func testMergedCoverageAllCompleteIsComplete() {
        var generator = Issue110LCG(seed: 7)
        for _ in 0..<100 {
            let count = generator.int(in: 1...10)
            let coverages = (0..<count).map { _ in ProgressUniverseCoverage.complete }
            XCTAssertEqual(
                VillageProgressProjection.mergedCoverage(of: coverages),
                .complete
            )
        }
    }

    /// 含任一 partial 输入 → 结果必须 .partial，且 missing/unmodeled 是各
    /// partial 输入的并集超集；missing 去重精确：映射到未建模类别的 section
    /// 从结果 missing 移除（类别只在 unmodeled 侧报一次）。
    func testMergedCoverageUnionSuperset() {
        var generator = Issue110LCG(seed: 99)
        for _ in 0..<100 {
            let partialCount = generator.int(in: 1...3)
            var inputs: [ProgressUniverseCoverage] = []
            var partialInputs: [ProgressUniverseCoverage] = []
            for _ in 0..<partialCount {
                var partial = randomCoverage(&generator)
                while partial == .unavailable || partial == .complete {
                    partial = randomCoverage(&generator) // 保证存在 partial 输入
                }
                partialInputs.append(partial)
                inputs.append(partial)
            }
            let fillerCount = generator.int(in: 0...3)
            for _ in 0..<fillerCount {
                inputs.append(generator.bool() ? .complete : .unavailable)
            }
            let merged = VillageProgressProjection.mergedCoverage(of: inputs)
            guard case .partial(let mergedMissing, let mergedUnmodeled) = merged else {
                return XCTFail("含 partial 输入的合并结果必须仍为 .partial，实际 \(merged)")
            }
            // unmodeled = 各 partial 输入的并集（恒等）
            let expectedUnmodeled = partialInputs.reduce(into: Set<TrackerCategory>()) { acc, c in
                if case .partial(_, let u) = c { acc.formUnion(u) }
            }
            XCTAssertEqual(mergedUnmodeled, expectedUnmodeled)
            // missing = 各 partial 输入的并集 - 映射到未建模类别的 section
            let expectedMissing = partialInputs.reduce(into: Set<String>()) { acc, c in
                if case .partial(let m, _) = c { acc.formUnion(m) }
            }
            XCTAssertEqual(
                mergedMissing,
                expectedMissing.filter {
                    guard let category = TrackerCategory.from(section: $0) else { return true }
                    return !expectedUnmodeled.contains(category)
                }
            )
        }
    }

    // MARK: - Issue #70 阶段 2：完整分母（known ∪ available 宇宙差集）

    /// 宇宙差集项 fixture：level 0、count 4（投影层合成的 .available 形态）。
    private func availableItem(
        id: String = "av",
        maxLevel: Int? = 10,
        stageMax: Int? = 6,
        count: Int? = 4
    ) -> VillageItemState {
        item(id: id, status: .available, level: 0, maxLevel: maxLevel,
             stageMax: stageMax, count: count)
    }

    func testCompleteDenominatorIncludesAvailableInStageGlobal() {
        // known：level 3/6；available：level 0/6、count 4（宇宙差集）
        // stage 分母 = 6 + 6×4 = 30，分子 = 3（available level 0 贡献 0）
        // global 分母 = 10 + 10×4 = 50，分子 = 3
        let items = [
            item(id: "k", level: 3, maxLevel: 10, stageMax: 6),
            availableItem(id: "a", count: 4),
        ]
        let m = metrics(items)  // 默认 coverage: .complete
        XCTAssertEqual(m.currentStageProgress.denominator, 30)
        XCTAssertEqual(m.currentStageProgress.numerator, 3)
        XCTAssertEqual(m.globalProgress.denominator, 50)
        XCTAssertEqual(m.globalProgress.numerator, 3)
        XCTAssertEqual(m.currentStageProgress.ratio ?? -1, 3.0 / 30.0, accuracy: 1e-9)
    }

    func testCoverageIncludesAvailableInDenominator() {
        // known 1 + unknown 1 + available count 4 → 覆盖率 = 1/6
        let items = [
            item(id: "k", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "u", status: .unknown, level: nil, maxLevel: nil, stageMax: nil),
            availableItem(id: "a", count: 4),
        ]
        let m = metrics(items).snapshotCoverage
        XCTAssertEqual(m.numerator, 1)
        XCTAssertEqual(m.denominator, 6)
        XCTAssertEqual(m.ratio ?? -1, 1.0 / 6.0, accuracy: 1e-9)
    }

    func testAvailableForcesPartialWhenCompleteDenominator() {
        // 无 unknown、只有 available → stage/global 仍 partial（覆盖率 < 100%
        // 保守：快照可能不全，不得伪装 ready）
        let items = [
            item(id: "k", level: 3, maxLevel: 10, stageMax: 6),
            availableItem(id: "a", count: 4),
        ]
        let m = metrics(items)
        XCTAssertEqual(m.currentStageProgress.state, .partial)
        XCTAssertEqual(m.globalProgress.state, .partial)
        let reason = m.currentStageProgress.degradedReason!
        XCTAssertTrue(reason.contains("宇宙差集"), reason)
        // 差集项是已知存在（非「目录未命中」）→ 不得误报「未知或待重新导入」
        XCTAssertFalse(reason.contains("未知或待重新导入"), reason)
        // 数值仍可展示（保守 partial 而非 unknown）
        XCTAssertEqual(m.currentStageProgress.ratio ?? -1, 3.0 / 30.0, accuracy: 1e-9)
    }

    func testCompleteDenominatorReadyWhenNoUnknownNoAvailable() {
        // 全宇宙观测（无 unknown 无 available）→ coverage .complete 可达 ready
        let m = metrics([item(id: "a", level: 3, maxLevel: 10, stageMax: 6)])
        XCTAssertEqual(m.currentStageProgress.state, .ready)
        XCTAssertEqual(m.globalProgress.state, .ready)
        XCTAssertEqual(m.snapshotCoverage.state, .ready)
        XCTAssertEqual(m.currentStageProgress.ratio, 0.5)
    }

    func testIncompleteDenominatorIgnoresAvailable() {
        // coverage 非 complete（TH 缺失/目录无宇宙）：available 不进
        // stage/global 分母（阶段 1 语义，eligible = known），coverage 仍含
        // available（覆盖率天然是观测+宇宙差集口径）。
        let items = [
            item(id: "k", level: 3, maxLevel: 10, stageMax: 6),
            availableItem(id: "a", count: 4),
        ]
        let m = metrics(items, coverage: .partial(missingSections: [], unmodeledCategories: [.troops]))
        XCTAssertEqual(m.currentStageProgress.denominator, 6)
        XCTAssertEqual(m.globalProgress.denominator, 10)
        XCTAssertEqual(m.currentStageProgress.state, .partial)  // 已观测文案
        XCTAssertEqual(m.snapshotCoverage.denominator, 5)      // 1 + 4
        let reason = m.currentStageProgress.degradedReason!
        XCTAssertTrue(reason.contains("分母为已观测项目"),
                      "coverage 非 complete 必须走已观测分母文案")
        // 审核 B-7 否定断言：availableWeight 只在 coverage.isComplete 时
        // 参与降级——非 complete 时不得出现「宇宙差集」文案（available 不进 eligible）。
        XCTAssertFalse(reason.contains("宇宙差集"),
                       "coverage 非 complete 时不得出现宇宙差集降级文案")
    }

    func testCompleteDenominatorFiltersAvailableLikeKnown() {
        // available 的 cap 过滤与 known 同规则：stageMax=0（恶意/不可算）→ 不进
        // stage 分母；maxLevel>0 → 仍进 global 分母。
        let items = [
            item(id: "k", level: 3, maxLevel: 10, stageMax: 6),
            availableItem(id: "a", maxLevel: 10, stageMax: 0, count: 4),
        ]
        let m = metrics(items)
        XCTAssertEqual(m.currentStageProgress.denominator, 6)
        XCTAssertEqual(m.globalProgress.denominator, 50)
    }

    /// 评审 A 守卫（VillageProgressMetrics 缺失侧注释语义）：available 差集项的
    /// stageMax == 0（cap 异常）由 eligible 过滤剔除后**不**计入
    /// stageMissingWeightInfo——差集项由 availableWeight 独立差集文案承担，
    /// 混入缺失侧会与「缺少阶段上限」文案重复降级（计数虚增）。
    /// 判别结构：known 正常项（撑出分母，使差集文案可达）+ known 缺失项
    ///（count 2，合法计入缺失侧）+ available 差集项（stageMax 0、count 7，
    /// 不得计入缺失侧——若混入，缺失计数会从 2 虚增为 9）。
    func testAvailableStageCapAbnormalExcludedFromMissingSide() throws {
        let items = [
            item(id: "k", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "kBad", level: 1, maxLevel: 10, stageMax: 0, count: 2),
            availableItem(id: "a", maxLevel: 10, stageMax: 0, count: 7),
        ]
        let m = metrics(items)
        let stage = m.currentStageProgress
        XCTAssertEqual(stage.denominator, 6, "cap 异常项（known 缺失 + 差集）均不进 stage 分母")
        XCTAssertEqual(stage.state, .partial, "差集权重 > 0 → 保守 partial")
        let reason = try XCTUnwrap(stage.degradedReason)
        XCTAssertTrue(reason.contains("宇宙差集"),
                      "差集项应有独立差集文案: \(reason)")
        XCTAssertTrue(reason.contains("2 项缺少阶段上限"),
                      "缺失侧只统计 known 缺失项（2 实例），差集混入会虚增为 9 项: \(reason)")
        XCTAssertFalse(reason.contains("9 项"), reason)
    }
}

/// Issue #110 property 测试专用确定性 LCG（与 CoAPIPropertyTests.SeededGenerator
/// 同参数：m = 2^32, a = 1664525, c = 1013904223）。独立命名 + fileprivate：
/// SeededGenerator 是同 module internal 类型，重名会编译冲突；固定种子 ⇒
/// 属性测试可复现（同一种子重跑得到同一序列）。
private struct Issue110LCG {
    private var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> UInt32 {
        state = 1664525 &* state &+ 1013904223
        return state
    }
    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int(next() % UInt32(range.count)) + range.lowerBound
    }
    mutating func bool() -> Bool { next() & 1 == 1 }
}
