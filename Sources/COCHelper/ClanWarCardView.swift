import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情页的当前战争卡片（**按需刷新**：用户点击按钮才请求 currentwar）。
///
/// 状态语义（Issue #7 stage 3b）：
/// - `notInWar` 是**成功**响应 → 显示"当前没有进行中的战争"空状态（不是失败）
/// - `preparation` / `inWar` → 双方摘要比分（攻击/星/摧毁%）
/// - `warEnded` → 战争已结束 + 结果
/// - 失败保留 last-good；成员级攻击表以展开组展示（默认折叠，上限 30 行）
struct ClanWarCardView: View {
    @EnvironmentObject private var model: AppModel

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
            Label("当前战争", systemImage: "cross.case.fill")
                .font(.headline)
            Spacer()
            if let label = model.currentClanWarState?.sourceLabel {
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
        if model.currentVillageClanStatusUnknown {
            Label("刷新官方玩家数据后可查看当前战争", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if model.currentVillageClanTag == nil {
            Label("不在部落中，没有战争数据", systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let state = model.currentClanWarState {
            statusLine(state)
            if let snapshot = state.lastGood {
                warSummary(snapshot)
                if !state.unrecognizedKeys.isEmpty {
                    Text("官方响应包含未识别字段：" + state.unrecognizedKeys.joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            refreshButton(title: "刷新战争状态")
        } else {
            // 从未请求过：按需懒加载入口
            VStack(alignment: .leading, spacing: 8) {
                Label("尚未获取当前战争", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                refreshButton(title: "查看当前战争")
            }
        }
    }

    private func refreshButton(title: String) -> some View {
        HStack {
            Button {
                model.refreshCurrentClanWar()
            } label: {
                if model.isRefreshingClanWarData {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(title, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.cocAccent)
            .disabled(model.isRefreshingClanWarData)
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
            // 成功空状态：无战争不是失败
            Label("当前没有进行中的战争", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.green)
        case "preparation":
            stateBadge("备战中", color: .orange)
            scoreRow(snapshot)
        case "inWar":
            stateBadge("战争中", color: .red)
            scoreRow(snapshot)
        case "warEnded":
            stateBadge("战争已结束", color: .secondary)
            scoreRow(snapshot)
        default:
            Label("未知战争状态", systemImage: "questionmark.circle")
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
                Text("队伍规模：\(teamSize) 人")
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
                memberDisclosure(title: "成员攻击表（\(clan.members?.count ?? 0) 人）", members: clan.members ?? [])
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
                memberDisclosure(title: "对方成员攻击表（\(opponent.members?.count ?? 0) 人）", members: opponent.members ?? [])
            }
            if snapshot.clan == nil && snapshot.opponent == nil {
                Text("战争详情字段缺失（可能刚结束或数据不完整）")
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
                        Text("Lv.\(level)")
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
                        + (destruction.map { " · 摧毁 \($0)%" } ?? ""))
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

    private func memberRow(_ member: ClanWarMember) -> some View {
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
                Text("TH\(th)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(attackSummary(member))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    /// 成员攻击表现摘要：N攻 · ⭐总星 · 摧毁总%（attacks 数组聚合；未攻击显示提示）。
    private func attackSummary(_ member: ClanWarMember) -> String {
        guard let attacks = member.attacks, !attacks.isEmpty else {
            return member.attacks != nil ? "未攻击" : "—"
        }
        let stars = attacks.reduce(0) { $0 + ($1.stars ?? 0) }
        let destruction = attacks.reduce(0.0) { $0 + ($1.destructionPercentage ?? 0) }
        return "\(attacks.count)攻 · ⭐\(stars) · 摧毁 \(Self.percent(destruction))%"
    }

    private static func percent(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value)) : String(format: "%.1f", value)
    }
}
