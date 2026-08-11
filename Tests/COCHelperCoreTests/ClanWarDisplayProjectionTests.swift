import XCTest
@testable import COCHelperCore

/// Issue #125：部落对战展示投影的单元测试。
///
/// 覆盖 spec（docs/plans/2026-08-11-issue125-war-display-projection.md）语义规则 1-11：
/// phase 映射、配额 fail-closed、成员行动 6 态、星数 known/unknown 分离、
/// 确定性排序、六桶计数、displayGroup 组合点、nil vs [] 区分、官方/成员分层与诊断、
/// 刷新状态、摧毁率逐次保留。
final class ClanWarDisplayProjectionTests: XCTestCase {

    // MARK: - 构造辅助

    private func attack(order: Int? = nil, stars: Int? = nil, destruction: Double? = nil) -> ClanWarAttack {
        ClanWarAttack(order: order, attackerTag: nil, defenderTag: nil,
                      stars: stars, destructionPercentage: destruction, duration: nil)
    }

    private func member(
        tag: String? = nil, name: String? = nil, mapPosition: Int? = nil,
        townhallLevel: Int? = nil, attacks: [ClanWarAttack]? = nil
    ) -> ClanWarMember {
        ClanWarMember(tag: tag, name: name, mapPosition: mapPosition,
                      townhallLevel: townhallLevel, attacks: attacks,
                      opponentAttacks: nil, bestOpponentAttack: nil)
    }

    private func participant(
        tag: String? = nil, name: String? = nil, clanLevel: Int? = nil,
        attacks: Int? = nil, stars: Int? = nil, destruction: Double? = nil,
        members: [ClanWarMember]? = nil
    ) -> ClanWarParticipant {
        ClanWarParticipant(tag: tag, name: name, badgeUrls: nil, clanLevel: clanLevel,
                           attacks: attacks, stars: stars,
                           destructionPercentage: destruction, members: members)
    }

    private func snapshot(
        state: String? = "inWar", teamSize: Int? = 10, attacksPerMember: Int? = 2,
        clan: ClanWarParticipant? = nil, opponent: ClanWarParticipant? = nil
    ) -> OfficialClanWarSnapshot {
        OfficialClanWarSnapshot(
            state: state, teamSize: teamSize, attacksPerMember: attacksPerMember,
            preparationStartTime: nil, startTime: nil, endTime: nil, warStartTime: nil,
            battleModifier: nil, clan: clan, opponent: opponent, unrecognizedKeys: []
        )
    }

    private func warState(status: OfficialAPIRequestStatus, fetchedAt: Date? = nil,
                          lastGood: OfficialClanWarSnapshot? = nil) -> ClanWarAPIState {
        ClanWarAPIState(status: status, fetchedAt: fetchedAt, lastGood: lastGood)
    }

    // MARK: - phase（规则 1）

    func testPhaseMapsKnownStates() {
        XCTAssertEqual(ClanWarDisplayProjection.phase(of: "notInWar"), .notInWar)
        XCTAssertEqual(ClanWarDisplayProjection.phase(of: "preparation"), .preparation)
        XCTAssertEqual(ClanWarDisplayProjection.phase(of: "inWar"), .inWar)
        XCTAssertEqual(ClanWarDisplayProjection.phase(of: "warEnded"), .warEnded)
    }

    func testPhaseUnknownPreservesRawValue() {
        let phase = ClanWarDisplayProjection.phase(of: "brandNewState")
        XCTAssertEqual(phase, .unknown(raw: "brandNewState"))
    }

    func testPhaseUnknownForMissingState() {
        XCTAssertEqual(ClanWarDisplayProjection.phase(of: nil), .unknown(raw: nil))
    }

    func testPhaseEmptyAndWhitespaceIsUnknown() {
        XCTAssertEqual(ClanWarDisplayProjection.phase(of: ""), .unknown(raw: ""))
        XCTAssertEqual(ClanWarDisplayProjection.phase(of: "  "), .unknown(raw: "  "))
        // spec 规则 1：trim 后精确匹配 → 带首尾空白的已知状态仍映射为已知阶段
        XCTAssertEqual(ClanWarDisplayProjection.phase(of: " inWar"), .inWar)
        XCTAssertEqual(ClanWarDisplayProjection.phase(of: "warEnded "), .warEnded)
    }

    // MARK: - quota（规则 2）

    func testQuotaNormalMultiplication() {
        let q = ClanWarDisplayProjection.quota(teamSize: 10, attacksPerMember: 2)
        XCTAssertEqual(q.totalAttacks, 20)
        XCTAssertFalse(q.saturated)
    }

    func testQuotaMissingFieldYieldsNilTotal() {
        XCTAssertNil(ClanWarDisplayProjection.quota(teamSize: nil, attacksPerMember: 2).totalAttacks)
        XCTAssertNil(ClanWarDisplayProjection.quota(teamSize: 10, attacksPerMember: nil).totalAttacks)
        XCTAssertNil(ClanWarDisplayProjection.quota(teamSize: nil, attacksPerMember: nil).totalAttacks)
    }

    func testQuotaZeroOrNegativeYieldsNilTotal() {
        XCTAssertNil(ClanWarDisplayProjection.quota(teamSize: 10, attacksPerMember: 0).totalAttacks)
        XCTAssertNil(ClanWarDisplayProjection.quota(teamSize: 10, attacksPerMember: -2).totalAttacks)
        XCTAssertNil(ClanWarDisplayProjection.quota(teamSize: -5, attacksPerMember: 2).totalAttacks)
        XCTAssertNil(ClanWarDisplayProjection.quota(teamSize: 0, attacksPerMember: 2).totalAttacks)
        // 无效配额不置饱和标志
        XCTAssertFalse(ClanWarDisplayProjection.quota(teamSize: 10, attacksPerMember: -2).saturated)
    }

    func testQuotaOverflowSaturatesWithoutCrash() {
        let q = ClanWarDisplayProjection.quota(teamSize: Int.max, attacksPerMember: Int.max)
        XCTAssertTrue(q.saturated)
        XCTAssertEqual(q.totalAttacks, Int.max)
    }

    func testQuotaKeepsRawValues() {
        let q = ClanWarDisplayProjection.quota(teamSize: -3, attacksPerMember: 0)
        XCTAssertEqual(q.teamSize, -3)
        XCTAssertEqual(q.attacksPerMember, 0)
    }

    // MARK: - memberAction（规则 3）

    func testMemberActionNilAttacksIsUnknown() {
        let action = ClanWarDisplayProjection.memberAction(attacks: nil, attacksPerMember: 2)
        XCTAssertEqual(action.status, .unknown)
        XCTAssertNil(action.attackCount)
        XCTAssertNil(action.remainingAttacks)
    }

    func testMemberActionEmptyAttacksIsZeroRegardlessOfQuota() {
        // 配额无关：即使配额缺失，[] 也是明确 0 次
        let withQuota = ClanWarDisplayProjection.memberAction(attacks: [], attacksPerMember: 2)
        XCTAssertEqual(withQuota.status, .zero)
        XCTAssertEqual(withQuota.attackCount, 0)

        let noQuota = ClanWarDisplayProjection.memberAction(attacks: [], attacksPerMember: nil)
        XCTAssertEqual(noQuota.status, .zero)
        XCTAssertEqual(noQuota.attackCount, 0)
    }

    func testMemberActionPartialReturnsRemaining() {
        let attacks = [attack(stars: 3)]
        let action = ClanWarDisplayProjection.memberAction(attacks: attacks, attacksPerMember: 2)
        XCTAssertEqual(action.status, .partial)
        XCTAssertEqual(action.attackCount, 1)
        XCTAssertEqual(action.remainingAttacks, 1)
    }

    func testMemberActionCompleteHasNilRemaining() {
        let attacks = [attack(stars: 3), attack(stars: 2)]
        let action = ClanWarDisplayProjection.memberAction(attacks: attacks, attacksPerMember: 2)
        XCTAssertEqual(action.status, .complete)
        XCTAssertEqual(action.attackCount, 2)
        XCTAssertNil(action.remainingAttacks)
    }

    func testMemberActionOverQuota() {
        let attacks = [attack(stars: 3), attack(stars: 2), attack(stars: 1)]
        let action = ClanWarDisplayProjection.memberAction(attacks: attacks, attacksPerMember: 2)
        XCTAssertEqual(action.status, .overQuota)
        XCTAssertEqual(action.attackCount, 3)
        XCTAssertNil(action.remainingAttacks)
    }

    func testMemberActionQuotaUnknownWhenQuotaInvalid() {
        // 配额缺失、0、负数 + 已有攻击 → quotaUnknown，不假设配额
        let attacks = [attack(stars: 3)]
        let nilQuota = ClanWarDisplayProjection.memberAction(attacks: attacks, attacksPerMember: nil)
        XCTAssertEqual(nilQuota.status, .quotaUnknown)
        XCTAssertEqual(nilQuota.attackCount, 1)

        let zeroQuota = ClanWarDisplayProjection.memberAction(attacks: attacks, attacksPerMember: 0)
        XCTAssertEqual(zeroQuota.status, .quotaUnknown)

        let negativeQuota = ClanWarDisplayProjection.memberAction(attacks: attacks, attacksPerMember: -2)
        XCTAssertEqual(negativeQuota.status, .quotaUnknown)

        // 攻击次数已知，但无法判定剩余
        XCTAssertNil(nilQuota.remainingAttacks)
    }

    // MARK: - memberStars（规则 4）

    func testMemberStarsAllKnown() {
        let m = member(attacks: [attack(stars: 1), attack(stars: 2), attack(stars: 3)])
        let stars = ClanWarDisplayProjection.memberStars(m)
        XCTAssertEqual(stars?.knownStars, 6)
        XCTAssertEqual(stars?.missingCount, 0)
    }

    func testMemberStarsPartialMissing() {
        let m = member(attacks: [attack(stars: 1), attack(stars: nil), attack(stars: 3)])
        let stars = ClanWarDisplayProjection.memberStars(m)
        XCTAssertEqual(stars?.knownStars, 4)
        XCTAssertEqual(stars?.missingCount, 1)
    }

    func testMemberStarsAllMissing() {
        let m = member(attacks: [attack(stars: nil), attack(stars: nil)])
        let stars = ClanWarDisplayProjection.memberStars(m)
        XCTAssertEqual(stars?.knownStars, 0)
        XCTAssertEqual(stars?.missingCount, 2)
    }

    func testMemberStarsNilAttacksIsNil() {
        let m = member(attacks: nil)
        XCTAssertNil(ClanWarDisplayProjection.memberStars(m))
    }

    func testMemberStarsEmptyAttacksIsZeroZero() {
        let m = member(attacks: [])
        let stars = ClanWarDisplayProjection.memberStars(m)
        XCTAssertEqual(stars?.knownStars, 0)
        XCTAssertEqual(stars?.missingCount, 0)
    }

    func testMemberStarsNegativeStarsClamped() {
        // 负数星数 clamp 到 [0,3] 后计入（与 UI 现有展示一致）
        let m = member(attacks: [attack(stars: -1), attack(stars: 5), attack(stars: 3)])
        let stars = ClanWarDisplayProjection.memberStars(m)
        XCTAssertEqual(stars?.knownStars, 6) // 0 + 3 + 3
    }

    // MARK: - sortedRows（规则 5）

    /// 四组顺序：zero(0) < partial(1) < complete(2) < {overQuota, quotaUnknown, unknown}(3)
    /// 注：quotaUnknown 与 partial 不能在同一全局 quota 下共存（成员状态由全局
    /// attacksPerMember 决定），故本测试覆盖 zero/partial/complete/overQuota/unknown，
    /// quotaUnknown 的组内位置由 testSortedRowsQuotaUnknownGroup 验证。
    func testSortedRowsGroupOrder() {
        let zero = member(tag: "z", name: "零攻击", mapPosition: 5, attacks: [])
        let partial = member(tag: "p", name: "部分", mapPosition: 3, attacks: [attack(stars: 1)])
        let complete = member(tag: "c", name: "完成", mapPosition: 4,
                              attacks: [attack(stars: 1), attack(stars: 2)])
        let unknown = member(tag: "u", name: "未知", mapPosition: 1, attacks: nil)
        let over = member(tag: "o", name: "超额", mapPosition: 2,
                          attacks: [attack(stars: 1), attack(stars: 2), attack(stars: 3)])

        let rows = ClanWarDisplayProjection.sortedRows(
            [over, unknown, complete, partial, zero],
            attacksPerMember: 2
        )
        // rank3 组内：u（position 1）在 o（position 2）前
        XCTAssertEqual(rows.map(\.tag), ["z", "p", "c", "u", "o"])
    }

    /// quotaUnknown 与 unknown、overQuota 同属"数据未知"组（rank 3）。
    func testSortedRowsQuotaUnknownGroup() {
        let unknown = member(tag: "u", name: "未知", mapPosition: 1, attacks: nil)
        let quotaUnknown = member(tag: "q", name: "配额未知", mapPosition: 2, attacks: [attack(stars: 1)])
        let over = member(tag: "o", name: "超额", mapPosition: 3,
                          attacks: [attack(stars: 1), attack(stars: 2)])
        let rows = ClanWarDisplayProjection.sortedRows([over, unknown, quotaUnknown],
                                                       attacksPerMember: nil)
        XCTAssertEqual(rows.map(\.tag), ["u", "q", "o"])
    }

    func testSortedRowsTieBreakPositionNameIndex() {
        // 同组（partial）：mapPosition 升序 → name 字典序 → sourceIndex 升序
        let a = member(tag: "a", name: "B", mapPosition: 2, attacks: [attack()])
        let b = member(tag: "b", name: "A", mapPosition: 2, attacks: [attack()])
        let c = member(tag: "c", name: "A", mapPosition: 1, attacks: [attack()])
        let d = member(tag: "d", name: "A", mapPosition: 1, attacks: [attack()])
        let rows = ClanWarDisplayProjection.sortedRows([a, b, d, c], attacksPerMember: 2)
        // position 1 的两个（name 相同按 sourceIndex：d(2) 在 c(3) 前）→ position 2（A 在 B 前）
        XCTAssertEqual(rows.map(\.tag), ["d", "c", "b", "a"])
    }

    func testSortedRowsNilPositionAndNameSortLast() {
        let nilPosition = member(tag: "np", name: "A", mapPosition: nil, attacks: [attack()])
        let nilName = member(tag: "nn", name: nil, mapPosition: 1, attacks: [attack()])
        let bothNil = member(tag: "bn", name: nil, mapPosition: nil, attacks: [attack()])
        let normal = member(tag: "n", name: "M", mapPosition: 1, attacks: [attack()])
        let rows = ClanWarDisplayProjection.sortedRows([bothNil, nilName, nilPosition, normal],
                                                       attacksPerMember: 2)
        // position 优先：n、nn（position 1）在前（组内 name：M 有值先于 nil）
        // → np（position nil 但 name 有值）→ bn（全 nil 最后）
        XCTAssertEqual(rows.map(\.tag), ["n", "nn", "np", "bn"])
    }

    func testSortedRowsIdempotent() {
        let members = [
            member(tag: "a", name: "X", mapPosition: 3, attacks: nil),
            member(tag: "b", name: "Y", mapPosition: 1, attacks: [attack()]),
            member(tag: "c", name: nil, mapPosition: 2, attacks: []),
        ]
        let first = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        let second = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        XCTAssertEqual(first, second)
    }

    // MARK: - actionCounts（规则 6）

    func testActionCountsSumConserved() {
        // quota 已知场景：unknown/zero/partial/complete/overQuota 五桶各 1
        let rows = ClanWarDisplayProjection.sortedRows([
            member(tag: "1", attacks: nil),
            member(tag: "2", attacks: []),
            member(tag: "3", attacks: [attack()]),
            member(tag: "4", attacks: [attack(), attack()]),
            member(tag: "5", attacks: [attack(), attack(), attack()]),
        ], attacksPerMember: 2)
        let counts = ClanWarDisplayProjection.actionCounts(rows)
        XCTAssertEqual(counts.unknownCount, 1)
        XCTAssertEqual(counts.zeroCount, 1)
        XCTAssertEqual(counts.partialCount, 1)
        XCTAssertEqual(counts.completeCount, 1)
        XCTAssertEqual(counts.overQuotaCount, 1)
        XCTAssertEqual(counts.quotaUnknownCount, 0)
        let sum = counts.unknownCount + counts.zeroCount + counts.partialCount
            + counts.completeCount + counts.overQuotaCount + counts.quotaUnknownCount
        XCTAssertEqual(sum, rows.count)

        // quota 未知场景：已有攻击的成员全部归 quotaUnknown 桶
        let rowsNoQuota = ClanWarDisplayProjection.sortedRows([
            member(tag: "6", attacks: [attack()]),
            member(tag: "7", attacks: [attack(), attack()]),
        ], attacksPerMember: nil)
        let countsNoQuota = ClanWarDisplayProjection.actionCounts(rowsNoQuota)
        XCTAssertEqual(countsNoQuota.quotaUnknownCount, 2)
        let sumNoQuota = countsNoQuota.unknownCount + countsNoQuota.zeroCount + countsNoQuota.partialCount
            + countsNoQuota.completeCount + countsNoQuota.overQuotaCount + countsNoQuota.quotaUnknownCount
        XCTAssertEqual(sumNoQuota, rowsNoQuota.count)
    }

    func testActionCountsUnknownNotCountedAsZero() {
        let rows = ClanWarDisplayProjection.sortedRows([
            member(tag: "u", attacks: nil),
            member(tag: "z", attacks: []),
        ], attacksPerMember: 2)
        let counts = ClanWarDisplayProjection.actionCounts(rows)
        XCTAssertEqual(counts.unknownCount, 1)
        XCTAssertEqual(counts.zeroCount, 1)
    }

    // MARK: - displayGroup（规则 7）

    func testDisplayGroupPreparationZeroIsAwaitingWar() {
        let action = ClanWarDisplayProjection.memberAction(attacks: [], attacksPerMember: 2)
        XCTAssertEqual(
            ClanWarDisplayProjection.displayGroup(phase: .preparation, action: action),
            .awaitingWar
        )
    }

    func testDisplayGroupInWarZeroIsNotAttacked() {
        let action = ClanWarDisplayProjection.memberAction(attacks: [], attacksPerMember: 2)
        XCTAssertEqual(
            ClanWarDisplayProjection.displayGroup(phase: .inWar, action: action),
            .notAttacked
        )
    }

    func testDisplayGroupWarEndedZeroIsNotAttacked() {
        let action = ClanWarDisplayProjection.memberAction(attacks: [], attacksPerMember: 2)
        XCTAssertEqual(
            ClanWarDisplayProjection.displayGroup(phase: .warEnded, action: action),
            .notAttacked
        )
    }

    func testDisplayGroupOtherStatuses() {
        let partial = ClanWarDisplayProjection.memberAction(attacks: [attack()], attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.displayGroup(phase: .inWar, action: partial), .remaining)

        let complete = ClanWarDisplayProjection.memberAction(attacks: [attack(), attack()], attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.displayGroup(phase: .inWar, action: complete), .complete)

        let over = ClanWarDisplayProjection.memberAction(
            attacks: [attack(), attack(), attack()], attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.displayGroup(phase: .inWar, action: over), .overQuota)

        let quotaUnknown = ClanWarDisplayProjection.memberAction(attacks: [attack()], attacksPerMember: nil)
        XCTAssertEqual(ClanWarDisplayProjection.displayGroup(phase: .inWar, action: quotaUnknown), .quotaUnknown)

        let unknown = ClanWarDisplayProjection.memberAction(attacks: nil, attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.displayGroup(phase: .inWar, action: unknown), .unknown)
    }

    // MARK: - participant（规则 8）

    func testParticipantMembersNilMeansNotReturned() {
        let p = participant(attacks: 4, stars: 6, members: nil)
        let projection = ClanWarDisplayProjection.participant(p, attacksPerMember: 2)
        XCTAssertNil(projection.members)
        XCTAssertNil(projection.knownAttackDataCount)
        XCTAssertNil(projection.unknownAttackDataCount)
        XCTAssertTrue(projection.mismatches.isEmpty)
        // 官方摘要透传
        XCTAssertEqual(projection.official.attacks, 4)
        XCTAssertEqual(projection.official.stars, 6)
    }

    func testParticipantMembersEmptyMeansZero() {
        let p = participant(attacks: 4, stars: 6, members: [])
        let projection = ClanWarDisplayProjection.participant(p, attacksPerMember: 2)
        XCTAssertEqual(projection.members, [])
        XCTAssertEqual(projection.knownAttackDataCount, 0)
        XCTAssertEqual(projection.unknownAttackDataCount, 0)
    }

    func testParticipantCountsKnownUnknown() {
        let members = [
            member(tag: "1", attacks: [attack()]),
            member(tag: "2", attacks: nil),
            member(tag: "3", attacks: []),
        ]
        let p = participant(attacks: 1, stars: 3, members: members)
        let projection = ClanWarDisplayProjection.participant(p, attacksPerMember: 2)
        XCTAssertEqual(projection.knownAttackDataCount, 2) // 有 attacks（含 []）的成员
        XCTAssertEqual(projection.unknownAttackDataCount, 1) // attacks == nil
        XCTAssertEqual(projection.members?.count, 3)
    }

    // MARK: - project（规则 11）

    func testProjectNotInWarHasNoParticipants() {
        // 即使原始响应意外携带成员数据，notInWar 也不生成成员列表
        let clan = participant(name: "我方", attacks: 0, stars: 0, members: [member(tag: "x", attacks: [])])
        let snapshot = self.snapshot(state: "notInWar", clan: clan, opponent: nil)
        let projection = ClanWarDisplayProjection.project(snapshot)
        XCTAssertEqual(projection.phase, .notInWar)
        XCTAssertNil(projection.clan)
        XCTAssertNil(projection.opponent)
    }

    func testProjectPassesPhaseAndQuota() {
        let snapshot = self.snapshot(state: "inWar", teamSize: 30, attacksPerMember: 2)
        let projection = ClanWarDisplayProjection.project(snapshot)
        XCTAssertEqual(projection.phase, .inWar)
        XCTAssertEqual(projection.quota.teamSize, 30)
        XCTAssertEqual(projection.quota.totalAttacks, 60)
    }

    func testProjectMapsBothParticipants() {
        let clan = participant(tag: "#CLAN", name: "我方", attacks: 4, stars: 6,
                               members: [member(tag: "m1", attacks: [attack(stars: 3), attack(stars: 2)]),
                                         member(tag: "m2", attacks: [attack(stars: 1), attack(stars: 0)])])
        let opponent = participant(tag: "#OPP", name: "对方", attacks: 3, stars: 5,
                                   members: [member(tag: "o1", attacks: [attack(stars: 3), attack(stars: 2)]),
                                             member(tag: "o2", attacks: nil)])
        let snapshot = self.snapshot(state: "inWar", clan: clan, opponent: opponent)
        let projection = ClanWarDisplayProjection.project(snapshot)
        XCTAssertEqual(projection.clan?.name, "我方")
        XCTAssertEqual(projection.opponent?.name, "对方")
        // 对方成员 2 攻击数据未知 → membersIncomplete
        XCTAssertEqual(projection.opponent?.mismatches, [.membersIncomplete])
        // 己方一致 → 无诊断
        XCTAssertTrue(projection.clan?.mismatches.isEmpty ?? false)
    }

    // MARK: - mismatches（规则 9）

    func testMismatchesEmptyWhenConsistent() {
        let members = [
            member(tag: "1", attacks: [attack(stars: 1), attack(stars: 2)]),
            member(tag: "2", attacks: [attack(stars: 3), attack(stars: 0)]),
        ]
        let p = participant(attacks: 4, stars: 6, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows), [])
    }

    func testMismatchesSkipWhenOfficialMissing() {
        let members = [member(tag: "1", attacks: [attack(stars: 1), attack(stars: 2)])]
        let p = participant(attacks: nil, stars: nil, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows), [])
    }

    func testMismatchesMembersIncomplete() {
        let members = [
            member(tag: "1", attacks: [attack(stars: 1)]),
            member(tag: "2", attacks: nil),
        ]
        let p = participant(attacks: 2, stars: 1, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        // 成员数据不完整 → 只报 membersIncomplete，不判数值差异
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows), [.membersIncomplete])
    }

    func testMismatchesAttackCount() {
        let members = [
            member(tag: "1", attacks: [attack(stars: 1), attack(stars: 2)]),
            member(tag: "2", attacks: [attack(stars: 3), attack(stars: 0)]),
        ]
        let p = participant(attacks: 5, stars: 6, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows),
                       [.attackCount(official: 5, memberSum: 4)])
    }

    func testMismatchesStarsWhenAllKnown() {
        let members = [
            member(tag: "1", attacks: [attack(stars: 1), attack(stars: 2)]),
            member(tag: "2", attacks: [attack(stars: 3), attack(stars: 0)]),
        ]
        let p = participant(attacks: 4, stars: 7, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows),
                       [.stars(official: 7, memberKnownSum: 6)])
    }

    func testMismatchesStarsSkippedWhenPartiallyUnknown() {
        let members = [
            member(tag: "1", attacks: [attack(stars: 1), attack(stars: nil)]),
            member(tag: "2", attacks: [attack(stars: 3), attack(stars: 2)]),
        ]
        let p = participant(attacks: 4, stars: 7, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        // 星数部分缺失 → 已知和只是下限，不判 stars mismatch
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows), [])
    }

    func testMismatchesBothDifferencesReported() {
        let members = [
            member(tag: "1", attacks: [attack(stars: 1), attack(stars: 2)]),
            member(tag: "2", attacks: [attack(stars: 3), attack(stars: 0)]),
        ]
        let p = participant(attacks: 5, stars: 7, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows),
                       [.attackCount(official: 5, memberSum: 4), .stars(official: 7, memberKnownSum: 6)])
    }

    // MARK: - refreshStatus（规则 10）

    func testRefreshStatusBasicMapping() {
        XCTAssertEqual(ClanWarDisplayProjection.refreshStatus(of: warState(status: .never)), .never)
        XCTAssertEqual(ClanWarDisplayProjection.refreshStatus(of: warState(status: .loading)), .loading)
        XCTAssertEqual(ClanWarDisplayProjection.refreshStatus(of: warState(status: .success,
                                                                           fetchedAt: Date())), .success)
        XCTAssertEqual(ClanWarDisplayProjection.refreshStatus(of: warState(status: .skipped)), .skipped)
    }

    func testRefreshStatusStale() {
        // 超过 staleThreshold（24h）即 stale；不硬编码时长，跟随阈值定义
        let old = Date(timeIntervalSinceNow: -(ClanWarAPIState.staleThreshold + 1))
        XCTAssertEqual(ClanWarDisplayProjection.refreshStatus(of: warState(status: .success,
                                                                           fetchedAt: old)), .stale)
    }

    func testRefreshStatusFailedWithLastGood() {
        let state = warState(status: .failed, fetchedAt: Date(), lastGood: snapshot())
        XCTAssertEqual(ClanWarDisplayProjection.refreshStatus(of: state), .failedWithLastGood)
    }

    func testRefreshStatusFailedWithoutLastGood() {
        let state = warState(status: .failed)
        XCTAssertEqual(ClanWarDisplayProjection.refreshStatus(of: state), .failedWithoutLastGood)
    }

    // MARK: - 摧毁率逐次保留

    func testLinesPreservedPerAttack() {
        let attacks = [
            attack(order: 1, stars: 3, destruction: 100),
            attack(order: 2, stars: 2, destruction: nil),
            attack(order: 3, stars: nil, destruction: 50),
        ]
        let m = member(attacks: attacks)
        let rows = ClanWarDisplayProjection.sortedRows([m], attacksPerMember: 2)
        let lines = rows[0].lines
        XCTAssertEqual(lines?.count, 3)
        XCTAssertEqual(lines?[0].destructionPercentage, 100)
        XCTAssertNil(lines?[1].destructionPercentage) // nil 原样保留，不得用 0 顶替
        XCTAssertEqual(lines?[2].destructionPercentage, 50)
        XCTAssertEqual(lines?[0].stars, 3)
        XCTAssertNil(lines?[2].stars)
    }

    func testLinesNilWhenAttacksNil() {
        let m = member(attacks: nil)
        let rows = ClanWarDisplayProjection.sortedRows([m], attacksPerMember: 2)
        XCTAssertNil(rows[0].lines)
        XCTAssertNil(rows[0].stars)
    }

    func testMemberRowIdentityIsSourceIndex() {
        let members = [
            member(tag: nil, name: nil, attacks: [attack()]),
            member(tag: nil, name: nil, attacks: [attack()]),
        ]
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        XCTAssertEqual(rows.map(\.id), [0, 1]) // 两个全 nil 成员靠 sourceIndex 区分
    }
}

/// Issue #125：部落对战展示投影的 property-based 测试。
///
/// 复用 SeededGenerator（CoAPIPropertyTests.swift，测试模块共享命名空间），
/// 固定 seed + 500 迭代；缺失判定用 `g.int(in: 0...3) == 0`（本 LCG 的 LSB
/// 交替，`g.bool()` 会产生系统性偏差，见 ClanCombatSummaryPropertyTests 注释）。
final class ClanWarDisplayProjectionPropertyTests: XCTestCase {

    private static let iterationCount = 500

    private func assertOrFail(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !condition() {
            print(context())
            XCTFail("\(message) | \(context())", file: file, line: line)
        }
    }

    private static let namePool = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon",
                                   "Zeta", "Eta", "Theta", "Iota", "Kappa"]

    private func randomAttack(_ g: inout SeededGenerator, order: Int) -> ClanWarAttack {
        ClanWarAttack(
            order: g.int(in: 0...3) == 0 ? nil : order,
            attackerTag: nil, defenderTag: nil,
            stars: g.int(in: 0...3) == 0 ? nil : g.int(in: -2...3),
            destructionPercentage: g.int(in: 0...3) == 0 ? nil : g.double(in: 0...150),
            duration: nil
        )
    }

    private func randomMember(_ g: inout SeededGenerator, index: Int) -> ClanWarMember {
        let attackRoll = g.int(in: 0...3)
        let attacks: [ClanWarAttack]? = attackRoll == 0 ? nil : (attackRoll == 1 ? [] :
            (0..<g.int(in: 1...4)).map { randomAttack(&g, order: $0 + 1) })
        return ClanWarMember(
            tag: g.int(in: 0...3) == 0 ? nil : "member-\(index)",
            name: g.int(in: 0...3) == 0 ? nil : Self.namePool[g.int(in: 0...(Self.namePool.count - 1))],
            mapPosition: g.int(in: 0...3) == 0 ? nil : g.int(in: 1...40),
            townhallLevel: g.int(in: 0...3) == 0 ? nil : g.int(in: 1...17),
            attacks: attacks,
            opponentAttacks: nil, bestOpponentAttack: nil
        )
    }

    private func randomMemberList(_ g: inout SeededGenerator) -> [ClanWarMember] {
        (0..<g.int(in: 0...40)).map { randomMember(&g, index: $0) }
    }

    // MARK: - 属性

    func testSortedRowsIdempotentProperty() {
        var g = SeededGenerator(seed: 101)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = g.int(in: 0...3) == 0 ? nil : g.int(in: 1...3)
            let first = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota)
            let second = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota)
            assertOrFail(first == second, "同一输入两次排序必须完全相等（幂等）",
                         context: "seed=101 n=\(members.count)")
        }
    }

    func testActionCountsSumConservedProperty() {
        var g = SeededGenerator(seed: 202)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = g.int(in: 0...3) == 0 ? nil : g.int(in: 1...3)
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota)
            let counts = ClanWarDisplayProjection.actionCounts(rows)
            let sum = counts.unknownCount + counts.zeroCount + counts.partialCount
                + counts.completeCount + counts.overQuotaCount + counts.quotaUnknownCount
            assertOrFail(sum == rows.count, "六桶计数之和必须等于成员行数",
                         context: "seed=202 n=\(members.count) sum=\(sum) rows=\(rows.count)")
        }
    }

    func testCoverageCountsConservedProperty() {
        var g = SeededGenerator(seed: 303)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = g.int(in: 0...3) == 0 ? nil : g.int(in: 1...3)
            let p = ClanWarParticipant(tag: nil, name: nil, badgeUrls: nil, clanLevel: nil,
                                       attacks: nil, stars: nil, destructionPercentage: nil,
                                       members: members)
            let projection = ClanWarDisplayProjection.participant(p, attacksPerMember: quota)
            let known = projection.knownAttackDataCount ?? -1
            let unknown = projection.unknownAttackDataCount ?? -1
            assertOrFail(known + unknown == members.count,
                         "已知 + 未知必须等于返回成员数",
                         context: "seed=303 n=\(members.count) known=\(known) unknown=\(unknown)")
        }
    }

    func testDestructionPreservedPerLineProperty() {
        var g = SeededGenerator(seed: 404)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = g.int(in: 0...3) == 0 ? nil : g.int(in: 1...3)
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota)
                // rows 是排序后的输出，必须按 sourceIndex 与原始输入配对（不能 zip 排序结果）
                for (index, member) in members.enumerated() {
                    guard let row = rows.first(where: { $0.sourceIndex == index }) else {
                        assertOrFail(false, "每个输入成员都必须有对应输出行（sourceIndex 配对）",
                                     context: "seed=404 index=\(index)")
                        continue
                    }
                    guard let inputAttacks = member.attacks else {
                        // attacks == nil：lines/stars 必须同步为 nil（与"明确 0 次"的空数组区分）
                        assertOrFail(row.lines == nil && row.stars == nil,
                                     "attacks == nil 时 lines/stars 必须为 nil",
                                     context: "seed=404 member=\(member.tag ?? "nil")")
                        continue
                    }
                    assertOrFail(row.lines?.count == inputAttacks.count,
                                 "lines 必须与输入攻击一一对应",
                                 context: "seed=404 member=\(member.tag ?? "nil")")
                    if let lines = row.lines {
                        for (line, attack) in zip(lines, inputAttacks) {
                            assertOrFail(line.stars == attack.stars
                                         && line.destructionPercentage == attack.destructionPercentage,
                                         "逐行字段必须原样保留（含 nil），摧毁率永不聚合",
                                         context: "seed=404 line=\(line) attack=\(attack)")
                        }
                    }
                }
        }
    }

    func testRemainingAttacksConsistentProperty() {
        var g = SeededGenerator(seed: 505)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = g.int(in: 0...3) == 0 ? nil : g.int(in: 1...3)
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota)
            for row in rows {
                if row.action.status == .partial {
                    assertOrFail((row.action.remainingAttacks ?? 0) >= 1,
                                 ".partial 时剩余次数必须 >= 1",
                                 context: "seed=505 row=\(row.tag ?? "nil")")
                } else if row.action.status == .unknown {
                    assertOrFail(row.action.attackCount == nil,
                                 ".unknown 时 attackCount 必须为 nil",
                                 context: "seed=505 row=\(row.tag ?? "nil")")
                } else {
                    assertOrFail(row.action.attackCount != nil,
                                 "非 .unknown 状态 attackCount 必须非 nil",
                                 context: "seed=505 row=\(row.tag ?? "nil")")
                }
            }
        }
    }

    func testQuotaNeverCrashesProperty() {
        var g = SeededGenerator(seed: 606)
        for _ in 0..<Self.iterationCount {
            let teamSize = g.int(in: 0...4) == 0 ? Int.max : g.int(in: -5...20)
            let perMember = g.int(in: 0...4) == 0 ? Int.max : g.int(in: -3...10)
            let q = ClanWarDisplayProjection.quota(teamSize: teamSize, attacksPerMember: perMember)
            if q.saturated {
                assertOrFail(q.totalAttacks != nil, "饱和时 totalAttacks 仍为可表示上界",
                             context: "seed=606 team=\(teamSize) per=\(perMember)")
            } else if teamSize <= 0 || perMember <= 0 {
                assertOrFail(q.totalAttacks == nil, "任一字段缺失或 <= 0 时不得伪造总配额",
                             context: "seed=606 team=\(teamSize) per=\(perMember)")
            } else {
                assertOrFail(q.totalAttacks == teamSize * perMember,
                             "正常输入 totalAttacks = teamSize × perMember",
                             context: "seed=606 team=\(teamSize) per=\(perMember)")
            }
        }
    }

    func testMemberRowsNeverCrashProperty() {
        var g = SeededGenerator(seed: 707)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = g.int(in: 0...3) == 0 ? nil : g.int(in: 1...3)
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota)
            let counts = ClanWarDisplayProjection.actionCounts(rows)
            // 触达所有输出字段，任何随机输入（全 nil、负数、异常大值）不得崩溃
            for row in rows {
                _ = row.id
                _ = row.mapPosition
                _ = row.name
                _ = row.stars?.knownStars
                _ = row.stars?.missingCount
                _ = ClanWarDisplayProjection.displayGroup(phase: .inWar, action: row.action)
            }
            assertOrFail(counts.unknownCount + counts.zeroCount + counts.partialCount
                         + counts.completeCount + counts.overQuotaCount + counts.quotaUnknownCount == rows.count,
                         "计数守恒（含全 nil 成员）",
                         context: "seed=707 n=\(members.count)")
        }
    }
}
