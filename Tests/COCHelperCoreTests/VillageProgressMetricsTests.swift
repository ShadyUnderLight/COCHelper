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
                         completeDenominator: Bool = true) -> VillageProgressMetrics {
        VillageProgressProjection.metrics(
            from: items,
            catalogIsUsable: usable,
            compatibility: compatibility,
            completeDenominator: completeDenominator
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
        // 无实例宇宙数据（completeDenominator false）：全 known 也无 unknown 项 →
        // stage/global 仍 partial（验收 3，不得误称全村庄进度）
        let items = [
            item(id: "a", level: 3, maxLevel: 10, stageMax: 6),
            item(id: "b", level: 5, maxLevel: 10, stageMax: 6),
        ]
        let m = metrics(items, completeDenominator: false)
        XCTAssertEqual(m.currentStageProgress.state, .partial)
        XCTAssertEqual(m.globalProgress.state, .partial)
        XCTAssertNotNil(m.currentStageProgress.degradedReason)
        XCTAssertEqual(m.snapshotCoverage.state, .ready) // 覆盖率不受影响
        XCTAssertEqual(m.currentStageProgress.ratio, 8.0 / 12.0) // 数值仍可展示
    }

    func testIncompleteDenominatorReasonText() {
        let m = metrics([item(id: "a", level: 3, maxLevel: 10, stageMax: 6)], completeDenominator: false)
        let reason = m.currentStageProgress.degradedReason!
        XCTAssertTrue(reason.contains("分母为已观测项目，非村庄全部实例，无法计算完整村庄进度。"), reason)
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
        XCTAssertEqual(result.known, 2)
        XCTAssertEqual(result.observed, 3)
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
        let m = metrics(items)  // completeDenominator: true
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
        // 全宇宙观测（无 unknown 无 available）→ completeDenominator=true 可达 ready
        let m = metrics([item(id: "a", level: 3, maxLevel: 10, stageMax: 6)])
        XCTAssertEqual(m.currentStageProgress.state, .ready)
        XCTAssertEqual(m.globalProgress.state, .ready)
        XCTAssertEqual(m.snapshotCoverage.state, .ready)
        XCTAssertEqual(m.currentStageProgress.ratio, 0.5)
    }

    func testIncompleteDenominatorIgnoresAvailable() {
        // completeDenominator=false（TH 缺失/目录无宇宙）：available 不进
        // stage/global 分母（阶段 1 语义，eligible = known），coverage 仍含
        // available（覆盖率天然是观测+宇宙差集口径）。
        let items = [
            item(id: "k", level: 3, maxLevel: 10, stageMax: 6),
            availableItem(id: "a", count: 4),
        ]
        let m = metrics(items, completeDenominator: false)
        XCTAssertEqual(m.currentStageProgress.denominator, 6)
        XCTAssertEqual(m.globalProgress.denominator, 10)
        XCTAssertEqual(m.currentStageProgress.state, .partial)  // 已观测文案
        XCTAssertEqual(m.snapshotCoverage.denominator, 5)      // 1 + 4
        let reason = m.currentStageProgress.degradedReason!
        XCTAssertTrue(reason.contains("分母为已观测项目"),
                      "completeDenominator=false 必须走已观测分母文案")
        // 审核 B-7 否定断言：availableWeight 只在 completeDenominator=true 时
        // 参与降级——false 时不得出现「宇宙差集」文案（available 不进 eligible）。
        XCTAssertFalse(reason.contains("宇宙差集"),
                       "completeDenominator=false 时不得出现宇宙差集降级文案")
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
