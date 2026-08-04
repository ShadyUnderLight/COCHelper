import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情页的部落资本赛季卡片（分页，按需刷新）。
///
/// 展示赛季摘要（战利品/奖励/攻击统计）；成员级 attackLog/defenseLog
/// deferred。分页语义与战争日志一致（累计页 + 游标 + 防无限）。
struct CapitalRaidCardView: View {
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
            Label("部落资本赛季", systemImage: "building.columns.fill")
                .font(.headline)
            Spacer()
            if let label = model.currentCapitalState?.sourceLabel {
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
            Label("刷新官方玩家数据后可查看部落资本", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if model.currentVillageClanTag == nil {
            Label("不在部落中，没有资本数据", systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let state = model.currentCapitalState {
            statusLine(state)
            if let page = state.lastGood {
                seasonList(page)
                if model.currentCapitalHasMore {
                    loadMoreButton("加载更多赛季")
                }
            } else {
                refreshButton("查看资本赛季")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("尚未获取资本赛季", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                refreshButton("查看资本赛季")
            }
        }
    }

    private func refreshButton(_ title: String) -> some View {
        HStack {
            Button {
                model.refreshCurrentCapitalRaid()
            } label: {
                if model.isRefreshingCapitalData {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.cocAccent)
            .disabled(model.isRefreshingCapitalData)
            Spacer()
        }
    }

    private func loadMoreButton(_ title: String) -> some View {
        HStack {
            Button {
                model.loadMoreCurrentCapitalRaid()
            } label: {
                if model.isRefreshingCapitalData {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: "ellipsis.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshingCapitalData)
            Spacer()
        }
    }

    @ViewBuilder
    private func statusLine(_ state: ClanCapitalAPIState) -> some View {
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

    private func seasonList(_ page: OfficialPaginatedPage<OfficialCapitalRaidSeason>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if page.items.isEmpty {
                Text("没有资本赛季记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(page.items.enumerated()), id: \.offset) { _, season in
                    seasonRow(season)
                    if season.endTime != page.items.last?.endTime {
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
    }

    private func seasonRow(_ season: OfficialCapitalRaidSeason) -> some View {
        HStack(spacing: 10) {
            Image(systemName: season.state == "ongoing" ? "play.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(season.state == "ongoing" ? .orange : .green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if let start = season.startTime, let end = season.endTime {
                    Text("\(start) ~ \(end)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    if let totalLooted = season.totalLooted {
                        Text("战利品 " + Self.formatted(totalLooted))
                            .font(.subheadline.weight(.semibold))
                    }
                    if let offensive = season.offensiveReward {
                        Text("进攻奖励 \(Self.formatted(offensive))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let clan = season.clan {
                        if let attacks = clan.attackCount {
                            Text("\(attacks) 次攻击")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let districts = clan.destroyedDistricts {
                            Text("\(districts) 个区域")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private static func formatted(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
