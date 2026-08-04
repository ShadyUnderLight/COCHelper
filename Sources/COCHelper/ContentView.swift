import SwiftUI
import COCHelperCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: AppSection? = .tracker

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
                UpgradeTrackerView(villageID: villageID) {
                    selection = .accountData
                }
            case .accountData:
                AccountDataView()
            case .info:
                TrackerInfoView()
            }
        }
    }
}

private enum AppSection: Hashable {
    case tracker
    case villageTracker(UUID)
    case accountData
    case info
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
                            scopeLabel: "当前村庄",
                            panelTitle: village.name + " · 正在升级",
                            now: context.date
                        )
                    }
                } else if villageID == nil && model.villages.contains(where: \.hasImportedData) {
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        TrackerOverviewContent(
                            villages: model.villages,
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
    let scopeLabel: String
    let panelTitle: String
    let now: Date

    var body: some View {
        let activeRecords = UpgradeTracker.activeRecords(from: villages, at: now)

        VStack(alignment: .leading, spacing: 18) {
            TrackerMetricsView(
                villages: villages,
                records: activeRecords,
                scopeLabel: scopeLabel
            )
            ActiveUpgradesPanel(records: activeRecords, now: now, title: panelTitle)
            TrackerOverviewFreshnessNote(villages: villages)
        }
    }
}

private struct TrackerMetricsView: View {
    let villages: [VillageProfile]
    let records: [VillageUpgradeRecord]
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
    let records: [VillageUpgradeRecord]
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
                            VillageUpgradeRecordRow(record: record, now: now)
                            if record.id != records.last?.id {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TrackerTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("升级项目")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("村庄与基地")
                .frame(width: 170, alignment: .leading)
            Text("等级")
                .frame(width: 100, alignment: .trailing)
            Text("预计完成")
                .frame(width: 160, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 46)
        .padding(.trailing, 4)
    }
}

private struct VillageUpgradeRecordRow: View {
    let record: VillageUpgradeRecord
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: record.upgrade.category.systemImage)
                .font(.body)
                .foregroundStyle(record.upgrade.category.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(record.upgrade.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let countLabel = record.upgrade.countLabel {
                        Text(countLabel)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.07), in: Capsule())
                    }
                    if record.upgrade.isNested {
                        Text("嵌套")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(record.upgrade.sourceSection + " · " + record.upgrade.dataIDLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.villageName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.cocAccent)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(record.base.title)
                    if let villageTag = record.villageTag {
                        Text(villageTag)
                            .monospaced()
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(width: 170, alignment: .leading)

            Text(record.upgrade.levelLabel)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.orange)
                .frame(width: 100, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 4) {
                if let remainingSeconds = record.remainingSeconds {
                    Text(AccountDurationFormatter.label(remainingSeconds, zeroLabel: "已完成"))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                    if let completionDate = record.completionDate(from: now) {
                        Text("完成 " + completionDate.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let progress = record.upgrade.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.orange)
                            .frame(width: 112)
                    }
                } else {
                    Text(record.upgrade.statusLabel)
                        .font(.caption)
                        .foregroundStyle(record.upgrade.hasTimer ? Color.secondary : Color.green)
                }
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.vertical, 10)
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
                OfficialPlayerCardView()

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
                    Text("不会联网")
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
                    text: "应用不联网、不调用账号接口，也不填充缺失的资源、工人归属或未来目标。原始文本、未知字段和解析诊断会保留在当前村庄快照中。"
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

private extension TrackerCategory {
    var tint: Color {
        switch self {
        case .buildings: .blue
        case .traps: .green
        case .troops: .orange
        case .spells: .purple
        case .siegeMachines: .brown
        case .heroes: .red
        case .equipment: .cyan
        case .pets: .pink
        case .guardians: .indigo
        }
    }
}

extension Color {
    static let cocAccent = Color(red: 0.47, green: 0.54, blue: 1.0)
    static let cocBackground = Color(red: 0.055, green: 0.063, blue: 0.09)
    static let cocPanel = Color(red: 0.105, green: 0.12, blue: 0.17)
    static let cocElevated = Color(red: 0.14, green: 0.155, blue: 0.21)
}
