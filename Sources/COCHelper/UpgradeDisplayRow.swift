import SwiftUI
import AppKit
import COCHelperCore

/// Issue #15：升级总览 / 村庄详情共用的升级行组件。
///
/// 输入 `UpgradeDisplayRecord`（投影聚合层），展示：
/// - 图标列：`item.preferredAssetRef` 可渲染时渲染目录 PNG（`bundledURL()`
///   解析 + NSImage 加载；levelVisual 优先、icon 兜底，Issue #34，与详情
///   sheet 共用 `VillageItemState.preferredAssetRef` 谓词防漂移）；加载失败
///   或不可渲染时统一走类别 SF Symbol 兜底。`item.assetMissingReason`
///   （icon 或 levelVisual 的缺失原因）非 nil 时叠加橙色警示角标（可见的
///   缺失状态）+ `.help` 提示原因，不隐藏行。
/// - 名称 × 数量、嵌套标记、副标题（类别 · #dataID · 目录版本）
/// - 完整时长行（目录缺失时显示「暂无目录数据」；duration == 0 的即时升级显示「即时」）
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
    /// 复用 `VillageItemState.needsReimport` 公共谓词（与投影层
    /// `pendingReimportRecords` 完全一致，避免两处手写条件漂移）。本组件会被村庄
    /// 详情页复用、届时可能直接展示非聚合 item，普通完成项（remaining == 0 且
    /// timer == nil）不得误标。不做自动等级 +1——nextLevel 只来自投影显式推断。
    private var needsReimport: Bool {
        item.needsReimport
    }

    private var isMaxed: Bool { item.status == .maxed }

    // MARK: - 完整时长

    private var durationLabel: String {
        if item.status == .maxed {
            // 已满级：目录无下一级，显示上限（避免误导的「暂无目录数据」）。
            return "已达目录上限 Lv " + String(item.maxLevel ?? 0)
        }
        guard let duration = item.nextLevelDurationSeconds else { return "暂无目录数据" }
        let prefix: String
        if item.isUpgrading {
            // 升级行：levelLabel 已显示「当前 → 目标」，时长不加前缀。
            prefix = "完整时长："
        } else if let currentLevel = item.currentLevel, let maxLevel = item.maxLevel, currentLevel < maxLevel {
            // 非升级未满级（投影层已推下一级时长）：issue 列表规则要求显示下一等级。
            // 编号由当前 + 1 推导（与投影层 nextLevel 推断同规则），时长来自目录。
            prefix = "下一级 Lv " + String(currentLevel + 1) + " · 完整时长："
        } else {
            prefix = "完整时长："
        }
        if duration > 0 {
            return prefix + AccountDurationFormatter.label(duration)
        }
        // duration == 0：真实目录中城墙等即时升级（75 个 level 的 durationSeconds == 0）。
        return prefix + "即时"
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

    /// 目录视觉资产缺失原因（icon 优先、levelVisual 兜底，见
    /// `VillageItemState.assetMissingReason`）：当前 bundled 目录（18.400.13）
    /// 27 个引用带缺失原因（23 个唯一键，export_not_found / render_failed），
    /// 非 nil 时 UI 必须给出可见的缺失状态（角标 + help），不能只在 hover 里。
    private var iconMissingReason: String? {
        item.assetMissingReason
    }

    /// SF Symbol 分支 help 文案优先级：目录视觉资产缺失原因（icon 或
    /// levelVisual）→ 目录 join 缺失原因 → 通用兜底（真实 PNG 渲染分支
    /// 用 `pngIconHelp`，勿在 SF Symbol 分支复用该文案）。
    private var iconHelp: String {
        if let iconMissingReason {
            return "目录图标或等级外观缺失：" + iconMissingReason
        }
        if let missingReason = item.missingReason { return missingReason }
        return "目录图标未渲染，显示类别图标"
    }

    /// PNG 已成功渲染时的 hover 提示：缺失原因优先（icon 缺失但 levelVisual
    /// 可渲染时仍需告知），无缺失原因时提示资产来源而非错误的「未渲染」
    /// （Issue #34 后 184 项建筑/陷阱行真实渲染 PNG，不能复用 SF Symbol 分支
    /// 的「未渲染」兜底文案）。
    private var pngIconHelp: String {
        if let iconMissingReason {
            return "目录图标或等级外观缺失：" + iconMissingReason
        }
        return "目录渲染资产"
    }

    private var iconImageName: String {
        item.category?.systemImage ?? "hammer.fill"
    }

    /// 目录渲染 PNG（`preferredAssetRef` 可渲染时）；否则 nil → SF Symbol 兜底。
    /// Issue #25/#34：视觉资产首选 levelVisual、icon 兜底（`VillageItemState.preferredAssetRef`，
    /// 与详情 sheet 同谓词防漂移）——建筑/陷阱目录项 icon 为 nil 但 levelVisual 可渲染
    /// （如 buildings:1000000 fireplace_lvl1.png），列表行必须显示真实 PNG。
    /// `bundledURL()` 解析 + NSImage 加载失败（Bundle 文件缺失等）同样回退 SF
    /// Symbol，不崩溃。版本参数取投影层 catalogVersion（与 `loadBundled()` 同源），
    /// 避免未来多版本资源错配。
    @ViewBuilder
    private var iconView: some View {
        if let url = item.preferredAssetRef?.bundledURL(
            version: record.catalogVersion ?? GameCatalog.defaultBundledVersion
        ), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .help(pngIconHelp)
        } else {
            Image(systemName: iconImageName)
                .font(.body)
                .foregroundStyle(item.category?.tint ?? Color.secondary)
                .frame(width: 24)
                .help(iconHelp)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconView
                .overlay(alignment: .bottomTrailing) {
                    if iconMissingReason != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .offset(x: 4, y: 4)
                    }
                }

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
                } else if item.status == .available {
                    // 目录存在但快照无记录（投影层当前不产出；#12 目录遍历接入前的防御）。
                    Text("目录中可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if item.status == .unavailable {
                    Text("不参与追踪")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if item.status == .unknown {
                    Text("目录未收录")
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
