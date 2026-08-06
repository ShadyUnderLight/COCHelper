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

    /// 本卡片村庄所属部落的共享状态（nil = 无部落 / 从未请求）。
    private var clanState: ClanAPIState? {
        guard let clanTag else { return nil }
        return model.clanState(for: clanTag)
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
        if let label = clanState?.sourceLabel {
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
        let statusUnknown = villageID.map { model.clanStatusUnknown(for: $0) } ?? false
        if !isManualEntry, statusUnknown {
            // 从未成功抓取玩家数据：归属是"未知"，不是"不在部落中"。
            unknownClanState
        } else if !isManualEntry, clanTag == nil {
            // 最近成功玩家快照确认无部落（clan 缺失/无效）。
            noClanState
        } else if let state = clanState, let clanTag {
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
                    model.refreshClan(tag: clanTag)
                } label: {
                    if model.isRefreshingClan(clanTag: clanTag) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("刷新部落数据", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
                .disabled(model.isRefreshingClanData || model.isRefreshingClan(clanTag: clanTag))
                Spacer()
            }
        } else if let clanTag {
            // 有部落 tag 但从未请求过部落数据：提示可刷新
            VStack(alignment: .leading, spacing: 8) {
                Label("尚未获取部落数据", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        model.refreshClan(tag: clanTag)
                    } label: {
                        if model.isRefreshingClan(clanTag: clanTag) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("刷新部落数据", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
                    .disabled(model.isRefreshingClanData || model.isRefreshingClan(clanTag: clanTag))
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
                if let badgeURL = ClanDisplayFormat.badgeURL(snapshot) {
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
                    metric("类型", snapshot.type.map(ClanDisplayFormat.typeLabel))
                }
                GridRow {
                    metric("战争胜利", snapshot.warWins.map { "\($0)" })
                    metric("胜-平-负", ClanDisplayFormat.warRecordLabel(snapshot))
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
