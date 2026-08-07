import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情页的部落对战日志卡片（分页，按需刷新）。
///
/// 状态语义（Issue #7 stage 3c）：
/// - 档案已知 `isWarLogPublic=false` → 显式"部落对战日志不公开"（不发起请求）
/// - 403 兜底：档案过期时请求失败显示失败原因
/// - lastGood = 累计页（items + 游标）；"加载更多"向后翻页，游标不前进即停
struct WarLogCardView: View {
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

    /// 本卡片村庄所属部落的战争日志状态（nil = 无部落 / 从未请求）。
    private var warLogState: ClanWarLogAPIState? {
        guard let clanTag else { return nil }
        return model.warLogState(for: clanTag)
    }

    /// 本卡片村庄所属部落档案是否已知战争日志不公开。
    private var knownNotPublic: Bool {
        guard let clanTag else { return false }
        return model.isWarLogKnownNotPublic(for: clanTag)
    }

    /// 本卡片村庄所属部落的战争日志是否还有更多页（分页按钮可用性）。
    private var hasMore: Bool {
        guard let clanTag else { return false }
        return model.warLogHasMore(for: clanTag)
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
            Label("部落对战日志", systemImage: "list.bullet.clipboard.fill")
                .font(.headline)
            Spacer()
            if let label = ClanDisplayFormat.sourceLabel(warLogState?.sourceLabel) {
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
            Label("刷新官方玩家数据后可查看部落对战日志", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !isManualEntry, clanTag == nil {
            Label("不在部落中，没有部落对战日志", systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if knownNotPublic,
                  !(warLogState?.status == .success || warLogState?.status == .failed),
                  let clanTag {
            // 显式状态：不伪造"没有历史部落对战"。
            // 仅当从未请求过时显示预判（force 请求后 success/failed 由
            // 状态分支呈现，避免 force 结果被预判 shadowing）。
            VStack(alignment: .leading, spacing: 8) {
                Label("该部落的部落对战日志不公开", systemImage: "eye.slash.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                HStack {
                    Button {
                        model.refreshWarLog(tag: clanTag, force: true)
                    } label: {
                        if model.isRefreshingWarLog(clanTag: clanTag) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("仍要检查", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRefreshingWarLogData || model.isRefreshingWarLog(clanTag: clanTag))
                    Spacer()
                }
            }
        } else if let state = warLogState, let clanTag {
            statusLine(state)
            if let page = state.lastGood {
                warLogList(page)
                if hasMore {
                        loadMoreButton("加载更多部落对战", tag: clanTag)
                }
            }
            // 总是显示刷新按钮：failed（重试）与 stale（重新拉取）都需入口，
            // 避免"有 lastGood 但状态非 success"时卡片死锁（对齐 3b 模式）。
            // 档案已知"不公开"时用户点刷新意图明确 → force 绕过预判
            //（否则被 AppModel 预判静默拦截，按钮无任何效果）。
            refreshButton("刷新部落对战日志", force: knownNotPublic, tag: clanTag)
        } else if let clanTag {
            VStack(alignment: .leading, spacing: 8) {
                Label("尚未获取部落对战日志", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                refreshButton("查看部落对战日志", tag: clanTag)
            }
        }
    }

    private func refreshButton(_ title: String, force: Bool = false, tag: String) -> some View {
        HStack {
            Button {
                if force {
                    model.refreshWarLog(tag: tag, force: true)
                } else {
                    model.refreshWarLog(tag: tag)
                }
            } label: {
                if model.isRefreshingWarLog(clanTag: clanTag) {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.cocAccent)
            .disabled(model.isRefreshingWarLogData || model.isRefreshingWarLog(clanTag: clanTag))
            Spacer()
        }
    }

    private func loadMoreButton(_ title: String, tag: String) -> some View {
        HStack {
            Button {
                model.loadMoreWarLog(tag: tag)
            } label: {
                if model.isRefreshingWarLog(clanTag: clanTag) {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: "ellipsis.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshingWarLogData || model.isRefreshingWarLog(clanTag: clanTag))
            Spacer()
        }
    }

    @ViewBuilder
    private func statusLine(_ state: ClanWarLogAPIState) -> some View {
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
                if state.lastHTTPStatus == 403 {
                    // 403 可能是"部落对战日志不公开"（档案预判过期时兜底），
                    // 也可能是 invalidIp 等凭证问题（reason 原样透传可区分）。
                    Text("部落对战日志可能不公开（403）")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

    private func warLogList(_ page: OfficialWarLogPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if page.items.isEmpty {
                Text("没有历史部落对战记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(page.items.enumerated()), id: \.offset) { _, entry in
                    warLogRow(entry)
                    if entry.endTime != page.items.last?.endTime {
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
    }

    /// 战争日志条目行：有成员明细时可展开（默认折叠；上限 30 行，超出提示），
    /// 无成员时仅渲染摘要（与改动前行为一致，无展开箭头）。
    @ViewBuilder
    private func warLogRow(_ entry: OfficialWarLogEntry) -> some View {
        if let members = entry.clan?.members, !members.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    // id: \.offset：成员全 optional，相同对象（如全 nil）会撞 \.self
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
            } label: {
                warLogSummary(entry)
            }
            .font(.caption)
        } else {
            warLogSummary(entry)
        }
    }

    private func warLogSummary(_ entry: OfficialWarLogEntry) -> some View {
        HStack(spacing: 10) {
            resultBadge(entry.result)
            VStack(alignment: .leading, spacing: 2) {
                Text("对阵 " + (entry.opponent?.name ?? "未知部落"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let endTime = entry.endTime {
                    Text("结束：\(endTime)（官方时间）")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let stars = entry.clan?.stars {
                    Text("⭐ \(stars)")
                        .font(.callout.weight(.semibold))
                }
                if let destruction = entry.clan?.destructionPercentage {
                        Text("摧毁率 \(Self.percent(ClanCombatSummary.clampedPercent(destruction)))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
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

    @ViewBuilder
    private func resultBadge(_ result: String?) -> some View {
        switch result {
        case "win":
            Text("胜").font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.green.opacity(0.18), in: Capsule())
                .foregroundStyle(.green)
        case "lose":
            Text("负").font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red.opacity(0.18), in: Capsule())
                .foregroundStyle(.red)
        case "tie":
            Text("平").font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.gray.opacity(0.18), in: Capsule())
                .foregroundStyle(.secondary)
        default:
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }
}
