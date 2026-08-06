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
        // 目录不可用或版本不匹配时（projection.catalogIsUsable == false）：
        // issue #16「不纳入可确认完成度」——完成度全部归未知，不显示百分比。
        let total = VillageDetailProjection.totalCompletion(
            from: trackedItems,
            catalogIsUsable: projection.catalogIsUsable
        )
        let statsByKey = Dictionary(
            uniqueKeysWithValues: VillageDetailProjection.completionStats(
                from: trackedItems,
                catalogIsUsable: projection.catalogIsUsable
            )
                .map { ($0.id, $0) }
        )
        let displayGroups = filtered(groups)
        // 分组 id 集合：数据变化（重新导入快照、切换基地等）后用于校正筛选，
        // 不得残留成错误的空筛选（issue #37 验收）。
        let groupIDs = groups.map(\.id)

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(village: village, projection: projection, total: total)
                officialAPISection()
                basePicker()
                categoryFilterBar(groups: groups, total: total, statsByKey: statsByKey)

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
        .onChange(of: groupIDs) { _, newIDs in
            // 同一基地重新导入快照后分组可能变化（如精制台消失）：当前选中
            // 分类若不再被数据代表，自动重置为「全部」，避免残留空筛选
            //（issue #37 验收「分类数据变化后不能残留成错误的空筛选」）。
            if !Self.filterIsRepresented(selectedFilter, in: Set(newIDs)) {
                selectedFilter = .all
            }
        }
    }

    /// 当前筛选是否仍被分组数据代表（数据变化后校正用，issue #37 验收）。
    private static func filterIsRepresented(_ filter: CategoryFilter, in groupIDs: Set<String>) -> Bool {
        switch filter {
        case .all: true
        case .display(let dc): groupIDs.contains(dc.rawValue)
        case .category(let c): groupIDs.contains(c.rawValue)
        case .other: groupIDs.contains("other")
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

    // MARK: - 官方 API

    /// Issue #35：官方 API 区域（header 之后、basePicker 之前，首屏可见）。
    ///
    /// 契约：本区域不发起任何自动请求——没有 onAppear/task/onChange 触发刷新，
    /// 打开或切换村庄页面不会自动调用官方 API；数据获取仅由各卡片内按钮显式
    /// 触发（Task 1/2 已接入的 by-ID 路由，全部使用本视图的存储属性 `villageID`）。
    private func officialAPISection() -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // 玩家卡平铺（主诉求：进入详情页首屏即见）。
            OfficialPlayerCardView(villageID: villageID)

            // 部落 4 卡是二级信息：包在 DisclosureGroup 中默认折叠，
            // 避免首屏被 5 张卡片占满。
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 18) {
                    ClanCardView(villageID: villageID)
                    ClanWarCardView(villageID: villageID)
                    WarLogCardView(villageID: villageID)
                    CapitalRaidCardView(villageID: villageID)
                }
            } label: {
                Label("部落信息（official-api）", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
            }
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
        .onChange(of: selectedBase) { _, _ in
            // issue #37 验收：切换基地后不得残留成错误的空筛选
            selectedFilter = .all
        }
    }

    /// issue #37：展示分类（防御/军事/精制台）作为一级筛选维度，原分类兜底。
    /// 计数规则与分组键一致：display 组按 displayCategory 匹配；无细分项的
    /// category 组按原分类匹配；category 为 nil 的项归「其他」。
    /// issue #53：满级判定复用 completion 统计（key = completion.id），
    /// 与分组桶键天然一致；空分类（count 0）无 stats → 不显示勾。
    private func categoryFilterBar(
        groups: [VillageDetailGroup],
        total: VillageCategoryCompletion,
        statsByKey: [String: VillageCategoryCompletion]
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(
                    title: "全部",
                    count: groups.reduce(0) { $0 + $1.items.count },
                    filter: .all,
                    isFullyMaxed: total.isFullyMaxed
                )
                ForEach(TrackerDisplayCategory.allCases) { display in
                    let count = groups.first(where: { $0.displayCategory == display })?.items.count ?? 0
                    filterChip(
                        title: display.title,
                        count: count,
                        filter: .display(display),
                        isFullyMaxed: statsByKey[display.rawValue]?.isFullyMaxed ?? false
                    )
                }
                ForEach(TrackerCategory.allCases) { category in
                    let count = groups.first(where: { $0.displayCategory == nil && $0.category == category })?.items.count ?? 0
                    filterChip(
                        title: category.title,
                        count: count,
                        filter: .category(category),
                        isFullyMaxed: statsByKey[category.rawValue]?.isFullyMaxed ?? false
                    )
                }
                let otherCount = groups.first(where: { $0.displayCategory == nil && $0.category == nil })?.items.count ?? 0
                if otherCount > 0 {
                    filterChip(
                        title: "其他",
                        count: otherCount,
                        filter: .other,
                        isFullyMaxed: statsByKey["other"]?.isFullyMaxed ?? false
                    )
                }
            }
        }
    }

    /// issue #53：全部满级（isFullyMaxed）的 chip 以绿色 + 勾选图标呈现；
    /// 未满级路径与 issue #37 既有灰/蓝样式完全一致，不改变筛选语义与点击区域。
    private func filterChip(
        title: String,
        count: Int,
        filter: CategoryFilter,
        isFullyMaxed: Bool
    ) -> some View {
        let isSelected = selectedFilter == filter
        let foreground: Color
        let background: Color
        let countColor: Color
        if isFullyMaxed {
            foreground = isSelected ? Color.white : .green
            background = isSelected ? Color.green : Color.green.opacity(0.15)
            countColor = isSelected ? Color.white.opacity(0.8) : Color.green.opacity(0.8)
        } else {
            foreground = isSelected ? Color.white : Color.secondary
            background = isSelected ? Color.cocAccent : Color.white.opacity(0.06)
            countColor = isSelected ? Color.white.opacity(0.8) : .secondary
        }
        return Button {
            selectedFilter = filter
        } label: {
            let chip = HStack(spacing: 5) {
                Text(title)
                if count > 0 {
                    Text(String(count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(countColor)
                }
                if isFullyMaxed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(foreground)
                        // 纯装饰图标：不进辅助功能树，避免被误报为选中/多读一次。
                        .accessibilityHidden(true)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
            if isFullyMaxed {
                chip.accessibilityLabel("\(title) \(count) 全部满级")
            } else {
                chip
            }
        }
        .buttonStyle(.plain)
        // 显式声明筛选选中态（外部 review P2：勾选图标曾误报 selected，
        // 实际选中的 chip 反而无选中语义）。
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func filtered(_ groups: [VillageDetailGroup]) -> [VillageDetailGroup] {
        switch selectedFilter {
        case .all: return groups
        case .display(let dc): return groups.filter { $0.displayCategory == dc }
        case .category(let c): return groups.filter { VillageDetailProjection.matchesCategoryFilter($0, category: c) }
        case .other: return groups.filter { $0.displayCategory == nil && $0.category == nil }
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
                        group.displayCategory?.title ?? group.category?.title ?? "其他",
                        systemImage: group.displayCategory?.systemImage ?? group.category?.systemImage ?? "ellipsis.circle"
                    )
                    .font(.headline)
                    Spacer()
                    sectionCompletionLabel(stats: stats)
                }

                LazyVStack(spacing: 0) {
                    // issue #24：嵌套 types/modules 归入根父的「类型/模块」区域——
                    // 父项行正常展示，嵌套后代缩进平铺（保持输入相对顺序）。
                    let rows = VillageDetailProjection.parentedRows(from: group.items)
                    ForEach(rows) { row in
                        itemRow(row.item, group: group, now: now, village: village)
                        ForEach(row.children) { child in
                            Divider().padding(.leading, UpgradeDisplayLayout.listDividerLeading)
                            itemRow(child, group: group, now: now, village: village, indented: true)
                        }
                        if row.id != rows.last?.id {
                            Divider().padding(.leading, UpgradeDisplayLayout.listDividerLeading)
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
        village: VillageProfile,
        indented: Bool = false
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
            // 嵌套项缩进展示在根父行下（issue #24「类型/模块」区域）。
            .padding(.leading, indented ? UpgradeDisplayLayout.nestedIndent : 0)
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
        // issue #53：满级判定改用严格谓词 isFullyMaxed——known 全满但
        // unknownCount > 0（存在未知/未观测项）时不再标绿，与 chip 一致。
        let tint: Color = stats.isFullyMaxed ? .green : .secondary
        return Text(summary)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(tint)
    }

    private enum CategoryFilter: Hashable {
        case all
        case display(TrackerDisplayCategory)
        case category(TrackerCategory)
        case other
    }
}
