import Foundation
import XCTest
@testable import COCHelperCore

/// 泛化兼容性（3c 前置承诺）：`OfficialEndpointState<T>` 必须与旧
/// `ClanAPIState`/`ClanWarAPIState` 编码键一致（typealias 后旧持久化数据
/// 仍可解码）；分页游标逻辑必须防无限循环。
final class GenericEndpointStateTests: XCTestCase {
    private func clanSnapshot() -> OfficialClanSnapshot {
        OfficialClanSnapshot(
            tag: "#CLAN", name: "c", type: nil, description: nil,
            clanLevel: 1, badgeUrls: nil, members: nil, requiredTrophies: nil,
            requiredTownHallLevel: nil, warWins: nil, warLosses: nil, warTies: nil,
            warWinStreak: nil, isWarLogPublic: nil, labels: nil, clanCapital: nil,
            unrecognizedKeys: []
        )
    }

    private func warSnapshot() -> OfficialClanWarSnapshot {
        OfficialClanWarSnapshot(
            state: "notInWar", teamSize: nil, attacksPerMember: nil,
            preparationStartTime: nil, startTime: nil, endTime: nil,
            warStartTime: nil, clan: nil, opponent: nil, unrecognizedKeys: []
        )
    }

    // MARK: - typealias 兼容（旧持久化数据）

    /// 旧 ClanAPIState 编码产物的 JSON 键与泛型一致（typealias 前格式）。
    func testGenericStateEncodingKeysMatchLegacyFormat() throws {
        // 构造全字段（nil 字段会被 encodeIfPresent 省略，需传非 nil 验证全键）
        let state = OfficialEndpointState<OfficialClanSnapshot>(
            status: .success,
            clanTag: "#CLAN",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastErrorReason: "x",
            lastHTTPStatus: 429,
            parserVersion: ClanAPIState.currentParserVersion,
            lastGood: clanSnapshot(),
            unrecognizedKeys: ["x"]
        )
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state)
        ) as? [String: Any]

        XCTAssertEqual(Set(json?.keys ?? [:].keys), [
            "status", "clanTag", "fetchedAt", "lastAttemptAt", "lastErrorReason",
            "lastHTTPStatus", "parserVersion", "lastGood", "unrecognizedKeys",
        ], "泛型编码键必须与旧格式一致（持久化兼容）")
        XCTAssertEqual(json?["parserVersion"] as? String, "clan-snapshot-0.3")
    }

    /// typealias：ClanAPIState 就是泛型实例化（编译期验证 + 行为一致）。
    func testTypealiasesResolveToGenericType() {
        let clanState = ClanAPIState(status: .never, clanTag: "#A")
        let warState = ClanWarAPIState(status: .never, clanTag: "#A")
        // 编译期：两者都是 OfficialEndpointState 的实例
        XCTAssertEqual(clanState.clanTag, warState.clanTag)
        XCTAssertEqual(
            OfficialEndpointState<OfficialClanSnapshot>.currentParserVersion,
            ClanAPIState.currentParserVersion
        )
    }

    /// 泛型跨 Snapshot 类型 round-trip（warlog/capital 页作为 lastGood）。
    func testGenericStateRoundTripWithPaginatedLastGood() throws {
        let page = OfficialWarLogPage(
            page: OfficialPaginatedPage<OfficialWarLogEntry>(items: [], before: "B", after: "A")
        )
        let state = OfficialEndpointState<OfficialWarLogPage>(
            status: .success,
            clanTag: "#CLAN",
            lastGood: page
        )

        let decoded = try JSONDecoder().decode(
            OfficialEndpointState<OfficialWarLogPage>.self,
            from: try JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.lastGood?.after, "A")
    }

    /// P2 回归：默认构造的 parserVersion 必须恢复端点版本
    /// （当前语义：`ClanAPIState(...)` 默认 "clan-snapshot-0.3"，
    /// 不得产生无法审计的 "endpoint-state"）。
    func testDefaultParserVersionRestoredPerEndpoint() {
        let clan = ClanAPIState(status: .never, clanTag: "#A")
        XCTAssertEqual(clan.parserVersion, "clan-snapshot-0.3")

        let war = ClanWarAPIState(status: .never, clanTag: "#A")
        XCTAssertEqual(war.parserVersion, "clan-war-0.2")

        let warLog = ClanWarLogAPIState(status: .never, clanTag: "#A")
        XCTAssertEqual(warLog.parserVersion, "clan-war-log-0.3")

        let capital = ClanCapitalAPIState(status: .never, clanTag: "#A")
        XCTAssertEqual(capital.parserVersion, "clan-capital-0.3")
    }

    func testParserVersionIdentifiesLegacyClanCache() {
        let legacy = ClanAPIState(
            status: .success,
            clanTag: "#A",
            parserVersion: "clan-snapshot-0.2"
        )
        let current = ClanAPIState(status: .success, clanTag: "#A")

        XCTAssertFalse(legacy.isCurrentParserVersion)
        XCTAssertTrue(current.isCurrentParserVersion)
    }

    // MARK: - 分页游标逻辑（防无限循环）

    func testHasMoreStopsWhenCursorDoesNotAdvance() {
        // 响应 after == 请求游标 → 游标未前进 → 停止
        XCTAssertFalse(PaginationLogic.hasMore(requestedCursor: "C1", responseAfter: "C1"))
        // 响应 after nil（末页）→ 停止
        XCTAssertFalse(PaginationLogic.hasMore(requestedCursor: "C1", responseAfter: nil))
        // 首屏（无请求游标）+ 响应 after 非 nil → 有更多
        XCTAssertTrue(PaginationLogic.hasMore(requestedCursor: nil, responseAfter: "C2"))
        // 新游标 ≠ 请求游标 → 有更多
        XCTAssertTrue(PaginationLogic.hasMore(requestedCursor: "C1", responseAfter: "C2"))
    }

    /// property-based：hasMore 是纯函数，随机组合满足真值表。
    func testHasMorePropertyBased() {
        var rng = LCG(seed: 0x3C3)
        let cursors: [String?] = [nil, "", "C1", "C2", "SAME", "SAME"]
        for _ in 0..<200 {
            let requested = cursors[Int.random(in: 0..<cursors.count, using: &rng)]
            let response = cursors[Int.random(in: 0..<cursors.count, using: &rng)]

            let expected: Bool
            if let response {
                expected = response != requested
            } else {
                expected = false
            }
            XCTAssertEqual(
                PaginationLogic.hasMore(requestedCursor: requested, responseAfter: response),
                expected,
                "requested=\(String(describing: requested)) response=\(String(describing: response))"
            )
        }
    }

    // MARK: - 泛型 store 兼容

    /// OfficialStateStore<T> 编码格式与旧 ClanStateStore 一致（单元素字典数组）。
    func testGenericStoreEncodingMatchesLegacyFormat() throws {
        let store = OfficialStateStore<ClanAPIState>(states: [
            "#A": ClanAPIState(status: .success, clanTag: "#A"),
        ])
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(store)
        ) as? [[String: Any]]

        XCTAssertEqual(json?.count, 1)
        XCTAssertNotNil(json?.first?["#A"], "存储格式必须是单元素字典数组（与旧格式一致）")
    }
}
