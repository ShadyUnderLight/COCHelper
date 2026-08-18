import SwiftUI
import AppKit
import COCHelperCore

/// Issue #47：升级列表与详情 Sheet 共用的图标/间距常量。
///
/// 图标资源选择仍由投影层的 `preferredAssetURLs` 决定；这里仅统一 UI
/// 绘制槽位，确保 PNG、SF Symbol、总览分隔线和村庄详情行不会尺寸漂移。
enum UpgradeDisplayLayout {
    static let listIconSize: CGFloat = 48
    static let listIconColumnWidth: CGFloat = 60
    static let listDividerLeading: CGFloat = 70
    static let nestedIndent: CGFloat = 24
    static let detailHeaderIconSize: CGFloat = 52
    static let detailLevelIconSize: CGFloat = 36
    /// Issue #70：村庄详情页三指标卡行布局（metricsBar/metricRow）。
    static let metricRowTitleWidth: CGFloat = 96
    static let metricProgressMaxWidth: CGFloat = 180
    static let metricPercentWidth: CGFloat = 44
}

/// Issue #15：升级总览 / 村庄详情共用的升级行组件。
///
/// 输入 `UpgradeDisplayRecord`（投影聚合层），展示：
/// - 图标列：`item.preferredAssetURLs` 非空且可加载时渲染 APK/目录 PNG（`bundledURL()`
///   解析 + NSImage 加载；精制台模组/父级类型图标优先，普通项 4 级候选链
///   currentLevelVisual → currentLevelIcon → levelVisual → icon，Issue #39（按 currentLevel 显示对应等级外观，
///   level-level 资产优先于 item-level）/#34，与详情 sheet 共用
///   `VillageItemState.preferredAssetURLs` 解析防漂移）；加载失败
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
        if let currentLevel = item.effectiveCurrentLevel {
            if let nextLevel = item.effectiveTargetLevel {
                return String(currentLevel) + " → " + String(nextLevel)
            }
            return "等级 " + String(currentLevel)
        }
        return "等级未记录"
    }

    // MARK: - 状态徽标

    /// 目录版本不匹配：nextLevel 存在且超过目录 maxLevel（目录可能过时）。
    private var hasVersionMismatch: Bool {
        guard let nextLevel = item.effectiveTargetLevel, let maxLevel = item.maxLevel else { return false }
        return nextLevel > maxLevel
    }

    /// 计时已结束（timer 存在、remaining 归零）：需要重新导入确认实际等级。
    /// 复用 `VillageItemState.effectivelyNeedsReimport` 公共谓词（与投影层
    /// `pendingReimportRecords` 完全一致，避免两处手写条件漂移）。本组件会被村庄
    /// 详情页复用、届时可能直接展示非聚合 item，普通完成项（remaining == 0 且
    /// timer == nil）不得误标。不做自动等级 +1——nextLevel 只来自投影显式推断。
    private var needsReimport: Bool {
        item.effectivelyNeedsReimport
    }

    private var isMaxed: Bool {
        item.isEffectivelyMaxed
    }

    /// 阶段满级（Issue #67）：currentStageMaxLevel 存在且低于全局 maxLevel——
    /// 当前大本营阶段已达目录上限，但目录全局仍有更高等级。仅用于 maxed
    /// 分支内的文案区分；`hasVersionMismatch` 保持全局语义（升级中 nextLevel
    /// 超过阶段上限属正常升级，不是目录过时，不参与版本不匹配判定）。
    private var isStageMaxed: Bool {
        guard let stage = item.currentStageMaxLevel, let max = item.maxLevel else { return false }
        return stage < max
    }

    // MARK: - 完整时长

    private var durationLabel: String {
        if item.isEffectivelyMaxed {
            // 已满级：目录无下一级，显示上限（避免误导的「暂无目录数据」）。
            // Issue #67：阶段满级（currentStageMaxLevel < maxLevel）与全局满级区分。
            let baseLabel: String
            if let stage = item.currentStageMaxLevel, let max = item.maxLevel, stage < max {
                baseLabel = "当前阶段已满级（全局尚有 " + String(max - stage) + "级）"
            } else {
                baseLabel = "已达到目录最高等级 " + String(item.maxLevel ?? 0) + "级"
            }
            // Issue #68 验收 2：阶段满级（.requires，仅当目录存在更高等级时产生）
            // 追加被门槛阻塞的下一级解锁条件，替代可操作升级时长。
            if case .requires(let nextLevel, let requirements, _) = item.effectiveNextUpgrade {
                return baseLabel + " · 下一级 " + String(nextLevel) + "级 解锁条件："
                    + requirements.displayLabels(base: item.base.rawValue)
            }
            return baseLabel
        }
        guard let state = item.effectiveNextLevelDurationState else { return "暂无目录数据" }
        let prefix: String
        if item.isEffectivelyUpgrading {
            // 升级行：levelLabel 已显示「当前 → 目标」；时长行仍带「完整时长：」
            // 前缀（与旧实现一致，明确这是完整耗时而非完成时刻）。
            prefix = "完整时长："
        } else if case .available(let level, _) = item.effectiveNextUpgrade {
            // 非升级未满级（issue 列表规则要求显示下一等级）：编号来自
            // nextUpgrade 投影（Issue #68，禁止 currentLevel + 1 推导），
            // 时长来自目录。
            prefix = "下一级：" + String(level) + "级 · 完整时长："
        } else {
            prefix = "完整时长："
        }
        // Issue #74b：缺失类状态（initialLevel/notApplicable/sourceMissing/
        // parseFailed/unknownReason）直接显示原因文案，**不带 prefix**——
        // 避免「下一级：N级 · 完整时长：目录缺失」怪句。
        switch state {
        case .timed(let seconds):
            return prefix + AccountDurationFormatter.label(seconds)
        case .instant:
            // duration == 0：真实目录中城墙等即时升级（75 个 level 的 durationSeconds == 0）。
            return prefix + "即时"
        default:
            return state.durationLabel
        }
    }

    // MARK: - 副标题

    private var catalogVersionLabel: String {
        record.catalogVersion.map { "v" + $0 } ?? "目录不可用"
    }

    private var subtitle: String {
        // Issue #74a：源目录标记已废弃（历史数据，不参与当前内容）。
        let deprecated = item.isCatalogDeprecated ? " · 已废弃" : ""
        return (item.displayCategory?.title ?? item.category?.title ?? item.section)
            + " · #" + String(item.dataID) + " · " + catalogVersionLabel + deprecated
    }

    // MARK: - 进度

    private var progress: Double? {
        let manualDuration = item.effectiveState?.activeManualRecords.count == 1
            ? item.effectiveState?.activeManualRecords.first?.durationSeconds
            : nil
        let timerSeconds = item.timerSeconds ?? manualDuration
        guard let timerSeconds, timerSeconds > 0,
              let remainingSeconds = item.effectiveRemainingSeconds(at: now) else { return nil }
        return min(1, max(0, 1 - Double(remainingSeconds) / Double(timerSeconds)))
    }

    // MARK: - 图标

    /// 目录视觉资产缺失原因（level-level 优先、icon 优先于 levelVisual，见
    /// `VillageItemState.assetMissingReason`）：当前 bundled 目录（18.400.13）
    /// 部分 item/level 资产带缺失原因（export_not_found / render_failed），
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

    /// PNG 已成功渲染时的 hover 提示：精制台嵌套项先标注 APK 图标；其余为
    /// 缺失原因优先（icon 缺失但 levelVisual
    /// 可渲染时仍需告知），无缺失原因时提示资产来源而非错误的「未渲染」
    /// （Issue #34 后 184 项建筑/陷阱行真实渲染 PNG，不能复用 SF Symbol 分支
    /// 的「未渲染」兜底文案）。
    private var pngIconHelp: String {
        if item.isNested,
           ModuleUpgradeIconCatalog.kind(for: item.dataID) != nil
            || CraftTableTypeIconCatalog.asset(for: item.dataID) != nil {
            return "精制台图标（来自游戏资源）"
        }
        if let iconMissingReason {
            return "目录图标或等级外观缺失：" + iconMissingReason
        }
        return "游戏资源图标"
    }

    private var iconImageName: String {
        item.displayCategory?.systemImage ?? item.category?.systemImage ?? "hammer.fill"
    }

    /// 目录/APK 渲染 PNG（`preferredAssetURLs` 非空且可加载时）；否则 SF Symbol 兜底。
    /// Issue #25/#34/#39：普通项视觉资产候选链为 currentLevelVisual →
    /// currentLevelIcon → levelVisual → icon；精制台模组会在该链前加入 APK 属性图标
    /// （`VillageItemState.preferredAssetURLs`，与详情 sheet 同解析防漂移）。链首为
    /// 当前等级资产（level-level，按 currentLevel 显示对应等级外观，优先于
    /// item-level）；建筑/陷阱目录项 icon 为 nil 但
    /// levelVisual 可渲染（如 buildings:1000000 fireplace_lvl1.png），列表行必须
    /// 显示真实 PNG；首选文件缺失时自动尝试次选（P2 评审），全部加载失败同样
    /// 回退 SF Symbol，不崩溃。版本参数取投影层 catalogVersion（与 `loadBundled()`
    /// 同源），避免未来多版本资源错配。
    @ViewBuilder
    private var iconView: some View {
        if let image = PerformanceImageDecode.firstDecodable(
            item.preferredAssetURLs(
                version: record.catalogVersion ?? GameCatalog.defaultBundledVersion
            )
        ) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: UpgradeDisplayLayout.listIconSize,
                       height: UpgradeDisplayLayout.listIconSize)
                .help(pngIconHelp)
        } else {
            Image(systemName: iconImageName)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(item.displayCategory?.tint ?? item.category?.tint ?? Color.secondary)
                .frame(width: UpgradeDisplayLayout.listIconSize,
                       height: UpgradeDisplayLayout.listIconSize)
                .help(iconHelp)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconView
                .overlay(alignment: .bottomTrailing) {
                    if iconMissingReason != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .offset(x: 4, y: 4)
                    }
                }
                .frame(width: UpgradeDisplayLayout.listIconColumnWidth,
                       height: UpgradeDisplayLayout.listIconColumnWidth)

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
                    StatusBadge(text: isStageMaxed ? "当前阶段已满级" : "已满级", tint: .green)
                        .help(isStageMaxed
                            ? "全局尚有 " + String(item.maxLevel! - item.currentStageMaxLevel!) + "级"
                            : "当前目录最高等级")
                }
            }
            .frame(width: 130, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 4) {
                if let remainingSeconds = item.effectiveRemainingSeconds(at: now), remainingSeconds > 0 {
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
                } else if item.status == .unverified {
                    // Issue #67 fail-closed：缺 prerequisite 无法验证阶段上限。
                    Text("无法验证阶段上限")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if let effectiveStatus = item.effectiveState?.status {
                    switch effectiveStatus {
                    case .conflict:
                        Text("本地状态冲突")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    case .unknown:
                        Text("本地状态未知")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    case .needsReimport:
                        Text("待重新导入确认")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    case .unavailable:
                        Text("不参与追踪")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .manualActive, .importedActive:
                        Text("正在升级")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    case .manualCompleted, .observed:
                        Text(isMaxed ? (isStageMaxed ? "当前阶段已满级" : "已满级") : "已记录")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } else {
                    Text(isMaxed ? (isStageMaxed ? "当前阶段已满级" : "已满级") : "已记录")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.vertical, 12)
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

/// issue #37：展示分类的 SF Symbol 着色（与 `TrackerCategory.tint` 同模式）。
extension TrackerDisplayCategory {
    var tint: Color {
        switch self {
        case .defense: .blue
        case .walls: .brown
        case .military: .orange
        case .craftTable: .purple
        }
    }
}
