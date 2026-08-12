import Foundation

// MARK: - 展示投影值类型（Issue #125）

/// 战争阶段（从 raw `state: String?` 投影）。
///
/// 契约（spec 规则 1）：
/// - 官方字符串 trim 后精确匹配，不做容错归一：未知字符串或字段缺失 → `.unknown`，
///   保留原始值供审计，绝不静默归入已知阶段（防止 schema 漂移时把新阶段
///   伪装成 preparation/inWar）。
/// - `.unknown(raw:)` 的 `raw == nil` 表示字段缺失，`raw` 非 nil 表示未知字符串；
///   存储原始值（不 trim），仅比较时 trim。
public enum ClanWarPhase: Hashable, Sendable {
    case notInWar
    case preparation
    case inWar
    case warEnded
    /// 未知阶段：raw = 官方原始 state 字符串；nil = 字段缺失。
    case unknown(raw: String?)
}

/// 攻击配额事实（teamSize × attacksPerMember），fail-closed。
///
/// 契约（spec 规则 2）：
/// - `totalAttacks` = teamSize × attacksPerMember；**任一字段缺失或任一值 <= 0
///   时恒为 nil**（不伪造总配额，不自行假设每人 1 或 2 次）。
/// - 乘法用饱和算术：`saturated == true` 时 `totalAttacks` 只是可表示上界，
///   显示层不得作为权威业务数据展示（负数/异常大值/溢出不崩溃）。
/// - 原始值原样保留供审计（`teamSize` / `attacksPerMember`）。
public struct ClanWarQuota: Hashable, Sendable {
    /// 官方 teamSize（队伍人数）；nil = 缺失。
    public let teamSize: Int?
    /// 官方 attacksPerMember；nil = 缺失。
    public let attacksPerMember: Int?
    /// 总攻击配额（teamSize × attacksPerMember）；不可计算时 nil。
    public let totalAttacks: Int?
    /// 乘法溢出饱和标志（fail-closed）。
    public let saturated: Bool

    public init(teamSize: Int?, attacksPerMember: Int?, totalAttacks: Int?, saturated: Bool) {
        self.teamSize = teamSize
        self.attacksPerMember = attacksPerMember
        self.totalAttacks = totalAttacks
        self.saturated = saturated
    }
}

/// 成员攻击行动状态——**纯数据事实**：只表达「已知攻击次数」与「有效配额」
/// 的关系，不掺入战争阶段（阶段由 `ClanWarPhase` 顶层表达，两者在
/// `ClanWarDisplayProjection.displayGroup(phase:action:)` 处才组合）。
///
/// 契约（spec 规则 3）：
/// - `attacks == nil` → `.unknown`：攻击数据未知，**不得显示"未攻击"**；
/// - `attacks == []` → `.zero`：明确 0 次（0 次攻击是配额无关的事实，
///   配额缺失也成立）；
/// - 配额有效（> 0）且 0 < count < quota → `.partial`（剩余次数见
///   `ClanWarMemberAction.remainingAttacks`）；
/// - count == quota → `.complete`；
/// - count > quota → `.overQuota`（数据异常/超出配额：不得伪造"已完成"、
///   不得产出负数剩余）；
/// - 配额缺失或无效（nil / <= 0）且已有攻击 → `.quotaUnknown`：次数已知但
///   无法判定完成/剩余（不假设配额为 1 或 2）。
public enum ClanWarMemberAttackStatus: Hashable, Sendable {
    /// 攻击数据未知（attacks == nil）。
    case unknown
    /// 明确 0 次攻击（attacks == []）。
    case zero
    /// 0 < count < 有效配额（尚有剩余攻击）。
    case partial
    /// count == 有效配额（已完成）。
    case complete
    /// count > 有效配额（超出配额，数据异常）。
    case overQuota
    /// 攻击次数已知但配额缺失/无效。
    case quotaUnknown
}

/// 成员攻击行动事实。`status` 与数值字段分层：数值不塞进枚举 case，
/// 由结构体字段承载。
public struct ClanWarMemberAction: Hashable, Sendable {
    /// 行动状态。
    public let status: ClanWarMemberAttackStatus
    /// 已知攻击次数；仅 `status == .unknown` 时为 nil，其余恒非 nil。
    public let attackCount: Int?
    /// 剩余攻击次数；**仅 `status == .partial` 时非 nil**（契约：>= 1，
    /// 有效配额下减法不会溢出）。
    public let remainingAttacks: Int?

    public init(status: ClanWarMemberAttackStatus, attackCount: Int?, remainingAttacks: Int?) {
        self.status = status
        self.attackCount = attackCount
        self.remainingAttacks = remainingAttacks
    }
}

/// 成员星数事实：Σ 已知星数 + 缺失数，显式分开。
///
/// 契约（spec 规则 4）：缺失星数**不计入** knownStars（0 是"已知且全为 0 星"
/// 的真实事实，与"星数缺失"可区分）。
/// **注意**：`knownStars + missingCount == attacks.count` 仅在官方契约值域
/// （stars ∈ [0,3]）内成立——schema 违反输入经 clamp 后和可能**不等于**
/// attack count（纯负数 → 小于；超大值如 [-1, Int.max] → known 3, missing 0,
/// count 2 → 大于），属 fail-closed 预期行为，不伪装总和。
/// 与旧 `ClanWarMemberSummary.totalStars`（缺失记 0，锁定旧语义）刻意不共用——
/// issue #125 要求表达"已知星数 + 未知攻击数"，旧类型无法表达。
public struct ClanWarMemberStars: Hashable, Sendable {
    /// 已知星数之和（缺失不计；负数星数 clamp 到 [0,3] 后计入）。
    public let knownStars: Int
    /// 星数缺失的攻击数。
    public let missingCount: Int

    public init(knownStars: Int, missingCount: Int) {
        self.knownStars = knownStars
        self.missingCount = missingCount
    }
}

/// 行动队列/明细中的一行成员（排序后的输出）。
///
/// - `sourceIndex` = 成员在官方数组中的原始下标：既是排序的最终平局键
///   （保证全序，与 sort 稳定性无关），也是 UI ForEach 的稳定 identity
///   （全 optional 输入可能产出完全相同行，不能用 `\.self`）。
///   **作用域注意**：`sourceIndex` 仅在单参与方内唯一——clan/opponent 双方
///   的成员行 `id` 会重复（两侧各从 0 计）；UI 若把双方行放进同一 ForEach，
///   需用复合 id（如 `"clan-\(sourceIndex)"` / `"opponent-\(sourceIndex)"`）。
/// - `lines` 复用既有 `ClanWarAttackLine`（摧毁率逐次原样保留，永不聚合，
///   与 `ClanCombatSummary.warMember` 同一契约）；`attacks == nil` 时与
///   `stars` 同步为 nil（与"明确 0 次攻击"的空数组区分）。
public struct ClanWarMemberRow: Hashable, Sendable, Identifiable {
    public let sourceIndex: Int
    public let mapPosition: Int?
    public let name: String?
    public let tag: String?
    public let townhallLevel: Int?
    /// 攻击行动事实。
    public let action: ClanWarMemberAction
    /// 星数事实；nil = attacks == nil（攻击数据未返回）。
    public let stars: ClanWarMemberStars?
    /// 逐次攻击明细；nil = attacks == nil，[] = 明确 0 次攻击。
    public let lines: [ClanWarAttackLine]?
    /// 防守列数据：对方攻击本成员的次数（raw `ClanWarMember.opponentAttacks`
    /// 直接透传，官方即整数次数）；nil = 官方未返回防守数据。
    public let defenseAttacks: Int?
    /// 最佳防守（官方 `bestOpponentAttack` 投影；nil = 官方未返回）。
    /// 只消费 stars/destructionPercentage/duration——order/defenderTag
    /// 对防守无意义，恒 nil（官方 bestOpponentAttack 的 defenderTag 是进攻方
    /// tag，防守视角不展示）。
    public let bestDefense: ClanWarAttackLine?

    public var id: Int { sourceIndex }

    public init(
        sourceIndex: Int, mapPosition: Int?, name: String?, tag: String?,
        townhallLevel: Int?, action: ClanWarMemberAction,
        stars: ClanWarMemberStars?, lines: [ClanWarAttackLine]?,
        defenseAttacks: Int?, bestDefense: ClanWarAttackLine? = nil
    ) {
        self.sourceIndex = sourceIndex
        self.mapPosition = mapPosition
        self.name = name
        self.tag = tag
        self.townhallLevel = townhallLevel
        self.action = action
        self.stars = stars
        self.lines = lines
        self.defenseAttacks = defenseAttacks
        self.bestDefense = bestDefense
    }
}

/// 成员行动状态计数（按 `ClanWarMemberAttackStatus` 六桶，阶段无关）。
///
/// 契约（spec 规则 6）：Σ 六桶 == rows.count；`.unknown` **独立成桶，不计入
/// "未出手"**。消费指引：若需按展示分组计数（如备战期"等待开战"人数 =
/// `zeroCount`），用 `displayGroup(phase:action:)` 逐行归类——本类型保持
/// 阶段无关，不做阶段推断。
public struct ClanWarActionCounts: Hashable, Sendable {
    public let unknownCount: Int
    public let zeroCount: Int
    public let partialCount: Int
    public let completeCount: Int
    public let overQuotaCount: Int
    public let quotaUnknownCount: Int

    public init(
        unknownCount: Int, zeroCount: Int, partialCount: Int,
        completeCount: Int, overQuotaCount: Int, quotaUnknownCount: Int
    ) {
        self.unknownCount = unknownCount
        self.zeroCount = zeroCount
        self.partialCount = partialCount
        self.completeCount = completeCount
        self.overQuotaCount = overQuotaCount
        self.quotaUnknownCount = quotaUnknownCount
    }
}

/// 成员行在给定战争阶段下的展示分组——「阶段 × 行动事实」的唯一组合点
/// （spec 规则 7）。
///
/// 契约：
/// - 备战期且明确 0 次攻击 → `.awaitingWar`（显示"等待开战"，不得显示"未出手"）；
/// - 其余分组与阶段无关，阶段不改写事实（warEnded 时同样分组，只是样式
///   上不突出待处理——样式是 view 职责）。
public enum ClanWarMemberDisplayGroup: Hashable, Sendable {
    /// 备战期且未出手：显示"等待开战"。
    case awaitingWar
    /// 未出手（0 次攻击）。
    case notAttacked
    /// 尚有剩余攻击。
    case remaining
    /// 已完成配额。
    case complete
    /// 超出配额（数据异常）。
    case overQuota
    /// 攻击次数已知但配额缺失/无效。
    case quotaUnknown
    /// 攻击数据未知（attacks == nil）。
    case unknown
}

/// 参与方官方摘要（顶部比分用）：attacks / stars / destructionPercentage
/// 原样透传（含 nil），**只来自官方 participant 字段，绝不来自成员推导**
/// （spec 规则 8）。
public struct ClanWarParticipantSummary: Hashable, Sendable {
    public let attacks: Int?
    public let stars: Int?
    public let destructionPercentage: Double?

    public init(attacks: Int?, stars: Int?, destructionPercentage: Double?) {
        self.attacks = attacks
        self.stars = stars
        self.destructionPercentage = destructionPercentage
    }
}

/// 官方摘要与成员推导不一致的诊断。空数组 = 一致（或官方缺失无从比对）
/// （spec 规则 9）。
///
/// 契约：
/// - 仅当**双方同字段都存在且不等**才产生对应 case（官方缺失时顶部不显示
///   即可，无矛盾可报）；
/// - 任一成员 `attacks == nil` 时推导总数不可得，报 `.membersIncomplete`
///   （防止把"成员数据不完整"误报成攻击数不一致；官方缺失时仍上报——
///   成员不完整是独立可审计事实）；
/// - 星数比对仅在全部攻击行星数已知时判定（部分缺失时已知和只是下限，
///   不构成权威差异）；比对使用成员**原始**星数的事实层求和（饱和累加），
///   展示层 clamp 值不参与（见 `mismatches(participant:rows:)`）；
/// - 摧毁率永不聚合 → 不存在摧毁率推导，也无摧毁率 mismatch；
/// - associated value 同时携带官方值与推导值——「保留两套事实」是 issue 硬需求。
public enum ClanWarSummaryMismatch: Hashable, Sendable {
    /// 成员攻击数据不完整（存在 attacks == nil 的成员），无法与官方摘要比对。
    case membersIncomplete
    /// 官方 attacks ≠ Σ 成员攻击数。
    case attackCount(official: Int, memberSum: Int)
    /// 官方 stars ≠ Σ 成员已知星数（全部攻击行星数已知时判定）。
    case stars(official: Int, memberKnownSum: Int)
    /// 官方 teamSize 已知、成员数组已返回但数量与 teamSize 不一致
    ///（成员覆盖率诊断；官方未返回成员数组时不产生——UI 已有"成员数据未返回"提示）。
    case memberCount(official: Int, returned: Int)
}

/// 参与方投影：官方摘要（顶部比分）与成员行动队列（明细/诊断）分层存放。
///
/// 契约（spec 规则 8）：
/// - `official` 是顶部比分唯一来源；
/// - `members` 按行动优先排序输出；**nil = 官方未返回成员数组**（与 `[]`
///   明确区分）；`knownAttackDataCount` / `unknownAttackDataCount` 与
///   `members` 同步为 nil（未返回时不得伪装成 0）。
public struct ClanWarParticipantProjection: Hashable, Sendable {
    /// 身份透传（不解释）。
    public let tag: String?
    public let name: String?
    public let clanLevel: Int?
    /// 官方摘要：顶部比分唯一来源。
    public let official: ClanWarParticipantSummary
    /// 行动队列：按行动优先排序后的成员行；nil = 官方未返回成员数组。
    public let members: [ClanWarMemberRow]?
    /// 攻击数据已知的成员数；nil = 成员数组未返回。
    public let knownAttackDataCount: Int?
    /// 攻击数据未知的成员数；nil = 成员数组未返回。
    public let unknownAttackDataCount: Int?
    /// 官方摘要与成员推导不一致的诊断（空 = 无矛盾）。
    public let mismatches: [ClanWarSummaryMismatch]

    public init(
        tag: String?, name: String?, clanLevel: Int?,
        official: ClanWarParticipantSummary,
        members: [ClanWarMemberRow]?,
        knownAttackDataCount: Int?, unknownAttackDataCount: Int?,
        mismatches: [ClanWarSummaryMismatch]
    ) {
        self.tag = tag
        self.name = name
        self.clanLevel = clanLevel
        self.official = official
        self.members = members
        self.knownAttackDataCount = knownAttackDataCount
        self.unknownAttackDataCount = unknownAttackDataCount
        self.mismatches = mismatches
    }
}

/// 部落对战展示投影顶层输出（spec 规则 11）。
///
/// 契约：
/// - `phase` 与 `quota` 是独立事实维度；刷新/传输状态由
///   `ClanWarDisplayProjection.refreshStatus(of:)` 单独产出，绝不合并进本类型
///   （"不把 HTTP 失败、未知字段、成员缺失、阶段未知压缩成同一个'无数据'"）。
/// - `phase == .notInWar` 时 `clan`/`opponent` 恒为 nil（成功空状态契约：
///   不生成成员列表，即使原始响应意外携带成员数据也不投影）。
public struct ClanWarProjection: Hashable, Sendable {
    /// 战争阶段（含可审计的未知阶段）。
    public let phase: ClanWarPhase
    /// 攻击配额事实（teamSize / attacksPerMember / 总配额，fail-closed）。
    public let quota: ClanWarQuota
    /// 己方投影；nil = 官方未返回该方或 notInWar 空状态。
    public let clan: ClanWarParticipantProjection?
    /// 对方投影；nil = 官方未返回该方或 notInWar 空状态。
    public let opponent: ClanWarParticipantProjection?

    public init(
        phase: ClanWarPhase,
        quota: ClanWarQuota,
        clan: ClanWarParticipantProjection?,
        opponent: ClanWarParticipantProjection?
    ) {
        self.phase = phase
        self.quota = quota
        self.clan = clan
        self.opponent = opponent
    }
}

/// 端点刷新状态（展示维度，与 `ClanWarPhase` 完全解耦，spec 规则 10）。
///
/// 与既有 `OfficialAPIDisplayStatus` 的关系：内部复用其派生逻辑（stale 判定
/// 同一映射点，不重复实现）；仅当 `status == .failed` 时按 last-good 有无拆成
/// 两种——issue #125 明示 `failed-with-lastGood` 是独立展示状态（失败保留
/// 上次成功数据 ≠ 首次失败）。
public enum ClanWarRefreshStatus: Hashable, Sendable {
    /// 从未发起请求。
    case never
    /// 请求进行中。
    case loading
    /// 最近一次请求成功。
    case success
    /// 成功但超过 staleThreshold（只提示新鲜度，不改变战争内容）。
    case stale
    /// 最近请求失败，但保留上次成功快照（可继续展示 last-good）。
    case failedWithLastGood
    /// 最近请求失败且无 last-good（首期失败）。
    case failedWithoutLastGood
    /// 未发起请求（缺 tag / 无效 tag / 批量刷新跳过）。
    case skipped
}

// MARK: - 投影入口

/// Issue #125：部落对战展示投影入口。纯函数，不改变任何现有模型/持久化语义。
///
/// 设计：投影只输出**结构化语义**（状态枚举 + 数值事实），不产出中文文案
/// （文案映射属 UI 层，UI 重构时基于本投影实现）；所有类型不实现 Codable
/// （瞬态展示模型，不参与持久化，raw snapshot 结构与 parserVersion 不变）。
public enum ClanWarDisplayProjection {

    /// 快照 → 顶层展示投影。`phase == .notInWar` 时 `clan`/`opponent` 恒为 nil
    ///（成功空状态，不生成成员列表）。
    public static func project(_ snapshot: OfficialClanWarSnapshot) -> ClanWarProjection {
        let phase = phase(of: snapshot.state)
        let quota = quota(teamSize: snapshot.teamSize, attacksPerMember: snapshot.attacksPerMember)
        let isNotInWar = phase == .notInWar
        return ClanWarProjection(
            phase: phase,
            quota: quota,
            clan: isNotInWar ? nil : snapshot.clan.map { participant($0, attacksPerMember: snapshot.attacksPerMember, teamSize: snapshot.teamSize) },
            opponent: isNotInWar ? nil : snapshot.opponent.map { participant($0, attacksPerMember: snapshot.attacksPerMember, teamSize: snapshot.teamSize) }
        )
    }

    /// 阶段映射：已知字符串 trim 后逐一映射；未知/缺失 → `.unknown(raw:)`
    ///（raw 保留原始值供审计）。
    public static func phase(of state: String?) -> ClanWarPhase {
        switch state?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "notInWar": return .notInWar
        case "preparation": return .preparation
        case "inWar": return .inWar
        case "warEnded": return .warEnded
        default: return .unknown(raw: state)
        }
    }

    /// 配额事实：teamSize × attacksPerMember，任一缺失或 <= 0 → totalAttacks nil；
    /// 乘法用饱和算术，溢出置 `saturated`。
    public static func quota(teamSize: Int?, attacksPerMember: Int?) -> ClanWarQuota {
        guard let teamSize, let attacksPerMember, teamSize > 0, attacksPerMember > 0 else {
            return ClanWarQuota(teamSize: teamSize, attacksPerMember: attacksPerMember,
                                totalAttacks: nil, saturated: false)
        }
        let result = SaturatingArithmetic.multiply(teamSize, attacksPerMember)
        return ClanWarQuota(teamSize: teamSize, attacksPerMember: attacksPerMember,
                            totalAttacks: result.value, saturated: result.overflowed)
    }

    /// 成员行动事实：attacks nil → .unknown；[] → .zero；配额有效时比较
    /// count 与 quota → .partial/.complete/.overQuota；配额缺失/无效且已有
    /// 攻击 → .quotaUnknown。
    public static func memberAction(attacks: [ClanWarAttack]?, attacksPerMember: Int?) -> ClanWarMemberAction {
        guard let attacks else {
            return ClanWarMemberAction(status: .unknown, attackCount: nil, remainingAttacks: nil)
        }
        let count = attacks.count
        if count == 0 {
            // 明确 0 次攻击是配额无关的事实（配额缺失也成立）。
            return ClanWarMemberAction(status: .zero, attackCount: 0, remainingAttacks: nil)
        }
        guard let perMember = attacksPerMember, perMember > 0 else {
            // 配额缺失/无效且已有攻击：次数已知，无法判定完成/剩余。
            return ClanWarMemberAction(status: .quotaUnknown, attackCount: count, remainingAttacks: nil)
        }
        if count < perMember {
            return ClanWarMemberAction(status: .partial, attackCount: count,
                                       remainingAttacks: perMember - count)
        }
        if count == perMember {
            return ClanWarMemberAction(status: .complete, attackCount: count, remainingAttacks: nil)
        }
        return ClanWarMemberAction(status: .overQuota, attackCount: count, remainingAttacks: nil)
    }

    /// 成员星数事实：Σ 已知星数（负数 clamp [0,3]）+ 缺失数；attacks == nil
    /// → nil（星数完全未知，与"明确 0 星"区分）。
    public static func memberStars(_ member: ClanWarMember) -> ClanWarMemberStars? {
        guard let attacks = member.attacks else { return nil }
        var knownSum = 0
        var missingCount = 0
        for attack in attacks {
            if let stars = attack.stars {
                knownSum += min(max(stars, 0), 3)
            } else {
                missingCount += 1
            }
        }
        return ClanWarMemberStars(knownStars: knownSum, missingCount: missingCount)
    }

    /// 行动优先排序 + 行投影（spec 规则 5）。
    ///
    /// 全序：rank（zero < partial < complete < 数据未知组）→ mapPosition
    ///（nil 排最后）→ name（nil 排最后，String 比较序，即 Unicode 规范化后
    /// 比较）→ sourceIndex 升序。
    /// `sourceIndex` 唯一 → 排序结果与输入顺序无关、与 sort 稳定性无关；幂等。
    /// Issue #126 起 delegate 到 `sortedRows(_:attacksPerMember:order:)`（行为不变）。
    public static func sortedRows(_ members: [ClanWarMember], attacksPerMember: Int?) -> [ClanWarMemberRow] {
        sortedRows(members, attacksPerMember: attacksPerMember, order: .actionPriority)
    }

    /// 排序组键：未出手(0) → 剩余(1) → 已完成(2) → 数据未知组(3)
    ///（overQuota / quotaUnknown / unknown 同组，符合 issue 四组语义）。
    private static func sortRank(_ status: ClanWarMemberAttackStatus) -> Int {
        switch status {
        case .zero: return 0
        case .partial: return 1
        case .complete: return 2
        case .overQuota, .quotaUnknown, .unknown: return 3
        }
    }

    /// 六桶计数（Σ == rows.count；unknown 独立，不计入 zero）。
    public static func actionCounts(_ rows: [ClanWarMemberRow]) -> ClanWarActionCounts {
        var unknown = 0, zero = 0, partial = 0, complete = 0, overQuota = 0, quotaUnknown = 0
        for row in rows {
            switch row.action.status {
            case .unknown: unknown += 1
            case .zero: zero += 1
            case .partial: partial += 1
            case .complete: complete += 1
            case .overQuota: overQuota += 1
            case .quotaUnknown: quotaUnknown += 1
            }
        }
        return ClanWarActionCounts(unknownCount: unknown, zeroCount: zero, partialCount: partial,
                                   completeCount: complete, overQuotaCount: overQuota,
                                   quotaUnknownCount: quotaUnknown)
    }

    /// 展示分组：阶段 × 行动事实的唯一组合点（preparation + zero → .awaitingWar）。
    public static func displayGroup(phase: ClanWarPhase, action: ClanWarMemberAction) -> ClanWarMemberDisplayGroup {
        switch action.status {
        case .zero:
            return phase == .preparation ? .awaitingWar : .notAttacked
        case .partial:
            return .remaining
        case .complete:
            return .complete
        case .overQuota:
            return .overQuota
        case .quotaUnknown:
            return .quotaUnknown
        case .unknown:
            return .unknown
        }
    }

    /// 参与方投影：官方摘要 + 排序行动队列 + 覆盖计数 + 诊断。
    ///
    /// `teamSize` 传入官方 teamSize（Issue #126 成员覆盖率诊断）；nil = 官方
    /// 缺失，不产生 memberCount 诊断。
    public static func participant(_ participant: ClanWarParticipant, attacksPerMember: Int?, teamSize: Int? = nil) -> ClanWarParticipantProjection {
        let official = ClanWarParticipantSummary(
            attacks: participant.attacks,
            stars: participant.stars,
            destructionPercentage: participant.destructionPercentage
        )
        guard let members = participant.members else {
            // 官方未返回成员数组：与 [] 明确区分，计数同步未知。
            return ClanWarParticipantProjection(
                tag: participant.tag, name: participant.name, clanLevel: participant.clanLevel,
                official: official, members: nil,
                knownAttackDataCount: nil, unknownAttackDataCount: nil,
                mismatches: []
            )
        }
        let rows = sortedRows(members, attacksPerMember: attacksPerMember)
        let known = members.filter { $0.attacks != nil }.count
        let unknown = members.count - known
        return ClanWarParticipantProjection(
            tag: participant.tag, name: participant.name, clanLevel: participant.clanLevel,
            official: official, members: rows,
            knownAttackDataCount: known, unknownAttackDataCount: unknown,
            mismatches: mismatches(participant: participant, rows: rows, teamSize: teamSize)
        )
    }

    /// 官方摘要 vs 成员推导诊断（spec 规则 9）。
    ///
    /// 前置条件：`rows` 必须与 `participant` 同源（同一参与方的成员数组投影），
    /// 类型系统不校验此绑定，传错参与方会产出错误诊断（当前唯一调用方
    /// `participant(_:attacksPerMember:teamSize:)` 保证同源）。
    /// 仅当成员侧数据完整（无 attacks == nil）且官方字段存在时才判数值差异：
    /// - `teamSize` 非 nil 且成员数组已返回但数量不一致 → `.memberCount`
    ///   （成员覆盖率诊断；`members == nil` 或 `teamSize == nil` 不产生）；
    /// - 任一成员 attacks == nil → `[.membersIncomplete]`（推导不可得；官方
    ///   缺失时仍上报——成员不完整是独立可审计事实）；
    /// - 官方 attacks 存在且 ≠ Σ 成员攻击数 → `.attackCount`；
    /// - 官方 stars 存在、全部攻击行星数已知（缺失合计 0）且 ≠ Σ 成员星数
    ///   → `.stars`（部分缺失时已知和只是下限，不构成权威差异）。
    /// **注意**：星数比对使用逐行**原始** stars 求和（事实层，`SaturatingArithmetic`
    /// 饱和累加防 malformed 输入崩溃），不使用 `ClanWarMemberStars.knownStars`
    /// （展示层 clamp 到 [0,3] 后的值）——schema 违反输入（如 stars=5）下
    /// clamp 会扭曲事实，导致"双侧一致却误报不一致"。
    /// **注意**：memberCount 的数量以 `participant.members`（raw 数组）为准，
    /// 不使用 `rows.count`——rows 是排序投影，契约上同源但 raw 才是事实层。
    public static func mismatches(participant: ClanWarParticipant, rows: [ClanWarMemberRow], teamSize: Int? = nil) -> [ClanWarSummaryMismatch] {
        var result: [ClanWarSummaryMismatch] = []
        // 成员覆盖率诊断：官方 teamSize 已知、成员数组已返回但数量不一致。
        if let teamSize, let members = participant.members, members.count != teamSize {
            result.append(.memberCount(official: teamSize, returned: members.count))
        }
        let memberAttacks = rows.compactMap { $0.lines }
        guard memberAttacks.count == rows.count else {
            // 存在成员 attacks == nil：推导不可得，不得误报数值差异。
            result.append(.membersIncomplete)
            return result
        }
        let memberAttackSum = memberAttacks.reduce(0) { $0 + $1.count }
        // 攻击次数求和用普通加法：count 是数组长度，受内存约束（现实不可达
        // 溢出）；星数求和用饱和加法（schema 违反输入可达，见下）。
        // 事实层：原始 stars 饱和累加（含 nil 记 0）与缺失计数；展示层 clamp 不参与。
        // 溢出饱和到 Int.max（不崩溃）：官方 stars 值域 [0,3]，饱和值必然 ≠ 官方值，
        // 一致性判断的 fail-closed 语义保持不变。
        var rawStarSum = 0
        var starMissingCount = 0
        for attacks in memberAttacks {
            for attack in attacks {
                if let stars = attack.stars {
                    rawStarSum = SaturatingArithmetic.add(rawStarSum, stars).value
                } else {
                    starMissingCount += 1
                }
            }
        }

        if let officialAttacks = participant.attacks, officialAttacks != memberAttackSum {
            result.append(.attackCount(official: officialAttacks, memberSum: memberAttackSum))
        }
        if let officialStars = participant.stars, starMissingCount == 0, officialStars != rawStarSum {
            result.append(.stars(official: officialStars, memberKnownSum: rawStarSum))
        }
        return result
    }

    /// 刷新状态投影（输入端点状态，与 phase 解耦）。
    ///
    /// 复用 `displayStatus` 派生 stale（同一判定点，防双实现漂移）；
    /// 仅 `.failed` 按 last-good 有无拆成 failedWithLastGood / failedWithoutLastGood。
    public static func refreshStatus(of state: ClanWarAPIState) -> ClanWarRefreshStatus {
        switch state.displayStatus {
        case .never: return .never
        case .loading: return .loading
        case .success: return .success
        case .stale: return .stale
        case .skipped: return .skipped
        case .failed:
            return state.lastGood == nil ? .failedWithoutLastGood : .failedWithLastGood
        }
    }
}

// MARK: - 成员筛选桶与排序变体（Issue #126）

/// 成员筛选桶（UI chips 的纯数据映射）。
///
/// 契约（Issue #126，SDD 3 候选投票定稿方案 A）：
/// - 基座五桶互斥且覆盖除 awaitingWar 外的全部 displayGroup：
///   notAttacked / remainingOnce / remainingMany / complete / unknownData；
/// - `pending` 是派生聚合桶：== notAttacked ∪ remaining（不含 awaitingWar——
///   备战期 0 次攻击是正常状态，不算"未出手告警"）；
/// - `.unknown`（attacks == nil）只能进 unknownData，绝不进未出手；
/// - awaitingWar（preparation + zero）不进任何告警桶，计数单独由
///   `ClanWarFilterCounts.awaitingWar` 输出（UI 显示"等待开战 N"，中性色）。
public enum ClanWarMemberFilter: Hashable, Sendable, CaseIterable {
    case all
    case pending
    case notAttacked
    case remainingOnce
    case remainingMany
    case complete
    case unknownData
}

/// 成员排序顺序（Issue #126：默认行动优先，提供地图位置/名称切换）。
public enum ClanWarSortOrder: Hashable, Sendable, CaseIterable {
    /// 行动优先（= #125 `sortedRows` 语义）：未出手 → 剩余 → 已完成 → 数据未知组。
    case actionPriority
    /// 地图位置升序（nil 排最后），平局按名称再按 sourceIndex。
    case mapPosition
    /// 名称升序（nil 排最后，String 比较序），平局按 mapPosition 再按 sourceIndex。
    case name
}

/// 筛选桶计数（Σ 守恒不变式的可测输出）。
public struct ClanWarFilterCounts: Hashable, Sendable {
    /// 派生聚合桶：notAttacked + remainingOnce + remainingMany（不含 awaitingWar）。
    public let pending: Int
    /// 未出手（0 次攻击，非备战期）。
    public let notAttacked: Int
    /// 剩余攻击恰好 1 次。
    public let remainingOnce: Int
    /// 剩余攻击 >= 2 次。
    public let remainingMany: Int
    /// 已完成配额。
    public let complete: Int
    /// 数据未知（unknown / quotaUnknown / overQuota 三态合并）。
    public let unknownData: Int
    /// 备战期且明确 0 次攻击（中性计数，不进告警桶）。
    public let awaitingWar: Int

    public init(pending: Int, notAttacked: Int, remainingOnce: Int,
                remainingMany: Int, complete: Int, unknownData: Int, awaitingWar: Int) {
        self.pending = pending
        self.notAttacked = notAttacked
        self.remainingOnce = remainingOnce
        self.remainingMany = remainingMany
        self.complete = complete
        self.unknownData = unknownData
        self.awaitingWar = awaitingWar
    }
}

extension ClanWarDisplayProjection {

    /// 行是否匹配筛选桶。`all` 恒 true；其余基于 displayGroup + remainingAttacks。
    ///
    /// 映射（契约见 `ClanWarMemberFilter`）：notAttacked ↔ group .notAttacked；
    /// remainingOnce/Many ↔ group .remaining 且 remainingAttacks == 1 / != 1；
    /// complete ↔ group .complete；unknownData ↔ group {.unknown, .quotaUnknown,
    /// .overQuota}；pending ↔ group {.notAttacked, .remaining}。
    public static func matches(_ row: ClanWarMemberRow, filter: ClanWarMemberFilter, phase: ClanWarPhase) -> Bool {
        switch filter {
        case .all:
            return true
        case .pending:
            switch displayGroup(phase: phase, action: row.action) {
            case .notAttacked, .remaining: return true
            default: return false
            }
        case .notAttacked:
            return displayGroup(phase: phase, action: row.action) == .notAttacked
        case .remainingOnce:
            return displayGroup(phase: phase, action: row.action) == .remaining
                && row.action.remainingAttacks == 1
        case .remainingMany:
            return displayGroup(phase: phase, action: row.action) == .remaining
                && row.action.remainingAttacks != 1
        case .complete:
            return displayGroup(phase: phase, action: row.action) == .complete
        case .unknownData:
            switch displayGroup(phase: phase, action: row.action) {
            case .unknown, .quotaUnknown, .overQuota: return true
            default: return false
            }
        }
    }

    /// 过滤行（保持输入顺序不变，仅过滤）。`all` 返回原数组。
    public static func filteredRows(_ rows: [ClanWarMemberRow], filter: ClanWarMemberFilter,
                                    phase: ClanWarPhase) -> [ClanWarMemberRow] {
        filter == .all ? rows : rows.filter { matches($0, filter: filter, phase: phase) }
    }

    /// 搜索过滤（Issue #126）：只匹配成员名称与 tag，大小写不敏感、包含匹配。
    ///
    /// 契约：
    /// - 空字符串/纯空白 → 返回原数组（不过滤）；
    /// - nil 名称/tag 不参与匹配（不把缺失当作空串命中）；
    /// - 匹配大小写不敏感（`lowercased()` 包含比较），tag 的 "#" 前缀是
    ///   tag 原文的一部分，包含匹配按完整 tag 字符串进行；
    /// - 保持输入顺序（仅过滤，不重排）。
    public static func rows(_ rows: [ClanWarMemberRow], matchingSearch query: String) -> [ClanWarMemberRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        let normalized = needle.lowercased()
        return rows.filter { row in
            (row.name?.lowercased().contains(normalized) ?? false)
                || (row.tag?.lowercased().contains(normalized) ?? false)
        }
    }

    /// 各筛选桶计数（含 awaitingWar 中性计数）。
    ///
    /// 不变式：notAttacked + remainingOnce + remainingMany + complete + unknownData
    /// + awaitingWar == rows.count；pending == notAttacked + remainingOnce + remainingMany。
    /// awaitingWar 仅来自 preparation + zero（displayGroup 唯一特判点）。
    public static func chipCounts(rows: [ClanWarMemberRow], phase: ClanWarPhase) -> ClanWarFilterCounts {
        var notAttacked = 0, once = 0, many = 0, complete = 0, unknownData = 0, awaitingWar = 0
        for row in rows {
            switch displayGroup(phase: phase, action: row.action) {
            case .awaitingWar:
                awaitingWar += 1
            case .notAttacked:
                notAttacked += 1
            case .remaining:
                // .remaining ⇒ status == .partial ⇒ remainingAttacks 恒非 nil 且 >= 1
                if row.action.remainingAttacks == 1 {
                    once += 1
                } else {
                    many += 1
                }
            case .complete:
                complete += 1
            case .overQuota, .quotaUnknown, .unknown:
                unknownData += 1
            }
        }
        return ClanWarFilterCounts(
            pending: notAttacked + once + many,
            notAttacked: notAttacked, remainingOnce: once, remainingMany: many,
            complete: complete, unknownData: unknownData, awaitingWar: awaitingWar
        )
    }

    /// 按指定顺序排序（`order` 变体；`actionPriority` 与 #125 `sortedRows` 全序一致）。
    /// 三种顺序均以 sourceIndex 为最终平局键 → 全序确定、结果与输入顺序无关、幂等。
    public static func sortedRows(_ members: [ClanWarMember], attacksPerMember: Int?,
                                  order: ClanWarSortOrder) -> [ClanWarMemberRow] {
        let rows = members.enumerated().map { index, member in
            ClanWarMemberRow(
                sourceIndex: index,
                mapPosition: member.mapPosition,
                name: member.name,
                tag: member.tag,
                townhallLevel: member.townhallLevel,
                action: memberAction(attacks: member.attacks, attacksPerMember: attacksPerMember),
                stars: memberStars(member),
                lines: member.attacks.map { attacks in
                    attacks.map {
                        ClanWarAttackLine(order: $0.order, stars: $0.stars,
                                          destructionPercentage: $0.destructionPercentage,
                                          defenderTag: $0.defenderTag, duration: $0.duration)
                    }
                },
                defenseAttacks: member.opponentAttacks,
                bestDefense: member.bestOpponentAttack.map {
                    ClanWarAttackLine(stars: $0.stars,
                                      destructionPercentage: $0.destructionPercentage,
                                      duration: $0.duration)
                }
            )
        }
        return rows.sorted { compareRows($0, $1, order: order) }
    }

    /// 对已投影行按指定顺序重排（Issue #126）。
    ///
    /// 契约：键链与 `sortedRows(_:attacksPerMember:order:)` 完全一致——
    /// - actionPriority：rank（displayGroup 语义：zero < partial < complete <
    ///   数据未知组）→ mapPosition → name → sourceIndex；
    /// - mapPosition：mapPosition → name → sourceIndex；
    /// - name：name → mapPosition → sourceIndex。
    ///
    /// `sourceIndex` 恒为最终平局键 → 全序确定、幂等、与输入顺序无关。
    /// UI 层二次排序必须走本函数（禁止自行实现比较器——平局键链是
    /// sortedRows 的既定契约，UI 复制实现会产生排序漂移）。
    public static func reorder(_ rows: [ClanWarMemberRow], order: ClanWarSortOrder) -> [ClanWarMemberRow] {
        rows.sorted { compareRows($0, $1, order: order) }
    }

    /// 全序比较器（键链依 order 而异，sourceIndex 恒为最终平局键）：
    /// - actionPriority：rank → mapPosition → name → sourceIndex（= #125 语义）；
    /// - mapPosition：mapPosition → name → sourceIndex；
    /// - name：name → mapPosition → sourceIndex。
    ///
    /// 键链是字典序比较：首个不同键即定序，sourceIndex 唯一 → 严格全序，
    /// 排序幂等且与输入顺序无关。
    private static func compareRows(_ lhs: ClanWarMemberRow, _ rhs: ClanWarMemberRow,
                                    order: ClanWarSortOrder) -> Bool {
        switch order {
        case .actionPriority:
            let lRank = sortRank(lhs.action.status)
            let rRank = sortRank(rhs.action.status)
            if lRank != rRank { return lRank < rRank }
            if let decision = compareNilLast(lhs.mapPosition, rhs.mapPosition) { return decision }
            if let decision = compareNilLast(lhs.name, rhs.name) { return decision }
        case .mapPosition:
            if let decision = compareNilLast(lhs.mapPosition, rhs.mapPosition) { return decision }
            if let decision = compareNilLast(lhs.name, rhs.name) { return decision }
        case .name:
            if let decision = compareNilLast(lhs.name, rhs.name) { return decision }
            if let decision = compareNilLast(lhs.mapPosition, rhs.mapPosition) { return decision }
        }
        // sourceIndex：最终平局键（全序）
        return lhs.sourceIndex < rhs.sourceIndex
    }

    /// 可空升序比较（nil 排最后）：返回 nil 表示两侧相等（继续下一键）。
    private static func compareNilLast<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?):
            return l != r ? l < r : nil
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return nil
        }
    }
}
