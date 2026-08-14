import SwiftUI
import COCHelperApp
import COCHelperCore

/// Issue #183：导入观察的本地队列映射面板。
///
/// 列出当前村庄所有导入观察项；未分配时显示「未分配本地队列」，提供
/// 「确认分配 / 解除分配」操作。这是用户显式的本地工作流判断，不代表
/// 游戏官方队列事实；映射不修改任何导入原始数据。
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
            } else {
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
            }
        }
        .padding(8)
        .background(Color.cocBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
            return Text("观察已结束/未确认")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: Capsule())
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
