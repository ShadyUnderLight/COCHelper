import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情页的当前部落对战卡片（**按需刷新**：用户点击按钮才请求 currentwar）。
///
/// 状态语义（Issue #7 stage 3b）：
/// - `notInWar` 是**成功**响应 → 显示"当前没有进行中的部落对战"空状态（不是失败）
/// - `preparation` / `inWar` → 双方摘要比分（攻击/星/摧毁%）
/// - `warEnded` → 部落对战已结束 + 结果
/// - 失败保留 last-good；成员级攻击表以展开组展示（默认折叠，上限 30 行）
struct ClanWarCardView: View {
    @EnvironmentObject private var model: AppModel
    /// 本卡片数据来源的村庄（显式路由，不得读全局选中村庄）。
    /// 手动部落入口传 nil，并直接注入 `clanTag`。
    let villageID: UUID?
    /// 手动部落入口注入的部落 tag（村庄入口为 nil）。
    let injectedClanTag: String?

    init(villageID: UUID? = nil, clanTag: String? = nil) {
        self.villageID = villageID
        self.injectedClanTag = clanTag
    }

    /// 手动入口直接使用注入 tag；村庄入口从玩家快照派生。
    private var isManualEntry: Bool { injectedClanTag != nil }

    /// 本卡片部落归属 tag（nil = 无部落 / 从未成功抓取）。
    private var clanTag: String? {
        injectedClanTag ?? villageID.flatMap { model.officialClanTag(for: $0) }
    }

    /// 本卡片村庄所属部落的当前战争共享状态（nil = 无部落 / 从未请求）。
    private var clanWarState: ClanWarAPIState? {
        guard let clanTag else { return nil }
        return model.clanWarState(for: clanTag)
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                header
                statusContent
            }
        }
    }

    private var header: some View {
        HStack {
            Label("当前部落对战", systemImage: "cross.case.fill")
                .font(.headline)
            Spacer()
            if let label = ClanDisplayFormat.sourceLabel(clanWarState?.sourceLabel) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.cocAccent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.cocAccent)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        let statusUnknown = villageID.map { model.clanStatusUnknown(for: $0) } ?? false
        if !isManualEntry, statusUnknown {
            Label("刷新官方玩家数据后可查看当前部落对战", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !isManualEntry, clanTag == nil {
            Label("不在部落中，没有部落对战数据", systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let state = clanWarState, let clanTag {
            statusLine(state)
            if let snapshot = state.lastGood {
                warSummary(snapshot)
                if !state.unrecognizedKeys.isEmpty {
                    Text("官方响应包含未识别字段：" + state.unrecognizedKeys.joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            refreshButton(title: "刷新部落对战状态", tag: clanTag)
        } else if let clanTag {
            // 从未请求过：按需懒加载入口
            VStack(alignment: .leading, spacing: 8) {
                Label("尚未获取当前部落对战", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                refreshButton(title: "查看当前部落对战", tag: clanTag)
            }
        }
    }

    private func refreshButton(title: String, tag: String) -> some View {
        HStack {
            Button {
                model.refreshClanWar(tag: tag)
            } label: {
                if model.isRefreshingClanWar(clanTag: clanTag) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(title, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.cocAccent)
            .disabled(model.isRefreshingClanWarData || model.isRefreshingClanWar(clanTag: clanTag))
            Spacer()
        }
    }

    @ViewBuilder
    private func statusLine(_ state: ClanWarAPIState) -> some View {
        switch state.displayStatus {
        case .success:
            if let fetchedAt = state.fetchedAt {
                Label("已获取 · \(fetchedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        case .stale:
            if let fetchedAt = state.fetchedAt {
                Label("数据已过期（上次获取 \(fetchedAt.formatted(date: .abbreviated, time: .shortened))）", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label("获取失败", systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                if let reason = state.lastErrorReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let fetchedAt = state.fetchedAt {
                    Text("保留上次成功数据（\(fetchedAt.formatted(date: .abbreviated, time: .shortened))）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .never, .loading, .skipped:
            EmptyView()
        }
    }

    @ViewBuilder
    private func warSummary(_ snapshot: OfficialClanWarSnapshot) -> some View {
        switch snapshot.state {
        case "notInWar":
            // 成功空状态：无部落对战不是失败
            Label("当前没有进行中的部落对战", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.green)
        case "preparation":
            stateBadge("备战中", color: .orange)
            scoreRow(snapshot)
        case "inWar":
            stateBadge("部落对战进行中", color: .red)
            scoreRow(snapshot)
        case "warEnded":
            stateBadge("部落对战已结束", color: .secondary)
            scoreRow(snapshot)
        default:
            Label("未知部落对战状态", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func stateBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func scoreRow(_ snapshot: OfficialClanWarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let teamSize = snapshot.teamSize {
                Text("对战规模：\(teamSize) 人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let clan = snapshot.clan {
                participantRow(
                    name: clan.name,
                    tag: clan.tag,
                    level: clan.clanLevel,
                    attacks: clan.attacks,
                    stars: clan.stars,
                    destruction: clan.destructionPercentage,
                    isClan: true
                )
                memberDisclosure(title: "成员进攻记录（\(clan.members?.count ?? 0) 人）", members: clan.members ?? [])
            }
            if let opponent = snapshot.opponent {
                participantRow(
                    name: opponent.name,
                    tag: opponent.tag,
                    level: opponent.clanLevel,
                    attacks: opponent.attacks,
                    stars: opponent.stars,
                    destruction: opponent.destructionPercentage,
                    isClan: false
                )
                memberDisclosure(title: "对方成员进攻记录（\(opponent.members?.count ?? 0) 人）", members: opponent.members ?? [])
            }
            if snapshot.clan == nil && snapshot.opponent == nil {
                Text("部落对战详情字段缺失（可能刚结束或数据不完整）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let start = snapshot.startTime ?? snapshot.warStartTime {
                Text("开始：\(start)（官方时间）")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            if let end = snapshot.endTime {
                Text("结束：\(end)（官方时间）")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func participantRow(
        name: String?, tag: String?, level: Int?,
        attacks: Int?, stars: Int?, destruction: Double?, isClan: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isClan ? "shield.fill" : "shield.lefthalf.filled.slash")
                .foregroundStyle(isClan ? Color.cocAccent : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name ?? (isClan ? "我方" : "对方"))
                        .font(.subheadline.weight(.semibold))
                    if let level {
                        Text("\(level)级大本营")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let tag {
                        Text(tag)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let stars {
                    Text("⭐ \(stars) 星" + (attacks.map { " · \($0) 次攻击" } ?? "")
                        + (destruction.map { " · 摧毁率 \($0)%" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// 成员攻击表展开组（默认折叠；上限 30 行，超出提示）。
    @ViewBuilder
    private func memberDisclosure(title: String, members: [ClanWarMember]) -> some View {
        if !members.isEmpty {
            DisclosureGroup(title) {
                VStack(alignment: .leading, spacing: 2) {
                    // id: \.offset：成员全 optional，两个相同对象（如全 nil）会撞 \.self
                    ForEach(Array(members.prefix(30).enumerated()), id: \.offset) { _, member in
                        memberRow(member)
                    }
                    if members.count > 30 {
                        Text("还有 \(members.count - 30) 名成员…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func memberRow(_ member: ClanWarMember) -> some View {
        if let attacks = member.attacks, !attacks.isEmpty {
            let summary = ClanCombatSummary.warMember(attacks: attacks)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, line in
                        attackLineRow(line)
                    }
                }
                .padding(.vertical, 2)
            } label: {
                memberLabel(member, summaryText: "\(summary.attackCount)次进攻 · ⭐\(summary.totalStars)")
            }
            .font(.caption)
        } else {
            memberLabel(member, summaryText: member.attacks != nil ? "未攻击" : "—")
        }
    }

    /// 成员行标签（旧布局，仅汇总文案参数化）。
    private func memberLabel(_ member: ClanWarMember, summaryText: String) -> some View {
        HStack(spacing: 8) {
            if let position = member.mapPosition {
                Text("\(position)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
            }
            Text(member.name ?? "未知成员")
                .font(.caption)
                .lineLimit(1)
            if let th = member.townhallLevel {
                Text("\(th)级大本营")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(summaryText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    /// 逐次攻击明细行：`1. ⭐⭐⭐ 摧毁率 100%`；缺失摧毁率显示"摧毁率未知"。
    private func attackLineRow(_ line: ClanWarAttackLine) -> some View {
        HStack(spacing: 8) {
            Text(line.order.map { "\($0)." } ?? "?")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)
            // 星数钳制到 [0,3]：官方契约虽为 0...3，但 schema 外输入不可信，
            // String(repeating:count:) 对负 count 会触发 fatal error "Negative count not allowed"
            Text(line.stars.map { String(repeating: "⭐", count: min(max($0, 0), 3)) } ?? "—")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(line.destructionPercentage.map { "摧毁率 \(Self.percent(ClanCombatSummary.clampedPercent($0)))%" } ?? "摧毁率未知")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private static func percent(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value)) : String(format: "%.1f", value)
    }
}
