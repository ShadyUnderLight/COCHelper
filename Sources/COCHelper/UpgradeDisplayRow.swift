import SwiftUI
import COCHelperCore

/// Issue #15：升级总览 / 村庄详情共用的升级行组件。
///
/// 输入 `UpgradeDisplayRecord`（投影聚合层），展示：
/// - 图标列：目录图标资产当前全部未渲染（renderedPath == nil），统一走类别
///   SF Symbol 兜底；`item.missingReason` 存在时用 `.help` 提示原因，不隐藏行。
///   渲染管线就绪后在此接入 `renderedPath` 加载，替换兜底图标。
/// - 名称 × 数量、嵌套标记、副标题（类别 · #dataID · 目录版本）
/// - 完整时长行（目录缺失时显示「暂无目录数据」，绝不显示 0）
/// - 当前 → 目标等级；状态徽标（目录版本不匹配 / 待重新导入确认 / 已满级）
/// - 剩余时间 + 完成时刻 + 进度条（沿用旧行样式：orange）
///
/// 共享：升级总览与村庄详情页（Issue #15 后续）都使用本组件，
/// 村庄详情页通过 `showsVillageColumn = false` 隐藏村庄列。
struct UpgradeDisplayRow: View {
    let record: UpgradeDisplayRecord
    let now: Date
    /// 村庄详情页复用时可隐藏村庄列。
    var showsVillageColumn: Bool = true

    private var item: VillageItemState { record.item }

    // MARK: - 等级

    private var levelLabel: String {
        if let currentLevel = item.currentLevel {
            if let nextLevel = item.nextLevel {
                return String(currentLevel) + " → " + String(nextLevel)
            }
            return "等级 " + String(currentLevel)
        }
        return "等级未记录"
    }

    // MARK: - 状态徽标

    /// 目录版本不匹配：nextLevel 存在且超过目录 maxLevel（目录可能过时）。
    private var hasVersionMismatch: Bool {
        guard let nextLevel = item.nextLevel, let maxLevel = item.maxLevel else { return false }
        return nextLevel > maxLevel
    }

    /// 计时已结束（timer 存在、remaining 归零）：需要重新导入确认实际等级。
    /// 不做自动等级 +1——nextLevel 只来自投影显式推断。
    private var needsReimport: Bool { item.remainingSeconds == 0 }

    private var isMaxed: Bool { item.status == .maxed }

    // MARK: - 完整时长

    private var durationLabel: String {
        guard let duration = item.nextLevelDurationSeconds, duration > 0 else { return "暂无目录数据" }
        return "完整时长：" + AccountDurationFormatter.label(duration)
    }

    // MARK: - 副标题

    private var catalogVersionLabel: String {
        record.catalogVersion.map { "v" + $0 } ?? "目录不可用"
    }

    private var subtitle: String {
        (item.category?.title ?? item.section) + " · #" + String(item.dataID) + " · " + catalogVersionLabel
    }

    // MARK: - 进度

    private var progress: Double? {
        guard let timerSeconds = item.timerSeconds, timerSeconds > 0,
              let remainingSeconds = item.remainingSeconds else { return nil }
        return min(1, max(0, 1 - Double(remainingSeconds) / Double(timerSeconds)))
    }

    // MARK: - 图标

    private var iconHelp: String {
        if let missingReason = item.missingReason { return missingReason }
        return "目录图标未渲染，显示类别图标"
    }

    private var iconImageName: String {
        item.category?.systemImage ?? "hammer.fill"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconImageName)
                .font(.body)
                .foregroundStyle(item.category?.tint ?? Color.secondary)
                .frame(width: 24)
                .help(iconHelp)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let count = item.count, count > 1 {
                        Text("×" + String(count))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.07), in: Capsule())
                    }
                    if item.isNested {
                        Text("嵌套")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(durationLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            if showsVillageColumn {
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
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text(levelLabel)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.orange)
                if hasVersionMismatch {
                    StatusBadge(text: "目录版本不匹配", tint: .red)
                }
                if needsReimport {
                    StatusBadge(text: "待重新导入确认", tint: .orange)
                }
                if isMaxed {
                    StatusBadge(text: "已满级", tint: .green)
                        .help("当前目录最高等级")
                }
            }
            .frame(width: 130, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 4) {
                if let remainingSeconds = item.remainingSeconds, remainingSeconds > 0 {
                    Text(AccountDurationFormatter.label(remainingSeconds, zeroLabel: "已完成"))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                    if let completionDate = record.completionDate(from: now) {
                        Text("完成 " + completionDate.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.orange)
                            .frame(width: 112)
                    }
                } else if needsReimport {
                    Text("计时已结束")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Text(isMaxed ? "已满级" : "已记录")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }
}

/// 行内状态徽标（目录版本不匹配 / 待重新导入确认 / 已满级）。
struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

extension TrackerCategory {
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
