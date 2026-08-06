import SwiftUI
import AppKit
import COCHelperCore

/// Issue #16：项目逐级升级详情 sheet。
///
/// 数据来源：`GameCatalog.item(section:dataID:)` 的 `levels` 数组（逐级时长、
/// 费用、解锁条件）。嵌套 items（`.types.`/`.modules.`）与目录未收录项
/// 与投影层同规则不 join，显示缺失原因而不是伪造数据。
/// Issue #25：头部图标与逐级行图标渲染目录 PNG（levelVisual 优先、icon 兜底），
/// 均不可渲染/加载失败时回退 SF Symbol，不崩溃。
struct LevelDetailSheet: View {
    let item: VillageItemState
    let catalog: GameCatalog?

    @Environment(\.dismiss) private var dismiss

    /// 目录项；嵌套项/未收录返回 nil（与投影层 join 规则一致）。
    private var catalogItem: CatalogItem? {
        guard !item.isNested else { return nil }
        return catalog?.item(section: item.section, dataID: item.dataID)
    }

    private var levelRows: [CatalogLevel] {
        catalogItem?.levels.sorted { $0.level < $1.level } ?? []
    }

    private var statusLabel: String {
        switch item.status {
        case .upgrading: "正在升级"
        case .maxed: "已满级"
        case .complete: "已记录"
        case .unknown: "目录未收录"
        case .unavailable: "不参与升级追踪"
        case .available: "目录中可用"
        }
    }

    private var missingNote: String? {
        if item.isNested {
            return "嵌套模块/类型不参与静态目录 join（\(item.section):\(item.dataID)），无逐级数据。"
        }
        if catalogItem == nil {
            return item.missingReason ?? "静态目录未收录该项目，无逐级数据。"
        }
        return nil
    }

    private func durationLabel(_ level: CatalogLevel) -> String {
        guard let seconds = level.durationSeconds else { return "暂无目录数据" }
        if seconds > 0 { return AccountDurationFormatter.label(seconds) }
        return "即时"
    }

    private func unlockLabel(_ level: CatalogLevel) -> String {
        var parts: [String] = []
        if let th = level.requiredTownHallLevel { parts.append("大本营 " + String(th) + " 级") }
        if let lab = level.requiredLaboratoryLevel { parts.append("实验室 " + String(lab) + " 级") }
        return parts.isEmpty ? "无解锁条件" : parts.joined(separator: " · ")
    }

    private func costLabel(_ level: CatalogLevel) -> String {
        guard let cost = level.upgradeCost else { return "无费用数据" }
        let resource = level.upgradeResource ?? "资源"
        return resource + " " + String(cost)
    }

    /// 资产解析的目录版本：优先当前 catalog 的 gameVersion，缺失时回落
    /// bundled 默认版本（与 `loadBundled()` 同源，避免未来多版本错配）。
    private var assetVersion: String {
        catalog?.gameVersion ?? GameCatalog.defaultBundledVersion
    }

    /// 头部图标引用：levelVisual 优先、icon 兜底（与列表行共用
    /// `VillageItemState.preferredAssetRef` 谓词防漂移）。
    /// 目录中部分 item（如兵营 buildings:1000000）icon 为 nil 但 levelVisual
    /// 可渲染（fireplace_lvl1.png）——头部必须与逐级行一致显示真实外观。
    private var itemAssetRef: CatalogAssetRef? {
        item.preferredAssetRef
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Group {
                            if let url = itemAssetRef?.bundledURL(version: assetVersion),
                               let nsImage = NSImage(contentsOf: url) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 36, height: 36)
                            } else {
                                Image(systemName: item.category?.systemImage ?? "hammer.fill")
                                    .font(.title2)
                                    .foregroundStyle(item.category?.tint ?? Color.secondary)
                                    .frame(width: 36)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.title3.weight(.bold))
                            Text(item.category?.title ?? item.section)
                                + Text(" · #" + String(item.dataID))
                            Text(statusLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.status == .maxed ? .green : (item.isUpgrading ? .orange : .secondary))
                        }
                    }

                    if let missingNote {
                        Label(missingNote, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text("全部等级（目录 v" + (catalog?.gameVersion ?? "?") + "）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 0) {
                            ForEach(levelRows) { level in
                                levelRow(level)
                                if level.id != levelRows.last?.id {
                                    Divider().padding(.leading, 12)
                                }
                            }
                        }
                        .background(Color.cocPanel, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(24)
            }
            .background(Color.cocBackground)
            .navigationTitle(item.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    /// 逐级图标：levelVisual 优先（等级外观是逐级语义核心），icon 兜底；
    /// 两者均不可渲染/加载失败 → nil（SF Symbol 兜底，不崩溃）。
    /// 返回原始 `Image`（修饰链在调用处拼装，避免 `some View` 类型歧义）。
    private func levelAssetImage(_ level: CatalogLevel) -> Image? {
        let ref = (level.levelVisual?.isRenderable == true) ? level.levelVisual
            : ((level.icon?.isRenderable == true) ? level.icon : nil)
        guard let url = ref?.bundledURL(version: assetVersion),
              let nsImage = NSImage(contentsOf: url) else {
            return nil
        }
        return Image(nsImage: nsImage)
    }

    private func levelRow(_ level: CatalogLevel) -> some View {
        let isCurrent = item.currentLevel == level.level
        // 升级中：item.nextLevel（投影显式推断）；非升级未满级：currentLevel + 1
        // （与 UpgradeDisplayRow.durationLabel 的「下一级 Lv N」推导同规则）。
        let effectiveNext = item.nextLevel ?? (item.currentLevel.map { $0 + 1 })
        let isNext = effectiveNext == level.level
        return HStack(spacing: 12) {
            Group {
                if let img = levelAssetImage(level) {
                    img
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: item.category?.systemImage ?? "hammer.fill")
                        .font(.body)
                        .foregroundStyle(item.category?.tint ?? Color.secondary)
                        .frame(width: 28, height: 28)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Lv " + String(level.level))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                    if isCurrent {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15), in: Capsule())
                    }
                    if isNext {
                        Text("下一级")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(durationLabel(level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(costLabel(level))
                    .font(.caption)
                Text(unlockLabel(level))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isCurrent ? Color.blue.opacity(0.07) : Color.clear)
    }
}
