import SwiftUI
import AppKit
import COCHelperCore

/// Issue #16：项目逐级升级详情 sheet。
///
/// 数据来源：`GameCatalog.item(section:dataID:)` 的 `levels` 数组（逐级时长、
/// 费用、解锁条件）。嵌套 items（`.types.`/`.modules.`）与目录未收录项
/// 与投影层同规则不 join，显示缺失原因而不是伪造数据。
/// Issue #25：逐级行图标渲染目录 PNG（CatalogLevel 内 levelVisual 优先、icon 兜底）；
/// Issue #39：头部图标走 4 级候选链 currentLevelVisual → currentLevelIcon →
/// levelVisual → icon（按 currentLevel 显示对应等级外观，超范围/无匹配时回退
/// item-level 资产）。均不可渲染/加载失败时回退 SF Symbol，不崩溃。
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
        case .maxed:
            // Issue #67：阶段满级（currentStageMaxLevel < maxLevel）与全局满级区分，
            // 但都不当作当前可升级项。
            if let stage = item.currentStageMaxLevel, let max = item.maxLevel, stage < max {
                "当前阶段已满级（全局尚有 \(max - stage) 级）"
            } else {
                "已满级"
            }
        case .complete: "已记录"
        case .unknown: "目录未收录"
        case .unverified: "无法验证当前阶段上限"
        case .unavailable: "不参与升级追踪"
        case .available: "目录中可用"
        }
    }

    private var missingNote: String? {
        if item.isNested {
            return "该项目属于内部子项目，暂不提供逐级升级数据。"
        }
        if item.status == .unverified {
            // Issue #67 fail-closed：缺 prerequisite 无法验证阶段上限，展示原因
            //（不伪装成可升级/未满级）。
            return item.missingReason ?? "快照缺少 prerequisite 解锁建筑记录，无法验证当前阶段上限。"
        }
        if item.status == .unknown {
            // Issue #67 P1-2 fail-closed：unknown 含版本不匹配/base 不匹配——
            // catalogItem 存在时旧目录 join 数据仍可用，但不得展示为可操作
            // 等级阶梯（旧目录等级/时长/费用）。有 missingReason 就展示原因，
            // 让 body 走提示分支而非「全部等级」列表（审核 P1：详情页旧目录泄漏）。
            return item.missingReason ?? "该项目暂无逐级升级数据。"
        }
        if catalogItem == nil {
            return item.missingReason ?? "该项目暂无逐级升级数据。"
        }
        return nil
    }

    private func durationLabel(_ level: CatalogLevel) -> String {
        guard let seconds = level.durationSeconds else { return "暂无目录数据" }
        if seconds > 0 { return AccountDurationFormatter.label(seconds) }
        return "即时"
    }

    /// 逐级解锁条件（Issue #67）：按 item.base 解析 village 语义，与
    /// `CatalogLevel.requirements(base:)` 共用同一分支规则防漂移。
    /// builder：requiredTownHallLevel → 建筑大师大本营、requiredLaboratoryLevel → 星空实验室；
    /// home/其他：requiredTownHallLevel → 大本营、requiredLaboratoryLevel → 实验室、
    /// requiredHeroTavernLevel（>0）→ 英雄殿堂。
    private func unlockLabel(_ level: CatalogLevel, base: String?) -> String {
        var parts: [String] = []
        if base == "builder" {
            if let bh = level.requiredTownHallLevel { parts.append("所需建筑大师大本营等级 " + String(bh) + "级") }
            if let sl = level.requiredLaboratoryLevel { parts.append("所需星空实验室等级 " + String(sl) + "级") }
        } else {
            if let th = level.requiredTownHallLevel { parts.append("所需大本营等级 " + String(th) + "级") }
            if let lab = level.requiredLaboratoryLevel { parts.append("所需实验室等级 " + String(lab) + "级") }
            if let ht = level.requiredHeroTavernLevel, ht > 0 { parts.append("所需英雄殿堂等级 " + String(ht) + "级") }
        }
        return parts.isEmpty ? "无解锁条件" : parts.joined(separator: " · ")
    }

    private func costLabel(_ level: CatalogLevel) -> String {
        guard let cost = level.upgradeCost else { return "无费用数据" }
        return ClanDisplayFormat.resourceLabel(level.upgradeResource) + " " + String(cost)
    }

    /// 资产解析的目录版本：优先当前 catalog 的 gameVersion，缺失时回落
    /// bundled 默认版本（与 `loadBundled()` 同源，避免未来多版本错配）。
    private var assetVersion: String {
        catalog?.gameVersion ?? GameCatalog.defaultBundledVersion
    }

    /// 头部图标：4 级候选链 currentLevelVisual → currentLevelIcon → levelVisual →
    /// icon 运行时候选（`VillageItemState.preferredAssetURLs`，与列表行共用解析
    /// 防漂移；首选文件缺失时自动尝试次选，P2 评审）。Issue #39：链首为当前等级
    /// 资产（按 currentLevel 显示对应等级外观）；目录中部分 item（如兵营
    /// buildings:1000000）icon 为 nil 但 levelVisual 可渲染（fireplace_lvl1.png——
    /// 游戏内部导出代号，兵营中心营火）——头部必须与逐级行一致显示真实外观。
    private var headerImage: NSImage? {
        item.preferredAssetURLs(version: assetVersion)
            .lazy.compactMap { NSImage(contentsOf: $0) }.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Group {
                            if let nsImage = headerImage {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: UpgradeDisplayLayout.detailHeaderIconSize,
                                           height: UpgradeDisplayLayout.detailHeaderIconSize)
                            } else {
                                Image(systemName: item.displayCategory?.systemImage ?? item.category?.systemImage ?? "hammer.fill")
                                    .font(.system(size: 30, weight: .medium))
                                    .foregroundStyle(item.displayCategory?.tint ?? item.category?.tint ?? Color.secondary)
                                    .frame(width: UpgradeDisplayLayout.detailHeaderIconSize,
                                           height: UpgradeDisplayLayout.detailHeaderIconSize)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.title3.weight(.bold))
                            Text(item.displayCategory?.title ?? item.category?.title ?? item.section)
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

    /// 逐级图标：levelVisual → icon 运行时候选（`CatalogLevel.preferredAssetURLs`，
    /// 与列表行/头部共用 `availableURLs` 实现防漂移；首选文件缺失时自动尝试
    /// 次选，P2 评审）；全部加载失败 → nil（SF Symbol 兜底，不崩溃）。
    /// 返回原始 `Image`（修饰链在调用处拼装，避免 `some View` 类型歧义）。
    private func levelAssetImage(_ level: CatalogLevel) -> Image? {
        guard let image = level.preferredAssetURLs(version: assetVersion)
            .lazy.compactMap({ NSImage(contentsOf: $0) }).first else {
            return nil
        }
        return Image(nsImage: image)
    }

    private func levelRow(_ level: CatalogLevel) -> some View {
        let isCurrent = item.currentLevel == level.level
        // 升级中：item.nextLevel（投影显式推断）；非升级未满级：currentLevel + 1
        // （与 UpgradeDisplayRow.durationLabel 的「下一级：N级」推导同规则）。
        // Issue #67：阶段满级（currentLevel >= currentStageMaxLevel）时下一级
        // 超出当前阶段上限，不标「下一级」——避免与「当前阶段已满级」文案矛盾
        //（审核 C important：验收「不把全局更高等级当作当前可升级项」）。
        // unverified（缺 prerequisite 无法验证）与 unknown（版本不匹配/base 不匹配，
        // 旧目录不可信）同样不标「下一级」（fail-closed，P1-2 审核：不得从旧目录
        // 推断可操作的下一级）。
        let effectiveNext: Int?
        if item.status == .unverified || item.status == .unknown {
            effectiveNext = nil
        } else if let stage = item.currentStageMaxLevel, item.currentLevel ?? -1 >= stage {
            effectiveNext = nil
        } else {
            effectiveNext = item.nextLevel ?? (item.currentLevel.map { $0 + 1 })
        }
        let isNext = effectiveNext == level.level
        return HStack(spacing: 12) {
            Group {
                if let img = levelAssetImage(level) {
                    img
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: UpgradeDisplayLayout.detailLevelIconSize,
                               height: UpgradeDisplayLayout.detailLevelIconSize)
                } else {
                    Image(systemName: item.displayCategory?.systemImage ?? item.category?.systemImage ?? "hammer.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(item.displayCategory?.tint ?? item.category?.tint ?? Color.secondary)
                        .frame(width: UpgradeDisplayLayout.detailLevelIconSize,
                               height: UpgradeDisplayLayout.detailLevelIconSize)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(String(level.level) + "级")
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
                Text(unlockLabel(level, base: catalogItem?.base))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isCurrent ? Color.blue.opacity(0.07) : Color.clear)
    }
}
