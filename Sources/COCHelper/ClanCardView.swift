import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情页的部落摘要卡片。
///
/// 数据来自**共享数据层**（`AppModel.clanStates`，clan tag → 状态）：
/// 同一部落的多个村庄看到同一份数据与来源，不复制到村庄档案。
/// 来源标签：`official-api`（最近成功）/ `cached-official-api`（失败但保留
/// last-good）/ no-clan 空状态（玩家不在部落中）。
struct ClanCardView: View {
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
            Label("部落数据", systemImage: "shield.lefthalf.filled")
                .font(.headline)
            Spacer()
            sourceBadge
        }
    }

    /// 来源标签：基于**部落状态本身**（`sourceLabel`），而非玩家状态。
    /// - success / stale → official-api
    /// - failed 且保留 last-good → cached-official-api
    /// - 部落数据从未获取 / no-clan / 首次失败无 last-good → 隐藏
    @ViewBuilder
    private var sourceBadge: some View {
        if let label = model.currentClanState?.sourceLabel {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.cocAccent.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.cocAccent)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if model.currentVillageClanStatusUnknown {
            // 从未成功抓取玩家数据：归属是"未知"，不是"不在部落中"。
            unknownClanState
        } else if model.currentVillageClanTag == nil {
            // 最近成功玩家快照确认无部落（clan 缺失/无效）。
            noClanState
        } else if let state = model.currentClanState {
            statusLine(state)
            if let snapshot = state.lastGood {
                clanSummary(state: state, snapshot: snapshot)
                if !state.unrecognizedKeys.isEmpty {
                    Text("官方响应包含未识别字段：" + state.unrecognizedKeys.joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    model.refreshCurrentClan()
                } label: {
                    if model.isRefreshingClanData {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("刷新部落数据", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
                .disabled(model.isRefreshingClanData)
                Spacer()
            }
        } else {
            // 有部落 tag 但从未请求过部落数据：提示可刷新
            VStack(alignment: .leading, spacing: 8) {
                Label("尚未获取部落数据", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        model.refreshCurrentClan()
                    } label: {
                        Label("刷新部落数据", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
                    .disabled(model.isRefreshingClanData)
                    Spacer()
                }
            }
        }
    }

    /// 归属未知：玩家数据尚未成功抓取，不能断言"不在部落中"。
    private var unknownClanState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("尚未获取玩家数据，无法确认部落归属", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("先刷新官方玩家数据即可显示部落信息。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// no-clan 明确空状态：玩家不在部落中（不是失败，不是空历史）。
    private var noClanState: some View {
        Label("该玩家当前不在部落中", systemImage: "person.crop.circle.badge.questionmark")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func statusLine(_ state: ClanAPIState) -> some View {
        switch state.displayStatus {
        case .never:
            EmptyView() // 由 statusContent 的 else 分支处理
        case .loading:
            Label("正在获取部落数据…", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
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
        case .skipped:
            Label(state.lastErrorReason ?? "已跳过", systemImage: "arrow.uturn.backward.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func clanSummary(state: ClanAPIState, snapshot: OfficialClanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let badgeURL = badgeURL(snapshot) {
                    AsyncImage(url: badgeURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 34, height: 34)
                }
                Text(snapshot.name ?? "（无名部落）")
                    .font(.title3.weight(.semibold))
                if let tag = snapshot.tag {
                    Text(tag)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    metric("等级", snapshot.clanLevel.map { "\($0)" })
                    metric("成员数", snapshot.members.map { "\($0)" })
                    metric("类型", snapshot.type.map(typeLabel))
                }
                GridRow {
                    metric("战争胜利", snapshot.warWins.map { "\($0)" })
                    metric("胜-平-负", warRecordLabel(snapshot))
                    metric("连胜", snapshot.warWinStreak.map { "\($0)" })
                }
                GridRow {
                    metric("战争日志", snapshot.isWarLogPublic.map { $0 ? "公开" : "不公开" })
                    metric("资本大厅", snapshot.clanCapital?.capitalHallLevel.map { "\($0) 级" })
                    metric("", nil)
                }
                if let requiredTrophies = snapshot.requiredTrophies, requiredTrophies > 0 {
                    GridRow {
                        metric("入会奖杯", "\(requiredTrophies)")
                        metric("", nil)
                        metric("", nil)
                    }
                }
            }
        }
    }

    /// 徽章 URL 安全：仅加载官方 https 图片域名，防止异常数据注入其他
    /// 协议/域名（AsyncImage 会跟随重定向，allowlist 是纵深防御）。
    private func badgeURL(_ snapshot: OfficialClanSnapshot) -> URL? {
        guard let string = snapshot.badgeUrls?["medium"] ?? snapshot.badgeUrls?["small"],
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              host == "clashofclans.com" || host.hasSuffix(".clashofclans.com") else {
            return nil
        }
        return url
    }

    private func typeLabel(_ raw: String) -> String {
        switch raw {
        case "open": "开放"
        case "inviteOnly": "仅邀请"
        case "closed": "关闭"
        default: raw
        }
    }

    private func warRecordLabel(_ snapshot: OfficialClanSnapshot) -> String? {
        switch (snapshot.warWins, snapshot.warLosses, snapshot.warTies) {
        case let (wins?, losses?, ties?):
            return "\(wins)-\(losses)-\(ties)"
        case let (wins?, losses?, _):
            return "\(wins)-\(losses)"
        default:
            return nil
        }
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.callout.weight(.medium))
        }
    }
}
