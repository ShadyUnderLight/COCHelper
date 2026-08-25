import Foundation
import XCTest
@testable import COCHelperCore

/// ClanWarAPIState 状态机：与 ClanAPIState 同构（displayStatus/isStale/
/// sourceLabel 契约），另验证 notInWar 快照的持久化语义。
final class ClanWarAPIStateTests: XCTestCase {
    private let hour: TimeInterval = 3600

    // MARK: - 状态机（关键分支）

    func testDisplayStatusFailedNeverBecomesStale() {
        let state = ClanWarAPIState(
            status: .failed,
            clanTag: "#CLAN",
            fetchedAt: Date(timeIntervalSinceNow: -3 * 24 * hour),
            lastErrorReason: "请求超时",
            lastGood: OfficialClanWarSnapshot(
                state: "inWar", teamSize: nil, attacksPerMember: nil,
                preparationStartTime: nil, startTime: nil, endTime: nil,
                warStartTime: nil, battleModifier: nil, clan: nil, opponent: nil, unrecognizedKeys: []
            )
        )
        XCTAssertEqual(state.displayStatus, .failed)
    }

    func testDisplayStatusSuccessBecomesStaleAfterThreshold() {
        let state = ClanWarAPIState(
            status: .success,
            clanTag: "#CLAN",
            fetchedAt: Date(timeIntervalSinceNow: -(ClanWarAPIState.staleThreshold + 1))
        )
        XCTAssertEqual(state.displayStatus, .stale)
    }

    func testStaleBoundaryExactlyAtThresholdIsNotStale() {
        let now = Date()
        let state = ClanWarAPIState(
            status: .success,
            clanTag: "#CLAN",
            fetchedAt: now.addingTimeInterval(-ClanWarAPIState.staleThreshold)
        )
        XCTAssertFalse(state.isStale(at: now))
    }

    // MARK: - notInWar 快照语义（成功状态，不是失败）

    /// notInWar 是 success + lastGood（state == "notInWar"），持久化后保持。
    func testNotInWarSnapshotIsSuccessAndPersists() throws {
        let notInWar = OfficialClanWarSnapshot(
            state: "notInWar", teamSize: nil, attacksPerMember: nil,
            preparationStartTime: nil, startTime: nil, endTime: nil,
            warStartTime: nil, battleModifier: nil, clan: nil, opponent: nil, unrecognizedKeys: []
        )
        let state = ClanWarAPIState(status: .success, clanTag: "#CLAN", lastGood: notInWar)

        XCTAssertEqual(state.displayStatus, .success)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ClanWarAPIState.self, from: data)
        XCTAssertEqual(decoded.status, .success)
        XCTAssertEqual(decoded.lastGood?.state, "notInWar")
    }

    // MARK: - Property-based 不变量

    /// displayStatus 是纯函数：随机组合必须满足完整真值表。
    func testDisplayStatusPropertyBasedInvariants() {
        var rng = LCG(seed: 0x1A7B5)
        let ageCandidates: [TimeInterval] = [
            0, 1, 100, ClanWarAPIState.staleThreshold - 60,
            ClanWarAPIState.staleThreshold + 60, 10 * 24 * hour, -5,
        ]

        for _ in 0..<200 {
            let statusIndex = Int.random(in: 0..<5, using: &rng)
            let status: OfficialAPIRequestStatus
            switch statusIndex {
            case 0: status = .never
            case 1: status = .loading
            case 2: status = .success
            case 3: status = .failed
            default: status = .skipped
            }
            let age = ageCandidates[Int.random(in: 0..<ageCandidates.count, using: &rng)]
            let state = ClanWarAPIState(status: status, clanTag: "#CLAN", fetchedAt: Date().addingTimeInterval(-age))

            switch status {
            case .never: XCTAssertEqual(state.displayStatus, .never)
            case .loading: XCTAssertEqual(state.displayStatus, .loading)
            case .failed: XCTAssertEqual(state.displayStatus, .failed)
            case .skipped: XCTAssertEqual(state.displayStatus, .skipped)
            case .success:
                if age > ClanWarAPIState.staleThreshold {
                    XCTAssertEqual(state.displayStatus, .stale, "age=\(age)")
                } else {
                    XCTAssertEqual(state.displayStatus, .success, "age=\(age)")
                }
            }
        }
    }

    /// Codable round-trip：随机状态编解码后全字段保持。
    func testCodableRoundTripPropertyBased() {
        var rng = LCG(seed: 0xC0FFEE)
        for _ in 0..<100 {
            let state = ClanWarAPIState(
                status: [.never, .loading, .success, .failed, .skipped].randomElement(using: &rng)!,
                clanTag: Bool.random(using: &rng) ? "#CLAN\(Int.random(in: 0...999, using: &rng))" : nil,
                fetchedAt: Bool.random(using: &rng) ? Date(timeIntervalSince1970: Double.random(in: 0...4_000_000_000, using: &rng)) : nil,
                lastErrorReason: Bool.random(using: &rng) ? "reason-\(Int.random(in: 0...9, using: &rng))" : nil,
                lastHTTPStatus: Bool.random(using: &rng) ? [401, 403, 404, 429, 500].randomElement(using: &rng) : nil,
                // Issue #252：结构化失败类别纳入泛型 round-trip 覆盖。
                failureKind: Bool.random(using: &rng)
                    ? [OfficialEndpointFailureKind.missingCredentials, .unauthorized, .accessDenied,
                       .notFound, .rateLimited, .serverError, .timeout, .network,
                       .malformedResponse, .cancelled].randomElement(using: &rng)!
                    : nil,
                lastGood: Bool.random(using: &rng) ? OfficialClanWarSnapshot(
                    state: ["notInWar", "preparation", "inWar", "warEnded"].randomElement(using: &rng),
                    teamSize: Int.random(in: 1...50, using: &rng), attacksPerMember: Int.random(in: 1...2, using: &rng),
                    preparationStartTime: nil, startTime: nil, endTime: nil,
                    warStartTime: nil,
                    battleModifier: Bool.random(using: &rng) ? "hardMode" : nil,
                    clan: nil, opponent: nil,
                    unrecognizedKeys: Bool.random(using: &rng) ? ["futureField"] : []
                ) : nil,
                unrecognizedKeys: Bool.random(using: &rng) ? ["a", "b"] : []
            )

            let decoded = try! JSONDecoder().decode(
                ClanWarAPIState.self,
                from: try! JSONEncoder().encode(state)
            )
            XCTAssertEqual(decoded, state)
            XCTAssertEqual(decoded.lastGood, state.lastGood)
        }
    }
}
