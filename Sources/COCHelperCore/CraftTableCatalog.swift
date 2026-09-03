import Foundation

/// Versioned APK data for the seasonal-defense craft table.
///
/// This catalog is deliberately separate from `GameCatalog`: the account JSON
/// stores `types` and `modules` as a nested tree, while the normal item catalog
/// has no direct rows for those IDs.
///
/// E0-03/Issue #303：不再做 manifest hash 对账（fail-closed 完整性门已撤销）；
/// 只保留 schemaVersion / gameVersion 一致性 + 内容解码。
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

    /// 读取 bundled 目录资源（manifest + craft 原始字节）。加载与完整性测试
    /// 共用同一数据源（防测试路径与生产路径读不同文件）。
    static func bundledResourceData(version: String = GameCatalog.defaultBundledVersion)
        -> (manifest: Data, craft: Data)? {
        guard let craftURL = Bundle.module.url(
            forResource: "craft_table_catalog",
            withExtension: "json",
            subdirectory: "GameCatalog/" + version
        ),
        let craftData = try? Data(contentsOf: craftURL),
        let manifestURL = Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "GameCatalog/" + version
        ),
        let manifestData = try? Data(contentsOf: manifestURL)
        else {
            return nil
        }
        return (manifestData, craftData)
    }

    /// Loads only the requested version. A missing file, malformed file, or
    /// version mismatch is a normal unavailable-data state for the UI.
    public static func loadBundled(
        version: String = GameCatalog.defaultBundledVersion
    ) -> CraftTableCatalog? {
        guard let resources = bundledResourceData(version: version),
              let catalog = try? JSONDecoder().decode(CraftTableCatalog.self, from: resources.craft),
              let manifest = try? JSONDecoder().decode(CatalogManifest.self, from: resources.manifest),
              catalog.schemaVersion == 1,
              catalog.gameVersion == version,
              manifest.schemaVersion == 3,
              manifest.gameVersion == catalog.gameVersion
        else {
            return nil
        }
        return CraftTableCatalog(
            schemaVersion: catalog.schemaVersion,
            gameVersion: catalog.gameVersion,
            buildTag: catalog.buildTag,
            locale: catalog.locale,
            source: catalog.source,
            defenses: catalog.defenses,
            modules: catalog.modules
        )
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
    /// 显式 memberwise init：`lifecycle` 带默认值 nil（既有调用点零改动）——注意
    /// Swift 合成 init 对「let 带默认值」的属性会省略参数（可省略但不可显式传），
    /// 测试需要构造带 .seasonalCandidate 的 spec，故必须显式写（仿 CatalogItem
    /// 模式）。Codable 合成解码缺键 → nil（旧 craft_table_catalog.json 兼容）。
    public let lifecycle: CatalogLifecycle?

    public init(
        dataID: Int64,
        name: String,
        sourceName: String,
        specialAbility: String,
        moduleIDs: [Int64],
        totalModuleLevelThresholds: [Int],
        lifecycle: CatalogLifecycle? = nil
    ) {
        self.dataID = dataID
        self.name = name
        self.sourceName = sourceName
        self.specialAbility = specialAbility
        self.moduleIDs = moduleIDs
        self.totalModuleLevelThresholds = totalModuleLevelThresholds
        self.lifecycle = lifecycle
    }

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
