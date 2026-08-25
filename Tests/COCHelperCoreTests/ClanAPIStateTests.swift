import Foundation
import XCTest
@testable import COCHelperCore

/// 确定性伪随机生成器（LCG，固定种子）：property-based 测试不依赖外部库，
/// 任意种子结果可复现。
struct LCG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class ClanAPIStateTests: XCTestCase {
    private let hour: TimeInterval = 3600

    // MARK: - 状态机（常规）

    func testDisplayStatusNeverIgnoresFetchedAt() {
        let state = ClanAPIState(
            status: .never,
            clanTag: "#CLAN",
            fetchedAt: Date(timeIntervalSinceNow: -30 * 24 * hour)
        )
        XCTAssertEqual(state.displayStatus, .never)
    }

    func testDisplayStatusLoading() {
        let state = ClanAPIState(status: .loading, clanTag: "#CLAN")
        XCTAssertEqual(state.displayStatus, .loading)
    }

    func testDisplayStatusSkipped() {
        let state = ClanAPIState(
            status: .skipped,
            clanTag: nil,
            lastErrorReason: "缺少有效的部落 tag，已跳过"
        )
        XCTAssertEqual(state.displayStatus, .skipped)
    }

    /// failed 状态即使残留旧 fetchedAt，也必须显示 failed 而非 stale
    /// （失败不清除 last-good，但展示语义必须诚实）。
    func testDisplayStatusFailedNeverBecomesStale() {
        let state = ClanAPIState(
            status: .failed,
            clanTag: "#CLAN",
            fetchedAt: Date(timeIntervalSinceNow: -3 * 24 * hour),
            lastErrorReason: "请求被限流（429），请稍后再试",
            lastGood: OfficialClanSnapshot(
                tag: "#CLAN", name: "old-good", type: nil, description: nil,
                clanLevel: 1, badgeUrls: nil, members: nil, requiredTrophies: nil,
                requiredTownHallLevel: nil, warWins: nil, warLosses: nil, warTies: nil,
                warWinStreak: nil, isWarLogPublic: nil, labels: nil, clanCapital: nil,
                unrecognizedKeys: []
            )
        )
        XCTAssertEqual(state.displayStatus, .failed)
    }

    func testDisplayStatusSuccessFresh() {
        let state = ClanAPIState(status: .success, clanTag: "#CLAN", fetchedAt: Date())
        XCTAssertEqual(state.displayStatus, .success)
    }

    func testDisplayStatusSuccessBecomesStaleAfterThreshold() {
        let state = ClanAPIState(
            status: .success,
            clanTag: "#CLAN",
            fetchedAt: Date(timeIntervalSinceNow: -(ClanAPIState.staleThreshold + 1))
        )
        XCTAssertEqual(state.displayStatus, .stale)
    }

    // MARK: - stale 边界

    func testStaleBoundaryExactlyAtThresholdIsNotStale() {
        // 与 player 版语义一致：严格大于阈值才算 stale。
        let now = Date()
        let state = ClanAPIState(
            status: .success,
            clanTag: "#CLAN",
            fetchedAt: now.addingTimeInterval(-ClanAPIState.staleThreshold)
        )
        XCTAssertFalse(state.isStale(at: now))
    }

    func testStaleBoundaryJustPastThresholdIsStale() {
        let now = Date()
        let state = ClanAPIState(
            status: .success,
            clanTag: "#CLAN",
            fetchedAt: now.addingTimeInterval(-ClanAPIState.staleThreshold - 1)
        )
        XCTAssertTrue(state.isStale(at: now))
    }

    func testIsStaleUsesInjectedDate() {
        let now = Date()
        let old = now.addingTimeInterval(-2 * 24 * hour)
        let state = ClanAPIState(status: .success, clanTag: "#CLAN", fetchedAt: old)
        // 未来视角（刷新后）：-12 天 → 不 stale
        XCTAssertFalse(state.isStale(at: now.addingTimeInterval(-10 * 24 * hour)))
        // 当前视角：+2 天 → stale
        XCTAssertTrue(state.isStale(at: now))
    }

    // MARK: - Property-based 不变量

    /// displayStatus 是纯函数：只依赖 (status, fetchedAt)。
    /// 随机组合必须满足完整真值表。
    /// 注意：不取精确边界值（displayStatus 内部用实时 Date()，与构造 fetchedAt
    /// 的 Date() 存在毫秒差，精确边界由注入 now 的专门测试覆盖）。
    func testDisplayStatusPropertyBasedInvariants() {
        var rng = LCG(seed: 0xC0C)
        let ageCandidates: [TimeInterval] = [
            0, 1, 100, ClanAPIState.staleThreshold - 60,
            ClanAPIState.staleThreshold + 60,
            10 * 24 * hour, -5, -24 * hour,
        ]

        for _ in 0..<200 {
            let statusIndex = Int.random(in: 0..<4, using: &rng)
            let status: OfficialAPIRequestStatus
            switch statusIndex {
            case 0: status = .never
            case 1: status = .loading
            case 2: status = .success
            case 3: status = .failed
            default: status = .skipped
            }
            let age = ageCandidates[Int.random(in: 0..<ageCandidates.count, using: &rng)]
            let state = ClanAPIState(status: status, clanTag: "#CLAN", fetchedAt: Date().addingTimeInterval(-age))

            switch status {
            case .never: XCTAssertEqual(state.displayStatus, .never)
            case .loading: XCTAssertEqual(state.displayStatus, .loading)
            case .failed: XCTAssertEqual(state.displayStatus, .failed)
            case .skipped: XCTAssertEqual(state.displayStatus, .skipped)
            case .success:
                if age > ClanAPIState.staleThreshold {
                    XCTAssertEqual(state.displayStatus, .stale, "age=\(age)")
                } else {
                    XCTAssertEqual(state.displayStatus, .success, "age=\(age)")
                }
            }
        }
    }

    /// Codable round-trip：随机状态编解码后全字段保持。
    func testCodableRoundTripPropertyBased() {
        var rng = LCG(seed: 0xBEEF)
        for _ in 0..<100 {
            let state = ClanAPIState(
                status: [.never, .loading, .success, .failed, .skipped].randomElement(using: &rng)!,
                clanTag: Bool.random(using: &rng) ? "#CLAN\(Int.random(in: 0...999, using: &rng))" : nil,
                fetchedAt: Bool.random(using: &rng) ? Date(timeIntervalSince1970: Double.random(in: 0...4_000_000_000, using: &rng)) : nil,
                lastAttemptAt: Bool.random(using: &rng) ? Date(timeIntervalSince1970: Double.random(in: 0...4_000_000_000, using: &rng)) : nil,
                lastErrorReason: Bool.random(using: &rng) ? "reason-\(Int.random(in: 0...9, using: &rng))" : nil,
                lastHTTPStatus: Bool.random(using: &rng) ? [401, 403, 404, 429, 500].randomElement(using: &rng) : nil,
                // Issue #252：结构化失败类别也纳入 round-trip 覆盖。
                failureKind: Bool.random(using: &rng)
                    ? [OfficialEndpointFailureKind.missingCredentials, .unauthorized, .accessDenied,
                       .notFound, .rateLimited, .serverError, .timeout, .network,
                       .malformedResponse, .cancelled].randomElement(using: &rng)!
                    : nil,
                lastGood: Bool.random(using: &rng) ? OfficialClanSnapshot(
                    tag: "#CLAN", name: "clan-\(Int.random(in: 0...99, using: &rng))", type: nil,
                    description: nil, clanLevel: Int.random(in: 1...50, using: &rng),
                    badgeUrls: nil, members: nil, requiredTrophies: nil,
                    requiredTownHallLevel: nil, warWins: nil, warLosses: nil, warTies: nil,
                    warWinStreak: nil, isWarLogPublic: nil, labels: nil, clanCapital: nil,
                    unrecognizedKeys: Bool.random(using: &rng) ? ["futureField"] : []
                ) : nil,
                unrecognizedKeys: Bool.random(using: &rng) ? ["a", "b"] : []
            )

            let data = try! JSONEncoder().encode(state)
            let decoded = try! JSONDecoder().decode(ClanAPIState.self, from: data)

            XCTAssertEqual(decoded, state)
            XCTAssertEqual(decoded.lastGood, state.lastGood)
            XCTAssertEqual(decoded.unrecognizedKeys, state.unrecognizedKeys)
        }
    }

    /// 失败语义：failed 状态携带 lastGood 时，编解码后 lastGood 仍在
    /// （last-good 契约的持久化保证）。
    func testFailedStateKeepsLastGoodThroughPersistence() {
        let snapshot = OfficialClanSnapshot(
            tag: "#CLAN", name: "good-clan", type: nil, description: nil,
            clanLevel: 9, badgeUrls: nil, members: 40, requiredTrophies: nil,
            requiredTownHallLevel: nil, warWins: 100, warLosses: nil, warTies: nil,
            warWinStreak: nil, isWarLogPublic: nil, labels: nil, clanCapital: nil,
            unrecognizedKeys: []
        )
        let state = ClanAPIState(
            status: .failed, clanTag: "#CLAN",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastErrorReason: "请求超时", lastGood: snapshot
        )

        let data = try! JSONEncoder().encode(state)
        let decoded = try! JSONDecoder().decode(ClanAPIState.self, from: data)

        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(decoded.lastGood?.name, "good-clan")
        XCTAssertEqual(decoded.fetchedAt, state.fetchedAt)
        XCTAssertEqual(decoded.lastErrorReason, "请求超时")
    }
}
