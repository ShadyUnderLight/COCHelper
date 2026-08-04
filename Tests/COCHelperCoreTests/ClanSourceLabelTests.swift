import Foundation
import XCTest
@testable import COCHelperCore

/// 部落卡片的来源标签（sourceLabel）：基于部落状态本身，而非玩家状态。
/// 契约：
/// - success / stale（success 的时间派生）→ "official-api"
/// - failed 且保留 last-good → "cached-official-api"
/// - failed 无 last-good / never / loading / skipped → nil（隐藏，避免误导）
final class ClanSourceLabelTests: XCTestCase {
    private func makeState(
        _ status: OfficialAPIRequestStatus,
        lastGood: OfficialClanSnapshot? = nil,
        fetchedAt: Date? = nil
    ) -> ClanAPIState {
        ClanAPIState(
            status: status,
            clanTag: "#CLAN",
            fetchedAt: fetchedAt,
            lastGood: lastGood
        )
    }

    private func sampleSnapshot(name: String = "clan") -> OfficialClanSnapshot {
        OfficialClanSnapshot(
            tag: "#CLAN", name: name, type: nil, description: nil,
            clanLevel: 1, badgeUrls: nil, members: nil, requiredTrophies: nil,
            requiredTownHallLevel: nil, warWins: nil, warLosses: nil, warTies: nil,
            warWinStreak: nil, isWarLogPublic: nil, labels: nil, clanCapital: nil,
            unrecognizedKeys: []
        )
    }

    func testSuccessShowsOfficialAPI() {
        XCTAssertEqual(makeState(.success, lastGood: sampleSnapshot()).sourceLabel, "official-api")
    }

    /// stale 是 success 的时间派生，来源仍是官方，标签不变。
    func testStaleStillShowsOfficialAPI() {
        let state = makeState(
            .success,
            lastGood: sampleSnapshot(),
            fetchedAt: Date(timeIntervalSinceNow: -48 * 3600)
        )
        XCTAssertEqual(state.displayStatus, .stale)
        XCTAssertEqual(state.sourceLabel, "official-api")
    }

    func testFailedWithLastGoodShowsCachedOfficialAPI() {
        let state = makeState(.failed, lastGood: sampleSnapshot(name: "old-good"))
        XCTAssertEqual(state.sourceLabel, "cached-official-api")
    }

    func testFailedWithoutLastGoodHidesLabel() {
        let state = makeState(.failed)
        XCTAssertNil(state.sourceLabel)
    }

    func testNeverHidesLabel() {
        XCTAssertNil(makeState(.never).sourceLabel)
    }

    func testLoadingHidesLabel() {
        XCTAssertNil(makeState(.loading).sourceLabel)
    }

    func testSkippedHidesLabel() {
        XCTAssertNil(makeState(.skipped).sourceLabel)
    }
}
