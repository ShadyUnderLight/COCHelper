import SwiftUI
import COCHelperCore
import COCHelperApp

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: AppSection? = .tracker
    @State private var showAddTrackedClan = false

    var body: some View {
        NavigationSplitView {
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                List(selection: $selection) {
                    Section("村庄") {
                        ForEach(model.villages) { village in
                            Button {
                                model.selectVillage(id: village.id)
                                selection = .villageTracker(village.id)
                            } label: {
                                VillageSidebarRow(
                                    village: village,
                                    isSelected: village.id == model.selectedVillageID,
                                    activeCount: model.activeUpgradeCount(for: village, at: context.date)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if model.canDeleteCurrentVillage {
                                    Button("删除此村庄", role: .destructive) {
                                        model.deleteVillage(id: village.id)
                                        if selection == .villageTracker(village.id) {
                                            selection = .tracker
                                        }
                                    }
                                }
                            }
                        }

                        Button {
                            model.addVillageForImport()
                            selection = .accountData
                        } label: {
                            Label("导入新村庄", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.cocAccent)
                    }

                    Section("升级追踪") {
                        Label("升级总览", systemImage: "chart.bar.xaxis")
                            .tag(AppSection.tracker)
                    }

                    Section("当前村庄") {
                        Label("账号数据", systemImage: "doc.text.magnifyingglass")
                            .tag(AppSection.accountData)
                        Label("数据说明", systemImage: "info.circle")
                            .tag(AppSection.info)
                    }

                    Section("官方 API") {
                        Button {
                            model.refreshAllOfficialPlayers()
                        } label: {
                            Label("刷新全部官方数据", systemImage: "arrow.clockwise.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRefreshingOfficialData)

                        if let summary = model.officialRefreshSummary {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Section("部落") {
                        if model.trackedClans.isEmpty {
                            // Issue #48 Step B：空状态引导（不依赖村庄的部落查看）。
                            Label("尚未添加部落，点击下方按钮添加后可从侧边栏随时查看",
                                  systemImage: "shield.lefthalf.filled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.trackedClans) { clan in
                            Button {
                                selection = .clan(clan.clanTag)
                            } label: {
                                TrackedClanSidebarRow(
                                    clan: clan,
                                    isCurrentVillageClan: model.isCurrentVillageClan(clan.clanTag)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            showAddTrackedClan = true
                        } label: {
                            Label("添加部落", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.cocAccent)
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("COC 助手")
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("本地升级追踪")
                            .font(.caption.weight(.semibold))
                        Text("每个村庄独立保存原始快照")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            }
        } detail: {
            switch selection ?? .tracker {
            case .tracker:
                UpgradeTrackerView {
                    selection = .accountData
                }
            case .villageTracker(let villageID):
                VillageDetailView(villageID: villageID) {
                    selection = .accountData
                }
                .id(villageID)
            case .accountData:
                AccountDataView()
            case .info:
                TrackerInfoView()
            case .clan(let tag):
                TrackedClanDetailView(clanTag: tag) {
                    selection = .tracker
                }
                .id(tag)
            }
        }
        .sheet(isPresented: $showAddTrackedClan) {
            AddTrackedClanSheet { tag in
                selection = .clan(tag)
            }
        }
    }
}

private enum AppSection: Hashable {
    case tracker
    case villageTracker(UUID)
    case accountData
    case info
    case clan(String)
}

private struct VillageSidebarRow: View {
    let village: VillageProfile
    let isSelected: Bool
    let activeCount: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: village.hasImportedData ? "house.fill" : "house")
                .foregroundStyle(village.hasImportedData ? Color.cocAccent : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(village.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(village.tag ?? "等待导入 JSON")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if village.hasImportedData {
                Text(String(activeCount))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(activeCount > 0 ? .orange : .secondary)
                    .help("当前快照中的正在升级记录")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            isSelected ? Color.cocAccent.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }
}

/// 侧边栏部落行：备注/名称 + Tag + "当前村庄所属"标识。
private struct TrackedClanSidebarRow: View {
    let clan: TrackedClanProfile
    let isCurrentVillageClan: Bool

    var body: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(Color.cocAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(clan.displayName ?? clan.clanTag)
                    .lineLimit(1)
                Text(clan.clanTag)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrentVillageClan {
                Text("当前村庄")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.cocAccent)
            }
        }
    }
}

/// 解析预览阶段（Issue #48 Step A：输入 → 解析 → 预览 → 确认保存）。
private enum ClanResolvePhase {
    case idle
    case resolving
    case resolved(OfficialClanSnapshot)
    case failed(String)
}

/// 添加部落表单（Issue #48 Step A）：输入 Tag → API 解析 → 预览 → 确认保存。
///
/// 流程：本地格式校验（AppModel）→ 查重（已跟踪直接提示，不请求）→
/// `resolveClan` 调基础部落 API → 成功后展示预览（名称/等级/成员数等），
/// 确认后才保存跟踪关系。失败（404/403/429/网络等）展示分类文案且不保存，
/// 避免"看起来已保存"的不存在部落。
private struct AddTrackedClanSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onAdded: (String) -> Void

    @State private var rawTag = ""
    @State private var displayName = ""
    @State private var phase: ClanResolvePhase = .idle
    /// 解析任务句柄：取消按钮可中断在途请求（网络挂起时用户不必干等
    /// 超时+重试的最坏 ~61s），CoAPIClient 的重试退避与 URLSession 均可取消。
    @State private var resolveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加部落")
                .font(.headline)
            TextField("部落 Tag（如 #2QJQ8J88）", text: $rawTag)
                .textFieldStyle(.roundedBorder)
                .disabled(isBusy)
                .onChange(of: rawTag) { _, _ in
                    phase = .idle
                }
            TextField("备注/显示名称（可选）", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .disabled(isBusy)

            phaseContent

            HStack {
                Spacer()
                Button("取消") {
                    // 解析中取消：中断在途请求并关闭；非解析中直接关闭。
                    resolveTask?.cancel()
                    resolveTask = nil
                    dismiss()
                }
                if case .resolved = phase {
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.cocAccent)
                } else {
                    Button(isBusy ? "解析中…" : "解析") { resolve() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.cocAccent)
                        .disabled(isBusy
                            || rawTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        // ESC / 系统关闭 sheet 也取消在途解析（B1：不只"取消"按钮路径）。
        .onDisappear {
            resolveTask?.cancel()
            resolveTask = nil
        }
    }

    private var isBusy: Bool {
        if case .resolving = phase { return true }
        return false
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .resolving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在解析部落信息…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .resolved(let snapshot):
            clanPreview(snapshot)
        }
    }

    /// 预览卡：只读展示解析结果，确认保存前不写任何状态。
    private func clanPreview(_ snapshot: OfficialClanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if let badgeURL = ClanDisplayFormat.badgeURL(snapshot) {
                    AsyncImage(url: badgeURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.name ?? "（未命名部落）")
                        .font(.subheadline.weight(.semibold))
                    Text(snapshot.tag ?? rawTag)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let level = snapshot.clanLevel {
                    Text("Lv.\(level)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cocAccent.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.cocAccent)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                previewRow("类型", snapshot.type.map(ClanDisplayFormat.typeLabel) ?? "未知")
                if let members = snapshot.members {
                    previewRow("成员", "\(members) 人")
                }
                if let record = ClanDisplayFormat.warRecordLabel(snapshot) {
                    previewRow("胜-平-负", record)
                }
                if let streak = snapshot.warWinStreak, streak > 0 {
                    previewRow("连胜", "\(streak) 场")
                }
                if let trophies = snapshot.requiredTrophies {
                    previewRow("所需奖杯", "\(trophies)")
                }
                if let th = snapshot.requiredTownHallLevel {
                    previewRow("所需大本等级", "\(th) 本")
                }
                if let capital = snapshot.clanCapital?.capitalHallLevel {
                    previewRow("部落首都", "大本 \(capital) 级")
                }
            }
            Text("确认保存后，部落详情可在侧边栏随时打开查看。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cocAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func previewRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
    }

    /// 解析：查重（不请求）→ resolveClan → 更新阶段。持有 Task 句柄供取消。
    private func resolve() {
        if model.isClanTracked(rawTag: rawTag) {
            phase = .failed("该部落已在跟踪列表中，无需重复添加。")
            return
        }
        phase = .resolving
        let task = Task {
            let result = await model.resolveClan(rawTag: rawTag)
            resolveTask = nil
            switch result {
            case .success(let snapshot):
                phase = .resolved(snapshot)
            case .failure(let error):
                phase = .failed(error.userFacingMessage)
            }
        }
        resolveTask = task
    }

    /// 保存：resolved 阶段确认后写入跟踪列表（addTrackedClan 自带重复防御）。
    /// 用 rawTag（解析时已通过校验）而非 snapshot.tag：缓存 key 契约是
    /// "请求使用的规范化 tag"，且避免 snapshot.tag 缺失的理论边界。
    private func save() {
        guard case .resolved = phase else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? nil : trimmedName
        switch model.addTrackedClan(rawTag: rawTag, displayName: name) {
        case .success(let profile):
            onAdded(profile.clanTag)
            dismiss()
        case .failure(.invalidTag):
            phase = .failed("Tag 无效：需要以 # 开头，仅含大写字母和数字，长度不超过 15 字符。")
        case .failure(.duplicate):
            phase = .failed("该部落已在跟踪列表中。")
        }
    }
}

struct UpgradeTrackerView: View {
    @EnvironmentObject private var model: AppModel
    let villageID: UUID?
    let openImport: () -> Void

    init(villageID: UUID? = nil, openImport: @escaping () -> Void) {
        self.villageID = villageID
        self.openImport = openImport
    }

    private var village: VillageProfile? {
        guard let villageID else { return nil }
        return model.villages.first(where: { $0.id == villageID })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TrackerHeaderView(village: village, openImport: openImport)

                if let village {
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        TrackerOverviewContent(
                            villages: [village],
                            catalog: model.gameCatalog,
                            scopeLabel: "当前村庄",
                            panelTitle: village.name + " · 正在升级",
                            now: context.date
                        )
                    }
                } else if villageID == nil && model.villages.contains(where: \.hasImportedData) {
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        TrackerOverviewContent(
                            villages: model.villages,
                            catalog: model.gameCatalog,
                            scopeLabel: "全部村庄",
                            panelTitle: "全部村庄 · 正在升级",
                            now: context.date
                        )
                    }
                } else {
                    EmptyTrackerView(openImport: openImport)
                }
            }
            .padding(28)
        }
        .background(Color.cocBackground)
    }
}

private struct TrackerHeaderView: View {
    @EnvironmentObject private var model: AppModel
    let village: VillageProfile?
    let openImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(village == nil ? "升级总览" : "升级追踪")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(village?.name ?? "全部村庄")
                        .font(.title3.weight(.semibold))
                    Text(village.map { $0.tag ?? "尚未导入账号 JSON" } ?? "已导入 " + String(model.villages.filter(\.hasImportedData).count) + " 个村庄")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: openImport) {
                    Label("更新快照", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .tint(Color.cocAccent)
            }

            Text(village == nil
                ? "汇总所有村庄当前正在升级的事项，按预计完成时间从近到远排列。"
                : "显示这个村庄已经存在的正在升级事项，按预计完成时间从近到远排列。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrackerOverviewContent: View {
    let villages: [VillageProfile]
    let catalog: GameCatalog?
    let scopeLabel: String
    let panelTitle: String
    let now: Date

    var body: some View {
        // 单趟投影：active + pending 一次算出，避免 60s tick 双倍投影（review fix）。
        let combined = UpgradeOverviewProjection.overviewRecords(from: villages, catalog: catalog, at: now)

        VStack(alignment: .leading, spacing: 18) {
            TrackerMetricsView(
                villages: villages,
                records: combined.active,
                scopeLabel: scopeLabel
            )
            CatalogStatusNote(catalog: catalog)
            ActiveUpgradesPanel(
                records: combined.active,
                pendingReimport: combined.pending,
                now: now,
                title: panelTitle
            )
            TrackerOverviewFreshnessNote(villages: villages)
        }
    }
}

/// 目录整体状态提示条（warning 样式）。
///
/// 行内徽标（UpgradeDisplayRow.hasVersionMismatch）只覆盖逐项 nextLevel > maxLevel
/// 的推断；catalog 整体缺失或版本与期望不匹配时，完整时长可能大范围静默错误，
/// 由本提示条在总览页显式标出。版本匹配时不渲染。
private struct CatalogStatusNote: View {
    let catalog: GameCatalog?

    var body: some View {
        if let catalog {
            if catalog.gameVersion != GameCatalog.defaultBundledVersion {
                note(text: "静态目录版本 \(catalog.gameVersion) 与期望版本 \(GameCatalog.defaultBundledVersion) 不匹配，完整时长可能过时。")
            }
        } else {
            note(text: "静态升级目录不可用，完整时长与等级上限信息缺失。")
        }
    }

    private func note(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("目录状态")
                    .font(.caption.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct TrackerMetricsView: View {
    let villages: [VillageProfile]
    let records: [UpgradeDisplayRecord]
    let scopeLabel: String

    private var importedVillageCount: Int {
        villages.filter(\.hasImportedData).count
    }

    private var affectedVillageCount: Int {
        Set(records.map(\.villageID)).count
    }

    private var nearestCompletion: String {
        guard let remainingSeconds = records.first?.remainingSeconds else { return "--" }
        return AccountDurationFormatter.label(remainingSeconds, zeroLabel: "已完成")
    }

    var body: some View {
        HStack(spacing: 12) {
            TrackerMetricCard(
                title: "正在升级",
                value: String(records.count),
                detail: scopeLabel,
                systemImage: "hammer.fill",
                tint: .orange
            )
            TrackerMetricCard(
                title: "涉及村庄",
                value: String(affectedVillageCount),
                detail: "存在进行中项目",
                systemImage: "house.2.fill",
                tint: Color.cocAccent
            )
            TrackerMetricCard(
                title: "最近完成",
                value: nearestCompletion,
                detail: "按剩余时间",
                systemImage: "clock.badge.checkmark.fill",
                tint: .green
            )
            TrackerMetricCard(
                title: "已导入村庄",
                value: String(importedVillageCount),
                detail: "本地快照",
                systemImage: "clock.fill",
                tint: .blue
            )
        }
    }
}

private struct TrackerMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Spacer()
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Color.cocPanel, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct ActiveUpgradesPanel: View {
    let records: [UpgradeDisplayRecord]
    let pendingReimport: [UpgradeDisplayRecord]
    let now: Date
    let title: String

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: "hammer.fill")
                        .font(.headline)
                    Spacer()
                    Text(records.isEmpty ? "当前没有进行中的记录" : "预计完成时间从近到远")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if records.isEmpty {
                    TrackerEmptyRow(
                        systemImage: "checkmark.circle",
                        title: "所有村庄当前没有正在升级的项目",
                        detail: "请在账号数据页导入或更新村庄 JSON，这里只显示已经存在且带有进行中倒计时的升级事项。"
                    )
                } else {
                    TrackerTableHeader()
                    VStack(spacing: 0) {
                        ForEach(records) { record in
                            UpgradeDisplayRow(record: record, now: now)
                            if record.id != records.last?.id {
                                Divider().padding(.leading, UpgradeDisplayLayout.listDividerLeading)
                            }
                        }
                    }
                }

                if !pendingReimport.isEmpty {
                    PendingReimportBlock(records: pendingReimport, now: now)
                }
            }
        }
    }
}

/// 「待重新导入确认」次级提示块：计时已结束的项目（验收标准：计时结束的项目
/// 显示重新导入提示）。复用同一行组件，精简样式（橙色淡底）。
private struct PendingReimportBlock: View {
    let records: [UpgradeDisplayRecord]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("待重新导入确认", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text("有 " + String(records.count) + " 个项目已计时结束，重新导入 JSON 确认实际等级。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(records) { record in
                    UpgradeDisplayRow(record: record, now: now)
                    if record.id != records.last?.id {
                        Divider().padding(.leading, UpgradeDisplayLayout.listDividerLeading)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TrackerTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("升级项目")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("村庄与基地")
                .frame(width: 170, alignment: .leading)
            Text("等级/时长")
                .frame(width: 130, alignment: .trailing)
            Text("预计完成")
                .frame(width: 160, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, UpgradeDisplayLayout.listDividerLeading)
        .padding(.trailing, 4)
    }
}

private struct TrackerOverviewFreshnessNote: View {
    let villages: [VillageProfile]

    private var importedVillages: [VillageProfile] {
        villages.filter(\.hasImportedData)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Color.cocAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text("快照状态")
                    .font(.caption.weight(.semibold))
                Text("已汇总 " + String(importedVillages.count) + " 个村庄快照。倒计时会在本地基于各自导入时间继续显示；完成后请重新导入一次 JSON 刷新等级。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.cocAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct EmptyTrackerView: View {
    let openImport: () -> Void

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.cocAccent)
                Text("先导入一个村庄快照")
                    .font(.title3.weight(.bold))
                Text("把游戏内复制的账号 JSON 粘贴到“账号数据”，确认后这里会汇总所有村庄当前已经存在的正在升级事项。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: openImport) {
                    Label("打开账号数据", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

private struct TrackerEmptyRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.cocAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }
}

struct AccountDataView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("账号数据")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("粘贴游戏内复制的 JSON，解析后保存为当前村庄的本地快照。")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VillageNameEditor()
                AccountImportPanel()
                // 账号数据页是"当前村庄"语义：与详情页共享同一组件 = 同一状态，
                // 不形成两套刷新入口（显式 villageID 均指向当前选中村庄）。
                OfficialPlayerCardView(villageID: model.selectedVillageID)
                ClanCardView(villageID: model.selectedVillageID)
                ClanWarCardView(villageID: model.selectedVillageID)
                WarLogCardView(villageID: model.selectedVillageID)
                CapitalRaidCardView(villageID: model.selectedVillageID)

                if let pending = model.pendingAccountSnapshot {
                    AccountSnapshotSummaryView(snapshot: pending, isPending: true)
                }

                if let snapshot = model.accountSnapshot {
                    AccountSnapshotSummaryView(snapshot: snapshot, isPending: false)
                } else if model.pendingAccountSnapshot == nil {
                    Panel {
                        TrackerEmptyRow(
                            systemImage: "tray",
                            title: "当前村庄还没有已应用快照",
                            detail: "解析成功后点击“确认导入”，数据才会进入升级追踪。"
                        )
                    }
                }
            }
            .padding(28)
        }
        .background(Color.cocBackground)
    }
}

private struct AccountImportPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("导入快照", systemImage: "arrow.down.doc")
                        .font(.headline)
                    Spacer()
                    Text("本地解析，不联网")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }

                TextEditor(text: $model.importText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 230)
                    .background(Color.cocElevated, in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Button {
                        model.pasteFromClipboard()
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.parseAccountText()
                    } label: {
                        Label("解析文本", systemImage: "checkmark.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
                    .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    if model.pendingAccountSnapshot != nil {
                        Button("清除待确认") {
                            model.discardPendingAccountSnapshot()
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if let error = model.accountImportError {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct VillageNameEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var draftName = ""

    var body: some View {
        HStack(spacing: 9) {
            Label("显示名称", systemImage: "pencil")
                .font(.subheadline.weight(.semibold))
            TextField("用于区分多个账号", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Button("保存名称") {
                model.renameSelectedVillage(draftName)
            }
            .buttonStyle(.bordered)
            .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
        }
        .onAppear {
            draftName = model.currentVillageName
        }
        .onChange(of: model.selectedVillageID) { _, _ in
            draftName = model.currentVillageName
        }
    }
}

private struct AccountSnapshotSummaryView: View {
    @EnvironmentObject private var model: AppModel
    let snapshot: AccountSnapshot
    let isPending: Bool

    private var snapshotTitle: String {
        isPending ? "待确认的账号快照" : "当前账号快照"
    }

    private var activeItems: [AccountItem] {
        snapshot.activeItems.filter { ($0.remainingSeconds ?? 0) > 0 }
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(snapshotTitle, systemImage: isPending ? "questionmark.circle" : "checkmark.circle.fill")
                            .font(.headline)
                        Text(snapshot.tag ?? "未提供账号标签")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(isPending ? "解析成功，尚未应用" : "已保存到本机")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isPending ? .orange : .green)
                }

                HStack(spacing: 10) {
                    SnapshotMetric(title: "主村记录", value: String(snapshot.mainVillageObjectItemCount))
                    SnapshotMetric(title: "建筑基地", value: String(snapshot.builderBaseObjectItemCount))
                    SnapshotMetric(title: "计时字段", value: String(snapshot.activeItemCount))
                    SnapshotMetric(title: "警告", value: String(snapshot.warningCount))
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("快照时间")
                            .font(.caption.weight(.semibold))
                        Text(snapshot.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未提供")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("解析器")
                            .font(.caption.weight(.semibold))
                        Text(AccountSnapshotImporter.parserVersion)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if !snapshot.sectionNames.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("已读取分区")
                            .font(.caption.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(snapshot.sectionNames, id: \.self) { section in
                                Text(section)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.white.opacity(0.06), in: Capsule())
                            }
                        }
                    }
                }

                if !activeItems.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("导入时检测到的进行中记录")
                            .font(.caption.weight(.semibold))
                        ForEach(Array(activeItems.prefix(10))) { item in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 7, height: 7)
                                Text(item.nameLabel)
                                    .font(.caption)
                                Spacer()
                                Text(item.remainingTimeLabel ?? "进行中")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                        }
                        if activeItems.count > 10 {
                            Text("还有 " + String(activeItems.count - 10) + " 条，升级总览会全部列出。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !snapshot.diagnostics.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("解析诊断")
                            .font(.caption.weight(.semibold))
                        ForEach(snapshot.diagnostics) { diagnostic in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: diagnostic.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                    .foregroundStyle(diagnostic.severity == .warning ? .orange : .blue)
                                Text(diagnostic.path + "：" + diagnostic.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if isPending {
                    if let destination = model.pendingAccountSnapshotDestinationDescription {
                        Text(destination)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.cocAccent)
                    }
                    HStack {
                        Spacer()
                        Button("放弃") {
                            model.discardPendingAccountSnapshot()
                        }
                        .buttonStyle(.bordered)
                        Button(model.pendingAccountSnapshotActionTitle ?? "应用快照") {
                            model.applyPendingAccountSnapshot()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.cocAccent)
                    }
                } else {
                    HStack {
                        Text("原始 JSON 会随快照保存在本机，未知字段不会被静默丢弃。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清除当前快照", role: .destructive) {
                            model.clearAccountSnapshot()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

private struct SnapshotMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TrackerInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("数据说明")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("这是一个本地升级 tracker：它读取游戏内复制的账号 JSON，整理当前快照中的计时和等级记录。")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                InfoCard(
                    number: "01",
                    title: "正在升级",
                    text: "带有计时字段且剩余时间大于 0 的项目会进入正在升级列表，并按剩余时间排序。倒计时只在本地基于导入时间继续显示。"
                )
                InfoCard(
                    number: "02",
                    title: "项目身份",
                    text: "每条进行中的记录都会标出项目名称、所属村庄、主村或建筑工人基地、账号 tag 和数据 ID；重复记录和数量不会合并丢失。"
                )
                InfoCard(
                    number: "03",
                    title: "目标等级边界",
                    text: "原始 JSON 没有单独的目标等级字段；正在升级行里的“当前 → 下一等级”是根据当前等级加 1 的界面推断，完成后应重新导入确认。"
                )
                InfoCard(
                    number: "04",
                    title: "本地与可审计",
                    text: "导入解析全部在本地完成；只有主动点击“刷新官方数据”时才会访问 Clash of Clans 官方 API，且官方数据作为独立来源展示，不填充缺失的资源、工人归属或未来目标。原始文本、未知字段和解析诊断会保留在当前村庄快照中。"
                )
            }
            .padding(28)
        }
        .background(Color.cocBackground)
    }
}

private struct InfoCard: View {
    let number: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number)
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(Color.cocAccent)
                .frame(width: 32, height: 32)
                .background(Color.cocAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color.cocPanel, in: RoundedRectangle(cornerRadius: 15))
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .background(Color.cocPanel, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

extension Color {
    static let cocAccent = Color(red: 0.47, green: 0.54, blue: 1.0)
    static let cocBackground = Color(red: 0.055, green: 0.063, blue: 0.09)
    static let cocPanel = Color(red: 0.105, green: 0.12, blue: 0.17)
    static let cocElevated = Color(red: 0.14, green: 0.155, blue: 0.21)
}
