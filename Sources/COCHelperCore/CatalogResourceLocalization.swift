import Foundation

/// 目录资源标识 → 官方简中资源名（Issue #73 Task 3：矿石本地化）。
///
/// 纯函数、无状态映射，放在 Core 层以便单元测试；COCHelper 侧
/// `ClanDisplayFormat.resourceLabel` 委托于此，避免 UI 层复制漂移
/// （与 `AccountDurationFormatter` 同为「Core 内展示格式化」先例）。
///
/// 未知值策略：兜底「未知资源」，不把英文标识泄漏到 UI 主文本；
/// 需要原始 raw 值的场景（如解析失败的费用项原文）由显示层另行携带
/// （`ClanDisplayFormat.upgradeCostLabel` 的 rawAmount），不在此处理。
public enum CatalogResourceLocalization {
    /// 匹配规则：trim + lowercased（官方源表值大小写不保证一致，如
    /// CommonOre / commonore 均可出现）。
    public static func label(_ raw: String?) -> String {
        guard let raw else { return "未知资源" }
        return switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gold": "金币"
        case "elixir": "圣水"
        case "darkelixir", "dark_elixir": "暗黑重油"
        case "capitalresource", "capitalgold", "raidcapitalgold": "都城金币"
        case "buildergold", "builderbasegold": "建筑大师基地金币"
        case "builderelixir", "builderbaseelixir": "建筑大师基地圣水"
        // Issue #73 Task 3：装备升级矿石（官方简中）。
        case "commonore": "闪亮矿石"
        case "rareore": "璀璨矿石"
        case "epicore": "星辉矿石"
        default: "未知资源"
        }
    }
}
