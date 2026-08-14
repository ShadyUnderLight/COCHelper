import SwiftUI
import COCHelperApp
import COCHelperCore

/// Issue #145：本地队列容量配置面板。
///
/// 容量是 userConfigured 的本地工作流事实，不代表游戏实际队列；只约束
/// 未来 local manual start。未配置的类别不做任何容量校验。
struct ManualQueueCapacitySettingsView: View {
    @EnvironmentObject private var model: AppModel
    let villageID: UUID
    let onDone: () -> Void

    @State private var capacityTexts: [String: String] = [:]
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地队列容量")
                .font(.title2.weight(.bold))
            Text("容量只约束本地手动升级的开始操作，不代表游戏实际队列；导入快照中的升级计时不计入容量。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ForEach(LocalQueueKind.knownKinds, id: \.self) { kind in
                capacityRow(kind)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: loadCurrent)
        .alert("容量配置无效", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func capacityRow(_ kind: LocalQueueKind) -> some View {
        let occupancy = model.queueOccupancy(for: villageID, queueKind: kind)
        return HStack(spacing: 10) {
            Text(kind.displayName)
                .frame(width: 90, alignment: .leading)
            TextField("未配置", text: Binding(
                get: { capacityTexts[kind.rawValue] ?? "" },
                set: { capacityTexts[kind.rawValue] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            Text("个同时升级")
            Spacer()
            if occupancy.isCapacityConfigured {
                Text("占用 \(occupancy.activeManualCount)/\(occupancy.capacity ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func loadCurrent() {
        capacityTexts = [:]
        for kind in LocalQueueKind.knownKinds {
            let occupancy = model.queueOccupancy(for: villageID, queueKind: kind)
            if let capacity = occupancy.capacity {
                capacityTexts[kind.rawValue] = String(capacity)
            }
        }
    }

    private func save() {
        for kind in LocalQueueKind.knownKinds {
            let text = capacityTexts[kind.rawValue] ?? ""
            if text.isEmpty {
                try? model.clearQueueCapacity(for: villageID, queueKind: kind)
                continue
            }
            guard let capacity = Int(text) else {
                errorMessage = "「\(kind.displayName)」容量必须是整数。"
                return
            }
            do {
                try model.setQueueCapacity(for: villageID, queueKind: kind, capacity: capacity)
            } catch ManualUpgradeCommandError.queueCapacityInvalid {
                errorMessage = "「\(kind.displayName)」容量必须在 0 到 \(LocalQueueCapacityConfig.maximumCapacity) 之间。"
                return
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                return
            }
        }
        onDone()
    }
}
