import Foundation

/// APK 中用于官方玩家资料分组的原生图标。
///
/// PNG 资源来自 `base.apk.1` 的 `assets/sc/ui.sc`，通过仓库已有的 SC2
/// 渲染管线生成后作为 Core 资源随 App 打包。调用方必须保留 SF Symbol
/// 回退，因为资源可能在未来版本更新时暂时缺失。
public enum OfficialPlayerCardIcon: String, CaseIterable, Sendable {
    case progress = "official_player_progress"
    case results = "official_player_results"
    case clan = "official_player_clan"

    /// Core 资源 Bundle 中的 PNG；资源不存在时返回 nil，由 UI 回退。
    public func bundledURL() -> URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "png")
    }
}
