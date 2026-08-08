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
        nextLevel: Int? = nil
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
            displayCategory: nil
        )
    }

    private func metrics(_ items: [VillageItemState],
                         usable: Bool = true,
                         compatibility: CatalogCompatibility? = nil) -> VillageProgressMetrics {
        VillageProgressProjection.metrics(from: items, catalogIsUsable: usable, compatibility: compatibility)
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
}
