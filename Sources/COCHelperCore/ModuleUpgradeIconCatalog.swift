import Foundation

/// 精制台模组使用的升级属性图标。
///
/// 这些图标来自 APK 的 `sc/ui.sc`，不是 `GameCatalog` 的 item/level 目录项：
/// 精制台的 `types/modules` 数据没有可直接 join 的静态目录等级数据，因此单独
/// 维护 dataID → UI 属性图标映射，避免用 SF Symbol 或猜测父建筑图标代替。
public enum ModuleUpgradeIconKind: String, Hashable, Sendable {
    case health
    case damage
    case effect

    public var exportName: String {
        switch self {
        case .health: return "info_icon_hp"
        case .damage: return "info_icon_damage"
        case .effect: return "info_icon_time_boosted"
        }
    }

    public var renderedPath: String {
        "icons/ui/" + exportName + ".png"
    }
}

/// APK 精制台模组升级图标目录。
///
/// 18.400.13 中 9 个模组 ID 复用 3 个属性图标：生命值、攻击力、效果时长。
/// 映射按 dataID 固定，而不是按名称或数组位置推断，防止导入顺序变化造成错图。
public enum ModuleUpgradeIconCatalog {
    public static let mappings: [Int64: ModuleUpgradeIconKind] = [
        // 火热蜡烛
        102_000_033: .health,
        102_000_034: .damage,
        102_000_035: .effect,
        // 英雄猎台
        102_000_036: .health,
        102_000_037: .damage,
        102_000_038: .effect,
        // 蛋糕投掷器
        102_000_039: .health,
        102_000_040: .damage,
        102_000_041: .effect,
    ]

    public static func kind(for dataID: Int64) -> ModuleUpgradeIconKind? {
        mappings[dataID]
    }

    /// 返回与普通目录资产一致的引用模型，便于复用 Bundle URL 解析和可渲染判定。
    public static func asset(for dataID: Int64) -> CatalogAssetRef? {
        guard let kind = kind(for: dataID) else { return nil }
        return CatalogAssetRef(
            container: "sc/ui.sc",
            exportName: kind.exportName,
            renderedPath: kind.renderedPath,
            missingReason: nil
        )
    }

    /// 解析当前版本 Bundle 中的实际 PNG；资源缺失时返回 nil，让 UI 继续走 SF Symbol 兜底。
    public static func bundledURL(
        for dataID: Int64,
        version: String = GameCatalog.defaultBundledVersion
    ) -> URL? {
        asset(for: dataID)?.bundledURL(version: version)
    }
}

/// 精制台父级 `types` 使用的实际建筑图标目录。
///
/// 这类图标来自 APK 的 `sc/buildings.sc`，与 `types/modules` 一样不参与
/// `GameCatalog` 的 item/level join；它们是父级精制台条目的视觉资产，不能用
/// 模组属性图标或 `hammer.fill` 代替。
public enum CraftTableTypeIconCatalog {
    public static let mappings: [Int64: String] = [
        103_000_011: "inferno_candle_tower_lvl1",
        103_000_012: "headhunter_tower_lvl1",
        103_000_013: "cake_thrower_lvl1",
    ]

    public static func exportName(for dataID: Int64) -> String? {
        mappings[dataID]
    }

    /// 返回与普通目录资产一致的引用模型，便于复用 Bundle URL 解析和可渲染判定。
    public static func asset(for dataID: Int64) -> CatalogAssetRef? {
        guard let exportName = exportName(for: dataID) else { return nil }
        return CatalogAssetRef(
            container: "sc/buildings.sc",
            exportName: exportName,
            renderedPath: "icons/buildings/\(exportName).png",
            missingReason: nil
        )
    }

    /// 解析当前版本 Bundle 中的实际 PNG；资源缺失时返回 nil，让 UI 继续走 SF Symbol 兜底。
    public static func bundledURL(
        for dataID: Int64,
        version: String = GameCatalog.defaultBundledVersion
    ) -> URL? {
        asset(for: dataID)?.bundledURL(version: version)
    }
}
