import SwiftUI
import AppKit
import COCHelperCore

/// Issue #65：精制台专用的 Defense → Module 只读表。
///
/// 根精制台只提供容器语义，不作为普通建筑行渲染；每个 Defense 左列一行，
/// 右列展示其模块、属性、当前/最高等级和快照状态。
struct CraftTableView: View {
    let defenses: [CraftTableDefenseState]
    let catalogVersion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let catalogVersion {
                Text("静态模组目录 v" + catalogVersion)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }

            if defenses.isEmpty {
                Text("当前快照没有精制台 Defense 数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(defenses) { defense in
                    defenseRow(defense)
                    if defense.id != defenses.last?.id {
                        Divider().padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private func defenseRow(_ defense: CraftTableDefenseState) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                CraftTableAssetIcon(
                    url: CraftTableTypeIconCatalog.bundledURL(for: defense.dataID),
                    fallback: "shield.lefthalf.filled",
                    size: 52
                )
                Text(defense.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("Defense #" + String(defense.dataID))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                if let currentLevel = defense.currentLevel {
                    Text("当前等级 " + String(currentLevel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let availabilityLabel = defense.availability.displayLabel {
                    Text(availabilityLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 180, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(defense.modules) { module in
                    moduleRow(module)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func moduleRow(_ module: CraftTableModuleState) -> some View {
        HStack(spacing: 10) {
            CraftTableAssetIcon(
                url: ModuleUpgradeIconCatalog.bundledURL(for: module.dataID),
                fallback: "chart.bar.fill",
                size: 30
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(module.attributeLabel ?? module.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if module.attributeLabel != nil {
                    Text(module.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let missingReason = module.missingReason {
                    Text(missingReason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(levelLabel(for: module))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(statusLabel(for: module))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(for: module))
                if module.isUpgrading, let remainingSeconds = module.remainingSeconds {
                    Text(AccountDurationFormatter.label(remainingSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func levelLabel(for module: CraftTableModuleState) -> String {
        let current = module.currentLevel.map(String.init) ?? "未记录"
        let maximum = module.maxLevel.map(String.init) ?? "—"
        return current + "/" + maximum
    }

    private func statusLabel(for module: CraftTableModuleState) -> String {
        if module.isUpgrading { return "正在升级" }
        if module.needsReimport { return "计时已结束" }
        switch module.status {
        case .recorded: return "已记录"
        case .maxed: return "已满级"
        case .upgrading: return "正在升级"
        case .unknown: return "未知"
        }
    }

    private func statusColor(for module: CraftTableModuleState) -> Color {
        if module.isUpgrading { return .orange }
        switch module.status {
        case .recorded: return .secondary
        case .maxed: return .green
        case .upgrading: return .orange
        case .unknown: return .orange
        }
    }
}

private struct CraftTableAssetIcon: View {
    let url: URL?
    let fallback: String
    let size: CGFloat

    var body: some View {
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.58, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
