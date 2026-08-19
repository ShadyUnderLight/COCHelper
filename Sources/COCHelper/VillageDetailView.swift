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
    /// Optional injection seam for the #142 store. Keeping this value outside
    /// `VillageProfile` preserves the raw snapshot/manual-storage boundary.
    var manualUpgradeCore: ManualUpgradeCore? = nil

    @State private var selectedBase: TrackerBase = .home
    @State private var selectedFilter: CategoryFilter = .all
    @State private var selectedHistoryCategory: SnapshotHistoryCategory = .all
    @State private var selectedItem: VillageItemState?
    // Issue #144：搜索 / 状态筛选 / 排序（纯投影消费，不重跑解析）。
    @State private var searchText = ""
    @State private var stateFilter: UpgradeDisplayStateFilter?
    @State private var sortOrder: UpgradeDisplaySort = .categoryName
    @State private var actionSheet: ManualUpgradeActionSheet?
    // Issue #145：本地队列容量配置面板。
    @State private var showQueueCapacitySettings = false
    // Issue #183：导入观察的本地队列映射面板。
    @State private var showQueueAssignmentSettings = false
    // Issue #61：快捷「粘贴并更新」的确认 sheet 与失败提示载体。
    // prepareQuickImport 是纯函数（不写状态），结果分派到这两个载体之一。
    @State private var quickImportPreview: QuickImportPreview?
    @State private var quickImportError: QuickImportError?

    private var village: VillageProfile? {
        model.villages.first(where: { $0.id == villageID })
    }

    private var catalog: GameCatalog? { model.gameCatalog }
    private var seasonalPhases: SeasonalPhaseTable { model.seasonalPhases }
    private var craftTableCatalog: CraftTableCatalog? { model.craftTableCatalog }

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
        // Issue #144：手动升级动作确认面板。
        .sheet(item: $actionSheet) { sheet in
            ManualUpgradeActionSheetView(
                sheet: sheet,
                villageID: villageID,
                onDone: { actionSheet = nil }
            )
        }
        // Issue #145：本地队列容量配置。
        .sheet(isPresented: $showQueueCapacitySettings) {
            ManualQueueCapacitySettingsView(
                villageID: villageID,
                onDone: { showQueueCapacitySettings = false }
            )
        }
        // Issue #183：导入观察的本地队列映射。
        .sheet(isPresented: $showQueueAssignmentSettings) {
            QueueAssignmentSettingsView(
                villageID: villageID,
                onDone: { showQueueAssignmentSettings = false }
            )
        }
        // Issue #61：快捷「粘贴并更新」预览确认 sheet（复用账号数据页的
        // AccountSnapshotSummaryView，经注入参数展示快捷导入的目标与文案）。
        .sheet(item: $quickImportPreview) { preview in
            QuickImportSheet(
                preview: preview,
                onConfirm: {
                    if model.applyQuickImport(preview) {
                        quickImportPreview = nil
                    } else {
                        quickImportError = .historyUnavailable(
                            model.snapshotHistoryError ?? "历史存储不可用，导入未提交。"
                        )
                        quickImportPreview = nil
                    }
                },
                onApplyDecision: { decision in
                    if model.applyQuickImport(preview, decision: decision) {
                        quickImportPreview = nil
                    } else {
                        quickImportError = .historyUnavailable(
                            model.snapshotHistoryError ?? "历史存储不可用，导入未提交。"
                        )
                        quickImportPreview = nil
                    }
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
    /// 玩家信息（officialAPISection）→ 完成度/升级列表（metricsBar →
    /// basePicker → 分类筛选 → 分组列表）」。完成度条位于官方玩家信息之后、
    /// 基地选择之前。
    private func detailContent(village: VillageProfile, now: Date) -> some View {
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: catalog,
            seasonalPhases: seasonalPhases,
            // Issue #98 审核 F1：嵌套精工防御（主目录不 join）回查精制台目录
            // lifecycle 声明，与精制台投影同口径（防同一防御两投影漂移）。
            craftTableCatalog: craftTableCatalog,
            base: selectedBase,
            now: now,
            manualUpgradeCore: manualUpgradeCore
        )
        // 与升级总览（UpgradeOverviewProjection.allRecords）口径一致：
        // decos/helpers/obstacles 等不参与升级追踪的类别不展示、不计入完成度。
        let trackedItems = projection.items.filter { $0.status != .unavailable }
        // Issue #70 阶段 2：消费拆分——列表/筛选/组卡用「已观测项」（排除
        // 宇宙差集 .available，保持 UI 只显示快照中存在的项目）；三指标
        // 消费「含宇宙差集」数组（完整分母/完整覆盖率）。
        let displayItems = trackedItems.filter { $0.status != .available }
        // Issue #144：search/state/sort 纯投影筛选（不重跑解析/reconcile）。
        let filteredDisplayItems = UpgradeActionProjection.filtered(
            displayItems,
            filter: UpgradeDisplayFilter(
                state: stateFilter,
                text: searchText,
                sort: sortOrder
            ),
            at: now
        )
        let groups = VillageDetailProjection.groups(from: filteredDisplayItems)
        // 目录不可用或版本不匹配时（projection.catalogIsUsable == false）：
        // issue #16「不纳入可确认完成度」——完成度全部归未知，不显示百分比。
        let total = VillageDetailProjection.totalCompletion(
            from: filteredDisplayItems,
            catalogIsUsable: projection.catalogIsUsable
        )
        // Issue #70：三指标（当前阶段进度 / 全局养成进度 / 观测数据完整性）。
        // Issue #96：消费 trackedItems（含宇宙差集 .available），coverage 按
        // projection.progressCoverage 传参——仅 .complete 时 stage/global
        // 分母 = known ∪ 差集（完整分母）；partial/unavailable → 已观测口径 +
        // 覆盖诊断；覆盖率为完整覆盖率；列表口径（displayItems）与指标
        // 口径分离（决策 3）。
        let progressMetrics = projection.progressMetrics
        let statsByKey = Dictionary(
            uniqueKeysWithValues: VillageDetailProjection.completionStats(
                from: filteredDisplayItems,
                catalogIsUsable: projection.catalogIsUsable
            )
                .map { ($0.id, $0) }
        )
        let displayGroups = filtered(groups)
        // 分组 id 集合：数据变化（重新导入快照、切换基地等）后用于校正筛选，
        // 不得残留成错误的空筛选（issue #37 验收）。
        let groupIDs = groups.map(\.id)
        // Issue #45/#140：同类建筑组卡复用同一有效村庄投影的 rawItems，
        // 不重新从 snapshot 推导 prerequisite、lifecycle 或 manual 状态。
        let buildingGroups = BuildingGroupProjection.project(
            projection: projection,
            catalog: catalog,
            base: selectedBase,
            manualUpgradeCore: manualUpgradeCore
        )
        let craftTable = CraftTableProjection.project(
            village: village,
            catalog: craftTableCatalog,
            base: selectedBase,
            seasonalPhases: seasonalPhases,
            now: now
        )
        // 原始快照记录 id → 组。BuildingInstance.id 与 VillageItemState.id 同源
        //（同一条快照记录），但聚合层记录 id 带 agg: 前缀，查找键需归一化
        //（rawRecordID）。快照记录 id 全局唯一，字典 1:1。
        let groupByInstanceID = Dictionary(
            buildingGroups.flatMap { group in group.instances.map { ($0.id, group) } },
            uniquingKeysWith: { first, _ in first }
        )
        let historyProjection = model.snapshotHistoryProjection(
            for: villageID,
            category: selectedHistoryCategory,
            at: now
        )
        // Issue #144：行级 canonical action（嵌套项/Craft Table 只读 → 无 action）。
        let actionsByItemID = Dictionary(
            uniqueKeysWithValues: filteredDisplayItems.compactMap { item -> (String, UpgradeAction)? in
                guard let action = UpgradeActionProjection.action(
                    for: item,
                    catalog: catalog,
                    catalogIsUsable: projection.catalogIsUsable,
                    manualUpgradeCore: manualUpgradeCore,
                    coverage: UpgradeActionProjection.coverage(
                        for: item,
                        progressCoverage: projection.progressCoverage
                    ),
                    now: now
                ) else { return nil }
                return (item.id, action)
            }
        )

        // Issue #199：扁平 render rows——组头卡 / 实例块 / 旧行都是外层
        // LazyVStack 的独立行（稳定 ID = 投影/快照 ID，不用 offset/UUID），
        // 60s tick / 筛选 / 排序切换时只构建可见行；1000+ 实例场景不会
        // 一次构建全部 offscreen 行（嵌套 LazyVStack 会被完全展开，故必须扁平）。
        let detailRows = buildDetailRows(
            displayGroups: displayGroups,
            statsByKey: statsByKey,
            groupByInstanceID: groupByInstanceID,
            craftTable: craftTable
        )

        return ScrollView {
            // 根容器 LazyVStack + spacing 0：固定 section 用底部 padding 分隔，
            // 扁平行用自身 padding / Divider 保持原有间距与分隔线语义。
            LazyVStack(alignment: .leading, spacing: 0) {
                header(village: village, projection: projection, now: now)
                    .padding(.bottom, 18)
                officialAPISection()
                    .padding(.bottom, 18)
                SnapshotHistoryView(
                    projection: historyProjection,
                    selectedCategory: $selectedHistoryCategory
                )
                .padding(.bottom, 18)
                metricsBar(metrics: progressMetrics, coverage: projection.progressCoverage)
                    .padding(.bottom, 18)
                basePicker()
                    .padding(.bottom, 18)
                categoryFilterBar(groups: groups, total: total, statsByKey: statsByKey)
                    .padding(.bottom, 18)
                manualUpgradeFilterBar()
                    .padding(.bottom, 18)

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
                    ForEach(detailRows) { row in
                        renderDetailRow(
                            row,
                            now: now,
                            village: village,
                            metrics: progressMetrics,
                            actionsByItemID: actionsByItemID
                        )
                    }
                }
            }
            // 撑满窗口宽度：LazyVStack 内与旧 VStack 同语义——
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
                            // Issue #74a：无玩家 build 时明确「未验证」，不得伪装已匹配。
                            Text("目录 v" + version
                                + (projection.compatibility.isUnverified ? " · 未验证" : ""))
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

    /// Issue #70：三指标卡（当前阶段进度 / 全局养成进度 / 观测数据完整性）。
    /// 每个指标显示名称、百分比、分子/分母（带单位）与降级文案；saturated
    /// 优先于 state 文案（fail-closed，数值不权威时显示异常而非百分比）。
    /// Issue #96：`coverage` = 投影的 progressCoverage，决定覆盖率行 help
    /// 文案口径——三分支（complete / partial / unavailable），措辞共享
    /// `ProgressUniverseCoverage.helpText`（Core 单一来源，防漂移）。
    private func metricsBar(metrics: VillageProgressMetrics, coverage: ProgressUniverseCoverage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 决策 7 标题回退：完整分母（coverage.isComplete）后，
            // stage/global 分母 = known ∪ 宇宙差集，不再是「已观测」口径——
            // 标题回退为「当前阶段进度/全局养成进度」。
            metricRow(metrics.currentStageProgress, title: "当前阶段进度")
            metricRow(metrics.globalProgress, title: "全局养成进度")
            // Issue #96：覆盖率分母随覆盖状态三分支变化——complete 时含宇宙
            // 差集（已观测占全部可建造）；partial 时差集仅覆盖建筑/陷阱
            //（分母 = 全部类别已观测 ∪ 建筑/陷阱差集；未建模类别只计观测，
            // 不得称为「已建模可建造」——P1 口径契约，见 helpText）；unavailable
            // 无差集（纯已观测）——help 文案必须跟随口径，否则误导（验收 3）。
            // Issue #110：coverage 非 complete（partial/unavailable）时标题为
            //「已观测数据关联率」——语义是已观测范围的关联率，不得再宣称
            //「完整性」（complete 才代表全量可建造口径）。
            metricRow(
                metrics.snapshotCoverage,
                title: coverage.isComplete ? "观测数据完整性" : "已观测数据关联率"
            )
            .help(coverage.helpText)
            if let notice = metricsNotice(metrics: metrics, coverage: coverage) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                    Text(notice.summary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(notice.details)
            }
        }
        .padding(12)
        .background(Color.cocAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metricRow(_ metric: ProgressMetric, title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: UpgradeDisplayLayout.metricRowTitleWidth, alignment: .leading)
            if metric.saturated {
                Text("数据异常（超出可表示范围）")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let ratio = metric.ratio {
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .tint(Color.cocAccent)
                    .frame(maxWidth: UpgradeDisplayLayout.metricProgressMaxWidth)
                Text(String(Int((ratio * 100).rounded())) + "%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.cocAccent)
                    .frame(width: UpgradeDisplayLayout.metricPercentWidth, alignment: .trailing)
                Text(String(metric.numerator) + " / " + String(metric.denominator) + " " + metric.units)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(degradedText(for: metric))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 诊断在卡片底部统一展示，避免同一组原因在三个指标行重复出现；完整
    /// 原因保留在悬停说明中，便于需要核对数据口径时查看。
    private func metricsNotice(
        metrics: VillageProgressMetrics,
        coverage: ProgressUniverseCoverage
    ) -> (summary: String, details: String)? {
        let reasons = [
            metrics.currentStageProgress.degradedReason,
            metrics.globalProgress.degradedReason,
            metrics.snapshotCoverage.degradedReason,
        ]
        .compactMap { $0 }
        .reduce(into: [String]()) { unique, reason in
            if !unique.contains(reason) {
                unique.append(reason)
            }
        }
        guard !reasons.isEmpty else { return nil }

        let hasUnavailableMetric = [
            metrics.currentStageProgress,
            metrics.globalProgress,
            metrics.snapshotCoverage,
        ].contains { $0.state == .unavailable }

        let summary: String
        if hasUnavailableMetric {
            summary = "当前目录或快照数据不足，以上指标暂无法完整确认。"
        } else if !coverage.isComplete {
            summary = "以上进度基于当前已观测数据，暂不代表完整村庄进度。"
        } else {
            summary = "部分项目数据尚未核验，以上百分比仅供参考。"
        }

        let details = ([coverage.helpText] + reasons).joined(separator: "\n")
        return (summary: summary, details: details)
    }

    /// 不可计算状态文案（unknown/unavailable；saturated 已在 metricRow 提前处理）。
    /// 单一来源：直接复用 Core 的 degradedReason（unavailable/unknown 时恒非 nil），
    /// 避免 UI 手写文案与 Core 漂移（曾漏句号）；?? 兜底仅防御不可达组合。
    private func degradedText(for metric: ProgressMetric) -> String {
        switch metric.state {
        // ready/partial 时 ratio 非 nil，UI 走 ratio 分支，本分支不可达；
        // 防御性兜底。
        case .ready, .partial: return "—"
        case .unavailable, .unknown: return metric.degradedReason ?? "暂无法计算该指标"
        }
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
        // 玩家卡平铺（主诉求：进入详情页首屏即见）。
        OfficialPlayerCardView(villageID: villageID)
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

    /// issue #37：展示分类（防御/城墙/军事/精制台）作为一级筛选维度，原分类兜底。
    /// 计数规则与分组键一致：display 组按 displayCategory 匹配；无细分项的
    /// category 组按原分类匹配；category 为 nil 的项归「其他」。
    /// issue #53：满级判定复用 completion 统计（key = completion.id），
    /// 与分组桶键天然一致；空分类（count 0）无 stats → 不显示勾。
    /// issue #66：chip 数字为实例权重数（聚合行按 count 计入，如 300 块城墙
    /// 显示 300 而非 1 行），由 completionStats 派生：known + unknown（守恒
    /// → 实例权重数，catalogIsUsable=false 时同样成立），不重复手写分组谓词。
    /// 「其他」chip 的 `otherCount > 0` 显隐判断依赖权重 ≥ 1 不变量（非空组
    /// 实例数 ≥ 1）；勿改回行数 `items.count`。
    /// 独立饱和后 known + unknown 可能溢出（两条 Int.max 相加），计数经
    /// `chipInstanceCount` 饱和加法兜底（issue #66 边界 3：UI 不崩溃）。
    private func categoryFilterBar(
        groups: [VillageDetailGroup],
        total: VillageCategoryCompletion,
        statsByKey: [String: VillageCategoryCompletion]
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(
                    title: "全部",
                    count: chipInstanceCount(total),
                    filter: .all,
                    isFullyMaxed: total.isFullyMaxed
                )
                ForEach(TrackerDisplayCategory.allCases) { display in
                    let count = chipInstanceCount(statsByKey[display.rawValue])
                    filterChip(
                        title: display.title,
                        count: count,
                        filter: .display(display),
                        isFullyMaxed: statsByKey[display.rawValue]?.isFullyMaxed ?? false
                    )
                }
                ForEach(TrackerCategory.allCases) { category in
                    let count = chipInstanceCount(statsByKey[category.rawValue])
                    filterChip(
                        title: category.title,
                        count: count,
                        filter: .category(category),
                        isFullyMaxed: statsByKey[category.rawValue]?.isFullyMaxed ?? false
                    )
                }
                let otherCount = chipInstanceCount(statsByKey["other"])
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

    /// chip 实例数 = known + unknown；独立饱和后可能溢出，用饱和加法兜底（issue #66）。
    private func chipInstanceCount(_ stats: VillageCategoryCompletion?) -> Int {
        guard let stats else { return 0 }
        let (sum, overflow) = stats.knownCount.addingReportingOverflow(stats.unknownCount)
        return overflow ? Int.max : sum
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

    /// Issue #199：详情页扁平 render row。全部作为外层 LazyVStack 的独立行
    /// 虚拟化；稳定 ID = 投影/快照 ID（禁止 offset / UUID——跨分页/筛选不变）。
    private enum DetailFlatRow: Identifiable {
        /// 非精制台 section 头部：标题 + 完成度（Panel）。
        case sectionHeader(group: VillageDetailGroup, stats: VillageCategoryCompletion?)
        /// 精制台整组：标题 + 表格保留单 Panel 外观。
        case craftTable(group: VillageDetailGroup, defenses: [CraftTableDefenseState])
        /// 组头卡：`BuildingGroupSummaryView` 汇总 + Start/Cancel/Adjust 动作行。
        case groupHeader(group: BuildingGroup)
        /// 单实例块：实例行 + 该记录自己的升级阶梯（leadingDivider = 组内非首个）。
        case instance(group: BuildingGroup, instance: BuildingInstance, leadingDivider: Bool)
        /// 旧列表行（issue #24 父子缩进平铺；leadingDivider = 非 section 内首行）。
        case legacy(item: VillageItemState, group: VillageDetailGroup, indented: Bool, leadingDivider: Bool)

        var id: String {
            switch self {
            case .sectionHeader(let group, _): return "section:\(group.id)"
            case .craftTable(let group, _): return "craft:\(group.id)"
            case .groupHeader(let group): return "groupHeader:\(group.id)"
            case .instance(let group, let instance, _): return "instance:\(group.id):\(instance.id)"
            case .legacy(let item, _, _, _): return "legacy:\(item.id)"
            }
        }
    }

    /// 扁平 render rows 构建：保持旧 sectionCard/groupedRows/legacyRows 的
    /// 顺序与分隔线语义（组按 items 首现顺序、实例按快照输入序、父项先于
    /// 缩进子项），只是把「面板嵌套」改为同一 LazyVStack 的独立行。
    private func buildDetailRows(
        displayGroups: [VillageDetailGroup],
        statsByKey: [String: VillageCategoryCompletion],
        groupByInstanceID: [String: BuildingGroup],
        craftTable: [CraftTableDefenseState]
    ) -> [DetailFlatRow] {
        var rows: [DetailFlatRow] = []
        for group in displayGroups {
            if group.displayCategory == .craftTable {
                rows.append(.craftTable(group: group, defenses: craftTable))
                continue
            }
            rows.append(.sectionHeader(group: group, stats: statsByKey[group.id]))

            var orderedGroups: [BuildingGroup] = []
            var seenGroupIDs = Set<String>()
            var fallbackItems: [VillageItemState] = []
            for item in group.items {
                if let buildingGroup = groupByInstanceID[Self.rawRecordID(item.id)] {
                    if !seenGroupIDs.contains(buildingGroup.id) {
                        seenGroupIDs.insert(buildingGroup.id)
                        orderedGroups.append(buildingGroup)
                    }
                } else {
                    fallbackItems.append(item)
                }
            }
            for buildingGroup in orderedGroups {
                rows.append(.groupHeader(group: buildingGroup))
                for (index, instance) in buildingGroup.instances.enumerated() {
                    rows.append(.instance(
                        group: buildingGroup,
                        instance: instance,
                        leadingDivider: index > 0
                    ))
                }
            }
            // issue #24：嵌套 types/modules 归入根父的「类型/模块」区域——
            // 父项行正常展示，嵌套后代缩进平铺（保持输入相对顺序）。
            let parented = VillageDetailProjection.parentedRows(from: fallbackItems)
            for (index, row) in parented.enumerated() {
                rows.append(.legacy(
                    item: row.item, group: group,
                    indented: false, leadingDivider: index > 0
                ))
                for child in row.children {
                    rows.append(.legacy(
                        item: child, group: group,
                        indented: true, leadingDivider: true
                    ))
                }
            }
        }
        return rows
    }

    /// 扁平 render row 渲染：section 头部 / 组头卡带 Panel，实例块与旧行
    /// 用自身 padding 对齐 Panel 内容（水平 18pt），分隔线语义与旧实现一致。
    @ViewBuilder
    private func renderDetailRow(
        _ row: DetailFlatRow,
        now: Date,
        village: VillageProfile,
        metrics: VillageProgressMetrics,
        actionsByItemID: [String: UpgradeAction]
    ) -> some View {
        switch row {
        case .sectionHeader(let group, let stats):
            Panel {
                sectionTitleRow(group: group, stats: stats)
            }
            .padding(.top, 18)
        case .craftTable(let group, let defenses):
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitleRow(group: group, stats: nil)
                    CraftTableView(
                        defenses: defenses,
                        catalogVersion: craftTableCatalog?.gameVersion
                    )
                }
            }
            .padding(.top, 18)
        case .groupHeader(let group):
            groupHeaderRow(group)
                .padding(.top, 10)
        case .instance(let group, let instance, let leadingDivider):
            // 实例块是扁平行：外层 VStack + 水平 18pt 对齐旧 Panel 内容缩进，
            // 组内非首个实例前加分隔线（与旧 instanceList 语义一致）。
            VStack(alignment: .leading, spacing: 0) {
                if leadingDivider {
                    Divider()
                }
                instanceBlock(group: group, instance: instance, now: now)
            }
            .padding(.horizontal, 18)
        case .legacy(let item, let group, let indented, let leadingDivider):
            // 旧行：水平 18pt 对齐 Panel 内容；父项间/子项前分隔线缩进
            // listDividerLeading（issue #24 语义）；section 内首行补 10pt 间距。
            VStack(alignment: .leading, spacing: 0) {
                if leadingDivider {
                    Divider().padding(.leading, UpgradeDisplayLayout.listDividerLeading)
                }
                itemRow(
                    item, group: group, now: now, village: village,
                    metrics: metrics, actionsByItemID: actionsByItemID,
                    indented: indented
                )
                .padding(.top, leadingDivider ? 0 : 10)
            }
            .padding(.horizontal, 18)
        }
    }

    /// section 标题行：标题 + 完成度（旧 sectionCard 头部）。
    private func sectionTitleRow(
        group: VillageDetailGroup,
        stats: VillageCategoryCompletion?
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(
                group.displayCategory?.title ?? group.category?.title ?? "其他",
                systemImage: group.displayCategory?.systemImage ?? group.category?.systemImage ?? "ellipsis.circle"
            )
            .font(.headline)
            Spacer()
            sectionCompletionLabel(stats: stats)
        }
    }

    /// 组头卡：`BuildingGroupSummaryView` 汇总 + Start/Cancel/Adjust 动作行
    ///（旧 BuildingGroupCard 的 Panel 部分，实例区改为扁平行）。
    private func groupHeaderRow(_ group: BuildingGroup) -> some View {
        let startActions = UpgradeActionProjection.actions(for: group, catalog: catalog)
        let activeRecords = group.trackerState.activeRecords
        return Panel {
            VStack(alignment: .leading, spacing: 8) {
                BuildingGroupSummaryView(group: group)
                if !startActions.isEmpty || !activeRecords.isEmpty {
                    Divider()
                    groupActionRow(
                        group: group,
                        startActions: startActions,
                        activeRecords: activeRecords
                    )
                }
            }
        }
    }

    /// 组级动作行（旧 BuildingGroupCard.actionRow）：聚合 action v1 一次启动
    /// 一个实例；active 记录提供 Cancel/Adjust。
    private func groupActionRow(
        group: BuildingGroup,
        startActions: [UpgradeAction],
        activeRecords: [ManualUpgradeRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("本地升级")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(startActions, id: \.id) { action in
                    if action.isStartable {
                        Button("开始升级 " + Self.levelLabel(action)) {
                            actionSheet = .start(action)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("开始升级 " + group.name + " " + Self.levelLabel(action))
                    } else {
                        Button("开始升级 " + Self.levelLabel(action)) {}
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(true)
                            .help(action.disabledReason ?? "不可启动")
                    }
                }
                let diagnostics = group.trackerState.diagnostics
                if !diagnostics.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(diagnostics.joined(separator: "\n"))
                }
                Spacer()
            }
            if !activeRecords.isEmpty {
                HStack(spacing: 8) {
                    Text("进行中")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(activeRecords) { record in
                        Text("Lv \(record.fromLevel) → \(record.targetLevel)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("取消") {
                            actionSheet = .cancel(record)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("取消升级 " + group.name + " " + Self.levelLabel(record))
                        Button("调整时间") {
                            actionSheet = .adjust(record)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("调整开始时间 " + group.name + " " + Self.levelLabel(record))
                    }
                    Spacer()
                }
            }
        }
    }

    private static func levelLabel(_ record: ManualUpgradeRecord) -> String {
        "\(record.fromLevel) → \(record.targetLevel)"
    }

    private static func levelLabel(_ action: UpgradeAction) -> String {
        guard let from = action.fromLevel, let target = action.targetLevel else { return "" }
        return "\(from) → \(target)"
    }

    /// 单实例块：头部行（Button → 打开 LevelDetailSheet）+ 该记录自己的阶梯
    /// 网格（per-record 阶梯，跨实例并集会破坏语义，Issue #45 验收）。
    private func instanceBlock(
        group: BuildingGroup,
        instance: BuildingInstance,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            instanceRow(group: group, instance: instance, now: now)
            Divider()
            // 缩进与头部图标列对齐（24pt 图标 + 10pt spacing）。
            BuildingUpgradeStepGrid(steps: instance.steps, item: instance.item)
                .padding(.leading, 34)
                .padding(.vertical, 8)
        }
    }

    /// 实例头部行（旧 BuildingGroupCard.instanceRow）：整行 Button 打开详情。
    private func instanceRow(
        group: BuildingGroup,
        instance: BuildingInstance,
        now: Date
    ) -> some View {
        let item = instance.item
        return Button {
            selectedItem = instance.item
        } label: {
            HStack(alignment: .center, spacing: 10) {
                iconView(item)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(Self.levelLabel(item))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        if let count = item.count, count > 1 {
                            Text("×" + String(count))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.07), in: Capsule())
                        }
                    }
                    if item.isEffectivelyUpgrading || item.effectivelyNeedsReimport {
                        HStack(spacing: 6) {
                            if item.isEffectivelyUpgrading {
                                StatusBadge(text: "正在升级", tint: .orange)
                            }
                            if item.effectivelyNeedsReimport {
                                StatusBadge(text: "待重新导入确认", tint: .orange)
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                if let remainingSeconds = item.effectiveRemainingSeconds(at: now), remainingSeconds > 0 {
                    Text(AccountDurationFormatter.label(remainingSeconds))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 等级标签：currentLevel 缺失 →「等级未记录」；maxLevel 缺失 →「X级 / --」。
    private static func levelLabel(_ item: VillageItemState) -> String {
        guard let currentLevel = item.effectiveCurrentLevel else { return "等级未记录" }
        if let maxLevel = item.maxLevel {
            return String(currentLevel) + "级 / " + String(maxLevel) + "级"
        }
        return String(currentLevel) + "级 / --"
    }

    /// 实例图标：4 级候选链异步加载（`ResourceIconView`，后台 actor + session
    /// cache），失败回退 SF Symbol。资产缺失原因叠加警告角标 + help
    ///（Issue #198：同步解码收敛到 ResourceIconView，候选链/回退/角标语义不变）。
    @ViewBuilder
    private func iconView(_ item: VillageItemState) -> some View {
        ResourceIconView(
            urls: item.preferredAssetURLs(version: GameCatalog.defaultBundledVersion),
            slotSize: 24,
            systemImage: item.displayCategory?.systemImage ?? item.category?.systemImage ?? "hammer.fill",
            tint: item.displayCategory?.tint ?? item.category?.tint ?? Color.secondary,
            symbolFont: .body,
            pngHelp: iconHelp(item),
            sfHelp: iconHelp(item)
        )
        .overlay(alignment: .bottomTrailing) {
            if item.assetMissingReason != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .offset(x: 4, y: 4)
            }
        }
    }

    /// 图标 help 文案：资产缺失原因优先（与 UpgradeDisplayRow.iconHelp 同语义）。
    private func iconHelp(_ item: VillageItemState) -> String {
        if let reason = item.assetMissingReason {
            return "目录图标或等级外观缺失：" + reason
        }
        if let missingReason = item.missingReason { return missingReason }
        return "游戏资源图标"
    }

    /// 单行：`UpgradeDisplayRecord` 在按钮外层构造，避免 label 闭包内长表达式
    /// 触发 Swift 编译器类型检查超时。`village` 已由 detailContent 解包后传入，
    /// 直接取 `.name`/`.tag`（不经 Optional 计算属性，避免与 SwiftUI
    /// `Optional.tag(_:)` modifier 歧义）。
    ///
    /// Issue #144：有 action 或 active manual 记录的行渲染动作按钮（Start /
    /// Cancel / Adjust），行主体用 onTapGesture 打开详情（按钮优先消费点击）；
    /// 无动作的行保持原 Button 语义。嵌套项/Craft Table 无 action → 只读。
    private func itemRow(
        _ item: VillageItemState,
        group: VillageDetailGroup,
        now: Date,
        village: VillageProfile,
        metrics: VillageProgressMetrics,
        actionsByItemID: [String: UpgradeAction],
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
            catalogVersion: catalog?.gameVersion,
            villageMetrics: metrics
        )
        let action = actionsByItemID[item.id]
        let activeRecords = item.effectiveState?.activeManualRecords ?? []
        let rowContent = UpgradeDisplayRow(
            record: record,
            now: now,
            showsVillageColumn: false
        )
        // 嵌套项缩进展示在根父行下（issue #24「类型/模块」区域）。
        let indentedRow = rowContent
            .padding(.leading, indented ? UpgradeDisplayLayout.nestedIndent : 0)

        if action == nil && activeRecords.isEmpty {
            return AnyView(Button {
                selectedItem = item
            } label: {
                indentedRow
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle()))
        }
        return AnyView(HStack(spacing: 10) {
            indentedRow
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedItem = item
                }
            rowActions(action: action, activeRecords: activeRecords)
        })
    }

    /// Issue #144：行内动作按钮（Start / Cancel / Adjust）。
    @ViewBuilder
    private func rowActions(
        action: UpgradeAction?,
        activeRecords: [ManualUpgradeRecord]
    ) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let action {
                if action.isStartable {
                    Button("开始升级") {
                        actionSheet = .start(action)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("开始升级 " + action.itemName)
                } else {
                    Button("开始升级") {}
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(true)
                        .help(action.disabledReason ?? "不可启动")
                        .accessibilityLabel("开始升级不可用：" + (action.disabledReason ?? ""))
                }
            }
            // review：多条 active 记录时每条都提供 Cancel/Adjust 入口。
            ForEach(activeRecords) { record in
                HStack(spacing: 6) {
                    Text("Lv \(record.fromLevel) → \(record.targetLevel)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        actionSheet = .cancel(record)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("取消升级 " + record.itemKey.stableID)
                    Button("调整时间") {
                        actionSheet = .adjust(record)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("调整开始时间 " + record.itemKey.stableID)
                }
            }
        }
    }

    /// Issue #144：搜索 / 状态筛选 / 排序（纯投影消费，View 不重跑解析）。
    private func manualUpgradeFilterBar() -> some View {
        HStack(spacing: 10) {
            TextField("搜索名称 / dataID", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Picker("状态", selection: $stateFilter) {
                Text("全部状态").tag(UpgradeDisplayStateFilter?.none)
                ForEach(UpgradeDisplayStateFilter.allCases, id: \.self) { state in
                    Text(Self.stateFilterTitle(state)).tag(Optional(state))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 140)
            Picker("排序", selection: $sortOrder) {
                ForEach(UpgradeDisplaySort.allCases, id: \.self) { sort in
                    Text(Self.sortTitle(sort)).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 140)
            if manualUpgradeCore != nil {
                Button {
                    showQueueCapacitySettings = true
                } label: {
                    Label("队列容量", systemImage: "rectangle.stack.badge.person.crop")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("配置本地队列容量（只约束本地手动升级）")
                .accessibilityLabel("配置本地队列容量")
                Button {
                    showQueueAssignmentSettings = true
                } label: {
                    Label("导入观察队列", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("确认导入观察属于哪个本地队列（不影响游戏）")
                .accessibilityLabel("配置导入观察的本地队列映射")
            }
            Spacer()
        }
    }

    private static func stateFilterTitle(_ state: UpgradeDisplayStateFilter) -> String {
        switch state {
        case .available: "可升级"
        case .manualActive: "本地升级中"
        case .importedActive: "导入升级中"
        case .completed: "已完成"
        case .needsReimport: "待重新导入"
        case .unknown: "未知/冲突"
        }
    }

    private static func sortTitle(_ sort: UpgradeDisplaySort) -> String {
        switch sort {
        case .remaining: "剩余时间"
        case .categoryName: "分类/名称"
        case .level: "等级"
        case .stageMax: "阶段上限"
        case .recentlyChanged: "最近变更"
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
            + " 已满级 · " + String(Int((ratio * 100).rounded())) + "%"
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
/// 待确认流程——注入的 onConfirm/onApplyDecision 由 VillageDetailView 负责执行
/// `applyQuickImport` 并关闭 sheet。`model` 经 @EnvironmentObject 从
/// VillageDetailView 环境继承（AppModel 在根部注入）。
private struct QuickImportSheet: View {
    /// 快捷导入预览（目标村庄、解析结果、目的地描述）。
    let preview: QuickImportPreview
    /// 无 reconciliation preview 时的兼容确认动作；外部负责 applyQuickImport 并关闭 sheet。
    let onConfirm: () -> Void
    /// 确认按钮动作（外部负责 applyQuickImport 并关闭 sheet）。
    let onApplyDecision: (ManualReconciliationDecision) -> Void
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
                    onCancel: onCancel,
                    onApplyDecision: onApplyDecision,
                    reconciliationPreview: preview.reconciliationPreview,
                    targetVillageName: preview.targetVillageName,
                    targetVillageTag: preview.targetVillageTag,
                    targetVillageHasSnapshot: preview.targetVillageHasSnapshot
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
