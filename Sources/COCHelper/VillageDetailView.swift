import SwiftUI
import COCHelperApp
import COCHelperCore

/// Issue #16：村庄详情页。
///
/// 数据流：`VillageCatalogProjection.project(village:catalog:base:now:)`（#14 投影层）
/// → `VillageDetailProjection`（分组/完成度）。列表行复用 #15 的
/// `UpgradeDisplayRow`（`showsVillageColumn = false`）。
struct VillageDetailView: View {
    @EnvironmentObject private var model: AppModel
    let villageID: UUID
    let openImport: () -> Void

    @State private var selectedBase: TrackerBase = .home
    @State private var selectedFilter: CategoryFilter = .all
    @State private var selectedItem: VillageItemState?

    private var village: VillageProfile? {
        model.villages.first(where: { $0.id == villageID })
    }

    private var catalog: GameCatalog? { model.gameCatalog }

    var body: some View {
        Group {
            if let village {
                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    detailContent(village: village, now: context.date)
                }
            } else {
                ContentUnavailableView(
                    "村庄不存在",
                    systemImage: "questionmark.folder",
                    description: Text("该村庄可能已被删除。")
                )
            }
        }
        .background(Color.cocBackground)
        .sheet(item: $selectedItem) { item in
            LevelDetailSheet(item: item, catalog: catalog)
        }
    }

    private func detailContent(village: VillageProfile, now: Date) -> some View {
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            base: selectedBase,
            now: now
        )
        // 与升级总览（UpgradeOverviewProjection.allRecords）口径一致：
        // decos/helpers/obstacles 等不参与升级追踪的类别不展示、不计入完成度。
        let trackedItems = projection.items.filter { $0.status != .unavailable }
        let groups = VillageDetailProjection.groups(from: trackedItems)
        let total = VillageDetailProjection.totalCompletion(from: trackedItems)
        let statsByKey = Dictionary(
            uniqueKeysWithValues: VillageDetailProjection.completionStats(from: trackedItems)
                .map { ($0.id, $0) }
        )
        let displayGroups = filtered(groups)

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(village: village, projection: projection, total: total)
                basePicker()
                categoryFilterBar(groups: groups)

                if displayGroups.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("当前筛选下没有项目", systemImage: "line.3.horizontal.decrease.circle")
                                .font(.subheadline.weight(.semibold))
                            Text("切换基地或分类查看其他项目；导入快照后这里会列出该村庄全部已观测建筑与部队。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(displayGroups) { group in
                        sectionCard(group: group, now: now, stats: statsByKey[group.id], village: village)
                    }
                }
            }
            .padding(28)
        }
    }

    // MARK: - 头部

    private func header(
        village: VillageProfile,
        projection: VillageCatalogProjection,
        total: VillageCategoryCompletion
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(village.name)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(village.tag ?? "尚未导入账号 JSON")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        snapshotTimeLabel(village)
                        if let version = projection.catalogVersion {
                            Text("目录 v" + version)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Button(action: openImport) {
                    Label("更新快照", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .tint(Color.cocAccent)
            }

            completionBar(total: total)
            diagnosticsNote(projection)
        }
    }

    private func snapshotTimeLabel(_ village: VillageProfile) -> some View {
        let text: String
        if let capturedAt = village.accountSnapshot?.capturedAt {
            text = "快照 " + capturedAt.formatted(date: .abbreviated, time: .shortened)
        } else if let importedAt = village.accountSnapshot?.importedAt {
            text = "导入 " + importedAt.formatted(date: .abbreviated, time: .shortened)
        } else {
            text = "尚未导入快照"
        }
        return Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
    }

    private func completionBar(total: VillageCategoryCompletion) -> some View {
        HStack(spacing: 12) {
            Text("完成度")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let ratio = total.completionRatio {
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .tint(Color.cocAccent)
                    .frame(maxWidth: 260)
                Text(String(Int((ratio * 100).rounded())) + "%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.cocAccent)
                Text(String(total.completedCount) + " / " + String(total.knownCount) + " 已满级")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("无可确认项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if total.unknownCount > 0 {
                Text(String(total.unknownCount) + " 项未知")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.cocAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func diagnosticsNote(_ projection: VillageCatalogProjection) -> some View {
        ForEach(projection.diagnostics) { diagnostic in
            Label(diagnostic.message, systemImage: diagnostic.severity == .warning
                ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.caption)
                .foregroundStyle(diagnostic.severity == .warning ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 筛选

    private func basePicker() -> some View {
        Picker("基地", selection: $selectedBase) {
            ForEach(TrackerBase.allCases) { base in
                Text(base.title).tag(base)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }

    private func categoryFilterBar(groups: [VillageDetailGroup]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "全部", count: groups.reduce(0) { $0 + $1.items.count }, filter: .all)
                ForEach(TrackerCategory.allCases) { category in
                    let count = groups.first(where: { $0.category == category })?.items.count ?? 0
                    filterChip(title: category.title, count: count, filter: .category(category))
                }
                let otherCount = groups.first(where: { $0.category == nil })?.items.count ?? 0
                if otherCount > 0 {
                    filterChip(title: "其他", count: otherCount, filter: .other)
                }
            }
        }
    }

    private func filterChip(title: String, count: Int, filter: CategoryFilter) -> some View {
        Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if count > 0 {
                    Text(String(count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selectedFilter == filter ? Color.white.opacity(0.8) : .secondary)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selectedFilter == filter ? Color.white : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                selectedFilter == filter ? Color.cocAccent : Color.white.opacity(0.06),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func filtered(_ groups: [VillageDetailGroup]) -> [VillageDetailGroup] {
        switch selectedFilter {
        case .all: return groups
        case .category(let c): return groups.filter { $0.category == c }
        case .other: return groups.filter { $0.category == nil }
        }
    }

    // MARK: - 列表

    private func sectionCard(
        group: VillageDetailGroup,
        now: Date,
        stats: VillageCategoryCompletion?,
        village: VillageProfile
    ) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        group.category?.title ?? "其他",
                        systemImage: group.category?.systemImage ?? "ellipsis.circle"
                    )
                    .font(.headline)
                    Spacer()
                    sectionCompletionLabel(stats: stats)
                }

                LazyVStack(spacing: 0) {
                    ForEach(group.items) { item in
                        itemRow(item, group: group, now: now, village: village)
                        if item.id != group.items.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
    }

    /// 单行：`UpgradeDisplayRecord` 在按钮外层构造，避免 label 闭包内长表达式
    /// 触发 Swift 编译器类型检查超时。`village` 已由 detailContent 解包后传入，
    /// 直接取 `.name`/`.tag`（不经 Optional 计算属性，避免与 SwiftUI
    /// `Optional.tag(_:)` modifier 歧义）。
    private func itemRow(
        _ item: VillageItemState,
        group: VillageDetailGroup,
        now: Date,
        village: VillageProfile
    ) -> some View {
        let rowID = villageID.uuidString + ":" + selectedBase.rawValue + ":" + item.id
        let record = UpgradeDisplayRecord(
            id: rowID,
            villageID: villageID,
            villageName: village.name,
            villageTag: village.tag,
            base: selectedBase,
            item: item,
            catalogVersion: catalog?.gameVersion
        )
        return Button {
            selectedItem = item
        } label: {
            UpgradeDisplayRow(
                record: record,
                now: now,
                showsVillageColumn: false
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func sectionCompletionLabel(stats: VillageCategoryCompletion?) -> some View {
        guard let stats, let ratio = stats.completionRatio else {
            return Text("无可确认完成度").font(.caption2).foregroundStyle(.tertiary)
        }
        let summary = String(stats.completedCount) + "/" + String(stats.knownCount)
            + " · " + String(Int((ratio * 100).rounded())) + "%"
        let tint: Color = stats.completedCount == stats.knownCount ? .green : .secondary
        return Text(summary)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(tint)
    }

    private enum CategoryFilter: Hashable {
        case all
        case category(TrackerCategory)
        case other
    }
}
