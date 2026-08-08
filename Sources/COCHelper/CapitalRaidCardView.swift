import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情页的部落都城突袭周末卡片（分页，按需刷新）。
///
/// 展示突袭周末摘要（都城金币/突袭奖章/攻击统计）；成员级 attackLog/defenseLog
/// deferred。分页语义与战争日志一致（累计页 + 游标 + 防无限）。
struct CapitalRaidCardView: View {
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

    /// 本卡片村庄所属部落的突袭周末状态（nil = 无部落 / 从未请求）。
    private var capitalState: ClanCapitalAPIState? {
        guard let clanTag else { return nil }
        return model.capitalState(for: clanTag)
    }

    /// 本卡片村庄所属部落的突袭周末是否还有更多页（分页按钮可用性）。
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
            Label("突袭周末", systemImage: "building.columns.fill")
                .font(.headline)
            Spacer()
            if let label = ClanDisplayFormat.sourceLabel(capitalState?.sourceLabel) {
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
            Label("刷新官方玩家数据后可查看部落都城", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !isManualEntry, clanTag == nil {
            Label("不在部落中，没有都城数据", systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let state = capitalState, let clanTag {
            statusLine(state)
            if let page = state.lastGood {
                seasonList(page)
                if hasMore {
                    loadMoreButton("加载更多突袭周末", tag: clanTag)
                }
            }
            // 总是显示刷新按钮（对齐 3b 模式，防 failed/stale 死锁）。
            refreshButton("刷新突袭周末", tag: clanTag)
        } else if let clanTag {
            VStack(alignment: .leading, spacing: 8) {
                Label("尚未获取突袭周末", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                refreshButton("查看突袭周末", tag: clanTag)
            }
        }
    }

    private func refreshButton(_ title: String, tag: String) -> some View {
        HStack {
            Button {
                model.refreshCapitalRaid(tag: tag)
            } label: {
                if model.isRefreshingCapital(clanTag: clanTag) {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.cocAccent)
            .disabled(model.isRefreshingCapitalData || model.isRefreshingCapital(clanTag: clanTag))
            Spacer()
        }
    }

    private func loadMoreButton(_ title: String, tag: String) -> some View {
        HStack {
            Button {
                model.loadMoreCapitalRaid(tag: tag)
            } label: {
                if model.isRefreshingCapital(clanTag: clanTag) {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: "ellipsis.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshingCapitalData || model.isRefreshingCapital(clanTag: clanTag))
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
                Text("没有突袭周末记录")
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
                        Text("都城金币 " + Self.formatted(loot))
                            .font(.subheadline.weight(.semibold))
                    }
                    if let offensive = season.offensiveReward {
                        Text("进攻突袭奖章 \(Self.formatted(offensive))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let defensive = season.defensiveReward {
                        Text("防守突袭奖章 \(Self.formatted(defensive))")
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
                        Text("摧毁 \(districts) 座子城")
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
                Text("成员突袭表现（\(members.count) 人）")
                    .font(.caption.weight(.semibold))
                ForEach(Array(members.prefix(30).enumerated()), id: \.offset) { _, member in
                    HStack {
                        Text(member.name ?? "未知成员").font(.caption).lineLimit(1)
                        Spacer()
                        Text([member.attacks.map { "\($0) 次进攻" },
                              member.capitalResourcesLooted.map { "掠夺 \(Self.formatted($0)) 都城金币" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if members.count > 30 {
                    Text("还有 \(members.count - 30) 名成员…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let log = season.attackLog, !log.isEmpty {
                Text("进攻记录（\(log.count) 条）").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(Array(log.prefix(30).enumerated()), id: \.offset) { _, entry in
                    raidLogRow(entry)
                }
                if log.count > 30 {
                    Text("还有 \(log.count - 30) 条…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let log = season.defenseLog, !log.isEmpty {
                Text("防守记录（\(log.count) 条）").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(Array(log.prefix(30).enumerated()), id: \.offset) { _, entry in
                    defenseLogRow(entry)
                }
                if log.count > 30 {
                    Text("还有 \(log.count - 30) 条…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func raidLogRow(_ entry: CapitalRaidAttackLogEntry) -> some View {
        logEntryRow(
            opponentName: entry.defender?.name,
            attackCount: entry.attackCount,
            districtsDestroyed: entry.districtsDestroyed,
            districts: entry.districts
        )
    }

    @ViewBuilder
    private func defenseLogRow(_ entry: CapitalRaidDefenseLogEntry) -> some View {
        logEntryRow(
            opponentName: entry.attacker?.name,
            attackCount: entry.attackCount,
            districtsDestroyed: entry.districtsDestroyed,
            districts: entry.districts
        )
    }

    /// 攻防日志条目行：有子城明细时可展开逐子城；摘要只显示可加/计数信息，
    /// 摧毁率永不累加（issue #69）。
    @ViewBuilder
    private func logEntryRow(
        opponentName: String?, attackCount: Int?,
        districtsDestroyed: Int?, districts: [CapitalRaidDistrict]?
    ) -> some View {
        if let districts, !districts.isEmpty {
            let summary = ClanCombatSummary.raidDistricts(districts)
            DisclosureGroup {
                districtRows(summary)
                    .padding(.vertical, 4)
            } label: {
                logEntryLabel(
                    opponentName: opponentName,
                    summaryText: logEntrySummaryText(
                        attackCount: attackCount,
                        destroyed: ClanCombatSummary.destroyedDistrictCount(
                            districtsDestroyed: districtsDestroyed, districts: districts
                        ),
                        looted: summary.totalLooted
                    )
                )
            }
            .font(.caption)
        } else {
            logEntryLabel(
                opponentName: opponentName,
                summaryText: logEntrySummaryText(
                    attackCount: attackCount,
                    destroyed: ClanCombatSummary.destroyedDistrictCount(
                        districtsDestroyed: districtsDestroyed, districts: []
                    ),
                    looted: nil
                )
            )
        }
    }

    private func logEntryLabel(opponentName: String?, summaryText: String) -> some View {
        HStack {
            Text("对阵 " + (opponentName ?? "未知部落"))
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text(summaryText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    /// 摘要文案：N 次进攻 · 摧毁 M 座子城 · 掠夺 X 都城金币（金币为 nil 时省略分句，缺失记 0 时显示 0）。
    private func logEntrySummaryText(attackCount: Int?, destroyed: Int?, looted: Int?) -> String {
        [attackCount.map { "\($0) 次进攻" },
         destroyed.map { "摧毁 \($0) 座子城" },
         looted.map { "掠夺 \(Self.formatted($0)) 都城金币" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func districtRows(_ summary: CapitalRaidDistrictSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(summary.districts.enumerated()), id: \.offset) { _, district in
                districtRow(district)
            }
        }
    }

    /// 逐子城明细行：名称 + ⭐星数 · 摧毁率 X% · N 次进攻 · 掠夺 Y 金币（缺失项省略）。
    private func districtRow(_ district: CapitalRaidDistrictLine) -> some View {
        HStack {
            Text(district.name ?? "未知子城")
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text([district.stars.map { "⭐\(min(max($0, 0), 3))" },
                  district.destructionPercent.flatMap(ClanCombatSummary.displayDestructionPercent).map { "摧毁率 \(Self.percent($0))%" },
                  district.attackCount.map { "\($0) 次进攻" },
                  district.totalLooted.map { "掠夺 \(Self.formatted($0)) 都城金币" }]
                .compactMap { $0 }
                .joined(separator: " · "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private static func percent(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func formatted(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
