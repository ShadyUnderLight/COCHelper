import SwiftUI
import COCHelperCore
import COCHelperApp

/// 部落对战双方比分卡（Issue #126）。
/// 只消费官方 participant 汇总（`row.official`），绝不从成员明细推导比分。
struct ClanWarScoreCardView: View {
    /// 参与方标签（"我方"），名称缺失时的兜底文案。
    let label: String
    /// 参与方投影（tag/name/clanLevel/official 摘要）。
    let row: ClanWarParticipantProjection
    /// 对方参与方标签（"对方"），名称缺失时的兜底文案。
    let opponentLabel: String
    /// 对方参与方投影（tag/name/clanLevel/official 摘要）。
    let opponentRow: ClanWarParticipantProjection
    /// 攻击配额事实（teamSize × attacksPerMember）。
    let quota: ClanWarQuota

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                // 自适应：宽窗口左右并排两卡，窄窗口上下堆叠。
                // ViewThatFits 取第一个水平放得下的候选（HStack 优先）。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        clanCard
                        opponentCard
                    }
                    VStack(spacing: 12) {
                        clanCard
                        opponentCard
                    }
                }
                scoreDifference
            }
        }
    }

    /// 我方卡（HStack 与 VStack 候选共用同一份内容，避免重复代码）。
    private var clanCard: some View {
        ScoreCard(label: label, row: row, quota: quota)
    }

    /// 对方卡（HStack 与 VStack 候选共用同一份内容，避免重复代码）。
    private var opponentCard: some View {
        ScoreCard(label: opponentLabel, row: opponentRow, quota: quota)
    }

    /// 星数差/摧毁率差单行：仅当双方官方 stars 与 destructionPercentage
    /// 双侧都存在时计算 `abs` 差；任一缺失 → 不渲染差值行。
    @ViewBuilder
    private var scoreDifference: some View {
        if let stars = row.official.stars,
           let opponentStars = opponentRow.official.stars,
           let destruction = row.official.destructionPercentage.flatMap(ClanCombatSummary.displayDestructionPercent),
           let opponentDestruction = opponentRow.official.destructionPercentage.flatMap(ClanCombatSummary.displayDestructionPercent) {
            Text("星数差 \(Self.absoluteDifference(stars, opponentStars)) · 摧毁率差 \(ClanDisplayFormat.percent(abs(destruction - opponentDestruction)))%")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    /// 两个 Int 的绝对差，防御 schema 外输入：`hi - lo` 在极端值下可上溢，
    /// 溢出时饱和到 Int.max（与 Core 的 fail-closed 风格一致，不崩溃）。
    private static func absoluteDifference(_ lhs: Int, _ rhs: Int) -> Int {
        let lo = min(lhs, rhs)
        let hi = max(lhs, rhs)
        let (result, overflowed) = hi.subtractingReportingOverflow(lo)
        return overflowed ? Int.max : result
    }
}

/// 单方比分卡（label/row/quota 由外部注入）。
/// internal（非 private）：主视图 `ClanWarCardView.singleScoreCard` 复用，
/// 单方缺失降级路径与双卡组件共用同一布局（Issue #126 评审 M5）。
struct ScoreCard: View {
    /// 参与方标签，名称缺失时的兜底文案。
    let label: String
    /// 参与方投影（tag/name/clanLevel/official 摘要）。
    let row: ClanWarParticipantProjection
    /// 攻击配额事实（teamSize × attacksPerMember）。
    let quota: ClanWarQuota

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.name ?? label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let levelLabel = ClanDisplayFormat.clanLevelLabel(row.clanLevel) {
                Text(levelLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let stars = row.official.stars {
                // 星数固定为 "⭐ N 星" 文本，不按星数重复 emoji。
                Text("⭐ \(stars) 星")
                    .font(.callout.weight(.semibold))
            }
            if let destruction = row.official.destructionPercentage.flatMap(ClanCombatSummary.displayDestructionPercent) {
                Text("摧毁率 \(ClanDisplayFormat.percent(destruction))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            attackProgress
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cocPanel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    /// 攻击进度：配额有效（未饱和）且官方攻击数均已知 → "已用攻击 X / Y"；
    /// 饱和时 `totalAttacks` 只是可表示上界（非权威业务数据），不得伪造总配额，
    /// 与配额缺失/无效同样显示 "攻击配额未知"。
    private var attackProgress: some View {
        Group {
            if let total = quota.totalAttacks, let attacks = row.official.attacks, !quota.saturated {
                Text("已用攻击 \(attacks) / \(total)")
            } else {
                Text("攻击配额未知")
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
    }
}
