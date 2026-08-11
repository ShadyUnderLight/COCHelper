import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情页的当前部落对战卡片（**按需刷新**：用户点击按钮才请求 currentwar）。
///
/// 状态语义（Issue #7 stage 3b）：
/// - `notInWar` 是**成功**响应 → 显示"当前没有进行中的部落对战"空状态（不是失败）
/// - `preparation` / `inWar` → 双方比分卡（ClanWarScoreCardView）+ 成员区
/// - `warEnded` → 部落对战已结束 + 结果
/// - 失败保留 last-good；成员区由 `ClanWarMemberSection` 渲染（全量无截断，
///   排序/筛选状态由本视图持有，Issue #126）
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

    // MARK: - 成员区状态（Issue #126）

    /// 当前展示的参与方（我方/对方切换；只渲染选中方成员表）。
    @State private var selectedSide = Side.clan
    /// 成员行排序顺序（行动优先/地图位置/名称）。
    @State private var sortOrder: ClanWarSortOrder = .actionPriority
    /// 当前筛选桶（chips 选中态，由 ClanWarMemberSection 双向绑定）。
    @State private var selectedFilter: ClanWarMemberFilter = .all

    private enum Side: String, CaseIterable {
        case clan, opponent
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

    /// 战争摘要：消费 `ClanWarDisplayProjection`（Issue #125/126），
    /// 不再直接消费 raw snapshot 的 state 字符串与成员数组。
    @ViewBuilder
    private func warSummary(_ snapshot: OfficialClanWarSnapshot) -> some View {
        let projection = ClanWarDisplayProjection.project(snapshot)
        switch projection.phase {
        case .notInWar:
            // 成功空状态：无部落对战不是失败
            Label("当前没有进行中的部落对战", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.green)
        case .preparation, .inWar, .warEnded:
            VStack(alignment: .leading, spacing: 10) {
                phaseBadge(projection.phase)
                metaLines(snapshot, projection)
                scoreCards(projection)
                memberArea(projection)
            }
        case .unknown(raw: let raw):
            VStack(alignment: .leading, spacing: 6) {
                Label("未知部落对战状态", systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // raw 原样展示（monospaced 小字，可审计）；字段缺失/空串时不渲染
                if let raw, !raw.isEmpty {
                    Text(raw)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
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

    /// 阶段胶囊（备战中/orange、部落对战进行中/red、部落对战已结束/secondary）。
    @ViewBuilder
    private func phaseBadge(_ phase: ClanWarPhase) -> some View {
        switch phase {
        case .preparation:
            stateBadge("备战中", color: .orange)
        case .inWar:
            stateBadge("部落对战进行中", color: .red)
        case .warEnded:
            stateBadge("部落对战已结束", color: .secondary)
        case .notInWar, .unknown:
            EmptyView()
        }
    }

    /// 元信息行：战争规则（BattleModifierText 映射）+ 对战规模（quota 投影）
    /// + 开始/结束时间（官方时间原样展示）。
    private func metaLines(_ snapshot: OfficialClanWarSnapshot, _ projection: ClanWarProjection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 战争规则（锦标赛模式 / 传奇杯）：无规则（nil/"none"）时不渲染占位
            if let rule = BattleModifierText.localizedText(for: snapshot.battleModifier) {
                Text("规则：\(rule)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let teamSize = projection.quota.teamSize {
                Text("对战规模：\(teamSize) 人")
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

    /// 双方比分卡：`ClanWarScoreCardView` 要求双参与方非 nil——双侧齐全时用组件
    ///（含星数差/摧毁率差）；一方缺失时降级为单卡（不伪造另一侧数据，不崩溃）；
    /// 双侧缺失保留现状提示。
    @ViewBuilder
    private func scoreCards(_ projection: ClanWarProjection) -> some View {
        if let clan = projection.clan, let opponent = projection.opponent {
            ClanWarScoreCardView(
                label: "我方",
                row: clan,
                opponentLabel: "对方",
                opponentRow: opponent,
                quota: projection.quota
            )
        } else if let clan = projection.clan {
            singleScoreCard(clan, label: "我方", quota: projection.quota)
        } else if let opponent = projection.opponent {
            singleScoreCard(opponent, label: "对方", quota: projection.quota)
        } else {
            Text("部落对战详情字段缺失（可能刚结束或数据不完整）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 单方比分卡（另一参与方官方未返回时降级）：信息层与
    /// `ClanWarScoreCardView` 的单卡一致，只消费官方 participant 摘要。
    private func singleScoreCard(_ row: ClanWarParticipantProjection, label: String, quota: ClanWarQuota) -> some View {
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
                Text("⭐ \(stars) 星")
                    .font(.callout.weight(.semibold))
            }
            if let destruction = row.official.destructionPercentage.flatMap(ClanCombatSummary.displayDestructionPercent) {
                Text("摧毁率 \(Self.percent(destruction))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 攻击进度：配额与官方攻击数均已知 → "已用攻击 X / Y"；否则 → "攻击配额未知"
            if let total = quota.totalAttacks, let attacks = row.official.attacks {
                Text("已用攻击 \(attacks) / \(total)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("攻击配额未知")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cocPanel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: - 成员区（Issue #126）

    /// 成员区：我方/对方切换（segmented）+ 标题行（标题 + 排序 Picker）
    /// + `ClanWarMemberSection`。
    /// - 排序：行动优先直接用投影已排序行（`side.members`）；地图位置/名称由
    ///   本视图二次排序（纯展示排序，sourceIndex 平局）。
    /// - 过滤：`ClanWarMemberSection` 内部按 `selectedFilter` 过滤，本视图只传
    ///   未过滤的排序后全量行（不过滤两次、不漏过滤）。
    /// - 只渲染当前选中参与方的表（两侧各一张大表无意义）。
    /// - `members == nil`（官方未返回成员数组）显示提示；`[]` 走空表（区分两者）。
    @ViewBuilder
    private func memberArea(_ projection: ClanWarProjection) -> some View {
        let side = selectedSide == .clan ? projection.clan : projection.opponent
        let sideTitle = selectedSide == .clan ? "我方成员" : "对方成员"
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $selectedSide) {
                Text("我方").tag(Side.clan)
                Text("对方").tag(Side.opponent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Text("\(sideTitle)（\(side?.members?.count ?? 0) 人）")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("排序", selection: $sortOrder) {
                    Text("行动优先").tag(ClanWarSortOrder.actionPriority)
                    Text("地图位置").tag(ClanWarSortOrder.mapPosition)
                    Text("名称").tag(ClanWarSortOrder.name)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if let rows = side?.members {
                let sortedRows = sortedMemberRows(rows, order: sortOrder)
                let counts = ClanWarDisplayProjection.chipCounts(rows: sortedRows, phase: projection.phase)
                // title 由上方标题行承担（排序 Picker 需与标题同排），组件内标题传空串
                ClanWarMemberSection(
                    title: "",
                    rows: sortedRows,
                    phase: projection.phase,
                    counts: counts,
                    selectedFilter: $selectedFilter
                )
            } else {
                // 官方未返回成员数组（与 [] 区分：空数组走空表，不显示此提示）
                Text("成员数据未返回")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 纯展示排序：行动优先 → 投影已排好（直接透传）；地图位置/名称 → 对行
    /// 二次排序（nil 排最后，sourceIndex 平局——全序确定、与输入顺序无关）。
    private func sortedMemberRows(_ rows: [ClanWarMemberRow], order: ClanWarSortOrder) -> [ClanWarMemberRow] {
        switch order {
        case .actionPriority:
            return rows
        case .mapPosition:
            return rows.sorted { lhs, rhs in
                if let decision = Self.compareNilLast(lhs.mapPosition, rhs.mapPosition) { return decision }
                return lhs.sourceIndex < rhs.sourceIndex
            }
        case .name:
            return rows.sorted { lhs, rhs in
                if let decision = Self.compareNilLast(lhs.name, rhs.name) { return decision }
                return lhs.sourceIndex < rhs.sourceIndex
            }
        }
    }

    /// 可空升序比较（nil 排最后）：nil 表示两侧相等（继续平局键）。
    private static func compareNilLast<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?):
            return l != r ? l < r : nil
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            return nil
        }
    }

    /// 百分比文本：整数无小数，非整数 1 位小数（与 ClanWarScoreCardView 一致）。
    private static func percent(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value)) : String(format: "%.1f", value)
    }
}
