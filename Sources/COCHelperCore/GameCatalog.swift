import Foundation

// MARK: - Manifest

public struct CatalogCounts: Codable, Hashable, Sendable {
    public let items: Int
    public let levels: Int
    public let missingIcons: Int?
    public let missingTime: Int?
}

public struct CatalogGeneratedFile: Codable, Hashable, Sendable {
    public let path: String
    public let sha256: String?
    public let size: Int?
    public let kind: String?
    public let entries: Int?
}

/// 版本化静态目录 manifest 模型。
///
/// 当前 `loadBundled()` 不读取 manifest（只解码 catalog.json）；此类型作为
/// 契约保留，供后续运行时版本审计（如 UI 展示 gameVersion/buildTag/locale、
/// 校验 generatedFiles 哈希）使用。
public struct CatalogManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let gameVersion: String
    public let buildTag: String
    public let locale: String
    public let sourceFingerprint: String
    public let generatedFiles: [CatalogGeneratedFile]
    public let counts: CatalogCounts
}

// MARK: - Assets

/// 静态资源引用；`missingReason != nil` 时表示该引用不可渲染，必须原样暴露给 UI。
public struct CatalogAssetRef: Codable, Hashable, Sendable {
    public let container: String?
    public let exportName: String?
    public let renderedPath: String?
    public let missingReason: String?

    /// 是否有可渲染的静态资源：renderedPath 存在且无缺失原因。
    /// 空串路径（""）不可渲染（契约 R2.2/R5.3，与 Python contract.is_renderable
    /// 同一语义）；18.400.13 全量渲染后：1246 个唯一路径可渲染（renderedPath
    /// 非空且无 missingReason）；23 个唯一缺失键（export_not_found /
    /// render_failed）带 missingReason，该属性为 false。UI 依据该属性选择
    /// PNG 或 SF Symbol。
    public var isRenderable: Bool {
        guard let renderedPath, !renderedPath.isEmpty else { return false }
        return missingReason == nil
    }
}

extension CatalogAssetRef {
    /// renderedPath 在 Core 资源 Bundle 内的 URL（契约 R1.1/R5.3）。
    ///
    /// - 仅当 `isRenderable` 时解析（renderedPath 非空且无缺失原因）；
    ///   否则返回 nil，UI 回退 SF Symbol。
    /// - `Bundle.module` 在本模块（COCHelperCore）内编译 → 解析到 Core
    ///   资源 bundle（与 `loadBundled()` 同一机制）。
    /// - 文件不存在时 Bundle 解析返回 nil，不抛错。
    /// - 注意：`Bundle.url(forResource:)` 的 resource 名必须是纯文件名
    ///   （`lastPathComponent`），目录部分走 `subdirectory` 参数；带路径
    ///   分隔符会解析失败返回 nil。
    public func bundledURL(version: String = GameCatalog.defaultBundledVersion) -> URL? {
        guard isRenderable, let renderedPath else { return nil }
        let nsPath = renderedPath as NSString
        let subdirectory = "GameCatalog/" + version + "/" + nsPath.deletingLastPathComponent
        let last = nsPath.lastPathComponent as NSString
        return Bundle.module.url(
            forResource: last.deletingPathExtension,
            withExtension: last.pathExtension,
            subdirectory: subdirectory
        )
    }

    /// 按显示优先级依次解析候选 ref 的 Bundle URL。`bundledURL` 仅在
    /// isRenderable 且文件真实存在时返回 URL，因此「元数据可渲染但文件缺失」
    /// 的候选被自动过滤——UI 对返回数组依次做 NSImage 加载探测，实现
    /// levelVisual → icon → SF Symbol 的运行时回退链（Issue #34 P2 评审：
    /// 不能只按元数据选定一个 ref、加载失败就直接回退 SF Symbol 而跳过次选）。
    public static func availableURLs(_ refs: [CatalogAssetRef?], version: String) -> [URL] {
        refs.compactMap { $0?.bundledURL(version: version) }
    }
}

// MARK: - Items

public struct CatalogItem: Codable, Identifiable, Hashable, Sendable {
    /// 与账号快照 section 名同源（含 `buildings2` 等后缀形式）。
    public let section: String
    public let category: String
    public let dataID: Int64
    /// home / builder / nil（capital 无 base）。
    public let base: String?
    public let baseMissingReason: String?
    public let name: String
    public let maxLevel: Int
    public let icon: CatalogAssetRef?
    public let levelVisual: CatalogAssetRef?
    public let levels: [CatalogLevel]

    public var id: String { "\(section):\(dataID)" }
}

public struct CatalogLevel: Codable, Identifiable, Hashable, Sendable {
    /// 源表原始等级号（可能不连续，如战斗直升机 15..35），查表必须按值匹配。
    public let level: Int
    /// 表语义见 `CatalogDurationSemantics`；缺失为 nil，不填 0。
    public let durationSeconds: Int64?
    public let upgradeResource: String?
    public let upgradeCost: Int64?
    public let requiredTownHallLevel: Int?
    public let requiredLaboratoryLevel: Int?
    public let icon: CatalogAssetRef?
    public let levelVisual: CatalogAssetRef?
    public let missingReason: String?

    /// 逐级视觉资产候选 URL（levelVisual → icon，运行时文件存在性过滤）；
    /// 与 `VillageItemState.preferredAssetURLs` 共用 `availableURLs` 实现，
    /// 防逐级行与列表行/详情头部优先级漂移（Issue #34 P2 评审）。
    public func preferredAssetURLs(version: String) -> [URL] {
        CatalogAssetRef.availableURLs([levelVisual, icon], version: version)
    }

    public var id: String { String(level) }
}

// MARK: - GameCatalog

/// 版本化静态目录。`Sendable`，不可变，可安全跨线程共享。
///
/// 时长语义（#13 已统一）：`levels[N].durationSeconds` 表示「升级到 N 级」的完整时长。
/// - BuildTime 系（buildings/traps 及 `2` 后缀）：`levels[1]` 是 0→1 的初始建造时长，非 nil；
/// - UpgradeTime 系（units/spells/heroes/pets/equipment/guardians 及 `2` 后缀）：
///   生成时已把行 N 映射到 level N+1，`levels[1]` 恒为初始等级（nil）。
/// 两种表在 catalog 中语义一致，无需表类型分派。
public struct GameCatalog: Sendable {
    public static let defaultBundledVersion = "18.400.13"

    public let gameVersion: String

    private let itemsBySection: [String: [CatalogItem]]
    private let index: [String: CatalogItem]

    /// 测试注入入口；`loadBundled` 只是其便捷包装。
    public init(gameVersion: String, items: [CatalogItem]) {
        self.gameVersion = gameVersion
        var bySection: [String: [CatalogItem]] = [:]
        var byKey: [String: CatalogItem] = [:]
        for item in items {
            bySection[item.section, default: []].append(item)
            byKey[Self.key(section: item.section, dataID: item.dataID)] = item
        }
        self.itemsBySection = bySection
        self.index = byKey
    }

    /// 从 Bundle 加载指定版本目录；目录缺失或解码失败返回 nil（调用方输出诊断，不崩溃）。
    public static func loadBundled(version: String = defaultBundledVersion) -> GameCatalog? {
        guard let url = Bundle.module.url(
            forResource: "catalog",
            withExtension: "json",
            subdirectory: "GameCatalog/" + version
        ),
        let data = try? Data(contentsOf: url),
        let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return nil
        }
        return GameCatalog(gameVersion: payload.gameVersion, items: payload.items)
    }

    /// 主查询：`(section, dataID)` 精确匹配（catalog.section 与快照 section 同源）。
    public func item(section: String, dataID: Int64) -> CatalogItem? {
        index[Self.key(section: section, dataID: dataID)]
    }

    public func items(in section: String) -> [CatalogItem] {
        itemsBySection[section] ?? []
    }

    /// 「升级到 nextLevel 级的完整时长」；目录无该等级记录时返回 nil。
    /// 所有表的 `levels[N].durationSeconds` 语义统一（见类型 doc comment）。
    /// 目录不存在 level <= 0 的记录，`nextLevel <= 0` 仅作非法输入防御；
    /// `nextLevel == 1` 时建筑系返回 0→1 建造时长、单位系返回 nil（初始等级）。
    public func durationToUpgradeLevel(nextLevel: Int, for item: CatalogItem) -> Int64? {
        guard nextLevel > 0 else { return nil }
        return item.levels.first(where: { $0.level == nextLevel })?.durationSeconds
    }

    private static func key(section: String, dataID: Int64) -> String {
        section + ":" + String(dataID)
    }

    private struct Payload: Decodable {
        let gameVersion: String
        let items: [CatalogItem]
    }
}
