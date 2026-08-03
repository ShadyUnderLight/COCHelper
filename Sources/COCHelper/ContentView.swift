import SwiftUI
import COCHelperCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: AppSection? = .roadmap
    @State private var isPresentingTaskEditor = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("规划") {
                    Label("Builder Roadmap", systemImage: "calendar.badge.clock")
                        .tag(AppSection.roadmap)
                }

                Section("账号") {
                    Label("账号数据", systemImage: "doc.text.magnifyingglass")
                        .tag(AppSection.accountData)
                }

                Section("工作台") {
                    Label("待升级项", systemImage: "list.bullet.rectangle")
                        .tag(AppSection.tasks)
                    Label("规则说明", systemImage: "slider.horizontal.3")
                        .tag(AppSection.rules)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("COC 助手")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("本地规划原型")
                        .font(.caption.weight(.semibold))
                    Text("示例数据可直接替换")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        } detail: {
            switch selection ?? .roadmap {
            case .roadmap:
                RoadmapDashboardView(isPresentingTaskEditor: $isPresentingTaskEditor)
            case .accountData:
                AccountDataView()
            case .tasks:
                TaskLibraryView(isPresentingTaskEditor: $isPresentingTaskEditor)
            case .rules:
                RulesView()
            }
        }
        .sheet(isPresented: $isPresentingTaskEditor) {
            TaskEditorView { task in
                model.addTask(task)
                isPresentingTaskEditor = false
            }
        }
        .onChange(of: model.input) { _, _ in
            model.rebuild()
        }
    }
}

private enum AppSection: Hashable {
    case roadmap
    case accountData
    case tasks
    case rules
}

struct RoadmapDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresentingTaskEditor: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DashboardHeaderView()
                PlanningControlsView()
                AccountStateView()
                MetricsGrid(metrics: model.plan.metrics)
                InsightsGrid(insights: model.plan.insights)
                BuilderTimelineView(plan: model.plan)
                ResearchQueueView(plan: model.plan)
                TaskLibraryPreview(isPresentingTaskEditor: $isPresentingTaskEditor)
                PrototypeBoundaryView()
            }
            .padding(28)
        }
        .background(Color.cocBackground)
        .toolbar {
            ToolbarItem {
                Button {
                    model.resetToDemo()
                } label: {
                    Label("恢复示例", systemImage: "arrow.counterclockwise")
                }
                .help("恢复一组可演示 Builder Roadmap 的本地示例数据")
            }
        }
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
                    Text("在游戏内复制原始 JSON，粘贴到这里后解析。文本不会联网，也不会在解析前自动保存。")
                        .foregroundStyle(.secondary)
                }

                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("粘贴原始 JSON", systemImage: "doc.on.clipboard")
                                .font(.headline)
                            Spacer()
                            Text("支持直接 ⌘V")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $model.importText)
                                .font(.system(.body, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 300)
                                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))

                            if model.importText.isEmpty {
                                Text("把游戏复制出来的 JSON 粘贴到这里…")
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(17)
                                    .allowsHitTesting(false)
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                model.pasteFromClipboard()
                            } label: {
                                Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered)

                            Button("清空") {
                                model.importText = ""
                                model.discardPendingAccountSnapshot()
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.importText.isEmpty)

                            Spacer()

                            Button {
                                model.parseAccountText()
                            } label: {
                                Label("解析文本", systemImage: "checkmark.seal")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.cocAccent)
                            .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if let error = model.accountImportError {
                            Label(error, systemImage: "xmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let pending = model.pendingAccountSnapshot {
                    AccountSnapshotSummaryView(snapshot: pending, isPending: true)
                }

                if let snapshot = model.accountSnapshot {
                    AccountSnapshotSummaryView(snapshot: snapshot, isPending: false)
                } else if model.pendingAccountSnapshot == nil {
                    Panel {
                        Label("还没有已应用的账号快照", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
        }
        .background(Color.cocBackground)
    }
}

struct AccountSnapshotSummaryView: View {
    @EnvironmentObject private var model: AppModel
    let snapshot: AccountSnapshot
    let isPending: Bool

    private var snapshotTitle: String {
        isPending ? "待确认的账号快照" : "当前账号快照"
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(snapshotTitle, systemImage: isPending ? "questionmark.circle" : "checkmark.circle.fill")
                            .font(.headline)
                        Text(snapshot.tag ?? "未提供账号标签")
                            .font(.title3.weight(.semibold).monospaced())
                        Text(capturedAtLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(isPending ? "解析成功，尚未应用" : "已保存到本机")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isPending ? .orange : .green)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    SnapshotMetric(title: "对象记录", value: String(snapshot.objectItemCount))
                    SnapshotMetric(title: "数字记录", value: String(snapshot.numericItemCount))
                    SnapshotMetric(title: "计时器", value: String(snapshot.activeItemCount))
                    SnapshotMetric(title: "警告", value: String(snapshot.warningCount))
                }

                if !snapshot.sectionNames.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已读取的字段")
                            .font(.subheadline.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(snapshot.sectionNames, id: \.self) { section in
                                HStack {
                                    Text(section)
                                        .font(.caption.monospaced())
                                    Spacer()
                                    Text(String(itemCount(for: section)))
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }

                if !snapshot.activeItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("发现的计时器")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("不会猜测工人或队列归属")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(snapshot.activeItems.prefix(12))) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.isActive ? "clock.fill" : "clock.badge.xmark")
                                    .foregroundStyle(item.isActive ? .orange : .secondary)
                                    .frame(width: 20)
                                Text(item.section + " · " + item.rawIDLabel)
                                    .font(.caption.monospaced())
                                if let level = item.level {
                                    Text("等级 " + String(level))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.remainingTimeLabel ?? "无剩余时间")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(item.isActive ? .orange : .secondary)
                            }
                            .padding(.vertical, 3)
                        }
                        if snapshot.activeItems.count > 12 {
                            Text("还有 " + String(snapshot.activeItems.count - 12) + " 个计时器未展开。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !snapshot.boosts.isEmpty || !helperCooldownItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("加速与冷却")
                            .font(.subheadline.weight(.semibold))
                        ForEach(snapshot.boosts.keys.sorted(), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(durationLabel(snapshot.boosts[key] ?? 0))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(helperCooldownItems) { item in
                            HStack {
                                Text(item.section + " · " + item.rawIDLabel + " · helper_cooldown")
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(durationLabel(item.remainingHelperCooldownSeconds ?? 0))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !snapshot.diagnostics.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("解析诊断")
                            .font(.subheadline.weight(.semibold))
                        ForEach(snapshot.diagnostics) { diagnostic in
                            HStack(alignment: .top, spacing: 7) {
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

                HStack {
                    if isPending {
                        Button("取消预览") {
                            model.discardPendingAccountSnapshot()
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button("应用此快照") {
                            model.applyPendingAccountSnapshot()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.cocAccent)
                    } else {
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

    private var capturedAtLabel: String {
        let captured = snapshot.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未提供快照时间"
        if let age = snapshot.ageSeconds, age > 0 {
            return "快照时间：" + captured + " · 导入时已扣除 " + durationLabel(age)
        }
        return "快照时间：" + captured
    }

    private func itemCount(for section: String) -> Int {
        snapshot.objectSections[section]?.count ?? snapshot.numericSections[section]?.count ?? 0
    }

    private var helperCooldownItems: [AccountItem] {
        snapshot.allObjectItems.filter { $0.remainingHelperCooldownSeconds != nil }
    }

    private func durationLabel(_ seconds: Int64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return String(days) + "天" + String(hours) + "小时" }
        if hours > 0 { return String(hours) + "小时" + String(minutes) + "分钟" }
        return String(max(1, minutes)) + "分钟"
    }
}

struct SnapshotMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DashboardHeaderView: View {
    @EnvironmentObject private var model: AppModel

    private var accountSummary: String {
        let townHall = String(model.input.townHallLevel)
        let builders = String(model.input.builderCount)
        let horizon = String(model.input.horizon.rawValue)
        return "大本营 " + townHall + " · " + builders + " 个工人 · 未来 " + horizon + " 天 · 数据层 " + model.input.gameDataCatalog.catalogVersion
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Builder Roadmap")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("规划原型")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.cocAccent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.cocAccent.opacity(0.12), in: Capsule())
                }
                Text("不只是更快满防，而是在保持部落战体验的前提下，让每个工人都知道下一步。")
                    .font(.title3)
                    .foregroundStyle(.primary)
                Text(accountSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                Text("当前策略")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.input.warMode.title)
                    .font(.headline)
                Text(model.input.warMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(16)
            .frame(width: 190, alignment: .trailing)
            .background(Color.cocElevated, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct PlanningControlsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("规划参数", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Text("调整后会自动重新计算")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
                    GridRow {
                        ParameterLabel(title: "规划窗口", subtitle: "看多远")
                        Picker("规划窗口", selection: $model.input.horizon) {
                            ForEach(PlanningHorizon.allCases) { horizon in
                                Text(horizon.title).tag(horizon)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)

                        ParameterLabel(title: "每日上线", subtitle: "影响错峰精度")
                        Picker("每日上线", selection: $model.input.checkInFrequency) {
                            ForEach(DailyCheckInFrequency.allCases) { frequency in
                                Text(frequency.title).tag(frequency)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    GridRow {
                        ParameterLabel(title: "部落战模式", subtitle: "影响英雄安排")
                        Picker("部落战模式", selection: $model.input.warMode) {
                            ForEach(WarMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)

                        ParameterLabel(title: "大本营准备度", subtitle: "防止升级过早")
                        Picker("大本营准备度", selection: $model.input.nextTownHallReadiness) {
                            ForEach(TownHallReadiness.allCases) { readiness in
                                Text(readiness.title).tag(readiness)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    GridRow {
                        ParameterLabel(title: "工人与等级", subtitle: "当前账号状态")
                        HStack(spacing: 10) {
                            Stepper("大本营 " + String(model.input.townHallLevel), value: $model.input.townHallLevel, in: 1...18)
                            Stepper("工人 " + String(model.input.builderCount), value: $model.input.builderCount, in: 1...6)
                        }
                        .frame(width: 260, alignment: .leading)

                        ParameterLabel(title: "约束开关", subtitle: "长期体验")
                        HStack(spacing: 16) {
                            Toggle("联赛保留英雄", isOn: $model.input.reserveHeroesDuringLeague)
                            Toggle("资源错峰", isOn: $model.input.avoidResourceOverflow)
                            Toggle("有魔法物品", isOn: $model.input.magicItemsAvailable)
                        }
                        .toggleStyle(.checkbox)
                        .frame(width: 420, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct ParameterLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 112, alignment: .leading)
    }
}

struct AccountStateView: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            BuilderStatusPanel()
            ResourceInventoryPanel()
            HeroStatusPanel()
            GameDataPanel()
        }
    }
}

struct BuilderStatusPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("工人当前状态", systemImage: "hammer.fill")
                        .font(.headline)
                    Spacer()
                    Text("剩余时间会成为下一段排程的起点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                    ForEach(0..<model.input.builderCount, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(model.input.builderStates[index].title)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(model.input.builderStates[index].isAvailable ? "空闲" : "进行中")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(model.input.builderStates[index].isAvailable ? .green : .orange)
                            }
                            TextField("当前任务", text: builderNameBinding(index))
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: 6) {
                                TextField("剩余天数", value: builderRemainingBinding(index), format: .number.precision(.fractionLength(1)))
                                    .textFieldStyle(.roundedBorder)
                                Text("天")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private func builderNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.input.builderStates[index].currentTaskName },
            set: { model.input.builderStates[index].currentTaskName = $0 }
        )
    }

    private func builderRemainingBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { model.input.builderStates[index].remainingDays },
            set: { model.input.builderStates[index].remainingDays = max(0, $0) }
        )
    }
}

struct ResourceInventoryPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("资源库存", systemImage: "shippingbox.fill")
                        .font(.headline)
                    Spacer()
                    Text("当前 / 上限 / 日收入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ResourceStockRow(title: "金币", tint: .yellow, stock: $model.input.resourceInventory.gold)
                ResourceStockRow(title: "圣水", tint: .cyan, stock: $model.input.resourceInventory.elixir)
                ResourceStockRow(title: "黑油", tint: .purple, stock: $model.input.resourceInventory.darkElixir)
            }
        }
    }
}

struct ResourceStockRow: View {
    let title: String
    let tint: Color
    @Binding var stock: ResourceStock

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, alignment: .leading)
            ResourceNumberField(label: "当前", value: $stock.current)
            ResourceNumberField(label: "上限", value: $stock.capacity)
            ResourceNumberField(label: "日收入", value: $stock.dailyIncome)
        }
    }
}

struct ResourceNumberField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(label, value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct HeroStatusPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("英雄可用窗口", systemImage: "person.crop.circle.badge.clock")
                        .font(.headline)
                    Spacer()
                    Text("升级剩余 / 出战保护至")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(model.input.heroStatuses.indices), id: \.self) { index in
                    HStack(spacing: 7) {
                        TextField("英雄", text: heroNameBinding(index))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 72)
                        TextField("等级", value: heroLevelBinding(index), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 58)
                        TextField("升级剩余", value: heroRemainingBinding(index), format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                        TextField("保护至", value: heroProtectedBinding(index), format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                        Text("天")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("保护至 0 表示没有额外的部落战保护窗口；英雄当前升级剩余时间会自动阻止下一次升级过早开始。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func heroNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.input.heroStatuses[index].name },
            set: { model.input.heroStatuses[index].name = $0 }
        )
    }

    private func heroLevelBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { model.input.heroStatuses[index].level },
            set: { model.input.heroStatuses[index].level = max(1, $0) }
        )
    }

    private func heroRemainingBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { model.input.heroStatuses[index].upgradeRemainingDays },
            set: { model.input.heroStatuses[index].upgradeRemainingDays = max(0, $0) }
        )
    }

    private func heroProtectedBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { model.input.heroStatuses[index].warProtectedUntilDay },
            set: { model.input.heroStatuses[index].warProtectedUntilDay = max(0, $0) }
        )
    }
}

struct GameDataPanel: View {
    @EnvironmentObject private var model: AppModel

    private var summary: String {
        let status = model.input.gameDataCatalog.status
        return status.versionLabel + " · " + status.source.title + " · " + String(status.entryCount) + " 条记录"
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("版本化游戏数据", systemImage: "checkmark.seal")
                        .font(.headline)
                    Spacer()
                    Text(model.input.gameDataCatalog.source.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.input.gameDataCatalog.source == .demo ? .orange : .green)
                }
                Text(summary)
                    .font(.subheadline.weight(.semibold).monospaced())
                Text("游戏版本：" + model.input.gameDataCatalog.gameVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("当前工期仍以账号填写的剩余时间为准；数据层只提供成本、资源类型、分类和默认工期元数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Image(systemName: model.input.gameDataCatalog.status.isStructurallyValid ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(model.input.gameDataCatalog.status.isStructurallyValid ? .green : .red)
                    Text(model.input.gameDataCatalog.status.isStructurallyValid ? "合同结构有效" : "合同结构需要修复")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("恢复演示数据层") {
                        model.input.gameDataCatalog = .demo
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

struct MetricsGrid: View {
    let metrics: PlanMetrics

    private var cards: [(String, String, String, Color, Double)] {
        [
            ("规划评分", String(metrics.overallScore), "不是速度分，是体验平衡分", .cocAccent, Double(metrics.overallScore) / 100),
            ("部落战友好度", String(metrics.warFriendlyScore), "英雄可用性与战期策略", .green, Double(metrics.warFriendlyScore) / 100),
            ("建筑 / 科技同步", String(metrics.syncScore), "核心建筑与科技队列的衔接", .blue, Double(metrics.syncScore) / 100),
            ("资源压力", String(metrics.resourcePressure), "越低越平滑 · 卡住 " + String(metrics.resourceBlockedCount) + " 项", .orange, Double(metrics.resourcePressure) / 100)
        ]
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(cards, id: \.0) { card in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(card.0)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: card.0 == "资源压力" ? "waveform.path.ecg" : "chart.line.uptrend.xyaxis")
                            .foregroundStyle(card.3)
                    }
                    Text(card.1)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(card.3)
                    Text(card.2)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: card.4)
                        .tint(card.3)
                }
                .padding(16)
                .background(Color.cocPanel, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

struct InsightsGrid: View {
    let insights: [PlannerInsight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("规划器的判断", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text("每条建议都对应一个可调整的输入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(insights) { insight in
                    InsightCard(insight: insight)
                }
            }
        }
    }
}

struct InsightCard: View {
    let insight: PlannerInsight

    private var tint: Color {
        switch insight.tone {
        case .positive: .green
        case .warning: .orange
        case .information: .blue
        case .neutral: .secondary
        }
    }

    private var icon: String {
        switch insight.tone {
        case .positive: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        case .neutral: "circle.dashed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
                Text(insight.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 12)
        }
    }
}

struct BuilderTimelineView: View {
    let plan: RoadmapPlan

    private var timelineWidth: CGFloat {
        max(820, CGFloat(plan.horizonDays) * 9)
    }

    private var markers: [Int] {
        [0, 7, 30, 60, 90, 120, 150, 180].filter { $0 <= plan.horizonDays }
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("工人时间线", systemImage: "chart.bar.xaxis")
                            .font(.headline)
                        Text("同一条线上的任务会顺序执行；留白代表有意保留的资源或部落战缓冲。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("未来 " + String(plan.horizonDays) + " 天")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Text("工人")
                                .font(.caption.weight(.semibold))
                                .frame(width: 136, alignment: .leading)
                            RulerView(markers: markers, horizonDays: plan.horizonDays, width: timelineWidth)
                        }

                        ForEach(plan.builders) { builder in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(builder.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(builder.role)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 136, height: 58, alignment: .leading)

                                TimelineLaneView(builder: builder, horizonDays: plan.horizonDays, width: timelineWidth)
                            }
                        }
                    }
                    .frame(width: 148 + timelineWidth, alignment: .leading)
                }
            }
        }
    }
}

struct RulerView: View {
    let markers: [Int]
    let horizonDays: Int
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
            ForEach(markers, id: \.self) { marker in
                VStack(spacing: 4) {
                    Text(marker == 0 ? "今天" : "D" + String(marker))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 1, height: 8)
                }
                .offset(x: xPosition(for: marker))
            }
        }
        .frame(width: width, height: 24, alignment: .leading)
    }

    private func xPosition(for day: Int) -> CGFloat {
        guard horizonDays > 0 else { return 0 }
        return CGFloat(day) / CGFloat(horizonDays) * width
    }
}

struct TimelineLaneView: View {
    let builder: BuilderPlan
    let horizonDays: Int
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                }

            ForEach(builder.tasks) { task in
                if task.startDay < Double(horizonDays) {
                    TimelineBlock(task: task, horizonDays: horizonDays, width: width)
                }
            }
        }
        .frame(width: width, height: 58, alignment: .leading)
    }
}

struct TimelineBlock: View {
    let task: PlannedTask
    let horizonDays: Int
    let width: CGFloat

    private var visibleStart: Double { max(0, task.startDay) }
    private var visibleEnd: Double { min(Double(horizonDays), task.endDay) }
    private var blockWidth: CGFloat {
        max(54, CGFloat(max(0.25, visibleEnd - visibleStart) / Double(horizonDays)) * width)
    }
    private var xOffset: CGFloat {
        CGFloat(visibleStart / Double(horizonDays)) * width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("D" + String(Int(task.startDay.rounded())) + "–" + String(Int(task.endDay.rounded())))
                .font(.caption2)
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(width: blockWidth, height: 42, alignment: .leading)
        .background(task.category.tint, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: task.category.tint.opacity(0.15), radius: 4, y: 2)
        .offset(x: xOffset, y: 0)
        .help(task.note ?? "无额外说明")
    }
}

struct ResearchQueueView: View {
    let plan: RoadmapPlan

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("科技队列", systemImage: "flask")
                        .font(.headline)
                    Spacer()
                    Text("不占建筑工人，但必须和建筑节奏同步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if plan.research.isEmpty {
                    Text("暂无科技目标")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(plan.research) { task in
                            HStack(spacing: 12) {
                                Image(systemName: "atom")
                                    .foregroundStyle(Color.blue)
                                    .frame(width: 24)
                                Text(task.name)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("第 " + String(Int(task.startDay.rounded())) + " 天")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text("第 " + String(Int(task.endDay.rounded())) + " 天")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.blue)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct TaskLibraryPreview: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresentingTaskEditor: Bool

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("待升级项", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Spacer()
                    Button {
                        isPresentingTaskEditor = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
                }

                Text("这些是规划器的输入，不是官方数据库；可以按你的账号实际剩余工期修改。完整编辑在左侧“待升级项”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(model.input.tasks.prefix(9)) { task in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(task.category.tint)
                                .frame(width: 8, height: 8)
                            Text(task.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f", task.durationDays) + "d")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
    }
}

struct PrototypeBoundaryView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color.cocAccent)
            VStack(alignment: .leading, spacing: 5) {
                Text("首版边界")
                    .font(.subheadline.weight(.semibold))
                Text("当前是可解释的本地启发式排程：工人剩余时间、资源库存、英雄保护窗口和版本化数据合同已经接入；仍不联网、不读取账号，也不承诺实时官方数值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(15)
        .background(Color.cocAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TaskLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresentingTaskEditor: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("待升级项")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("把当前账号真实的剩余工期填进来，Roadmap 才会有意义。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        isPresentingTaskEditor = true
                    } label: {
                        Label("添加升级项", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
                }

                Panel {
                    VStack(spacing: 0) {
                        ForEach(model.input.tasks) { task in
                            TaskRow(task: task) {
                                model.removeTask(id: task.id)
                            }
                            if task.id != model.input.tasks.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("科技目标", systemImage: "flask")
                            .font(.headline)
                        ForEach(model.input.researchTasks) { task in
                            HStack {
                                Text(task.name)
                                Spacer()
                                Text(String(format: "%.1f", task.durationDays) + " 天")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .padding(28)
        }
        .background(Color.cocBackground)
    }
}

struct TaskRow: View {
    let task: UpgradeTask
    let onDelete: () -> Void

    private var detail: String {
        let cost = task.estimatedCost > 0 ? " · 估算 " + String(task.estimatedCost) : " · 成本未知"
        return String(format: "%.1f", task.durationDays) + " 天 · " + task.resource.title + cost + " · " + task.track.title
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.category.systemImage)
                .foregroundStyle(task.category.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(task.name)
                        .font(.subheadline.weight(.semibold))
                    Text(task.category.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(task.category.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(task.category.tint.opacity(0.1), in: Capsule())
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if task.isRepeatable {
                Text("可重复")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除此输入项")
        }
        .padding(.vertical, 10)
    }
}

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (UpgradeTask) -> Void

    @State private var name = ""
    @State private var category: UpgradeCategory = .building
    @State private var durationText = "3"
    @State private var estimatedCostText = "0"
    @State private var resource: ResourceClass = .gold
    @State private var priority = 70
    @State private var track: BuilderTrack = .automatic
    @State private var isRepeatable = false
    @State private var highWarImpact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加升级项")
                        .font(.title2.weight(.bold))
                    Text("输入你的账号实际剩余工期")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
            }

            Form {
                TextField("名称", text: $name)
                Picker("类别", selection: $category) {
                    ForEach(UpgradeCategory.allCases.filter { $0 != .research }) { category in
                        Text(category.title).tag(category)
                    }
                }
                TextField("剩余工期（天）", text: $durationText)
                TextField("估算花费（0 = 未知）", text: $estimatedCostText)
                Picker("主要资源", selection: $resource) {
                    ForEach(ResourceClass.allCases) { resource in
                        Text(resource.title).tag(resource)
                    }
                }
                Picker("工人轨道", selection: $track) {
                    ForEach(BuilderTrack.allCases) { track in
                        Text(track.title).tag(track)
                    }
                }
                Stepper("优先级 (priority)", value: $priority, in: 1...100)
                Toggle("允许在规划窗口内重复", isOn: $isRepeatable)
                Toggle("部落战敏感项", isOn: $highWarImpact)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("加入规划") {
                    let duration = Double(durationText.replacingOccurrences(of: ",", with: ".")) ?? 1
                    let estimatedCost = Int(estimatedCostText.replacingOccurrences(of: ",", with: "")) ?? 0
                    onSave(UpgradeTask(
                        name: name.isEmpty ? "未命名升级" : name,
                        category: category,
                        durationDays: duration,
                        resource: resource,
                        priority: priority,
                        warImpact: highWarImpact ? .high : .medium,
                        track: track,
                        isRepeatable: isRepeatable,
                        estimatedCost: estimatedCost
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
    }
}

struct RulesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("规划规则")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Builder Roadmap 的价值不在于给出一个看似精确的天数，而在于把长期选择公开成可检查的取舍。")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                RuleCard(number: "01", title: "先保护部落战体验", text: "联赛模式下，开启“保留英雄”会把英雄任务推迟到保护窗口之后；部落战优先模式则提醒你手动处理关键战期。")
                RuleCard(number: "02", title: "建筑与科技同时看", text: "建筑工人和实验室是两条独立队列。规划器会把两者放到同一条时间轴，暴露“建筑升级了但进攻科技没跟上”的错位。")
                RuleCard(number: "03", title: "库存决定任务能否启动", text: "规划器会读取当前资源、容量和日收入；如果成本暂时不够，会把任务后移并标记库存原因。")
                RuleCard(number: "04", title: "大本营要有准备度", text: "大本营不是永远的最高优先级。你可以标记还没准备好，规划器会留出缓冲，并在判断区解释原因。")
                RuleCard(number: "05", title: "版本数据和账号状态分离", text: "游戏数据目录负责版本、成本和默认工期；账号填写的当前剩余时间优先，不会被数据层静默覆盖。")
            }
            .padding(28)
        }
        .background(Color.cocBackground)
    }
}

struct RuleCard: View {
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

private extension UpgradeCategory {
    var systemImage: String {
        switch self {
        case .townHall: "building.2.fill"
        case .building: "building.fill"
        case .defense: "shield.lefthalf.filled"
        case .hero: "person.crop.circle.badge.star"
        case .wall: "rectangle.split.3x1"
        case .trap: "exclamationmark.octagon"
        case .resource: "shippingbox.fill"
        case .research: "flask.fill"
        }
    }

    var tint: Color {
        switch self {
        case .townHall: .purple
        case .building: .blue
        case .defense: .red
        case .hero: .orange
        case .wall: .brown
        case .trap: .green
        case .resource: .cyan
        case .research: .indigo
        }
    }
}

private extension Color {
    static let cocAccent = Color(red: 0.47, green: 0.54, blue: 1.0)
    static let cocBackground = Color(red: 0.055, green: 0.063, blue: 0.09)
    static let cocPanel = Color(red: 0.105, green: 0.12, blue: 0.17)
    static let cocElevated = Color(red: 0.14, green: 0.155, blue: 0.21)
}
