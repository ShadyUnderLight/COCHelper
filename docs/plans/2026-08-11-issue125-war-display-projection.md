# Issue #125：部落对战展示投影 — 设计定稿（SDD）

日期：2026-08-11
基线：origin/main @ 55d57fb
状态：三候选设计投票定稿（候选 A 骨架 + B/C 局部吸收）

## 目标

建立可测试的 Core 展示投影，把 `ClanWarCardView` 中散落的展示语义（战争阶段、攻击配额、成员行动状态、未知值处理、排序）抽成 `COCHelperCore` 中的纯函数/值类型投影，作为后续 UI 重构的唯一输入。

约束：不扩展 API、不改变 raw snapshot 持久化结构、不修改 parserVersion、不依赖 SwiftUI、不重做 `ClanWarCardView` 布局、不改动既有类型（`ClanWarMemberSummary` 的 `?? 0` 旧语义锁定不动）。

## 设计决策记录（三候选投票）

| 决策点 | 候选 A | 候选 B | 候选 C | 定稿 |
|---|---|---|---|---|
| 成员状态是否含 phase | 不含，`displayGroup` 组合 | 含 `waitingForStart` | 不含，文案定稿 | **A**：状态纯事实，阶段在 `displayGroup(phase:action:)` 唯一组合 |
| 未知 phase 表达 | `unknown(raw: String?)` | 同 A | 同 A | **一致**：associated value 保留原始值，`raw == nil` 区分缺失 |
| 排序未知组 | 拆 3 组 | 合并 1 组 | 合并 1 组 | **B/C**：`zero < partial < complete < {overQuota, quotaUnknown, unknown}` |
| mismatch 判定门槛 | `membersIncomplete` 单 case | 完整才判、部分未知独立诊断 | 同 B | **A/B 融合**：数据不完整 → `membersIncomplete`；星数缺失 → 不判 stars mismatch |
| 配额溢出 | 饱和值 + `saturated` | 同 A | nil + 诊断 | **A/B**：饱和算术（项目惯例） |
| 文案定稿 | 不产出文案 | 不产出文案 | 定稿在 Core | **A/B**：投影只产结构化状态，文案属 UI 层 |
| 诊断数量 | 3 种 | 12 种 | 带 message | **A**：只保留 issue 要求的官方 vs 成员推导诊断 |
| 入口形态 | 函数式多入口 | 同 A | `project(endpoint:)` 单一入口 | **A/B**：snapshot → 内容投影 + state → 刷新投影 |

## 类型契约（完整声明）

新文件：`Sources/COCHelperCore/ClanWarDisplayProjection.swift`（全部 `Hashable & Sendable`，不实现 Codable）

```swift
/// 战争阶段。unknown 保留原始 state 字符串（nil = 字段缺失），不静默归入已知阶段。
public enum ClanWarPhase: Hashable, Sendable {
    case notInWar
    case preparation
    case inWar
    case warEnded
    case unknown(raw: String?)
}

/// 攻击配额事实。totalAttacks 在任一字段缺失或任一值 <= 0 时为 nil（不伪造）；
/// 乘法饱和溢出时 saturated == true，饱和值仅是可表示上界，不得作权威展示。
public struct ClanWarQuota: Hashable, Sendable {
    public let teamSize: Int?
    public let attacksPerMember: Int?
    public let totalAttacks: Int?
    public let saturated: Bool
    public init(teamSize: Int?, attacksPerMember: Int?, totalAttacks: Int?, saturated: Bool)
}

/// 成员攻击行动状态——纯数据事实，不含战争阶段。
/// attacks == nil → .unknown（不得显示"未攻击"）
/// attacks == [] → .zero（明确 0 次，配额无关）
/// 0 < count < 有效配额 → .partial
/// count == 有效配额 → .complete
/// count > 有效配额 → .overQuota（异常数据，不伪造完成）
/// 配额缺失/无效（nil 或 <= 0）且 count > 0 → .quotaUnknown
public enum ClanWarMemberAttackStatus: Hashable, Sendable {
    case unknown, zero, partial, complete, overQuota, quotaUnknown
}

public struct ClanWarMemberAction: Hashable, Sendable {
    public let status: ClanWarMemberAttackStatus
    /// 仅 .unknown 时为 nil，其余恒非 nil。
    public let attackCount: Int?
    /// 仅 .partial 时非 nil 且 >= 1。
    public let remainingAttacks: Int?
    public init(status: ClanWarMemberAttackStatus, attackCount: Int?, remainingAttacks: Int?)
}

/// 成员星数事实：已知星数之和 + 星数缺失的攻击数。缺失不计入 knownStars（0 只代表"已知且全 0"）。
public struct ClanWarMemberStars: Hashable, Sendable {
    public let knownStars: Int
    public let missingCount: Int
    public init(knownStars: Int, missingCount: Int)
}

/// 行动队列成员行。sourceIndex = 官方数组原始下标：排序最终平局键 + 稳定 id
/// （成员全 optional，两个全 nil 成员会撞 \.self）。
public struct ClanWarMemberRow: Hashable, Sendable, Identifiable {
    public let sourceIndex: Int
    public let mapPosition: Int?
    public let name: String?
    public let tag: String?
    public let townhallLevel: Int?
    public let action: ClanWarMemberAction
    /// nil = attacks == nil（攻击数据未返回）；[] = 明确 0 次攻击。
    public let stars: ClanWarMemberStars?
    /// 逐次攻击明细（复用 ClanWarAttackLine，摧毁率逐次保留永不聚合）；与 stars 同步 nil。
    public let lines: [ClanWarAttackLine]?
    public var id: Int { sourceIndex }
    public init(...)
}

/// 六桶计数。Σ 六桶 == rows.count；.unknown 独立成桶，不计入"未出手"。
public struct ClanWarActionCounts: Hashable, Sendable {
    public let unknownCount: Int
    public let zeroCount: Int
    public let partialCount: Int
    public let completeCount: Int
    public let overQuotaCount: Int
    public let quotaUnknownCount: Int
    public init(...)
}

/// 展示分组：阶段 × 行动事实的唯一组合点。preparation + .zero → .awaitingWar（"等待开战"）。
public enum ClanWarMemberDisplayGroup: Hashable, Sendable {
    case awaitingWar, notAttacked, remaining, complete, overQuota, quotaUnknown, unknown
}

/// 官方摘要（顶部比分唯一来源，原样透传含 nil，绝不来自成员推导）。
public struct ClanWarParticipantSummary: Hashable, Sendable {
    public let attacks: Int?
    public let stars: Int?
    public let destructionPercentage: Double?
    public init(...)
}

/// 官方摘要与成员推导不一致诊断（保留两套事实）。
/// 仅当官方字段存在且成员侧数据完整（无 attacks == nil）时才判数值差异。
public enum ClanWarSummaryMismatch: Hashable, Sendable {
    /// 存在成员 attacks == nil，推导不可得。
    case membersIncomplete
    /// 官方 attacks ≠ Σ 成员攻击数。
    case attackCount(official: Int, memberSum: Int)
    /// 官方 stars ≠ Σ 成员已知星数（全部攻击行星数已知时判定）。
    case stars(official: Int, memberKnownSum: Int)
}

public struct ClanWarParticipantProjection: Hashable, Sendable {
    public let tag: String?
    public let name: String?
    public let clanLevel: Int?
    /// 官方摘要：顶部比分唯一来源。
    public let official: ClanWarParticipantSummary
    /// 行动队列（已排序）；nil = 官方未返回成员数组（与 [] 区分）。
    public let members: [ClanWarMemberRow]?
    /// 攻击数据已知成员数；nil = 成员数组未返回。
    public let knownAttackDataCount: Int?
    /// 攻击数据未知成员数；nil = 成员数组未返回。
    public let unknownAttackDataCount: Int?
    public let mismatches: [ClanWarSummaryMismatch]
    public init(...)
}

/// 顶层投影。phase == .notInWar 时 clan/opponent 恒为 nil（成功空状态，不生成成员列表）。
public struct ClanWarProjection: Hashable, Sendable {
    public let phase: ClanWarPhase
    public let quota: ClanWarQuota
    public let clan: ClanWarParticipantProjection?
    public let opponent: ClanWarParticipantProjection?
    public init(...)
}

/// 刷新状态（与战争阶段完全解耦，第三条维度）。
public enum ClanWarRefreshStatus: Hashable, Sendable {
    case never, loading, success, stale, failedWithLastGood, failedWithoutLastGood, skipped
}
```

## 投影入口（enum ClanWarDisplayProjection，纯函数命名空间）

```swift
public enum ClanWarDisplayProjection {
    public static func project(_ snapshot: OfficialClanWarSnapshot) -> ClanWarProjection
    public static func phase(of state: String?) -> ClanWarPhase
    public static func quota(teamSize: Int?, attacksPerMember: Int?) -> ClanWarQuota
    public static func memberAction(attacks: [ClanWarAttack]?, attacksPerMember: Int?) -> ClanWarMemberAction
    public static func memberStars(_ member: ClanWarMember) -> ClanWarMemberStars?
    public static func sortedRows(_ members: [ClanWarMember], attacksPerMember: Int?) -> [ClanWarMemberRow]
    public static func actionCounts(_ rows: [ClanWarMemberRow]) -> ClanWarActionCounts
    public static func displayGroup(phase: ClanWarPhase, action: ClanWarMemberAction) -> ClanWarMemberDisplayGroup
    public static func participant(_ participant: ClanWarParticipant, attacksPerMember: Int?) -> ClanWarParticipantProjection
    public static func mismatches(participant: ClanWarParticipant, rows: [ClanWarMemberRow]) -> [ClanWarSummaryMismatch]
    public static func refreshStatus(of state: ClanWarAPIState) -> ClanWarRefreshStatus
}
```

## 语义映射规则（实现必须遵守）

1. **phase**：trim 后精确匹配 notInWar/preparation/inWar/warEnded；其余（含空串、缺失）→ `.unknown(raw:)`，raw 为原始值。
2. **quota**：有效配额 = `attacksPerMember != nil && > 0`；`totalAttacks = teamSize × attacksPerMember` 用 `SaturatingArithmetic`（或 `multipliedReportingOverflow`），溢出 → 饱和值 + `saturated = true`；任一输入 nil 或 <= 0 → `totalAttacks = nil`。
3. **memberAction**：`attacks == nil` → `.unknown`；`attacks == []` → `.zero`（无条件，配额无关）；配额有效时按 count 与 quota 比较 → partial/complete/overQuota；配额无效且 count > 0 → `.quotaUnknown`。`remainingAttacks = quota - count`（仅 partial，恒 >= 1，无溢出可能）。
4. **memberStars**：`attacks == nil` → nil；否则 `knownStars = Σ 非 nil stars`（负数/超大星数 clamp 到 [0,3] 再计入，与 UI 现有 `min(max($0,0),3)` 一致），`missingCount = 攻击条数中 stars == nil 的条数`。**守恒断言 `knownStars + missingCount == attacks.count` 仅在官方契约值域 [0,3] 内成立**——schema 违反输入经 clamp 后和可能不等于 attack count（可小于或大于，fail-closed 预期，不伪装总和）。
5. **排序**：rank = zero(0) < partial(1) < complete(2) < {overQuota, quotaUnknown, unknown}(3)；组内 mapPosition（nil 排最后）→ name（nil 排最后，String 比较序，即 Unicode 规范化后比较）→ sourceIndex 升序。全序，与 sort 稳定性无关，幂等。
6. **actionCounts**：六桶按 status 计数，Σ == rows.count。
7. **displayGroup**：`preparation + .zero` → `.awaitingWar`；其余 status → 同名 case（.unknown/.zero → notAttacked 的映射仅当非 preparation）。具体：zero → (preparation ? awaitingWar : notAttacked)；partial → remaining；complete → complete；overQuota → overQuota；quotaUnknown → quotaUnknown；unknown → unknown。
8. **participant**：`official` 透传 participant 三字段；`members == nil` → members/knownAttackDataCount/unknownAttackDataCount 全 nil；否则排序输出 + 计数（known = attacks != nil 计数，unknown = attacks == nil 计数）；`mismatches` 见规则 9。
9. **mismatches**：任一成员 `attacks == nil` → `[.membersIncomplete]`（官方摘要缺失时仍上报——成员不完整是独立可审计事实；其余数值差异不判）；否则若官方 attacks 存在且 ≠ Σ 成员攻击数 → `.attackCount(official:memberSum:)`；若官方 stars 存在、全部攻击行 stars 已知（无缺失）且 ≠ Σ 成员**原始**星数（事实层求和，不使用展示层 clamp 值）→ `.stars(official:memberKnownSum:)`；空数组 = 一致。
10. **refreshStatus**：复用 `state.displayStatus`（stale 判定同一映射点，不重复实现）；`status == .failed` 时按 `lastGood != nil` 分 `failedWithLastGood` / `failedWithoutLastGood`；never/loading/success/stale/skipped 一一映射。
11. **notInWar**：`clan`/`opponent` 恒 nil，即使原始响应意外携带成员数据。

## 测试要求（TDD，先写测试验证 RED）

新文件：`Tests/COCHelperCoreTests/ClanWarDisplayProjectionTests.swift`

单元测试覆盖：
- phase 5 态 + 未知字符串（含空白串）+ 缺失（nil）
- 配额：正常乘法、缺失任一、0/负数、Int.max 溢出（saturated）、负数 teamSize
- memberAction 全组合：nil / [] / partial / complete / overQuota / quotaUnknown（配额 nil、配额 0、配额负数）
- memberStars：全已知、部分缺失、全缺失、attacks nil → nil、负数星数
- 排序：四组顺序、组内 mapPosition/name/sourceIndex 三级 tie-break、nil 排后、幂等
- actionCounts 六桶守恒
- displayGroup：preparation+zero → awaitingWar；inWar+zero → notAttacked；其余映射
- participant：nil vs [] 区分、计数、mismatches
- mismatches：一致 → 空；官方缺失 → 空；成员不完整 → membersIncomplete；attacks 差异；stars 差异（含星数缺失时不判）
- notInWar → clan/opponent nil
- refreshStatus：从 ClanWarAPIState 构造各状态（success/stale/failed±lastGood/never/loading/skipped）
- 摧毁率逐次保留（复用 ClanWarAttackLine 契约，property 测试断言双向保真）

Property-based（SeededGenerator + 500 迭代，模式同 ClanCombatSummaryPropertyTests）：
- 随机成员数组 → 排序幂等（两次投影结果相等）
- Σ 六桶 == rows.count
- knownAttackDataCount + unknownAttackDataCount == members.count（members 非 nil 时）
- 摧毁率有值集合 == 输入有值集合（无聚合无篡改）
- 所有随机输入不崩溃（含负数、异常大值、全 nil 成员）

## 非目标

- 不重做 `ClanWarCardView` 布局（UI 消费切换放后续 PR）
- 不产出中文文案（结构化状态即交付物）
- 不改动 `ClanWarMemberSummary` / `ClanCombatSummary` / raw 模型 / parserVersion
- 不建模时间解析、battleModifier、warlog、胜负判定、成员行截断
- 不提供备选排序

## 验收标准

- raw `OfficialClanWarSnapshot` Codable 字段与旧缓存字节格式不变
- `currentParserVersion`（clan-war-0.3）不 bump
- 投影不依赖 SwiftUI，全部被 Core 测试直接验证
- 全量 `swift test` 通过（现有 1029 + 新增全部绿）
