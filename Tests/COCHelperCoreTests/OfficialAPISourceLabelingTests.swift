import Foundation
import XCTest
@testable import COCHelperCore

/// 来源标签纯函数：ClanAPIState 与 ClanWarAPIState 共用（提取自 3a 的
/// ClanAPIState.sourceLabel，避免双份实现漂移）。
final class OfficialAPISourceLabelingTests: XCTestCase {
    func testSuccessShowsOfficialAPI() {
        XCTAssertEqual(
            OfficialAPISourceLabeling.label(status: .success, hasLastGood: true),
            "official-api"
        )
    }

    func testFailedWithLastGoodShowsCachedOfficialAPI() {
        XCTAssertEqual(
            OfficialAPISourceLabeling.label(status: .failed, hasLastGood: true),
            "cached-official-api"
        )
    }

    func testFailedWithoutLastGoodHidesLabel() {
        XCTAssertNil(OfficialAPISourceLabeling.label(status: .failed, hasLastGood: false))
    }

    func testNeverLoadingSkippedHideLabel() {
        XCTAssertNil(OfficialAPISourceLabeling.label(status: .never, hasLastGood: true))
        XCTAssertNil(OfficialAPISourceLabeling.label(status: .loading, hasLastGood: true))
        XCTAssertNil(OfficialAPISourceLabeling.label(status: .skipped, hasLastGood: true))
    }

    /// 现有 ClanAPIState.sourceLabel 必须与新纯函数一致（防双实现漂移）。
    func testClanAPIStateSourceLabelMatchesSharedFunction() {
        let states: [ClanAPIState] = [
            ClanAPIState(status: .success, clanTag: "#A",
                         lastGood: OfficialClanSnapshot(tag: "#A", name: "c", type: nil, description: nil,
                                                        clanLevel: 1, badgeUrls: nil, members: nil,
                                                        requiredTrophies: nil, requiredTownHallLevel: nil,
                                                        warWins: nil, warLosses: nil, warTies: nil,
                                                        warWinStreak: nil, isWarLogPublic: nil,
                                                        labels: nil, clanCapital: nil, unrecognizedKeys: [])),
            ClanAPIState(status: .failed, clanTag: "#A"),
            ClanAPIState(status: .failed, clanTag: "#A",
                         lastGood: OfficialClanSnapshot(tag: "#A", name: "c", type: nil, description: nil,
                                                        clanLevel: 1, badgeUrls: nil, members: nil,
                                                        requiredTrophies: nil, requiredTownHallLevel: nil,
                                                        warWins: nil, warLosses: nil, warTies: nil,
                                                        warWinStreak: nil, isWarLogPublic: nil,
                                                        labels: nil, clanCapital: nil, unrecognizedKeys: [])),
            ClanAPIState(status: .never, clanTag: "#A"),
        ]
        for state in states {
            XCTAssertEqual(
                state.sourceLabel,
                OfficialAPISourceLabeling.label(status: state.status, hasLastGood: state.lastGood != nil),
                "ClanAPIState.sourceLabel 必须与共享纯函数一致"
            )
        }
    }

    /// ClanWarAPIState 的 sourceLabel 同样走共享纯函数。
    func testClanWarAPIStateSourceLabelUsesSharedFunction() {
        let war = OfficialClanWarSnapshot(
            state: "inWar", teamSize: nil, attacksPerMember: nil,
            preparationStartTime: nil, startTime: nil, endTime: nil,
            warStartTime: nil, battleModifier: nil, clan: nil, opponent: nil, unrecognizedKeys: []
        )
        let success = ClanWarAPIState(status: .success, clanTag: "#A", lastGood: war)
        let failedWithGood = ClanWarAPIState(status: .failed, clanTag: "#A", lastGood: war)
        let failedNoGood = ClanWarAPIState(status: .failed, clanTag: "#A")

        XCTAssertEqual(success.sourceLabel, "official-api")
        XCTAssertEqual(failedWithGood.sourceLabel, "cached-official-api")
        XCTAssertNil(failedNoGood.sourceLabel)
    }
}
