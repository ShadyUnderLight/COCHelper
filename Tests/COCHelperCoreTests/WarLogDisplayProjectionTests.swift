import XCTest
@testable import COCHelperCore

final class WarLogDisplayProjectionTests: XCTestCase {
    // MARK: - 常量

    func testConstants() {
        XCTAssertEqual(WarLogDisplayProjection.defaultVisibleCount, 10)
        XCTAssertEqual(WarLogDisplayProjection.increment, 10)
    }

    // MARK: - visibleEntries：prefix 语义 + 顺序保持 + 负值钳制

    func testVisibleEntriesPrefixAndOrderPreserved() {
        let items = Array(0..<30)
        for visibleCount in 0...40 {
            let visible = WarLogDisplayProjection.visibleEntries(items, visibleCount: visibleCount)
            XCTAssertEqual(visible, Array(0..<min(max(0, visibleCount), 30)),
                           "visibleCount=\(visibleCount) 应为前 min(vc,30) 条且保持顺序")
        }
    }

    func testVisibleEntriesClampsNegativeToEmpty() {
        XCTAssertEqual(WarLogDisplayProjection.visibleEntries([1, 2, 3], visibleCount: -5), [])
        XCTAssertEqual(WarLogDisplayProjection.visibleEntries([1, 2, 3], visibleCount: 0), [])
    }

    func testVisibleEntriesEmptyInput() {
        XCTAssertEqual(WarLogDisplayProjection.visibleEntries([String](), visibleCount: 10), [])
    }

    func testVisibleEntriesLessThanDefaultShowsAll() {
        let items = [1, 2]
        XCTAssertEqual(WarLogDisplayProjection.visibleEntries(items, visibleCount: 10), [1, 2])
    }

    // MARK: - moreState：全组合枚举 + 优先级

    func testMoreStateAllCombinations() {
        for total in 0...5 {
            for visible in 0...8 {
                for server in [false, true] {
                    let state = WarLogDisplayProjection.moreState(
                        totalEntries: total, visibleCount: visible, hasServerMore: server)
                    let expected: WarLogDisplayProjection.MoreState =
                        visible < total ? .localHidden
                        : (server ? .serverMore : .none)
                    XCTAssertEqual(state, expected,
                                   "total=\(total) visible=\(visible) server=\(server)")
                }
            }
        }
    }

    func testMoreStateLocalHiddenTakesPriorityOverServerMore() {
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 15, visibleCount: 10, hasServerMore: true),
            .localHidden)
    }

    func testMoreStateBoundaryExactlyAtTotal() {
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 10, visibleCount: 10, hasServerMore: false),
            .none)
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 10, visibleCount: 10, hasServerMore: true),
            .serverMore)
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 10, visibleCount: 9, hasServerMore: true),
            .localHidden)
    }

    func testMoreStateExhaustedLocallyButServerHasMore() {
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 10, visibleCount: 10, hasServerMore: true),
            .serverMore)
    }
}
