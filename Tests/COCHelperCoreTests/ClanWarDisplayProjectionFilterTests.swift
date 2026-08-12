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
        name: String? = nil,
        tag: String? = nil
    ) -> ClanWarMemberRow {
        ClanWarMemberRow(
            sourceIndex: sourceIndex, mapPosition: mapPosition, name: name, tag: tag,
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

    /// 契约外 malformed 行（`.partial` 但 `remainingAttacks == nil`）：
    /// `matches(.remainingMany)` 按 `!= 1` 语义返回 true，与 `chipCounts` 的
    /// else 分支一致。该行为**依赖 #125 Core 契约**（"仅 `.partial` 时
    /// `remainingAttacks` 非 nil"）——malformed 输入属契约外，本测试只
    /// 文档化既有行为、防止实现漂移，不要求 Core 对契约外输入特判。
    func testMatchesRemainingManyMalformedRow() {
        let malformed = ClanWarMemberRow(
            sourceIndex: 0, mapPosition: nil, name: nil, tag: nil, townhallLevel: nil,
            action: ClanWarMemberAction(status: .partial, attackCount: 1, remainingAttacks: nil),
            stars: nil, lines: nil, defenseAttacks: nil
        )
        let phase = ClanWarPhase.inWar
        XCTAssertTrue(ClanWarDisplayProjection.matches(malformed, filter: .remainingMany, phase: phase))
        XCTAssertFalse(ClanWarDisplayProjection.matches(malformed, filter: .remainingOnce, phase: phase))
        // 与 chipCounts 一致：该行计入 remainingMany（remainingOnce 为 0）
        let counts = ClanWarDisplayProjection.chipCounts(rows: [malformed], phase: phase)
        XCTAssertEqual(counts.remainingMany, 1)
        XCTAssertEqual(counts.remainingOnce, 0)
    }

    // MARK: - 搜索过滤（Issue #126：只匹配名称与 tag）

    func testSearchMatchesNameCaseInsensitive() {
        let rows = [makeRow(0, status: .complete, name: "Alex")]
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "ALEX").map(\.sourceIndex), [0])
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "ale").map(\.sourceIndex), [0])
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "lEX").map(\.sourceIndex), [0])
    }

    func testSearchMatchesTagPrefix() {
        let rows = [makeRow(0, status: .complete, name: "随便", tag: "#ABCDEF")]
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "#ABC").map(\.sourceIndex), [0])
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "abcdef").map(\.sourceIndex), [0])
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "DEF").map(\.sourceIndex), [0])
    }

    func testSearchEmptyReturnsAll() {
        let rows = [
            makeRow(0, status: .complete, name: "Alpha"),
            makeRow(1, status: .zero, name: "Beta", tag: "#BETA"),
        ]
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: ""), rows)
    }

    func testSearchWhitespaceReturnsAll() {
        let rows = [makeRow(0, status: .complete, name: "Alpha")]
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "   "), rows)
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "\n\t "), rows)
    }

    /// nil 名称/tag 不参与匹配：nil 名称 + 匹配 tag 时由 tag 命中；
    /// 名称查询不得因 nil 名称误命中；反之亦然（两方向分开断言）。
    func testSearchNilNameAndTagNeverMatch() {
        // 名称 nil、tag 匹配：只有 tag 查询能命中，名称查询不命中
        let noName = [makeRow(0, status: .complete, name: nil, tag: "#ABC123")]
        XCTAssertEqual(ClanWarDisplayProjection.rows(noName, matchingSearch: "#ABC").map(\.sourceIndex), [0])
        XCTAssertTrue(ClanWarDisplayProjection.rows(noName, matchingSearch: "alex").isEmpty)
        XCTAssertTrue(ClanWarDisplayProjection.rows(noName, matchingSearch: "XYZ").isEmpty)
        // tag nil、名称匹配：只有名称查询能命中，tag 查询不命中
        let noTag = [makeRow(0, status: .complete, name: "Alex", tag: nil)]
        XCTAssertEqual(ClanWarDisplayProjection.rows(noTag, matchingSearch: "ALEX").map(\.sourceIndex), [0])
        XCTAssertTrue(ClanWarDisplayProjection.rows(noTag, matchingSearch: "#ABC").isEmpty)
    }

    func testSearchNoMatchReturnsEmpty() {
        let rows = [
            makeRow(0, status: .complete, name: "Alpha", tag: "#AAA"),
            makeRow(1, status: .zero, name: "Beta", tag: "#BBB"),
        ]
        XCTAssertTrue(ClanWarDisplayProjection.rows(rows, matchingSearch: "zzz").isEmpty)
        XCTAssertTrue(ClanWarDisplayProjection.rows(rows, matchingSearch: "#CCC").isEmpty)
        XCTAssertTrue(ClanWarDisplayProjection.rows(rows, matchingSearch: "阿尔法").isEmpty)
    }

    /// CJK 正向用例：中文名称包含匹配（"阿尔法" 匹配 "阿尔"），大小写
    /// 归一化对 CJK 是恒等（无字母大小写语义）；子串跨 CJK 字符边界正常命中。
    func testSearchMatchesChineseName() {
        let rows = [
            makeRow(0, status: .complete, name: "阿尔法", tag: "#AAA"),
            makeRow(1, status: .complete, name: "贝塔", tag: "#BBB"),
            makeRow(2, status: .complete, name: nil, tag: "#伽马"),
        ]
        // 正向：完整词 / 前缀子串 / 单字后缀均命中
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "阿尔").map(\.sourceIndex), [0])
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "阿尔法").map(\.sourceIndex), [0])
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "法").map(\.sourceIndex), [0])
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "贝").map(\.sourceIndex), [1])
        // tag 中文匹配同样生效（与名称匹配独立）
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "伽").map(\.sourceIndex), [2])
        // 负向：不存在的词不命中任何行；query 含空白仍 trim 后匹配
        XCTAssertTrue(ClanWarDisplayProjection.rows(rows, matchingSearch: "德尔塔").isEmpty)
        XCTAssertEqual(ClanWarDisplayProjection.rows(rows, matchingSearch: "  阿尔 ").map(\.sourceIndex), [0])
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

    // MARK: - reorder（已投影行重排，Issue #126）

    /// 契约：reorder 的键链必须与 sortedRows(order:) 完全一致。
    /// actionPriority 键链 = rank → mapPosition → name → sourceIndex；
    /// reorder 对已按 actionPriority 排好的行是恒等（同一全序）。
    func testReorderActionPriorityMatchesSortedRows() {
        let members = [
            member(tag: "1", name: "未知", mapPosition: 3, attacks: nil),
            member(tag: "2", name: "零", mapPosition: nil, attacks: []),
            member(tag: "3", name: "部分", mapPosition: 1, attacks: [attack()]),
            member(tag: "4", name: "完成", mapPosition: 4, attacks: [attack(), attack()]),
            member(tag: "5", name: nil, mapPosition: 2, attacks: [attack(), attack(), attack()]),
        ]
        let expected = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2, order: .actionPriority)
        // reorder 对已按 actionPriority 排好的行恒等
        XCTAssertEqual(ClanWarDisplayProjection.reorder(expected, order: .actionPriority), expected)
        // 乱序输入重排 == sortedRows 输出（键链一致，与输入顺序无关）
        XCTAssertEqual(
            ClanWarDisplayProjection.reorder(Array(expected.reversed()), order: .actionPriority),
            expected
        )
    }

    /// mapPosition 键链 = mapPosition → name → sourceIndex：重复 mapPosition
    /// 时平局必须按 name（UI 旧实现缺 name 键，会按 sourceIndex 错误定序）。
    func testReorderMapPositionUsesCoreKeyChain() {
        let rows = [
            makeRow(0, status: .complete, mapPosition: 1, name: "C"),
            makeRow(1, status: .complete, mapPosition: 2, name: "B"),
            makeRow(2, status: .complete, mapPosition: 1, name: "A"),
        ]
        let reordered = ClanWarDisplayProjection.reorder(rows, order: .mapPosition)
        // position 1 组：name A(2) → C(0)；position 2：B(1)
        XCTAssertEqual(reordered.map(\.sourceIndex), [2, 0, 1])

        // 与 sortedRows 键链一致：乱序投影行重排 == sortedRows 输出
        let members = [
            member(tag: "a", name: "C", mapPosition: 3, attacks: [attack()]),
            member(tag: "b", name: "B", mapPosition: nil, attacks: [attack()]),
            member(tag: "c", name: "B", mapPosition: 1, attacks: [attack()]),
            member(tag: "d", name: "A", mapPosition: 1, attacks: [attack()]),
        ]
        let expected = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2, order: .mapPosition)
        XCTAssertEqual(
            ClanWarDisplayProjection.reorder(Array(expected.reversed()), order: .mapPosition),
            expected
        )
    }

    /// name 键链 = name → mapPosition → sourceIndex：重名（含双 nil 名）平局
    /// 必须按 mapPosition（UI 旧实现缺 mapPosition 键）。
    func testReorderNameUsesCoreKeyChain() {
        let rows = [
            makeRow(0, status: .zero, mapPosition: 5, name: "B"),
            makeRow(1, status: .zero, mapPosition: 1, name: "B"),
            makeRow(2, status: .zero, mapPosition: 3, name: nil),
            makeRow(3, status: .zero, mapPosition: 2, name: nil),
        ]
        let reordered = ClanWarDisplayProjection.reorder(rows, order: .name)
        // B(pos1) → B(pos5) → nil 名组（pos2 → pos3）
        XCTAssertEqual(reordered.map(\.sourceIndex), [1, 0, 3, 2])

        // 与 sortedRows 键链一致：乱序投影行重排 == sortedRows 输出
        let members = [
            member(tag: "a", name: "B", mapPosition: 5, attacks: [attack()]),
            member(tag: "b", name: nil, mapPosition: 1, attacks: [attack()]),
            member(tag: "c", name: "A", mapPosition: 2, attacks: [attack()]),
            member(tag: "d", name: "A", mapPosition: 1, attacks: [attack()]),
            member(tag: "e", name: "C", mapPosition: nil, attacks: [attack()]),
        ]
        let expected = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2, order: .name)
        XCTAssertEqual(
            ClanWarDisplayProjection.reorder(Array(expected.reversed()), order: .name),
            expected
        )
    }

    /// 三种 order 下 reorder 幂等 + 乱序重排 == sortedRows（契约对齐的汇总校验）。
    func testReorderIdempotentForAllOrders() {
        let members = [
            member(tag: "1", name: "D", mapPosition: 2, attacks: [attack()]),
            member(tag: "2", name: "A", mapPosition: nil, attacks: []),
            member(tag: "3", name: nil, mapPosition: 1, attacks: [attack(), attack()]),
            member(tag: "4", name: "A", mapPosition: 1, attacks: [attack(), attack()]),
        ]
        for order in ClanWarSortOrder.allCases {
            let expected = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2, order: order)
            XCTAssertEqual(ClanWarDisplayProjection.reorder(expected, order: order), expected,
                           "幂等：order=\(order)")
            XCTAssertEqual(
                ClanWarDisplayProjection.reorder(Array(expected.reversed()), order: order),
                expected,
                "乱序重排 == sortedRows：order=\(order)"
            )
        }
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

    // MARK: - mismatches 成员覆盖率诊断（Issue #126 复审：teamSize 与成员数组数量比对）

    /// teamSize 已知（30）但成员数组仅 1 人 → .memberCount 诊断（成员覆盖率告警）。
    func testMismatchesMemberCountWhenCountDiffers() {
        let members = [member(tag: "1", attacks: [attack(stars: 1)])]
        let p = participant(attacks: 1, stars: 1, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        XCTAssertEqual(
            ClanWarDisplayProjection.mismatches(participant: p, rows: rows, teamSize: 30),
            [.memberCount(official: 30, returned: 1)]
        )
    }

    /// teamSize 与成员数组数量一致 → 不产生 memberCount（30/30）。
    func testMismatchesNoMemberCountWhenMatch() {
        let members = [
            member(tag: "1", attacks: [attack(stars: 1)]),
            member(tag: "2", attacks: [attack(stars: 2)]),
            member(tag: "3", attacks: [attack(stars: 0)]),
        ]
        let p = participant(attacks: 3, stars: 3, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows, teamSize: 3), [])
    }

    /// teamSize 缺失（nil，含默认参数路径）→ 不产生 memberCount（既有调用兼容）。
    func testMismatchesNoMemberCountWhenTeamSizeNil() {
        let members = [member(tag: "1", attacks: [attack(stars: 1)])]
        let p = participant(attacks: 1, stars: 1, members: members)
        let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
        // 显式 nil 与缺省参数等价：都不产生 memberCount
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows), [])
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: rows, teamSize: nil), [])
    }

    /// 官方未返回成员数组（members == nil）→ 不产生 memberCount
    ///（UI 已有"成员数据未返回"提示，不重复告警）。
    /// 官方数值字段一并置 nil（rows 为空时官方 attacks/stars 会触发既有
    /// attackCount/stars 诊断——本测试只隔离 memberCount 行为）。
    func testMismatchesNoMemberCountWhenMembersNil() {
        let p = participant(attacks: nil, stars: nil, members: nil)
        // rows 为空与 members == nil 对应（mismatches 前置条件：rows 与 participant 同源）
        XCTAssertEqual(ClanWarDisplayProjection.mismatches(participant: p, rows: [], teamSize: 30), [])
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

    private static let iterationCount = 400
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
        // I1：统计 nil 比例（生成器偏差防再犯）。LCG 低 2 位周期 4 会让
        // `next() % 4 == 0` 恒真/恒假 → nil 比例 0% 或 100%，此断言直接失败。
        var totalMembers = 0
        var nilMapPosition = 0
        var nilTag = 0
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            for member in members {
                totalMembers += 1
                if member.mapPosition == nil { nilMapPosition += 1 }
                if member.tag == nil { nilTag += 1 }
            }
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
        // I1：nil 出现比例必须在 [15%, 35%]（期望 25%）——生成器真正覆盖 nil
        // 分支；低 2 位 LCG（`next() % 4 == 0`）周期 4 会产生 0%/100% 极端
        // 比例，本断言直接失败（防再犯）。
        assertOrFail(totalMembers > 0, "生成器必须产出成员", context: "seed=0x126")
        let mapPositionRatio = Double(nilMapPosition) / Double(totalMembers)
        let tagRatio = Double(nilTag) / Double(totalMembers)
        assertOrFail(mapPositionRatio >= 0.15 && mapPositionRatio <= 0.35,
                     "mapPosition nil 比例必须在 [15%, 35%]",
                     context: "seed=0x126 total=\(totalMembers) nil=\(nilMapPosition) ratio=\(mapPositionRatio)")
        assertOrFail(tagRatio >= 0.15 && tagRatio <= 0.35,
                     "tag nil 比例必须在 [15%, 35%]",
                     context: "seed=0x126 total=\(totalMembers) nil=\(nilTag) ratio=\(tagRatio)")
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

    // MARK: - 搜索 property（Issue #126：只匹配名称与 tag，大小写不敏感、包含匹配）

    /// 搜索用字符池：大小写混合 ASCII + 数字 + "#" + 空白（覆盖大小写不敏感、
    /// tag 前缀、空/纯空白查询；"#" 在 tag 内与官方 tag 格式一致）。
    private static let searchCharPool: [Character] = Array("#ABCdef012 xY")

    /// 随机搜索查询：长度 0...6；10% 概率纯空白（覆盖"空查询不过滤"）。
    private func randomSearchQuery(_ g: inout FilterSeededGenerator) -> String {
        let length = g.int(in: 0...6)
        if g.int(in: 0...9) == 0 { return String(repeating: " ", count: max(length, 1)) }
        return String((0..<length).map { _ in Self.searchCharPool[g.int(in: 0...(Self.searchCharPool.count - 1))] })
    }

    /// 随机搜索行：名称 25% nil、tag 25% nil（nil 不匹配），其余随机文本。
    private func randomSearchRow(_ g: inout FilterSeededGenerator, index: Int) -> ClanWarMemberRow {
        ClanWarMemberRow(
            sourceIndex: index, mapPosition: nil,
            name: g.int(in: 0...3) == 0 ? nil : randomSearchQuery(&g),
            tag: g.int(in: 0...3) == 0 ? nil : "#" + randomSearchQuery(&g),
            townhallLevel: nil,
            action: ClanWarMemberAction(status: .complete, attackCount: 1, remainingAttacks: nil),
            stars: nil, lines: nil, defenseAttacks: nil
        )
    }

    /// 手动参考实现：trim 后空 → 全匹配；否则名称或 tag 小写包含匹配。
    private func manualSearchMatch(_ row: ClanWarMemberRow, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let needle = trimmed.lowercased()
        return (row.name?.lowercased().contains(needle) ?? false)
            || (row.tag?.lowercased().contains(needle) ?? false)
    }

    /// 随机 rows + 随机 query：rows(matchingSearch:) 结果 == 手动包含匹配过滤
    /// （N=100，确定性生成器 seed 固定可复现）。空/纯空白查询两侧都必须返回全量。
    func testPropertySearchMatchesManualFilter() {
        var g = FilterSeededGenerator(seed: 0x526)
        for round in 0..<100 {
            let rows = (0..<g.int(in: 0...30)).map { randomSearchRow(&g, index: $0) }
            let query = randomSearchQuery(&g)
            let expected = rows.filter { manualSearchMatch($0, query: query) }
            let actual = ClanWarDisplayProjection.rows(rows, matchingSearch: query)
            assertOrFail(actual == expected,
                         "rows(matchingSearch:) 必须等于手动包含匹配过滤（保持输入顺序）",
                         context: "seed=0x526 round=\(round) n=\(rows.count) query=\(query.debugDescription)")
            // 真值 oracle（防"与生产同构错"）：query 非空时，结果中每一行都
            // 必须真实包含查询——name 或 tag（小写）包含 query（小写）。
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let needle = trimmed.lowercased()
                for row in actual {
                    assertOrFail(
                        (row.name?.lowercased().contains(needle) ?? false)
                            || (row.tag?.lowercased().contains(needle) ?? false),
                        "结果行必须真实匹配查询（真值 oracle）",
                        context: "seed=0x526 round=\(round) query=\(query.debugDescription) name=\(row.name?.debugDescription ?? "nil") tag=\(row.tag?.debugDescription ?? "nil")"
                    )
                }
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

    /// 取 LCG 状态**高位** 32 位映射到区间（I1 修复）：低 2 位周期为 4
    /// （a ≡ 1 mod 4 且 c 奇数），`next() % 4 == 0` 恒真/恒假 → nil 分支
    /// 0%/100% 系统性偏差；高位比特随完整周期均匀分布。
    /// range.count == 1 时先返回 lowerBound（% 0 防御，仅防御不可达路径）。
    mutating func int(in range: ClosedRange<Int>) -> Int {
        let count = range.count
        guard count > 1 else { return range.lowerBound }
        return Int(next() >> 32) % count + range.lowerBound
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        Double(next()) / Double(UInt64.max) * (range.upperBound - range.lowerBound) + range.lowerBound
    }
}
