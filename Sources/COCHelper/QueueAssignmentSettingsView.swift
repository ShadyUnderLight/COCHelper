import SwiftUI
import COCHelperApp
import COCHelperCore

/// Issue #183：导入观察的本地队列映射面板。
///
/// 列出当前村庄所有导入观察项；按 Issue #189 的证据资格投影展示可执行
/// 操作：未分配且证据合格时提供「确认分配」；`observedOnly` 且证据恢复时
/// 提供「重新确认」；证据不足时只显示原因，不让用户点击后才收到预期内
/// 的命令错误。这是用户显式的本地工作流判断，不代表游戏官方队列事实；
/// 映射不修改任何导入原始数据。
struct QueueAssignmentSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let villageID: UUID
    let onDone: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        let candidates = model.queueAssignmentCandidates(for: villageID)
        VStack(alignment: .leading, spacing: 12) {
            Text("导入观察的本地队列")
                .font(.title2.weight(.bold))
            Text("确认后，该导入计时作为本地规划占用计入容量；这是本地记录，不是游戏官方队列事实。未确认的导入计时永不占用容量。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            if candidates.isEmpty {
                Text("当前没有可确认的导入观察。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(candidates) { candidate in
                            row(candidate)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ candidate: ImportedObservationCandidate) -> some View {
        let assignment = candidate.assignment
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                statusBadge(candidate)
            }
            actionRow(candidate, assignment: assignment)
            // Issue #183 review P2：旧 lineage 历史映射必须可见（审计证据，
            // 不占当前容量；解除操作只作用于当前 lineage）。
            if !candidate.historicalAssignments.isEmpty {
                let kinds = candidate.historicalAssignments
                    .map { $0.queueKind.displayName }
                    .joined(separator: "、")
                Text("历史映射（旧账号/旧身份，不占当前容量）：\(kinds)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(Color.cocBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Issue #189：按「当前候选状态 + 证据资格」投影可执行操作。
    ///
    /// 资格（`candidate.isConfirmable`）由 AppModel 基于 Core 谓词提供，
    /// View 不自行推断 timer/coverage。证据不足时不渲染可执行菜单，只显示
    /// 原因，避免用户点击后才收到预期内的命令错误。
    @ViewBuilder
    private func actionRow(
        _ candidate: ImportedObservationCandidate,
        assignment: QueueAssignmentDecision?
    ) -> some View {
        switch assignment?.status {
        case .userAssigned:
            if let assignment {
                HStack(spacing: 8) {
                    Text("已分配：\(assignment.queueKind.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("解除分配", role: .destructive) {
                        unassign(candidate)
                    }
                    .font(.caption)
                }
            }
        case .observedOnly:
            if candidate.isConfirmable {
                HStack(spacing: 8) {
                    Text("证据已恢复，重新确认前不占容量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu {
                        ForEach(LocalQueueKind.knownKinds, id: \.self) { kind in
                            Button(kind.displayName) {
                                assign(candidate, queueKind: kind)
                            }
                        }
                    } label: {
                        Label("重新确认到队列…", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    Button("解除分配", role: .destructive) {
                        unassign(candidate)
                    }
                    .font(.caption)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(candidate.displayName)：观察已结束，证据已恢复，可重新确认到本地队列；重新确认前不占本地容量"
                )
            } else {
                HStack(spacing: 8) {
                    Text(candidate.unconfirmableReason ?? "等待完整观察/无进行中计时")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("解除分配", role: .destructive) {
                        unassign(candidate)
                    }
                    .font(.caption)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(candidate.displayName)：\(candidate.unconfirmableReason ?? "等待完整观察/无进行中计时")，可解除分配"
                )
            }
        case .unknown:
            HStack(spacing: 8) {
                Text("身份不可靠，保留历史证据，不提供当前确认")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("解除分配", role: .destructive) {
                    unassign(candidate)
                }
                .font(.caption)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(candidate.displayName)：身份不可靠，保留历史证据，不提供当前确认，可解除分配"
            )
        case nil:
            if candidate.isConfirmable {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(LocalQueueKind.knownKinds, id: \.self) { kind in
                            Button(kind.displayName) {
                                assign(candidate, queueKind: kind)
                            }
                        }
                    } label: {
                        Label("确认分配到队列…", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    Text("未分配本地队列")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Text(candidate.unconfirmableReason ?? "暂不能确认")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("未分配本地队列")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(candidate.displayName)：未分配本地队列，\(candidate.unconfirmableReason ?? "暂不能确认")"
                )
            }
        }
    }

    private func statusBadge(_ candidate: ImportedObservationCandidate) -> some View {
        guard let assignment = candidate.assignment else {
            return Text("未分配")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        switch assignment.status {
        case .userAssigned:
            return Text("已确认")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15), in: Capsule())
        case .observedOnly:
            if candidate.isConfirmable {
                // Issue #189：证据已恢复但尚未重新确认。
                return Text("等待重新确认")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            } else {
                return Text("观察已结束/未确认")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }
        case .unknown:
            return Text("身份不可靠")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: Capsule())
        }
    }

    private func assign(_ candidate: ImportedObservationCandidate, queueKind: LocalQueueKind) {
        do {
            try model.assignQueueToImportedObservation(
                for: villageID, itemKey: candidate.itemKey, queueKind: queueKind
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func unassign(_ candidate: ImportedObservationCandidate) {
        do {
            try model.unassignQueueFromImportedObservation(
                for: villageID, itemKey: candidate.itemKey
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
