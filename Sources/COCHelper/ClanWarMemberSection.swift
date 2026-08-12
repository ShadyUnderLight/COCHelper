import SwiftUI
import COCHelperCore
import COCHelperApp

/// 部落对战成员区（Issue #126）：筛选 chips、排序切换、成员表与行展开。
/// 全部计数来自传入的 `counts`（chipCounts 输出），UI 不重新统计。
/// 区标题由父视图承担（本组件不渲染标题）。
struct ClanWarMemberSection: View {
    /// 已按当前排序顺序排好的成员行（单参与方）。
    let rows: [ClanWarMemberRow]
    /// 当前战争阶段（chips 语义与备战期文案依赖）。
    let phase: ClanWarPhase
    /// 筛选桶计数（由主视图 chipCounts 算好传入）。
    let counts: ClanWarFilterCounts
    /// 当前筛选桶（主视图持有）。
    @Binding var selectedFilter: ClanWarMemberFilter
    /// 搜索词（主视图持有，跨 side/村庄切换保留；纯显示过滤，不影响计数）。
    let searchText: String

    /// 已展开攻击明细的成员**身份**（tag 优先 → name → "#\(sourceIndex)" 兜底；
    /// nil = 无展开行）。
    /// 身份绑定语义：sourceIndex 会随排序/刷新重排而漂移，不能作为跨刷新
    /// 展开身份；tag/name 是成员稳定身份——重排后 tag/name 相同的成员保持
    /// 展开，不同成员不误展开（双 nil 用 sourceIndex 兜底，仅合同内不可达的
    /// 全匿名行退化为位置绑定）。
    @State private var expandedIdentity: String?

    /// 列宽固定值：表头与数据行共用，窄窗口下右侧列不被挤出。
    fileprivate static let positionWidth: CGFloat = 26
    fileprivate static let townhallWidth: CGFloat = 52
    fileprivate static let attackProgressWidth: CGFloat = 56
    fileprivate static let starsWidth: CGFloat = 88
    fileprivate static let defenseWidth: CGFloat = 36
    fileprivate static let statusWidth: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterChips
            headerRow
            memberList
        }
    }

    // MARK: - 筛选 chips

    /// 筛选桶 chips 行（顺序固定：全部/待处理/未出手/剩余1次/剩余多次/已完成/数据未确认），
    /// 备战期且有"等待开战"成员时在末尾追加中性 chip。
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chipItems) { item in
                    chipButton(item)
                }
                if counts.awaitingWar > 0 {
                    awaitingWarChip
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// chip 数据（label + count；计数全部来自传入 `counts`，"全部" = rows.count）。
    private var chipItems: [ChipItem] {
        [
            ChipItem(filter: .all, label: "全部", count: rows.count),
            ChipItem(filter: .pending, label: "待处理", count: counts.pending),
            ChipItem(filter: .notAttacked, label: "未出手", count: counts.notAttacked),
            ChipItem(filter: .remainingOnce, label: "剩余1次", count: counts.remainingOnce),
            ChipItem(filter: .remainingMany, label: "剩余多次", count: counts.remainingMany),
            ChipItem(filter: .complete, label: "已完成", count: counts.complete),
            ChipItem(filter: .unknownData, label: "数据未确认", count: counts.unknownData)
        ]
    }

    /// 胶囊 chip 按钮：选中 cocAccent + 白字；未选中 cocElevated + secondary 字。
    /// 待处理 chip 仅 inWar 阶段用橙色强调（备战期 0 次攻击与 warEnded 结算
    /// 都是正常状态——#125 Core 契约"warEnded 时同样分组，只是样式上不突出"）。
    private func chipButton(_ item: ChipItem) -> some View {
        let isSelected = selectedFilter == item.filter
        let isPendingWarning = item.filter == .pending
            && phase != .preparation && phase != .warEnded
        return Button {
            selectedFilter = item.filter
        } label: {
            Text("\(item.label) \(item.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : (isPendingWarning ? Color.orange : Color.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.cocAccent : Color.cocElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// "等待开战 N" 中性 chip：备战期 0 次攻击是正常状态，不参与筛选，绝不用警示色。
    private var awaitingWarChip: some View {
        Text("等待开战 \(counts.awaitingWar)")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.cocElevated, in: Capsule())
    }

    // MARK: - 成员表

    /// 表头行：与数据行同列宽（caption2 secondary）。
    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("位置").frame(width: Self.positionWidth)
            Text("成员").frame(maxWidth: .infinity, alignment: .leading)
            Text("大本营").frame(width: Self.townhallWidth)
            Text("攻击进度").frame(width: Self.attackProgressWidth)
            Text("星数/摧毁率").frame(width: Self.starsWidth)
            Text("防守").frame(width: Self.defenseWidth)
            Text("状态").frame(width: Self.statusWidth, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// 成员表：按当前筛选桶过滤后**全量渲染**（无 prefix 截断），行可展开攻击/防守明细。
    /// 搜索词非空（trim 后）且过滤后无行 → 空态文案替代空列表（避免纯空白区）。
    @ViewBuilder
    private var memberList: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && visibleRows.isEmpty {
            Text("无匹配成员")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows, id: \.sourceIndex) { row in
                    memberRow(row)
                    if expandedIdentity == identity(of: row), Self.hasExpandableContent(row) {
                        detailBlock(row)
                    }
                }
            }
        }
    }

    /// 当前筛选桶下的可见行（投影 `filteredRows`，UI 不重新统计）。
    /// 搜索是纯显示过滤：先按桶过滤、再按搜索词过滤（顺序与语义无关）；
    /// 计数（chips）不受搜索影响——计数反映桶归属。
    private var visibleRows: [ClanWarMemberRow] {
        let filtered = ClanWarDisplayProjection.filteredRows(rows, filter: selectedFilter, phase: phase)
        return ClanWarDisplayProjection.rows(filtered, matchingSearch: searchText)
    }

    /// 成员数据行：整行 Button 切换展开；列宽固定，成员列弹性截断。
    private func memberRow(_ row: ClanWarMemberRow) -> some View {
        Button {
            // 身份绑定：同一身份再点收起，不同身份切换展开（见 expandedIdentity 注释）
            expandedIdentity = expandedIdentity == identity(of: row) ? nil : identity(of: row)
        } label: {
            HStack(spacing: 6) {
                Text(row.mapPosition.map { "\($0)" } ?? "—")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.positionWidth)
                memberCell(row)
                Text(row.townhallLevel.map { "\($0)" } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.townhallWidth)
                Text(attackProgressText(row))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    // 长数值（malformed 超长攻击数）单行缩放，不得换行撑高行
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: Self.attackProgressWidth)
                starsCell(row)
                    .frame(width: Self.starsWidth)
                Text(row.defenseAttacks.map { "防\($0)" } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: Self.defenseWidth)
                statusCell(row)
                    .frame(width: Self.statusWidth, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        // VoiceOver 提示：仅当行有可展开内容（攻击明细或最佳防守）时提供
        // （无可展开内容的行点击不产生新内容，不给误导性提示）。
        .accessibilityHint(expandableHint(for: row))
    }

    /// 行展开的 a11y 提示文案：有可展开内容 → 提示可展开；否则空串（不加提示）。
    private func expandableHint(for row: ClanWarMemberRow) -> String {
        Self.hasExpandableContent(row) ? "双击展开攻击/防守明细" : ""
    }

    /// 行是否有可展开内容：攻击明细非空 或 最佳防守非 nil。
    private static func hasExpandableContent(_ row: ClanWarMemberRow) -> Bool {
        if let lines = row.lines, !lines.isEmpty { return true }
        return row.bestDefense != nil
    }

    /// 成员列：行首 chevron（仅当有可展开内容，否则同宽占位）+ 名称单行截断。
    private func memberCell(_ row: ClanWarMemberRow) -> some View {
        HStack(spacing: 4) {
            Group {
                if Self.hasExpandableContent(row) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        // 装饰性图标：语义由整行 Button 承载，VoiceOver 跳过
                        .accessibilityHidden(true)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)
            Text(row.name ?? "未知成员")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 攻击进度文案（caption2）：displayGroup 唯一组合点映射，备战期零次 → "等待开战"。
    private func attackProgressText(_ row: ClanWarMemberRow) -> String {
        switch ClanWarDisplayProjection.displayGroup(phase: phase, action: row.action) {
        case .awaitingWar: return "等待开战"
        case .notAttacked: return "未出手"
        case .remaining:
            let count = row.action.attackCount.map { "\($0)" } ?? "?"
            let remaining = row.action.remainingAttacks.map { "\($0)" } ?? "?"
            return "已用\(count)·剩\(remaining)"
        case .complete: return "已完成"
        case .overQuota: return "超配额"
        case .quotaUnknown: return "配额未知"
        case .unknown: return "—"
        }
    }

    /// 星数/摧毁率文案（caption2）：
    /// - `stars == nil`（无攻击数据）→ "—"；
    /// - `lines` 非空 → 星数文本（"⭐N" / "⭐N+?M"）+ 空格 + 逐次摧毁率
    ///   （`ClanCombatSummary.displayDestructionPercent` 过滤非法值，nil 跳过
    ///   不显示；全部 nil 时只显示星数）；
    /// - `lines` 为空（明确 0 次攻击）→ "⭐0"。
    /// 摧毁率**逐次保留、永不聚合**（Issue #69 契约）。长文本单行缩放，
    /// 不得换行挤动行高。
    private func starsCell(_ row: ClanWarMemberRow) -> some View {
        Group {
            if row.stars == nil {
                Text("—")
            } else if let lines = row.lines, !lines.isEmpty {
                let starsText = row.stars.map(Self.starsSummaryText) ?? ""
                let destructions = lines.compactMap {
                    $0.destructionPercentage
                        .flatMap(ClanCombatSummary.displayDestructionPercent)
                        .map { ClanDisplayFormat.percent($0) + "%" }
                }.joined(separator: " ")
                let text = destructions.isEmpty ? starsText : starsText + " " + destructions
                Text(text)
                    .accessibilityLabel(row.stars.map(Self.starsAccessibilityLabel) ?? "未知星数")
            } else {
                Text("⭐0")
                    .accessibilityLabel("0 颗星")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    /// 星数摘要文本（"⭐N" / "⭐N+?M"，缺失提示）；与既有展示格式逐字一致。
    private static func starsSummaryText(_ stars: ClanWarMemberStars) -> String {
        stars.missingCount > 0
            ? "⭐\(stars.knownStars)+\(stars.missingCount)?"
            : "⭐\(stars.knownStars)"
    }

    /// 星数单元格的 VoiceOver 标签（保留既有语义，不含摧毁率——逐次摧毁率
    /// 已由明细行承载，展开后可读）。
    private static func starsAccessibilityLabel(_ stars: ClanWarMemberStars) -> String {
        stars.missingCount > 0
            ? "\(stars.knownStars) 颗星，另有 \(stars.missingCount) 次未知"
            : "\(stars.knownStars) 颗星"
    }

    /// 行展开身份：tag 优先，name 次之，双 nil 用 sourceIndex 兜底
    ///（刷新重排后 tag/name 相同的成员保持展开，不同成员不误展开）。
    private func identity(of row: ClanWarMemberRow) -> String {
        row.tag ?? row.name ?? "#\(row.sourceIndex)"
    }

    /// 状态列（displayGroup 映射）：颜色只表状态——待处理警示 / 完成成功 / 未知中性。
    /// 长文案（malformed 超长值）单行缩放，不得换行撑高行破坏表头对齐。
    private func statusCell(_ row: ClanWarMemberRow) -> some View {
        Text(statusText(row))
            .font(.caption)
            .foregroundStyle(statusColor(row))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private func statusText(_ row: ClanWarMemberRow) -> String {
        switch ClanWarDisplayProjection.displayGroup(phase: phase, action: row.action) {
        case .awaitingWar: return "等待开战"
        case .notAttacked: return "未出手"
        case .remaining:
            return "剩余\(row.action.remainingAttacks.map { "\($0)" } ?? "?")次"
        case .complete: return "已完成"
        case .overQuota: return "超出配额"
        case .quotaUnknown: return "配额未知"
        case .unknown: return "数据未确认"
        }
    }

    /// 状态列颜色：待处理（未出手/剩余）橙色警示；完成绿色；未知中性。
    /// 备战期等待开战与 warEnded 结算都是正常状态（#125 Core 契约）→
    /// 未出手/剩余与 chip 的 isPendingWarning 逻辑一致降为 secondary
    /// （备战期契约内数据不应有 partial，属防御路径一致性）。
    private func statusColor(_ row: ClanWarMemberRow) -> Color {
        switch ClanWarDisplayProjection.displayGroup(phase: phase, action: row.action) {
        case .notAttacked, .remaining:
            return (phase == .warEnded || phase == .preparation) ? .secondary : .orange
        case .complete: return .green
        case .awaitingWar, .overQuota, .quotaUnknown, .unknown: return .secondary
        }
    }

    /// 展开的逐次攻击明细 + 最佳防守块（cocElevated 圆角背景）。
    /// 调用方保证 row 至少有一个可展开内容（lines 非空 或 bestDefense 非 nil）。
    private func detailBlock(_ row: ClanWarMemberRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let lines = row.lines, !lines.isEmpty {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(ClanWarDetailText.attackLine(line))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let best = row.bestDefense {
                Text(ClanWarDetailText.bestDefense(best))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cocElevated, in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 6)
    }
}

/// chip 数据项（label + count 展示；filter 决定选中态与点击行为）。
private struct ChipItem: Identifiable {
    let filter: ClanWarMemberFilter
    let label: String
    let count: Int
    var id: ClanWarMemberFilter { filter }
}
