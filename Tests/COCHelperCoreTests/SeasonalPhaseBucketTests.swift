import XCTest
@testable import COCHelperCore

/// Issue #200：phase bucket = 所有阶段边界（from/until，过滤非法区间）中
/// now 所在的区间。bucket 内任意 now 的 availability 判定恒定
///（phase 选择与 notStarted/active/ended 状态都不跨边界变化）。
final class SeasonalPhaseBucketTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func phase(_ id: String, from: TimeInterval, until: TimeInterval) -> SeasonalPhase {
        SeasonalPhase(
            phaseID: id,
            name: nil,
            from: Date(timeIntervalSince1970: from),
            until: Date(timeIntervalSince1970: until),
            itemKeys: ["buildings:1000001"]
        )
    }

    func testEmptyTableYieldsUnconfiguredBucket() {
        let bucket = SeasonalPhaseTable.empty.bucket(at: t0)
        XCTAssertEqual(bucket.start, .distantPast)
        XCTAssertEqual(bucket.end, .distantFuture)
        // 空表任意 now 同一 bucket（单桶语义）。
        XCTAssertEqual(bucket, SeasonalPhaseTable.empty.bucket(at: t0.addingTimeInterval(3600)))
    }

    func testSinglePhaseInsideAndOutside() {
        let table = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [phase("p1", from: 1_000_000, until: 2_000_000)]
        )
        let inside = table.bucket(at: Date(timeIntervalSince1970: 1_500_000))
        XCTAssertEqual(inside.start.timeIntervalSince1970, 1_000_000)
        XCTAssertEqual(inside.end.timeIntervalSince1970, 2_000_000)

        let outside = table.bucket(at: Date(timeIntervalSince1970: 3_000_000))
        XCTAssertEqual(outside.start.timeIntervalSince1970, 2_000_000)
        XCTAssertEqual(outside.end, .distantFuture)
    }

    func testMultiplePhaseBoundaries() {
        let table = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [
                phase("p1", from: 1_000_000, until: 2_000_000),
                phase("p2", from: 2_500_000, until: 3_500_000),
            ]
        )
        // 1_800_000 位于 p1 内部。
        let bucket = table.bucket(at: Date(timeIntervalSince1970: 1_800_000))
        XCTAssertEqual(bucket.start.timeIntervalSince1970, 1_000_000)
        XCTAssertEqual(bucket.end.timeIntervalSince1970, 2_000_000)
        // 2_200_000 位于 p1 结束与 p2 开始之间。
        let gap = table.bucket(at: Date(timeIntervalSince1970: 2_200_000))
        XCTAssertEqual(gap.start.timeIntervalSince1970, 2_000_000)
        XCTAssertEqual(gap.end.timeIntervalSince1970, 2_500_000)
    }

    func testInvalidPhaseRangesAreFiltered() {
        // from >= until 的非法区间与 availability 判定同口径过滤。
        let table = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [
                phase("bad", from: 2_000_000, until: 1_000_000),
                phase("good", from: 1_000_000, until: 1_500_000),
            ]
        )
        let bucket = table.bucket(at: Date(timeIntervalSince1970: 1_200_000))
        XCTAssertEqual(bucket.start.timeIntervalSince1970, 1_000_000)
        XCTAssertEqual(bucket.end.timeIntervalSince1970, 1_500_000)
    }

    func testBucketAtExactBoundary() {
        let table = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [phase("p1", from: 1_000_000, until: 2_000_000)]
        )
        // from 边界本身：<= date 取边界（与 availability 的 from <= now 同口径）。
        let atFrom = table.bucket(at: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(atFrom.start.timeIntervalSince1970, 1_000_000)
        XCTAssertEqual(atFrom.end.timeIntervalSince1970, 2_000_000)
    }

    func testTableContentChangeYieldsDifferentIdentity() {
        let tableA = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [phase("p1", from: 1_000_000, until: 2_000_000)]
        )
        let tableB = SeasonalPhaseTable(
            schemaVersion: 1,
            phases: [phase("p1", from: 1_000_000, until: 3_000_000)]
        )
        let now = Date(timeIntervalSince1970: 1_500_000)
        XCTAssertNotEqual(tableA.bucket(at: now).tableIdentity, tableB.bucket(at: now).tableIdentity)
    }
}