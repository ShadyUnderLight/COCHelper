import XCTest
@testable import COCHelperCore

/// Issue #126：成员筛选桶（matches/filteredRows/chipCounts）、排序变体
/// （sortedRows order）与防守列（defenseAttacks）的单元测试。
///
/// 契约（docs/plans/2026-08-11-issue126-currentwar-ui.md Task 1）：
/// - 基座五桶互斥且覆盖除 awaitingWar 外的全部 displayGroup；
/// - pending = notAttacked ∪ remaining（不含 awaitingWar）；
/// - unknown（attacks == nil）只进 unknownData，绝不进未出手；
/// - awaitingWar（preparation + zero）不进任何告警桶，仅由 counts.awaitingWar 输出；
/// - 三种排序均以 sourceIndex 为最终平局键 → 全序确定。
final class ClanWarDisplayProjectionFilterTests: XCTestCase {

    // MARK: - 构造辅助（沿用 #125 测试模式）

    private func attack(order: Int? = nil, stars: Int? = nil, destruction: Double? = nil) -> ClanWarAttack {
        ClanWarAttack(order: order, attackerTag: nil, defenderTag: nil,
                      stars: stars, destructionPercentage: destruction, duration: nil)
    }

    private func member(
        tag: String? = nil, name: String? = nil, mapPosition: Int? = nil,
        townhallLevel: Int? = nil, attacks: [ClanWarAttack]? = nil,
        opponentAttacks: Int? = nil
    ) -> ClanWarMember {
        ClanWarMember(tag: tag, name: name, mapPosition: mapPosition,
                      townhallLevel: townhallLevel, attacks: attacks,
                      opponentAttacks: opponentAttacks, bestOpponentAttack: nil)
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

    /// 直接构造成员行（筛选/计数测试的精确 fixture；投影链路由
    /// sortedRows/participant/project 相关测试覆盖）。
    private func makeRow(
        _ sourceIndex: Int,
        status: ClanWarMemberAttackStatus,
        remainingAttacks: Int? = nil,
        mapPosition: Int? = nil,
        name: String? = nil
    ) -> ClanWarMemberRow {
        ClanWarMemberRow(
            sourceIndex: sourceIndex, mapPosition: mapPosition, name: name, tag: nil,
            townhallLevel: nil,
            action: ClanWarMemberAction(status: status, attackCount: nil,
                                        remainingAttacks: remainingAttacks),
            stars: nil, lines: nil, defenseAttacks: nil
        )
    }

    // MARK: - matches

    func testMatchesAllAlwaysTrue() {
        // 全部 6 种行动状态 × 4 种阶段：.all 恒 true
        let statuses: [ClanWarMemberAttackStatus] = [
            .zero, .partial, .complete, .overQuota, .quotaUnknown, .unknown,
        ]
        for (index, status) in statuses.enumerated() {
            let r = makeRow(index, status: status, remainingAttacks: status == .partial ? 2 : nil)
            for phase in [ClanWarPhase.preparation, .inWar, .warEnded, .unknown(raw: nil)] {
                XCTAssertTrue(ClanWarDisplayProjection.matches(r, filter: .all, phase: phase),
                              "status=\(status) phase=\(phase)")
            }
        }
    }

    func testMatchesNotAttackedExcludesAwaitingWar() {
        let zeroRow = makeRow(0, status: .zero)
        // 备战期 + 明确 0 次攻击 → awaitingWar：不进 notAttacked / pending 告警
        XCTAssertFalse(ClanWarDisplayProjection.matches(zeroRow, filter: .notAttacked, phase: .preparation))
        XCTAssertFalse(ClanWarDisplayProjection.matches(zeroRow, filter: .pending, phase: .preparation))
        XCTAssertFalse(ClanWarDisplayProjection.matches(zeroRow, filter: .remainingOnce, phase: .preparation))
        XCTAssertFalse(ClanWarDisplayProjection.matches(zeroRow, filter: .remainingMany, phase: .preparation))
        // 开战后 → notAttacked：进告警桶
        XCTAssertTrue(ClanWarDisplayProjection.matches(zeroRow, filter: .notAttacked, phase: .inWar))
        XCTAssertTrue(ClanWarDisplayProjection.matches(zeroRow, filter: .pending, phase: .inWar))
        // warEnded / 未知阶段同样视为"未出手"（displayGroup 只特判 preparation）
        XCTAssertTrue(ClanWarDisplayProjection.matches(zeroRow, filter: .notAttacked, phase: .warEnded))
        XCTAssertTrue(ClanWarDisplayProjection.matches(zeroRow, filter: .notAttacked, phase: .unknown(raw: nil)))
    }

    func testMatchesRemainingOnceVsMany() {
        let once = makeRow(0, status: .partial, remainingAttacks: 1)
        let many = makeRow(1, status: .partial, remainingAttacks: 2)
        let phase = ClanWarPhase.inWar
        XCTAssertTrue(ClanWarDisplayProjection.matches(once, filter: .remainingOnce, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(once, filter: .remainingMany, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(many, filter: .remainingOnce, phase: phase))
        XCTAssertTrue(ClanWarDisplayProjection.matches(many, filter: .remainingMany, phase: phase))
        // 两种剩余都进 pending（未出手 ∪ 剩余）
        XCTAssertTrue(ClanWarDisplayProjection.matches(once, filter: .pending, phase: phase))
        XCTAssertTrue(ClanWarDisplayProjection.matches(many, filter: .pending, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(once, filter: .complete, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(many, filter: .notAttacked, phase: phase))
    }

    func testMatchesUnknownDataBuckets() {
        // unknown / quotaUnknown / overQuota 三态都进 unknownData
        let unknown = makeRow(0, status: .unknown)
        let quotaUnknown = makeRow(1, status: .quotaUnknown)
        let overQuota = makeRow(2, status: .overQuota)
        for r in [unknown, quotaUnknown, overQuota] {
            XCTAssertTrue(ClanWarDisplayProjection.matches(r, filter: .unknownData, phase: .inWar))
        }
        // unknown（attacks == nil）绝不计入未出手/剩余/完成告警
        XCTAssertFalse(ClanWarDisplayProjection.matches(unknown, filter: .notAttacked, phase: .inWar))
        XCTAssertFalse(ClanWarDisplayProjection.matches(unknown, filter: .pending, phase: .inWar))
        XCTAssertFalse(ClanWarDisplayProjection.matches(unknown, filter: .remainingOnce, phase: .inWar))
        XCTAssertFalse(ClanWarDisplayProjection.matches(unknown, filter: .remainingMany, phase: .inWar))
        XCTAssertFalse(ClanWarDisplayProjection.matches(unknown, filter: .complete, phase: .inWar))
        // 备战期 unknown 同样不进 awaitingWar 之外的任何桶（unknown ≠ 明确 0 次）
        XCTAssertFalse(ClanWarDisplayProjection.matches(unknown, filter: .notAttacked, phase: .preparation))
        // overQuota / quotaUnknown 不得伪造"已完成"
        XCTAssertFalse(ClanWarDisplayProjection.matches(overQuota, filter: .complete, phase: .inWar))
        XCTAssertFalse(ClanWarDisplayProjection.matches(quotaUnknown, filter: .complete, phase: .inWar))
    }

    func testMatchesComplete() {
        let complete = makeRow(0, status: .complete)
        let phase = ClanWarPhase.warEnded
        XCTAssertTrue(ClanWarDisplayProjection.matches(complete, filter: .complete, phase: phase))
        XCTAssertTrue(ClanWarDisplayProjection.matches(complete, filter: .all, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(complete, filter: .notAttacked, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(complete, filter: .pending, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(complete, filter: .remainingOnce, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(complete, filter: .remainingMany, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(complete, filter: .unknownData, phase: phase))
    }

    // MARK: - filteredRows

    func testFilteredRowsPreservesOrderAndAllReturnsIdentity() {
        let rows = [
            makeRow(0, status: .unknown),
            makeRow(1, status: .zero),
            makeRow(2, status: .partial, remainingAttacks: 1),
            makeRow(3, status: .complete),
            makeRow(4, status: .partial, remainingAttacks: 2),
        ]
        let phase = ClanWarPhase.inWar
        // .all 返回原数组（恒等）
        XCTAssertEqual(ClanWarDisplayProjection.filteredRows(rows, filter: .all, phase: phase), rows)
        // 过滤保持输入顺序不变：pending == {zero(1), once(2), many(4)} 原序
        XCTAssertEqual(
            ClanWarDisplayProjection.filteredRows(rows, filter: .pending, phase: phase).map(\.sourceIndex),
            [1, 2, 4]
        )
        XCTAssertEqual(
            ClanWarDisplayProjection.filteredRows(rows, filter: .notAttacked, phase: phase).map(\.sourceIndex),
            [1]
        )
        XCTAssertEqual(
            ClanWarDisplayProjection.filteredRows(rows, filter: .remainingOnce, phase: phase).map(\.sourceIndex),
            [2]
        )
        XCTAssertEqual(
            ClanWarDisplayProjection.filteredRows(rows, filter: .remainingMany, phase: phase).map(\.sourceIndex),
            [4]
        )
        XCTAssertEqual(
            ClanWarDisplayProjection.filteredRows(rows, filter: .unknownData, phase: phase).map(\.sourceIndex),
            [0]
        )
    }

    // MARK: - chipCounts

    /// 7 行 fixture 覆盖全部 7 种 displayGroup 形态：zero（preparation →
    /// awaitingWar / 其余 → notAttacked）、partial(once)、partial(many)、
    /// complete、overQuota、quotaUnknown、unknown。
    func testChipCountsSumInvariant() {
        let rows = [
            makeRow(0, status: .zero),
            makeRow(1, status: .partial, remainingAttacks: 1),
            makeRow(2, status: .partial, remainingAttacks: 2),
            makeRow(3, status: .complete),
            makeRow(4, status: .overQuota),
            makeRow(5, status: .quotaUnknown),
            makeRow(6, status: .unknown),
        ]
        // 备战期视角：zero → awaitingWar（不进告警桶）
        let prep = ClanWarDisplayProjection.chipCounts(rows: rows, phase: .preparation)
        XCTAssertEqual(prep.awaitingWar, 1)
        XCTAssertEqual(prep.notAttacked, 0)
        XCTAssertEqual(prep.remainingOnce, 1)
        XCTAssertEqual(prep.remainingMany, 1)
        XCTAssertEqual(prep.complete, 1)
        XCTAssertEqual(prep.unknownData, 3) // overQuota + quotaUnknown + unknown
        XCTAssertEqual(prep.pending, 2) // once + many，不含 awaitingWar
        XCTAssertEqual(prep.notAttacked + prep.remainingOnce + prep.remainingMany
                       + prep.complete + prep.unknownData + prep.awaitingWar, rows.count)
        XCTAssertEqual(prep.pending, prep.notAttacked + prep.remainingOnce + prep.remainingMany)

        // 开战视角：zero → notAttacked（awaitingWar 清 0）
        let inWar = ClanWarDisplayProjection.chipCounts(rows: rows, phase: .inWar)
        XCTAssertEqual(inWar.awaitingWar, 0)
        XCTAssertEqual(inWar.notAttacked, 1)
        XCTAssertEqual(inWar.pending, 3)
        XCTAssertEqual(inWar.notAttacked + inWar.remainingOnce + inWar.remainingMany
                       + inWar.complete + inWar.unknownData + inWar.awaitingWar, rows.count)
        XCTAssertEqual(inWar.pending, inWar.notAttacked + inWar.remainingOnce + inWar.remainingMany)
    }

    func testChipCountsAwaitingWarOnlyInPreparation() {
        let zeroRows = [makeRow(0, status: .zero), makeRow(1, status: .zero)]
        // warEnded + zero → notAttacked（不是 awaitingWar）
        let ended = ClanWarDisplayProjection.chipCounts(rows: zeroRows, phase: .warEnded)
        XCTAssertEqual(ended.notAttacked, 2)
        XCTAssertEqual(ended.awaitingWar, 0)
        XCTAssertEqual(ended.pending, 2)
        // 未知阶段 + zero → 同样 notAttacked（displayGroup 只特判 preparation）
        let unknownPhase = ClanWarDisplayProjection.chipCounts(rows: zeroRows, phase: .unknown(raw: nil))
        XCTAssertEqual(unknownPhase.notAttacked, 2)
        XCTAssertEqual(unknownPhase.awaitingWar, 0)
        // 对照组：preparation + zero → awaitingWar
        let prep = ClanWarDisplayProjection.chipCounts(rows: zeroRows, phase: .preparation)
        XCTAssertEqual(prep.awaitingWar, 2)
        XCTAssertEqual(prep.notAttacked, 0)
        XCTAssertEqual(prep.pending, 0)
    }

    // MARK: - sortedRows（排序变体）

    func testSortedRowsMapPositionOrder() {
        // 同组（partial）成员：mapPosition 升序 → 平局 name → sourceIndex；nil 排最后
        let a = member(tag: "a", name: "C", mapPosition: 3, attacks: [attack()])
        let b = member(tag: "b", name: "B", mapPosition: nil, attacks: [attack()])
        let c = member(tag: "c", name: "B", mapPosition: 1, attacks: [attack()])
        let d = member(tag: "d", name: "A", mapPosition: 1, attacks: [attack()])
        let e = member(tag: "e", name: nil, mapPosition: 2, attacks: [attack()])
        let rows = ClanWarDisplayProjection.sortedRows([a, b, d, e, c], attacksPerMember: 2, order: .mapPosition)
        // position 1：d（name A）在 c（name B）前；position 2：e；position 3：a；nil 最后：b
        XCTAssertEqual(rows.map(\.tag), ["d", "c", "e", "a", "b"])
    }

    func testSortedRowsNameOrder() {
        // name 升序（String 比较序）→ 平局 mapPosition → sourceIndex；nil 最后
        let a = member(tag: "a", name: "B", mapPosition: 5, attacks: [attack()])
        let b = member(tag: "b", name: nil, mapPosition: 1, attacks: [attack()])
        let c = member(tag: "c", name: "A", mapPosition: 2, attacks: [attack()])
        let d = member(tag: "d", name: "A", mapPosition: 1, attacks: [attack()])
        let e = member(tag: "e", name: "C", mapPosition: nil, attacks: [attack()])
        let f = member(tag: "f", name: nil, mapPosition: 2, attacks: [attack()])
        let rows = ClanWarDisplayProjection.sortedRows([f, a, d, b, e, c], attacksPerMember: 2, order: .name)
        // A(pos1): d → A(pos2): c → B: a → C: e → nil 组内 mapPosition 升序：b(1) → f(2)
        XCTAssertEqual(rows.map(\.tag), ["d", "c", "a", "e", "b", "f"])
    }

    func testSortedRowsActionPriorityMatchesLegacy() {
        let members = [
            member(tag: "1", name: "未知", mapPosition: 3, attacks: nil),
            member(tag: "2", name: "零", mapPosition: nil, attacks: []),
            member(tag: "3", name: "部分", mapPosition: 1, attacks: [attack()]),
            member(tag: "4", name: "完成", mapPosition: 4, attacks: [attack(), attack()]),
            member(tag: "5", name: nil, mapPosition: 2, attacks: [attack(), attack(), attack()]),
        ]
        let legacy = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        let new = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2, order: .actionPriority)
        XCTAssertEqual(legacy, new)
        // 与 #125 行为一致：zero → partial → complete → {overQuota, unknown} 组内 position 升序
        XCTAssertEqual(legacy.map(\.tag), ["2", "3", "4", "5", "1"])
    }

    // MARK: - 防守列

    func testDefenseAttacksProjected() {
        // 直接投影路径：raw opponentAttacks（官方被攻击次数）→ defenseAttacks
        let rows = ClanWarDisplayProjection.sortedRows([
            member(tag: "d3", attacks: [], opponentAttacks: 3),
            member(tag: "d0", attacks: [], opponentAttacks: 0),
            member(tag: "dn", attacks: [], opponentAttacks: nil),
        ], attacksPerMember: 2)
        XCTAssertEqual(rows[0].defenseAttacks, 3)
        XCTAssertEqual(rows[1].defenseAttacks, 0)
        XCTAssertNil(rows[2].defenseAttacks)
        // 其余字段不受影响
        XCTAssertEqual(rows[0].tag, "d3")
        XCTAssertEqual(rows[0].action.status, .zero)

        // participant 全链路投影
        let p = participant(members: [
            member(tag: "x", name: "防守", mapPosition: 1, attacks: [], opponentAttacks: 2),
            member(tag: "y", attacks: [], opponentAttacks: nil),
        ])
        let projection = ClanWarDisplayProjection.participant(p, attacksPerMember: 2)
        XCTAssertEqual(projection.members?[0].defenseAttacks, 2)
        XCTAssertNil(projection.members?[1].defenseAttacks)
    }

    // MARK: - 40 人全量投影（无截断路径）

    func testFortyMembersAllProjected() {
        // 40 人 fixture（超过任何截断阈值规模）：project 全量投影，无截断路径
        var members: [ClanWarMember] = []
        for index in 0..<40 {
            members.append(member(
                tag: "m-\(index)", name: "成员\(index + 1)", mapPosition: index + 1,
                townhallLevel: index % 17 + 1,
                attacks: [attack(stars: 3), attack(stars: 2)],
                opponentAttacks: index % 3
            ))
        }
        let projection = ClanWarDisplayProjection.project(
            snapshot(state: "inWar", teamSize: 40, attacksPerMember: 2,
                     clan: participant(attacks: 80, stars: 200, members: members))
        )
        let rows = projection.clan?.members
        XCTAssertEqual(rows?.count, 40)
        // 第 31 行（sourceIndex 30）存在且字段完整
        let row31 = rows?[30]
        XCTAssertEqual(row31?.sourceIndex, 30)
        XCTAssertEqual(row31?.mapPosition, 31)
        XCTAssertEqual(row31?.name, "成员31")
        XCTAssertEqual(row31?.tag, "m-30")
        XCTAssertEqual(row31?.townhallLevel, 30 % 17 + 1)
        XCTAssertEqual(row31?.action.status, .complete)
        XCTAssertEqual(row31?.action.attackCount, 2)
        XCTAssertEqual(row31?.stars?.knownStars, 5)
        XCTAssertEqual(row31?.lines?.count, 2)
        XCTAssertEqual(row31?.defenseAttacks, 30 % 3)
        // 全部 40 个 sourceIndex 一一对应（无截断、无丢失）
        XCTAssertEqual(Set(rows?.map(\.sourceIndex) ?? []), Set(0..<40))
    }
}

/// Issue #126：筛选桶/排序变体的 property-based 测试（确定性 LCG，seed 固定可复现）。
///
/// 缺失判定用 `int(in: 0...3) == 0`（LCG 的 LSB 交替，`bool()` 会产生系统性偏差，
/// 与 #125 property 测试同一约定）。
final class ClanWarDisplayProjectionFilterPropertyTests: XCTestCase {

    private static let iterationCount = 200
    private static let phases: [ClanWarPhase] = [.preparation, .inWar, .warEnded, .unknown(raw: nil)]
    private static let filters: [ClanWarMemberFilter] = [
        .pending, .notAttacked, .remainingOnce, .remainingMany, .complete, .unknownData,
    ]
    private static let namePool = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon",
                                   "Zeta", "Eta", "Theta", "Iota", "Kappa"]

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

    private func randomAttack(_ g: inout FilterSeededGenerator, order: Int) -> ClanWarAttack {
        ClanWarAttack(
            order: g.int(in: 0...3) == 0 ? nil : order,
            attackerTag: nil, defenderTag: nil,
            stars: g.int(in: 0...3) == 0 ? nil : g.int(in: -2...3),
            destructionPercentage: g.int(in: 0...3) == 0 ? nil : g.double(in: 0...150),
            duration: nil
        )
    }

    private func randomMember(_ g: inout FilterSeededGenerator, index: Int) -> ClanWarMember {
        let attackRoll = g.int(in: 0...3)
        let attacks: [ClanWarAttack]? = attackRoll == 0 ? nil : (attackRoll == 1 ? [] :
            (0..<g.int(in: 1...4)).map { randomAttack(&g, order: $0 + 1) })
        return ClanWarMember(
            tag: g.int(in: 0...3) == 0 ? nil : "member-\(index)",
            name: g.int(in: 0...3) == 0 ? nil : Self.namePool[g.int(in: 0...(Self.namePool.count - 1))],
            mapPosition: g.int(in: 0...3) == 0 ? nil : g.int(in: 1...40),
            townhallLevel: g.int(in: 0...3) == 0 ? nil : g.int(in: 1...17),
            attacks: attacks,
            opponentAttacks: g.int(in: 0...3) == 0 ? nil : g.int(in: 0...5),
            bestOpponentAttack: nil
        )
    }

    private func randomMemberList(_ g: inout FilterSeededGenerator) -> [ClanWarMember] {
        (0..<g.int(in: 0...40)).map { randomMember(&g, index: $0) }
    }

    private func randomQuota(_ g: inout FilterSeededGenerator) -> Int? {
        g.int(in: 0...3) == 0 ? nil : g.int(in: 1...3)
    }

    /// 行 → 成员（保 key 字段与攻击数；用于对排序结果再次排序做全序幂等校验）。
    private func memberFromRow(_ row: ClanWarMemberRow) -> ClanWarMember {
        ClanWarMember(
            tag: row.tag, name: row.name, mapPosition: row.mapPosition,
            townhallLevel: row.townhallLevel,
            attacks: row.lines?.map {
                ClanWarAttack(order: $0.order, attackerTag: nil, defenderTag: nil,
                              stars: $0.stars, destructionPercentage: $0.destructionPercentage,
                              duration: nil)
            },
            opponentAttacks: row.defenseAttacks, bestOpponentAttack: nil
        )
    }

    // MARK: - 属性

    func testPropertyFilterCountsSumConserved() {
        var g = FilterSeededGenerator(seed: 0x126)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = randomQuota(&g)
            let phase = Self.phases[g.int(in: 0...(Self.phases.count - 1))]
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota)
            let counts = ClanWarDisplayProjection.chipCounts(rows: rows, phase: phase)
            assertOrFail(counts.notAttacked + counts.remainingOnce + counts.remainingMany
                         + counts.complete + counts.unknownData + counts.awaitingWar == rows.count,
                         "Σ 基座五桶 + awaitingWar == rows.count",
                         context: "seed=0x126 n=\(rows.count) sum=\(counts.notAttacked + counts.remainingOnce + counts.remainingMany + counts.complete + counts.unknownData + counts.awaitingWar)")
            assertOrFail(counts.pending == counts.notAttacked + counts.remainingOnce + counts.remainingMany,
                         "pending == notAttacked + once + many",
                         context: "seed=0x126 n=\(rows.count) pending=\(counts.pending)")
            // matches 与计数互相一致：每个桶的 filteredRows 数 == 对应计数字段
            assertOrFail(ClanWarDisplayProjection.filteredRows(rows, filter: .notAttacked, phase: phase).count == counts.notAttacked,
                         "notAttacked 计数与 matches 一致",
                         context: "seed=0x126 n=\(rows.count)")
            assertOrFail(ClanWarDisplayProjection.filteredRows(rows, filter: .remainingOnce, phase: phase).count == counts.remainingOnce,
                         "remainingOnce 计数与 matches 一致",
                         context: "seed=0x126 n=\(rows.count)")
            assertOrFail(ClanWarDisplayProjection.filteredRows(rows, filter: .remainingMany, phase: phase).count == counts.remainingMany,
                         "remainingMany 计数与 matches 一致",
                         context: "seed=0x126 n=\(rows.count)")
            assertOrFail(ClanWarDisplayProjection.filteredRows(rows, filter: .complete, phase: phase).count == counts.complete,
                         "complete 计数与 matches 一致",
                         context: "seed=0x126 n=\(rows.count)")
            assertOrFail(ClanWarDisplayProjection.filteredRows(rows, filter: .unknownData, phase: phase).count == counts.unknownData,
                         "unknownData 计数与 matches 一致",
                         context: "seed=0x126 n=\(rows.count)")
            // awaitingWar 只来自 preparation + zero
            let awaitingRows = rows.filter {
                ClanWarDisplayProjection.displayGroup(phase: phase, action: $0.action) == .awaitingWar
            }
            assertOrFail(awaitingRows.count == counts.awaitingWar,
                         "awaitingWar 计数 == displayGroup(.awaitingWar) 行数",
                         context: "seed=0x126 n=\(rows.count) phase=\(phase)")
        }
    }

    func testPropertyUnknownNeverCountedAsNotAttacked() {
        var g = FilterSeededGenerator(seed: 0x226)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = randomQuota(&g)
            let phase = Self.phases[g.int(in: 0...(Self.phases.count - 1))]
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota)
            var unknownTotal = 0
            for row in rows where row.action.status == .unknown {
                unknownTotal += 1
                assertOrFail(ClanWarDisplayProjection.matches(row, filter: .unknownData, phase: phase),
                             "unknown 行必须 matches .unknownData",
                             context: "seed=0x226 n=\(rows.count) row=\(row.sourceIndex)")
                assertOrFail(!ClanWarDisplayProjection.matches(row, filter: .notAttacked, phase: phase),
                             "unknown 行不得 matches .notAttacked（未知不计入未出手）",
                             context: "seed=0x226 n=\(rows.count) row=\(row.sourceIndex)")
                assertOrFail(!ClanWarDisplayProjection.matches(row, filter: .pending, phase: phase),
                             "unknown 行不得 matches .pending",
                             context: "seed=0x226 n=\(rows.count) row=\(row.sourceIndex)")
                assertOrFail(!ClanWarDisplayProjection.matches(row, filter: .remainingOnce, phase: phase),
                             "unknown 行不得 matches .remainingOnce",
                             context: "seed=0x226 n=\(rows.count) row=\(row.sourceIndex)")
                assertOrFail(!ClanWarDisplayProjection.matches(row, filter: .remainingMany, phase: phase),
                             "unknown 行不得 matches .remainingMany",
                             context: "seed=0x226 n=\(rows.count) row=\(row.sourceIndex)")
                assertOrFail(!ClanWarDisplayProjection.matches(row, filter: .complete, phase: phase),
                             "unknown 行不得 matches .complete",
                             context: "seed=0x226 n=\(rows.count) row=\(row.sourceIndex)")
            }
            // 计数层面：unknownData 桶必须覆盖全部 unknown 行（quotaUnknown/overQuota 也归该桶）
            let counts = ClanWarDisplayProjection.chipCounts(rows: rows, phase: phase)
            assertOrFail(counts.unknownData >= unknownTotal,
                         "unknownData 计数必须覆盖全部 unknown 行",
                         context: "seed=0x226 n=\(rows.count) unknown=\(unknownTotal) unknownData=\(counts.unknownData)")
        }
    }

    func testPropertySortingDeterministic() {
        var g = FilterSeededGenerator(seed: 0x326)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = randomQuota(&g)
            for order in ClanWarSortOrder.allCases {
                let first = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota, order: order)
                // 对"排序结果"再次排序：必须恢复同一键序（全序确定；唯一差异是
                // sourceIndex 按位置重编号）——任何 comparator 不一致都会被捕获
                let reSort = ClanWarDisplayProjection.sortedRows(
                    first.map(memberFromRow), attacksPerMember: quota, order: order
                )
                let expected = first.enumerated().map { index, r in
                    ClanWarMemberRow(
                        sourceIndex: index, mapPosition: r.mapPosition, name: r.name, tag: r.tag,
                        townhallLevel: r.townhallLevel, action: r.action, stars: r.stars,
                        lines: r.lines, defenseAttacks: r.defenseAttacks
                    )
                }
                assertOrFail(reSort == expected,
                             "排序结果再排序必须恢复同一键序（全序确定）",
                             context: "seed=0x326 n=\(members.count) order=\(order)")
                // 主键非降序校验：mapPosition order → mapPosition 键；name order → name 键
                let byPosition = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota, order: .mapPosition)
                let posNonNil = byPosition.compactMap { $0.mapPosition }
                assertOrFail(posNonNil == posNonNil.sorted(),
                             "mapPosition 主键必须非降序",
                             context: "seed=0x326 n=\(members.count) order=mapPosition")
                let posNilCount = byPosition.filter { $0.mapPosition == nil }.count
                assertOrFail(byPosition.suffix(posNilCount).allSatisfy { $0.mapPosition == nil },
                             "mapPosition nil 必须排最后",
                             context: "seed=0x326 n=\(members.count) order=mapPosition")
                let byName = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota, order: .name)
                let nameNonNil = byName.compactMap { $0.name }
                assertOrFail(nameNonNil == nameNonNil.sorted(),
                             "name 主键必须非降序（String 比较序）",
                             context: "seed=0x326 n=\(members.count) order=name")
                let nameNilCount = byName.filter { $0.name == nil }.count
                assertOrFail(byName.suffix(nameNilCount).allSatisfy { $0.name == nil },
                             "name nil 必须排最后",
                             context: "seed=0x326 n=\(members.count) order=name")
            }
        }
    }

    func testPropertyFilteredRowsMatchesMatches() {
        var g = FilterSeededGenerator(seed: 0x426)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let quota = randomQuota(&g)
            let phase = Self.phases[g.int(in: 0...(Self.phases.count - 1))]
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: quota)
            assertOrFail(ClanWarDisplayProjection.filteredRows(rows, filter: .all, phase: phase) == rows,
                         ".all 必须返回原数组（恒等）",
                         context: "seed=0x426 n=\(rows.count)")
            for filter in Self.filters {
                let expected = rows.filter { ClanWarDisplayProjection.matches($0, filter: filter, phase: phase) }
                let actual = ClanWarDisplayProjection.filteredRows(rows, filter: filter, phase: phase)
                assertOrFail(actual == expected,
                             "filteredRows(\(filter)) 必须等于 rows.filter { matches }",
                             context: "seed=0x426 n=\(rows.count) filter=\(filter)")
            }
        }
    }
}

// MARK: - 确定性伪随机生成器（property-based 测试专用，seed 固定可复现）

private struct FilterSeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int(next() % UInt64(range.count)) + range.lowerBound
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        Double(next()) / Double(UInt64.max) * (range.upperBound - range.lowerBound) + range.lowerBound
    }
}
