import SwiftUI
import COCHelperCore
import COCHelperApp

/// Issue #144：手动升级动作确认面板（Start / Cancel / Adjust）。
///
/// 契约：
/// - Start：展示 stable identity、from → target、quantity、多资源成本（含
///   unknown/raw 证据）、duration/instant、catalog 版本与来源，以及
///   「这是本地记录，不会操作游戏」明确文案；cost unknown 不阻塞。
/// - Cancel：只对 active manual 记录显示，不修改 imported snapshot。
/// - Adjust：startedAt 不允许未来；调整后由 Core 重算，已到期立即 settle。
enum ManualUpgradeActionSheet: Identifiable {
    case start(UpgradeAction)
    case cancel(ManualUpgradeRecord)
    case adjust(ManualUpgradeRecord)

    var id: String {
        switch self {
        case .start(let action): "start:" + action.id
        case .cancel(let record): "cancel:" + record.recordID.uuidString
        case .adjust(let record): "adjust:" + record.recordID.uuidString
        }
    }
}

struct ManualUpgradeActionSheetView: View {
    @EnvironmentObject private var model: AppModel
    let sheet: ManualUpgradeActionSheet
    let villageID: UUID
    let onDone: () -> Void

    @State private var adjustDate: Date = Date()
    @State private var errorMessage: String?
    @State private var busy = false
    // Issue #145：Start 队列类别选择（"" = 不归类）。
    @State private var selectedQueueRawValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch sheet {
            case .start(let action):
                startContent(action)
            case .cancel(let record):
                cancelContent(record)
            case .adjust(let record):
                adjustContent(record)
                    // review P1-3：默认时间必须是现有记录 startedAt，
                    // 用户直接确认不会把原始开始时间静默改成打开时刻。
                    .onAppear { adjustDate = record.startedAt }
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Start

    private func startContent(_ action: UpgradeAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开始本地升级")
                .font(.title2.weight(.bold))
            identityRow(action)
            Divider()
            detailGrid(action)
            Divider()
            queueKindBlock
            Divider()
            costBlock(action)
            Divider()
            localOnlyNote
            HStack {
                Spacer()
                Button("取消") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "正在记录…" : "确认开始") {
                    confirmStart(action)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
                .disabled(busy || isSelectedQueueFull)
            }
        }
    }

    private func identityRow(_ action: UpgradeAction) -> some View {
        HStack {
            Text(action.itemName)
                .font(.headline)
            Text(action.itemKey.stableID)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private func detailGrid(_ action: UpgradeAction) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("等级").foregroundStyle(.secondary)
                Text("\(action.fromLevel ?? -1) → \(action.targetLevel ?? -1)")
                    .monospacedDigit()
            }
            GridRow {
                Text("数量").foregroundStyle(.secondary)
                Text("×\(action.quantity)")
                    .monospacedDigit()
            }
            GridRow {
                Text("时长").foregroundStyle(.secondary)
                Text(action.durationState.map { $0 == .instant ? "即时" : $0.durationLabel } ?? "未知")
            }
            GridRow {
                Text("目录版本").foregroundStyle(.secondary)
                Text(action.catalogProvenance?.gameVersion ?? "不可用")
                    .monospaced()
            }
            if let provenance = action.catalogProvenance, let buildTag = provenance.buildTag {
                GridRow {
                    Text("目录来源").foregroundStyle(.secondary)
                    Text("buildTag " + buildTag)
                        .font(.caption2.monospaced())
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func costBlock(_ action: UpgradeAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("升级费用")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let costs = action.frozenCosts, !costs.isEmpty {
                ForEach(costs, id: \.self) { cost in
                    Text(costLine(cost))
                        .font(.callout)
                }
                if costs.contains(where: \.parseFailed) {
                    Text("部分费用解析失败，保留原始证据；这只是本地记录。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("费用未知（目录未提供）；这只是本地记录。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func costLine(_ cost: CatalogUpgradeCost) -> String {
        if cost.parseFailed {
            return "\(cost.rawResource ?? cost.resource)：\(cost.rawAmount ?? "解析失败")（原始值）"
        }
        if let amount = cost.amount {
            return "\(cost.resource)：\(amount)"
        }
        return "\(cost.resource)：未知"
    }

    private var localOnlyNote: some View {
        Label("这是本地记录，不会操作游戏。", systemImage: "externaldrive.badge.checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Issue #145 队列类别与容量

    private var selectedQueueKind: LocalQueueKind? {
        selectedQueueRawValue.isEmpty
            ? nil
            : LocalQueueKind(rawValue: selectedQueueRawValue)
    }

    /// 已选队列的占用投影；未归类时为 nil。
    private var selectedOccupancy: LocalQueueOccupancy? {
        selectedQueueKind.map { model.queueOccupancy(for: villageID, queueKind: $0) }
    }

    private var isSelectedQueueFull: Bool {
        selectedOccupancy?.isFull ?? false
    }

    /// 队列类别选择 + 本地占用/容量摘要 + imported 不占用的固定诊断。
    private var queueKindBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("队列类别", selection: $selectedQueueRawValue) {
                Text("不归类").tag("")
                ForEach(LocalQueueKind.knownKinds, id: \.self) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            if let occupancy = selectedOccupancy {
                switch occupancy.status {
                case .available:
                    if occupancy.isCapacityConfigured {
                        Label(
                            "本地占用 \(occupancy.activeManualCount)/\(occupancy.capacity ?? 0)",
                            systemImage: "rectangle.stack.badge.person.crop"
                        )
                        .font(.caption)
                        .foregroundStyle(occupancy.isFull ? .red : .secondary)
                        if occupancy.isFull {
                            Text("本地容量已满，不能开始新的本地升级。")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Label("未配置容量，不限制本地升级。", systemImage: "rectangle.stack")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .unreconciled:
                    // Issue #192：未对账时不得显示旧 overlay/manual 占用数字，
                    // 也不得给出「容量已满」结论；明确提示尚未对账。
                    Label(
                        "快照尚未对账，当前容量占用暂不可确认",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                case .unavailable:
                    Label(
                        "手动升级存储不可用，暂无法确认占用",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            Label(
                "导入快照中的升级计时不计入本地容量；本地记录与导入计时相互独立。",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func confirmStart(_ action: UpgradeAction) {
        busy = true
        do {
            let record = try model.startManualUpgrade(
                for: villageID,
                action: action,
                startedAt: Date(),
                queueKind: selectedQueueKind
            )
            if record.status == .completed {
                onDone()
            } else {
                onDone()
            }
        } catch {
            busy = false
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Cancel

    private func cancelContent(_ record: ManualUpgradeRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("取消升级")
                .font(.title2.weight(.bold))
            Text("取消「\(record.itemKey.stableID)」从 \(record.fromLevel) 级到 \(record.targetLevel) 级的本地记录。")
                .font(.callout)
            Text("取消只影响本地记录，不会修改已导入的快照。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("不取消") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "正在取消…" : "确认取消", role: .destructive) {
                    confirmCancel(record)
                }
                .disabled(busy)
            }
        }
    }

    private func confirmCancel(_ record: ManualUpgradeRecord) {
        busy = true
        do {
            _ = try model.cancelManualUpgrade(for: villageID, recordID: record.recordID)
            onDone()
        } catch {
            busy = false
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Adjust

    private func adjustContent(_ record: ManualUpgradeRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("调整开始时间")
                .font(.title2.weight(.bold))
            Text("「\(record.itemKey.stableID)」当前预计完成：\(record.expectedEndAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout)
            DatePicker(
                "开始时间",
                selection: $adjustDate,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            Text("调整会影响本地倒计时，不代表修改了游戏内实际升级时间。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "正在调整…" : "确认调整") {
                    confirmAdjust(record)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
                .disabled(busy)
            }
        }
    }

    private func confirmAdjust(_ record: ManualUpgradeRecord) {
        busy = true
        do {
            _ = try model.adjustManualUpgradeStart(
                for: villageID,
                recordID: record.recordID,
                startedAt: adjustDate,
                now: Date()
            )
            onDone()
        } catch {
            busy = false
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
