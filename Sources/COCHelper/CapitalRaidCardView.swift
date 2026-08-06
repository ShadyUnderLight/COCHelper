import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情页的部落资本赛季卡片（分页，按需刷新）。
///
/// 展示赛季摘要（战利品/奖励/攻击统计）；成员级 attackLog/defenseLog
/// deferred。分页语义与战争日志一致（累计页 + 游标 + 防无限）。
struct CapitalRaidCardView: View {
    @EnvironmentObject private var model: AppModel
    /// 本卡片数据来源的村庄（显式路由，不得读全局选中村庄）。
    let villageID: UUID

    /// 本卡片村庄的部落归属 tag（nil = 无部落 / 从未成功抓取）。
    private var clanTag: String? {
        model.officialClanTag(for: villageID)
    }

    /// 本卡片村庄所属部落的资本赛季状态（nil = 无部落 / 从未请求）。
    private var capitalState: ClanCapitalAPIState? {
        guard let clanTag else { return nil }
        return model.capitalState(for: clanTag)
    }

    /// 本卡片村庄所属部落的资本赛季是否还有更多页（分页按钮可用性）。
    private var hasMore: Bool {
        guard let clanTag else { return false }
        return model.capitalHasMore(for: clanTag)
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
            Label("部落资本赛季", systemImage: "building.columns.fill")
                .font(.headline)
            Spacer()
            if let label = capitalState?.sourceLabel {
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
        if model.clanStatusUnknown(for: villageID) {
            Label("刷新官方玩家数据后可查看部落资本", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if clanTag == nil {
            Label("不在部落中，没有资本数据", systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let state = capitalState {
            statusLine(state)
            if let page = state.lastGood {
                seasonList(page)
                if hasMore {
                    loadMoreButton("加载更多赛季")
                }
            }
            // 总是显示刷新按钮（对齐 3b 模式，防 failed/stale 死锁）。
            refreshButton("刷新资本赛季")
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
                model.refreshCapitalRaid(villageID: villageID)
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
                model.loadMoreCapitalRaid(villageID: villageID)
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

    private func seasonList(_ page: OfficialCapitalRaidPage) -> some View {
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

    @ViewBuilder
    private func seasonRow(_ season: OfficialCapitalRaidSeason) -> some View {
        let hasDetail = !(season.members ?? []).isEmpty
            || !(season.attackLog ?? []).isEmpty
            || !(season.defenseLog ?? []).isEmpty
        if hasDetail {
            DisclosureGroup {
                seasonDetail(season)
                    .padding(.vertical, 4)
            } label: {
                seasonSummary(season)
            }
            .font(.caption)
        } else {
            seasonSummary(season)
        }
    }

    private func seasonSummary(_ season: OfficialCapitalRaidSeason) -> some View {
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
                    if let loot = season.capitalTotalLoot {
                        Text("战利品 " + Self.formatted(loot))
                            .font(.subheadline.weight(.semibold))
                    }
                    if let offensive = season.offensiveReward {
                        Text("进攻奖励 \(Self.formatted(offensive))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let defensive = season.defensiveReward {
                        Text("防守奖励 \(Self.formatted(defensive))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let raids = season.raidsCompleted {
                        Text("\(raids) 次突袭")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let attacks = season.totalAttacks {
                        Text("\(attacks) 次攻击")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let districts = season.enemyDistrictsDestroyed {
                        Text("摧毁 \(districts) 区域")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func seasonDetail(_ season: OfficialCapitalRaidSeason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let members = season.members, !members.isEmpty {
                Text("成员贡献（\(members.count) 人）")
                    .font(.caption.weight(.semibold))
                ForEach(Array(members.prefix(30).enumerated()), id: \.offset) { _, member in
                    HStack {
                        Text(member.name ?? "未知成员").font(.caption).lineLimit(1)
                        Spacer()
                        Text([member.attacks.map { "\($0) 攻" },
                              member.capitalResourcesLooted.map { Self.formatted($0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if members.count > 30 {
                    Text("还有 \(members.count - 30) 名成员…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let log = season.attackLog, !log.isEmpty {
                Text("进攻日志（\(log.count) 条）").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(Array(log.prefix(30).enumerated()), id: \.offset) { _, entry in
                    raidLogRow(entry)
                }
                if log.count > 30 {
                    Text("还有 \(log.count - 30) 条…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let log = season.defenseLog, !log.isEmpty {
                Text("防守日志（\(log.count) 条）").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(Array(log.prefix(30).enumerated()), id: \.offset) { _, entry in
                    defenseLogRow(entry)
                }
                if log.count > 30 {
                    Text("还有 \(log.count - 30) 条…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func raidLogRow(_ entry: CapitalRaidAttackLogEntry) -> some View {
        HStack {
            Text("vs " + (entry.defender?.name ?? "未知部落"))
                .font(.caption).lineLimit(1)
            Spacer()
            Text([entry.attackCount.map { "\($0) 攻" },
                  entry.districtsDestroyed.map { "\($0) 区域" },
                  districtSummary(entry.districts)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func defenseLogRow(_ entry: CapitalRaidDefenseLogEntry) -> some View {
        HStack {
            Text("vs " + (entry.attacker?.name ?? "未知部落"))
                .font(.caption).lineLimit(1)
            Spacer()
            Text([entry.attackCount.map { "\($0) 攻" },
                  entry.districtsDestroyed.map { "\($0) 区域" },
                  districtSummary(entry.districts)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }

    /// 区域概要：摧毁 X% · 掠夺 Y（districts 聚合；官方无顶层 looted）。
    private func districtSummary(_ districts: [CapitalRaidDistrict]?) -> String? {
        guard let districts, !districts.isEmpty else { return nil }
        let destruction = districts.reduce(0.0) { $0 + ($1.destructionPercent ?? 0) }
        let loot = districts.reduce(0) { $0 + ($1.totalLooted ?? 0) }
        let parts = ["摧毁 \(Self.percent(destruction))%", Self.formatted(loot)]
        return parts.joined(separator: " · ")
    }

    private static func percent(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func formatted(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
