import SwiftUI
import COCHelperCore

/// Native macOS history presentation for one village's active lineage.
/// All comparisons, names, categories, evidence and statistics arrive through
/// `SnapshotHistoryProjection`; this view never reads raw snapshots or the
/// current GameCatalog.
struct SnapshotHistoryView: View {
    let projection: SnapshotHistoryProjection
    @Binding var selectedCategory: SnapshotHistoryCategory

    @State private var selectedWindow: StatisticsRange = .last7Days
    @State private var expandedRows: Set<UUID> = []

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                header
                availabilityContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("快照历史")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("快照历史", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.title3.weight(.semibold))
            if projection.totalSnapshotCount > 0 {
                Text(String(projection.totalSnapshotCount))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.cocAccent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.cocAccent)
                    .accessibilityLabel("历史快照 \(projection.totalSnapshotCount) 条")
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var availabilityContent: some View {
        switch projection.availability {
        case .noSnapshot:
            historyEmptyState(
                title: "尚未导入账号快照",
                systemImage: "tray.and.arrow.down",
                message: "先导入游戏内复制的账号 JSON；第一次成功导入会建立历史基线。"
            )
        case .empty:
            historyEmptyState(
                title: "历史尚未建立",
                systemImage: "clock.badge.questionmark",
                message: "当前快照仍可使用，但历史迁移尚未产生可展示的基线。"
            )
        case .baselineOnly:
            summaryBlock
            statusNote(
                title: "已建立历史基线",
                systemImage: "flag.checkered",
                message: "等待下一次有变化的导入；基线不会被统计成全部项目新增。",
                tint: .secondary
            )
            timelineSection
        case .available:
            summaryBlock
            statisticsSection
            filterBar
            timelineSection
        case .insufficient(let reason):
            summaryBlock
            statusNote(
                title: "历史比较受限",
                systemImage: "exclamationmark.triangle",
                message: reason,
                tint: .orange
            )
            statisticsSection
            filterBar
            timelineSection
        case .corrupt(let reason):
            unavailableState(
                title: "历史文件损坏",
                systemImage: "externaldrive.badge.exclamationmark",
                reason: reason
            )
        case .unsupported(let reason):
            unavailableState(
                title: "历史版本不受支持",
                systemImage: "questionmark.folder",
                reason: reason
            )
        case .unavailable(let reason):
            unavailableState(
                title: "历史不可用",
                systemImage: "clock.badge.exclamationmark",
                reason: reason
            )
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            coverageTrustNote
            if let appliedAt = projection.latestAppliedAt {
                Text("最近应用：" + appliedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let checkedAt = projection.latestCheckedAt,
               checkedAt > (projection.latestAppliedAt ?? .distantPast) {
                Text("最近检查：" + checkedAt.formatted(date: .abbreviated, time: .shortened)
                    + "（相同快照，未新增时间线记录）")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let summary = projection.latestSummary {
                Text(summary)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var coverageTrustNote: some View {
        let state = projection.coverageTrustState
        let tint: Color = switch state {
        case .verified: .green
        case .pendingRevalidation: .orange
        case .insufficientCoverage: .orange
        }
        return statusNote(
            title: state.title,
            systemImage: coverageTrustIcon(state),
            message: state.detail,
            tint: tint
        )
    }

    private func coverageTrustIcon(_ state: SnapshotCoverageTrustDisplayState) -> String {
        switch state {
        case .verified: "checkmark.shield"
        case .pendingRevalidation: "clock.badge.exclamationmark"
        case .insufficientCoverage: "shield.slash"
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Text("变化类别")
                .font(.subheadline.weight(.semibold))
            Picker("变化类别", selection: $selectedCategory) {
                ForEach(SnapshotHistoryCategory.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 210, alignment: .leading)
            Spacer()
        }
    }

    @ViewBuilder
    private var timelineSection: some View {
        if projection.filterIsEmpty {
            historyEmptyState(
                title: "当前筛选没有变化",
                systemImage: "line.3.horizontal.decrease.circle",
                message: "该类别在当前 lineage 的历史中没有可展示记录。"
            )
            Button("显示全部") {
                selectedCategory = .all
            }
            .buttonStyle(.bordered)
        } else if projection.timeline.isEmpty {
            historyEmptyState(
                title: "没有可展示的时间线",
                systemImage: "clock",
                message: "历史中没有可比较的记录。"
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("时间线")
                    .font(.headline)
                LazyVStack(spacing: 0) {
                    ForEach(projection.timeline) { row in
                        timelineRow(row)
                        if row.id != projection.timeline.last?.id {
                            Divider().padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func timelineRow(_ row: SnapshotHistoryRow) -> some View {
        if row.isBaseline {
            VStack(alignment: .leading, spacing: 7) {
                rowHeader(row)
                Text("初始基线（不计变化）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                duplicateNote(row)
            }
            .padding(.vertical, 10)
        } else {
            DisclosureGroup(isExpanded: expandedBinding(for: row.id)) {
                VStack(alignment: .leading, spacing: 10) {
                    if row.changes.isEmpty {
                        Text(row.comparisonState == .insufficientCoverage
                             ? "覆盖不足，无法确认具体变化。"
                             : "本次导入没有可确认变化。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(row.changes) { change in
                            changeRow(change)
                            if change.id != row.changes.last?.id {
                                Divider()
                            }
                        }
                    }
                    diagnostics(rows: row.diagnostics)
                    duplicateNote(row)
                }
                .padding(.top, 10)
                .padding(.leading, 4)
            } label: {
                rowHeader(row)
            }
            .padding(.vertical, 10)
        }
    }

    private func rowHeader(_ row: SnapshotHistoryRow) -> some View {
        let countLabel = row.containsUncertainChanges
            ? String(row.visibleChangeCount) + " 项（含待确认）"
            : String(row.visibleChangeCount) + " 项变化"
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.appliedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(row.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let sourceTimestamp = row.sourceTimestamp {
                    Text("来源时间：" + sourceTimestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 10)
            if !row.isBaseline {
                Text(countLabel)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(row.comparisonState == .insufficientCoverage ? .orange : Color.cocAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.cocElevated, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func changeRow(_ change: SnapshotChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(change.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(changeKindTitle(change))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(change.changeKind == .unknown ? .orange : Color.cocAccent)
            }
            Text(changeValueText(change))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                evidenceBadge(change.evidence)
                if change.coverage.state != .complete {
                    badge(
                        change.coverage.state == .partial ? "部分覆盖" : "覆盖不足",
                        tint: .orange
                    )
                }
                if !change.relatedChangeKinds.isEmpty {
                    Text(change.relatedChangeKinds.map(changeKindTitle).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !change.coverage.reasons.isEmpty {
                Text(change.coverage.reasons.joined(separator: "；"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("历史统计")
                    .font(.headline)
                Spacer()
                Picker("统计范围", selection: $selectedWindow) {
                    ForEach(StatisticsRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }

            let metrics = statisticMetrics(window: selectedWindow.value(from: projection.statistics))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(metric.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        switch metric.value.state {
                        case .available:
                            if let value = metric.value.value {
                                Text(String(value))
                                    .font(.title3.weight(.semibold).monospacedDigit())
                            } else {
                                Text("数据异常")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        case .insufficientData:
                            Text("数据不足")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            if let reason = metric.value.reason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    .padding(10)
                    .background(Color.cocElevated, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func statisticMetrics(window: SnapshotHistoryStatisticsWindow) -> [StatisticMetric] {
        [
            StatisticMetric(title: "建筑升级完成（已确认）", value: window.buildingUpgradeCompletions),
            StatisticMetric(
                title: "建筑升级完成（聚合推断）",
                value: window.aggregateInferredBuildingUpgradeCompletions
            ),
            StatisticMetric(title: "建筑等级增长（已确认）", value: window.buildingLevelGrowth),
            StatisticMetric(
                title: "建筑等级增长（聚合推断）",
                value: window.aggregateInferredBuildingLevelGrowth
            ),
            StatisticMetric(title: "城墙等级增长（总计）", value: window.wallLevelGrowth),
            StatisticMetric(title: "城墙等级增长（已确认）", value: window.confirmedWallLevelGrowth),
            StatisticMetric(
                title: "城墙等级增长（聚合推断）",
                value: window.aggregateInferredWallLevelGrowth
            ),
            StatisticMetric(title: "英雄等级增长", value: window.heroLevelGrowth),
            StatisticMetric(title: "兵种等级增长", value: window.troopLevelGrowth),
            StatisticMetric(title: "法术等级增长", value: window.spellLevelGrowth),
            StatisticMetric(title: "战宠等级增长", value: window.petLevelGrowth),
            StatisticMetric(title: "英雄装备增长", value: window.heroEquipmentLevelGrowth),
            StatisticMetric(title: "聚合推断事件数", value: window.aggregateInferredEventCount)
        ]
    }

    private func expandedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedRows.contains(id) },
            set: { expanded in
                if expanded {
                    expandedRows.insert(id)
                } else {
                    expandedRows.remove(id)
                }
            }
        )
    }

    @ViewBuilder
    private func duplicateNote(_ row: SnapshotHistoryRow) -> some View {
        if row.duplicateImportCount > 0, let lastSeenAt = row.lastSeenAt {
            Text("相同快照又检查 \(row.duplicateImportCount) 次 · 最近 "
                 + lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func diagnostics(rows: [String]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("数据诊断", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(rows, id: \.self) { diagnostic in
                    Text("• " + diagnostic)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func evidenceBadge(_ evidence: SnapshotChangeEvidence) -> some View {
        switch evidence {
        case .confirmed: badge("已确认", tint: .green)
        case .aggregateInferred: badge("聚合推断", tint: .blue)
        case .unknown: badge("证据不足", tint: .orange)
        }
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func changeKindTitle(_ kind: SnapshotChangeKind) -> String {
        switch kind {
        case .levelIncreased: "等级提升"
        case .levelDecreased: "等级下降"
        case .quantityChanged: "数量变化"
        case .newlyObserved: "新观察到"
        case .noLongerObserved: "不再观察到"
        case .upgradeStarted: "观察到计时开始"
        case .upgradeCompleted: "观察到升级完成"
        case .timerChanged: "观察到计时变化"
        case .timerEndedObserved: "观察到计时结束"
        case .unknown: "无法确认变化"
        }
    }

    private func changeKindTitle(_ change: SnapshotChange) -> String {
        if change.changeKind == .noLongerObserved,
           change.evidence == .unknown || change.coverage.state != .complete {
            return "无法确认是否消失"
        }
        return changeKindTitle(change.changeKind)
    }

    private func changeValueText(_ change: SnapshotChange) -> String {
        var parts: [String] = []
        if let oldLevel = change.oldLevel, let newLevel = change.newLevel {
            parts.append("Lv.\(oldLevel) → Lv.\(newLevel)")
        } else if let oldLevel = change.oldLevel {
            parts.append("原等级 Lv.\(oldLevel)")
        } else if let newLevel = change.newLevel {
            parts.append("当前等级 Lv.\(newLevel)")
        }
        if let quantityText = change.snapshotHistoryQuantityText {
            parts.append(quantityText)
        }
        if parts.isEmpty {
            parts.append(change.identity.rawSection + " #" + String(change.identity.dataID))
        }
        return parts.joined(separator: " · ")
    }

    private func historyEmptyState(title: String, systemImage: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusNote(title: String, systemImage: String, message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func unavailableState(title: String, systemImage: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("当前村庄状态不会被清空；原历史文件会保留，修复或恢复后可重新加载。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private enum StatisticsRange: String, CaseIterable, Identifiable {
        case today
        case last7Days
        case last30Days

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: "今天"
            case .last7Days: "近 7 天"
            case .last30Days: "近 30 天"
            }
        }

        func value(from statistics: SnapshotHistoryStatistics) -> SnapshotHistoryStatisticsWindow {
            switch self {
            case .today: statistics.today
            case .last7Days: statistics.last7Days
            case .last30Days: statistics.last30Days
            }
        }
    }

    private struct StatisticMetric: Identifiable {
        let title: String
        let value: SnapshotStatisticValue
        var id: String { title }
    }
}
