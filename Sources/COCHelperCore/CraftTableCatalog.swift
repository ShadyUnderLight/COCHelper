import Foundation

/// Versioned APK data for the seasonal-defense craft table.
///
/// This catalog is deliberately separate from `GameCatalog`: the account JSON
/// stores `types` and `modules` as a nested tree, while the normal item catalog
/// has no direct rows for those IDs.
public struct CraftTableCatalog: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let gameVersion: String
    public let buildTag: String
    public let locale: String
    public let source: String
    public let defenses: [CraftTableDefenseSpec]
    public let modules: [CraftTableModuleSpec]

    public init(
        schemaVersion: Int = 1,
        gameVersion: String,
        buildTag: String,
        locale: String = "zh-CN",
        source: String = "",
        defenses: [CraftTableDefenseSpec],
        modules: [CraftTableModuleSpec]
    ) {
        self.schemaVersion = schemaVersion
        self.gameVersion = gameVersion
        self.buildTag = buildTag
        self.locale = locale
        self.source = source
        self.defenses = defenses
        self.modules = modules
    }

    /// Loads only the requested version. A missing file, malformed file, or
    /// version mismatch is a normal unavailable-data state for the UI.
    public static func loadBundled(
        version: String = GameCatalog.defaultBundledVersion
    ) -> CraftTableCatalog? {
        guard let url = Bundle.module.url(
            forResource: "craft_table_catalog",
            withExtension: "json",
            subdirectory: "GameCatalog/" + version
        ),
        let data = try? Data(contentsOf: url),
        let catalog = try? JSONDecoder().decode(CraftTableCatalog.self, from: data),
        catalog.schemaVersion == 1,
        catalog.gameVersion == version
        else {
            return nil
        }
        return catalog
    }

    public func defense(dataID: Int64) -> CraftTableDefenseSpec? {
        defenses.first { $0.dataID == dataID }
    }

    public func module(dataID: Int64) -> CraftTableModuleSpec? {
        modules.first { $0.dataID == dataID }
    }
}

public struct CraftTableDefenseSpec: Codable, Hashable, Sendable, Identifiable {
    public let dataID: Int64
    public let name: String
    public let sourceName: String
    public let specialAbility: String
    public let moduleIDs: [Int64]
    public let totalModuleLevelThresholds: [Int]
    /// Issue #98：生命周期声明（permanent / seasonalCandidate；nil = 旧数据未标注）。
    /// 合成 memberwise init 自动带默认值 nil（现有调用点零改动）；
    /// Codable 合成解码缺键 → nil（旧 craft_table_catalog.json 兼容）。
    public let lifecycle: CatalogLifecycle?

    public var id: Int64 { dataID }
}

public struct CraftTableModuleSpec: Codable, Hashable, Sendable, Identifiable {
    public let dataID: Int64
    public let name: String
    public let sourceName: String
    public let specialAbility: String
    public let statTypes: [String]
    public let displayTitles: [String]
    public let maxLevel: Int
    public let levels: [CraftTableLevelSpec]

    public var id: Int64 { dataID }

    public var attributeLabel: String? {
        let titles = displayTitles.filter { !$0.isEmpty }
        guard !titles.isEmpty else { return nil }
        return titles.joined(separator: "、")
    }
}

public struct CraftTableLevelSpec: Codable, Hashable, Sendable, Identifiable {
    public let level: Int
    public let durationSeconds: Int64?
    public let upgradeResource: String?
    public let upgradeCost: Int64?
    public let requiredTownHallLevel: Int?

    public var id: Int { level }
}
