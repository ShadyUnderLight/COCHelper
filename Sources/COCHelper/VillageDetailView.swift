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
    // Issue #61：快捷「粘贴并更新」的确认 sheet 与失败提示载体。
    // prepareQuickImport 是纯函数（不写状态），结果分派到这两个载体之一。
    @State private var quickImportPreview: QuickImportPreview?
    @State private var quickImportError: QuickImportError?

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
        // Issue #61：快捷「粘贴并更新」预览确认 sheet（复用账号数据页的
        // AccountSnapshotSummaryView，经注入参数展示快捷导入的目标与文案）。
        .sheet(item: $quickImportPreview) { preview in
            QuickImportSheet(
                preview: preview,
                onConfirm: {
                    model.applyQuickImport(preview)
                    quickImportPreview = nil
                },
                onCancel: {
                    quickImportPreview = nil
                }
            )
        }
        // Issue #61：快捷导入失败提示（剪贴板空 / 解析失败 / 村庄缺失 /
        // 误覆盖拦截），错误文案由 QuickImportError（LocalizedError）提供。
        .alert(
            "粘贴并更新失败",
            isPresented: Binding(
                get: { quickImportError != nil },
                set: { if !$0 { quickImportError = nil } }
            ),
            presenting: quickImportError
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }

    /// Issue #49 验收阅读顺序：首屏自上而下为「玩家昵称与身份（header）→
    /// 玩家信息（officialAPISection）→ 完成度/升级列表（completionBar →
    /// basePicker → 分类筛选 → 分组列表）」。完成度条位于官方玩家信息之后、
    /// 基地选择之前。
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
        // Issue #45：同类建筑组卡投影（buildings/buildings2 原始记录层）。
        // 与 VillageCatalogProjection.project 并行调用：聚合层（agg: 前缀记录）
        // 继续供完成度/诊断/筛选使用，组卡基于原始记录层，两者语义互不影响。
        let buildingGroups = BuildingGroupProjection.project(
            village: village, catalog: catalog, base: selectedBase, now: now
        )
        // 原始快照记录 id → 组。BuildingInstance.id 与 VillageItemState.id 同源
        //（同一条快照记录），但聚合层记录 id 带 agg: 前缀，查找键需归一化
        //（rawRecordID）。快照记录 id 全局唯一，字典 1:1。
        let groupByInstanceID = Dictionary(
            buildingGroups.flatMap { group in group.instances.map { ($0.id, group) } },
            uniquingKeysWith: { first, _ in first }
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(village: village, projection: projection, now: now)
                officialAPISection()
                completionBar(total: total)
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
                        sectionCard(
                            group: group,
                            now: now,
                            stats: statsByKey[group.id],
                            village: village,
                            groupByInstanceID: groupByInstanceID
                        )
                    }
                }
            }
            // 撑满窗口宽度：ScrollView 内 VStack(alignment: .leading) 默认按内容
            // 理想宽度布局（实测 1180pt 窗口内容只占 ~600pt，右侧大片空白）；
            // 官方玩家卡等自适布局依赖完整提议宽度（Issue #49 窗口级验收）。
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Issue #49 Task 3：头部身份投影（昵称优先）。
    ///
    /// 头部只含身份信息（昵称主标题、tag 行、本地别名、快照时间、目录版本、
    /// 更新按钮、诊断行）；完成度条不在头部内——#49 验收顺序要求它在官方玩家
    /// 信息之后（见 detailContent 的阅读顺序契约）。
    ///
    /// `now` 来自外层 `TimelineView(.periodic)` 的 `context.date`（detailContent 在
    /// TimelineView 内），投影 `at:` 用它而非默认 `Date()`——stale 派生随 60s tick
    /// 重算，跨过 24h 阈值后头部在下一分钟即可翻转为「已过期」；升级总览头部与
    /// 账号数据页身份行同规则（#49 评审 P2 修复）。
    private func header(
        village: VillageProfile,
        projection: VillageCatalogProjection,
        now: Date
    ) -> some View {
        let identity = VillageDisplayIdentityProjection.project(
            village: village,
            officialState: village.officialAPIState,
            at: now
        )
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    // 主标题 = 玩家昵称（官方昵称 → 本地名 → tag → 未命名村庄），
                    // 单行截断，不挤压右侧按钮（与升级总览头部一致）。
                    Text(identity.primaryName)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    // 第二行：tag · 官方来源/状态（stale/failed/fallback 文案与
                    // 侧边栏、升级总览头部共用同一 helper）。
                    Text(VillageIdentityDisplayText.tagLineText(
                        identity: identity,
                        fallback: "尚未导入账号 JSON"
                    ))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // 官方昵称存在且与本地名不同：保留本地命名，不丢用户信息（#49 评审坑点）。
                    if let alias = identity.localAlias {
                        Text("本地别名：" + alias)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        // Issue #49 评审 P2：无官方昵称（本地名/tag/未命名回退）时
                        // 明确标出"待获取昵称"，与侧边栏同语义（别名与标记互斥：
                        // 别名只在 source == .officialName 时出现）。
                        VillageIdentityDisplayText.nicknamePendingMarkerView(identity: identity)
                    }
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
                // Issue #61：快捷「粘贴并更新」——剪贴板 JSON 直接预览并
                // 更新当前村庄，免去「账号数据 → 粘贴 → 解析 → 确认」流程。
                Button(action: prepareQuickImport) {
                    Label("粘贴并更新", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
                Button(action: openImport) {
                    Label("更新快照", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .tint(Color.cocAccent)
            }

            diagnosticsNote(projection)
        }
    }

    // MARK: - 快捷导入（Issue #61）

    /// Issue #61：从剪贴板解析并预览针对当前村庄的快捷导入。
    /// 成功 → 弹出确认 sheet（quickImportPreview）；失败 → alert
    /// （quickImportError）。prepareQuickImport 是纯函数（数据层无副作用），
    /// 本方法只做结果分派，不额外读写模型状态。
    private func prepareQuickImport() {
        switch model.prepareQuickImport(for: villageID) {
        case .success(let preview):
            quickImportPreview = preview
        case .failure(let error):
            quickImportError = error
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
                Label("部落信息（官方 API 数据）", systemImage: "shield.lefthalf.filled")
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

    /// 分组卡片：标题 + 完成度（保持现状）；内容按展示分类分派（Issue #45）——
    /// 精制台整组走旧列表（父子缩进），其余组（buildings/buildings2 平铺记录）
    /// 接入组卡，无组卡归属的 items（防御性兜底）继续走旧行。
    private func sectionCard(
        group: VillageDetailGroup,
        now: Date,
        stats: VillageCategoryCompletion?,
        village: VillageProfile,
        groupByInstanceID: [String: BuildingGroup]
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

                if group.displayCategory == .craftTable {
                    // 精制台：整组走旧列表（issue #24 父子缩进），不接入组卡。
                    legacyRows(items: group.items, group: group, now: now, village: village)
                } else {
                    groupedRows(
                        items: group.items,
                        group: group,
                        groupByInstanceID: groupByInstanceID,
                        now: now,
                        village: village
                    )
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

    /// Issue #45：非精制台分组的组卡内容。有组归属的 items 按 BuildingGroup 聚类
    /// 渲染组卡（组按 items 首现顺序，组内实例保持快照输入序），无归属的 items
    ///（防御性兜底：未知 section 项、嵌套后代等）走旧列表行，统一放在组卡下方。
    /// 聚合行与组卡实例数量可能不同（如同等级墙聚合为 1 行 ×N，组卡按原始记录
    /// 逐实例展示），chips 计数仍按聚合口径，已知外观差异（Task 4 验证）。
    private func groupedRows(
        items: [VillageItemState],
        group: VillageDetailGroup,
        groupByInstanceID: [String: BuildingGroup],
        now: Date,
        village: VillageProfile
    ) -> some View {
        var orderedGroups: [BuildingGroup] = []
        var seenGroupIDs = Set<String>()
        var fallbackItems: [VillageItemState] = []
        for item in items {
            if let buildingGroup = groupByInstanceID[Self.rawRecordID(item.id)] {
                if !seenGroupIDs.contains(buildingGroup.id) {
                    seenGroupIDs.insert(buildingGroup.id)
                    orderedGroups.append(buildingGroup)
                }
            } else {
                fallbackItems.append(item)
            }
        }

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(orderedGroups) { buildingGroup in
                BuildingGroupCard(group: buildingGroup) { instance in
                    selectedItem = instance.item
                }
            }
            if !fallbackItems.isEmpty {
                legacyRows(items: fallbackItems, group: group, now: now, village: village)
            }
        }
    }

    /// 旧列表行（精制台整组 / 无组卡归属的兜底 items）：issue #24 父子缩进平铺。
    private func legacyRows(
        items: [VillageItemState],
        group: VillageDetailGroup,
        now: Date,
        village: VillageProfile
    ) -> some View {
        LazyVStack(spacing: 0) {
            // issue #24：嵌套 types/modules 归入根父的「类型/模块」区域——
            // 父项行正常展示，嵌套后代缩进平铺（保持输入相对顺序）。
            let rows = VillageDetailProjection.parentedRows(from: items)
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

    /// 聚合记录 id 归一化：`agg:` 前缀 → 原始快照记录 id。VillageDetailProjection
    /// 的 items 来自聚合层（aggregate 对静态记录统一加 agg: 前缀），而
    /// BuildingGroupProjection 的实例 id 是原始记录层 id——查找键不归一化会
    /// 全部 miss，组卡只剩升级中记录（Issue #45 组卡聚类键）。
    /// 剥离安全前提：原始快照 id 由解析器生成为 `section:path` 形态
    /// （AccountSnapshot），结构上不可能以 `agg:` 开头，故剥离只映射聚合行
    /// 回其源记录，不会误伤原始 id。
    private static func rawRecordID(_ id: String) -> String {
        id.hasPrefix("agg:") ? String(id.dropFirst(4)) : id
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

/// Issue #61：快捷「粘贴并更新」的确认 sheet。
///
/// 复用账号数据页的 `AccountSnapshotSummaryView`（同一预览组件、同一视觉）：
/// 通过注入参数展示快捷导入的目的地描述、确认标题与确认/放弃动作。
/// 快捷导入直接写入目标村庄，不经过 AppModel 的 pendingAccountSnapshot
/// 待确认流程——注入的 onConfirm 由 VillageDetailView 负责执行
/// `applyQuickImport` 并关闭 sheet。`model` 经 @EnvironmentObject 从
/// VillageDetailView 环境继承（AppModel 在根部注入）。
private struct QuickImportSheet: View {
    /// 快捷导入预览（目标村庄、解析结果、目的地描述）。
    let preview: QuickImportPreview
    /// 确认按钮动作（外部负责 applyQuickImport 并关闭 sheet）。
    let onConfirm: () -> Void
    /// 放弃按钮动作（外部负责关闭 sheet）。
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("粘贴并更新")
                    .font(.title2.weight(.bold))
                AccountSnapshotSummaryView(
                    snapshot: preview.snapshot,
                    isPending: true,
                    destinationDescription: preview.destinationDescription,
                    confirmTitle: preview.confirmationTitle,
                    onConfirm: onConfirm,
                    onCancel: onCancel
                )
            }
            .padding(24)
            // 宽度上限 560pt：预览内容较窄时自适应，不撑满整个窗口
            //（与 LevelDetailSheet 的固定 minWidth 520 同一量级）。
            .frame(maxWidth: 560, alignment: .leading)
        }
        .background(Color.cocBackground)
        // macOS sheet 需显式最小尺寸（与 LevelDetailSheet 同一量级）。
        .frame(minWidth: 480, minHeight: 420)
    }
}
