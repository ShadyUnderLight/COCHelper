import Foundation

/// 联赛/段位本地化目录（Issue #71）。
///
/// 与 `CraftTableCatalog` 同一版本化 bundled 机制（`GameCatalog/<gameVersion>/`
/// 目录，Package.swift 用 `.copy` 保留目录结构）。按稳定 API ID 查中文名，
/// 不依赖官方返回的英文 name；未知 ID 返回 nil，由调用方决定降级文案。
public struct LeagueTierCatalog: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let gameVersion: String
    public let locale: String
    public let source: String
    public let contexts: [LeagueTierContextSpec]

    public init(
        schemaVersion: Int = 1,
        gameVersion: String,
        locale: String = "zh-CN",
        source: String,
        contexts: [LeagueTierContextSpec]
    ) {
        self.schemaVersion = schemaVersion
        self.gameVersion = gameVersion
        self.locale = locale
        self.source = source
        self.contexts = contexts
    }

    /// 只加载指定版本。文件缺失、malformed 或版本不匹配都是 UI 的正常
    /// 「目录不可用」状态，返回 nil 不抛错（与 CraftTableCatalog 同一 guard 模式）。
    public static func loadBundled(
        version: String = GameCatalog.defaultBundledVersion
    ) -> LeagueTierCatalog? {
        guard let url = Bundle.module.url(
            forResource: "league_tier_catalog",
            withExtension: "json",
            subdirectory: "GameCatalog/" + version
        ),
        let data = try? Data(contentsOf: url),
        let catalog = try? JSONDecoder().decode(LeagueTierCatalog.self, from: data),
        catalog.schemaVersion == 1,
        catalog.gameVersion == version,
        isSemanticallyValid(catalog)
        else {
            return nil
        }
        return catalog
    }

    /// Bundled 数据必须覆盖每个已知语境，且同一语境内不得重复 ID。
    /// 否则查询中的 `.first` 会把生成错误静默变成错误本地化结果。
    static func isSemanticallyValid(_ catalog: LeagueTierCatalog) -> Bool {
        let contexts = catalog.contexts.map(\.context)
        guard Set(contexts).count == contexts.count,
              Set(contexts) == Set(LeagueTierContext.allCases)
        else {
            return false
        }

        return catalog.contexts.allSatisfy { context in
            let ids = context.tiers.map(\.id)
            return Set(ids).count == ids.count
        }
    }

    /// 按 context + ID 查中文名；未知 ID 或 context 无该 ID → nil。
    public func name(forID id: Int, context: LeagueTierContext) -> String? {
        contexts.first { $0.context == context }?.tiers.first { $0.id == id }?.name
    }
}

/// 联赛/段位出现的语境：主村联赛（290000xx 奖杯联赛）、建筑大师基地联赛
/// （440000xx）、部落都城联赛（850000xx）、排位段位（105xxxxxx，玩家
/// leagueTier 与部落入会 requiredLeagueTier 共用同一 ID 表）、部落对战
/// 联赛 CWL（48000000-48000022，warLeague 字段）。
public enum LeagueTierContext: String, Codable, CaseIterable, Sendable {
    case home
    case builderBase
    case capital
    case leagueTier
    case war
}

public struct LeagueTierContextSpec: Codable, Hashable, Sendable {
    public let context: LeagueTierContext
    public let tiers: [LeagueTierEntry]

    public init(context: LeagueTierContext, tiers: [LeagueTierEntry]) {
        self.context = context
        self.tiers = tiers
    }

    /// 显式 CodingKeys：与自动合成等价，但新增存储属性时若漏加 key 会
    /// 编译报错（合成版本会静默忽略），作防漏防护。
    private enum CodingKeys: String, CodingKey {
        case context
        case tiers
    }
}

public struct LeagueTierEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}
