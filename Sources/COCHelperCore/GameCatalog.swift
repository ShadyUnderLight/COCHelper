import CryptoKit
import Foundation

// MARK: - Manifest

public struct CatalogCounts: Codable, Hashable, Sendable {
    public let items: Int
    public let levels: Int
    public let missingIcons: Int?
    public let missingTime: Int?
    /// Issue #74b：时长语义拆分（可选字段，旧 manifest 缺键 → nil 向后兼容；
    /// 语义与 Python classify_duration 同桶）。不变量：
    /// timed + instant + missingTime == levels；缺失类四桶之和 == missingTime
    ///（有效目录由 validate 的 nil⟺reason 互斥保证 unknown == 0 时成立）。
    public let timed: Int?
    public let instant: Int?
    public let notApplicable: Int?
    public let initialLevel: Int?
    public let sourceMissing: Int?
    public let parseFailed: Int?
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
/// `loadBundled()` 已读取同目录 manifest（Issue #74a），经 `GameCatalog.manifest`
/// 暴露 buildTag/sourceFingerprint/counts；缺失或解码失败时目录仍加载、
/// manifest 为 nil（增强信息，不阻塞）。
public struct CatalogManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let gameVersion: String
    public let buildTag: String
    public let locale: String
    public let sourceFingerprint: String
    public let generatedFiles: [CatalogGeneratedFile]
    public let counts: CatalogCounts

    /// Issue #74（可信度验收）+ Issue #73 交叉审核 P1：运行时完整性校验。
    ///
    /// 校验：① counts 与目录内容重算一致（items/levels 必查；missingTime/
    /// timed/instant/缺失类四桶等拆分字段存在才查——旧 manifest 缺键跳过）；
    /// ② `generatedFiles` 中 catalog.json 声明的 sha256 与真实文件一致
    ///（声明缺失时跳过，向后兼容）；③ schemaVersion 在支持范围（1...2，
    /// 未来版本扩展时在此收紧）；④ sourceFingerprint 格式合法（sha256: 前缀
    /// + 64 hex）；⑤ `fileCheck` 注入时校验 generatedFiles 全部条目文件存在
    /// 且 size 匹配、以及目录引用的全部图标（renderedPath）文件存在。
    /// 返回 false = 漂移/篡改，调用方应 fail-closed（manifest 视为无效，
    /// 不进入「已验证」状态）。
    /// 不校验 icons 哈希（展示资源，不影响统计可信度，size/存在性已由 ⑤
    /// 覆盖）与 sourceFingerprint 内容（APK hash，运行时无 APK 可比）。
    /// fileCheck 保持注入式（纯函数可测）：调用方 `loadBundled` 提供基于
    /// Bundle 的实现。
    public func validate(
        against items: [CatalogItem],
        catalogData: Data,
        fileCheck: ((String, Int?) -> Bool)? = nil
    ) -> Bool {
        // ③ schemaVersion 支持范围（fail-closed：未知 schema 不进入已验证态）
        guard (1...2).contains(schemaVersion) else { return false }
        // ④ sourceFingerprint 格式：sha256: + 64 hex（生成器恒写该格式）
        let fp = sourceFingerprint
        guard fp.hasPrefix("sha256:"),
              fp.dropFirst("sha256:".count).count == 64,
              fp.dropFirst("sha256:".count).allSatisfy({ $0.isHexDigit }) else {
            return false
        }
        let levels = items.flatMap(\.levels)
        guard counts.items == items.count,
              counts.levels == levels.count else { return false }
        if let missingTime = counts.missingTime,
           missingTime != levels.filter({ $0.durationSeconds == nil }).count {
            return false
        }
        // 拆分字段（存在才校验；映射走 CatalogDurationState.state 单一映射点，
        // 与 Python classify_duration 同语义）
        if let timed = counts.timed,
           timed != levels.filter({ ($0.durationSeconds ?? 0) > 0 }).count { return false }
        if let instant = counts.instant,
           instant != levels.filter({ $0.durationSeconds == 0 }).count { return false }
        if let notApplicable = counts.notApplicable,
           notApplicable != levels.filter({ $0.durationState == .notApplicable }).count { return false }
        if let initialLevel = counts.initialLevel,
           initialLevel != levels.filter({ $0.durationState == .initialLevel }).count { return false }
        if let sourceMissing = counts.sourceMissing,
           sourceMissing != levels.filter({ $0.durationState == .sourceMissing }).count { return false }
        if let parseFailed = counts.parseFailed,
           parseFailed != levels.filter({ $0.durationState == .parseFailed }).count { return false }
        // catalog.json sha256：声明缺失跳过（向后兼容）；声明存在但格式异常
        //（无 sha256: 前缀）→ 数据异常 fail-closed（生成器恒写前缀）。
        if let entry = generatedFiles.first(where: { $0.path == "catalog.json" }),
           let declared = entry.sha256 {
            guard declared.hasPrefix("sha256:") else { return false }
            let actual = SHA256.hash(data: catalogData)
                .map { String(format: "%02x", $0) }.joined()
            guard declared.dropFirst("sha256:".count) == actual else { return false }
        }
        // ⑤ 文件级完整性：generatedFiles 全部条目（catalog.json 已单独校验
        // sha256，此处仅查存在性/其它条目 size）+ 目录引用的图标文件存在性。
        // fileCheck 为 nil（旧调用方/旧 manifest 路径）→ 跳过文件级校验，
        // 保持向后兼容；loadBundled 恒注入。
        if let fileCheck {
            for file in generatedFiles where file.kind != "directory" {
                guard fileCheck(file.path, file.size) else { return false }
            }
            // 目录引用的全部图标：item 级 + 每级（icon / levelVisual），
            // renderedPath 非 nil 即校验存在性（size 声明缺失 → 只查存在）。
            let iconRefs = items.flatMap { item -> [CatalogAssetRef?] in
                [item.icon, item.levelVisual] + item.levels.flatMap { [$0.icon, $0.levelVisual] }
            }
            for ref in iconRefs {
                if let renderedPath = ref?.renderedPath {
                    guard fileCheck(renderedPath, nil) else { return false }
                }
            }
        }
        return true
    }
}

// MARK: - 来源可信度标注（Issue #73 P1-2）

extension CatalogManifest {
    /// 升级费用来源标注：静态 APK 目录数值为参考值，不是对全体玩家绝对有效。
    /// UI 详情/诊断展示用（LevelDetailSheet 等），与 Python 生成期口径一致。
    public var provenanceLabel: String {
        "参考升级费用 · 来源：目录 v\(gameVersion) / buildTag \(buildTag)"
    }

    /// 来源指纹标注（sourceFingerprint 为 APK sha256，完整展示以便
    /// 与 manifest.json 对账、跨会话追溯；UI 侧 textSelection 可复制）。
    public var sourceFingerprintLabel: String {
        "来源指纹 " + sourceFingerprint
    }
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
    /// 的候选被自动过滤——本函数只对给定候选做有序过滤，回退链语义在调用方：
    /// `VillageItemState.preferredAssetURLs`（4 级候选 currentLevelVisual →
    /// currentLevelIcon → levelVisual → icon，Issue #39/#34）与
    /// `CatalogLevel.preferredAssetURLs`（2 级候选 levelVisual → icon）。
    /// UI 对返回数组依次做 NSImage 加载探测，逐级回退到 SF Symbol（Issue #34
    /// P2 评审：不能只按元数据选定一个 ref、加载失败就直接回退 SF Symbol 而
    /// 跳过次选）。
    public static func availableURLs(_ refs: [CatalogAssetRef?], version: String) -> [URL] {
        refs.compactMap { $0?.bundledURL(version: version) }
    }
}

// MARK: - Duration semantics (Issue #74b)

/// 逐级时长的可区分语义。`CatalogLevel.missingReason` 字符串值域在 Python
/// 生成器（LEVEL_MISSING_REASONS）与 Swift 映射点（`durationState`）两处定义；
/// 契约外 reason 走 `unknownReason` 防御，不修改值域契约。
public enum CatalogDurationState: Hashable, Sendable {
    /// 有值且 > 0：完整升级时长（秒）。
    case timed(seconds: Int64)
    /// 0 秒：有效即时升级（如城墙），不得归为缺失。
    case instant
    /// 初始等级（min_level_initial_no_upgrade）：to_next 表最低等级，无升级时长。
    case initialLevel
    /// 源表无时间列（no_time_source）：仅表示数据源层面无时长数据；
    /// 不得推断为「游戏内无需升级时间」（Issue #74 评审定稿）。
    case notApplicable
    /// 源字段缺失（time_missing / upgrade_data_missing）。
    case sourceMissing
    /// 源字段格式解析失败（time_invalid）。
    case parseFailed
    /// 未知 reason（防御：值域契约外或合成数据）。
    case unknownReason(String)

    /// 时长语义唯一映射点（`CatalogLevel`/`BuildingUpgradeStep` 共用防漂移，
    /// Issue #74b）。nil = durationSeconds 与 reason 双 nil（未知场景，UI 兜底
    /// 「暂无目录数据」）；unknownReason = reason 在契约外，或 durationSeconds
    /// 为负（防御分支：生成层已拒绝负数，仅解码旧/损坏数据可达）。
    public static func state(
        durationSeconds: Int64?,
        missingReason: String?
    ) -> CatalogDurationState? {
        if let seconds = durationSeconds {
            if seconds > 0 { return .timed(seconds: seconds) }
            if seconds == 0 { return .instant }
            return .unknownReason("negative_duration")  // 防御：生成层已拒绝负数
        }
        switch missingReason {
        case "min_level_initial_no_upgrade": return .initialLevel
        case "no_time_source": return .notApplicable
        case "time_invalid": return .parseFailed
        case "time_missing", "upgrade_data_missing": return .sourceMissing
        case let reason?: return .unknownReason(reason)
        case nil: return nil
        }
    }
}

extension CatalogLevel {
    /// 时长语义映射（单一映射点 `CatalogDurationState.state` 的便捷包装）。
    /// nil = durationSeconds 为 nil 且 reason 为 nil（未知场景，UI 兜底
    /// 「暂无目录数据」）；unknownReason = 目录记录存在但 reason 在契约外，
    /// 或 durationSeconds 为负（防御分支：生成层已拒绝负数，仅解码旧/损坏
    /// 数据可达）。
    public var durationState: CatalogDurationState? {
        CatalogDurationState.state(durationSeconds: durationSeconds, missingReason: missingReason)
    }
}

extension CatalogDurationState {
    /// 展示文案（Core 层可测；timed 走既有 AccountDurationFormatter 防格式漂移）。
    /// prefix（「完整时长：」等）由 UI 上下文拼接；缺失类文案不带 prefix。
    public var durationLabel: String {
        switch self {
        case .timed(let seconds): return AccountDurationFormatter.label(seconds)
        case .instant: return "即时"
        case .initialLevel: return "初始等级，无升级时长"
        case .notApplicable: return "该类别无时长数据"
        case .sourceMissing: return "目录缺失"
        case .parseFailed: return "目录解析失败"
        case .unknownReason: return "暂无目录数据"
        }
    }
}

// MARK: - Availability (Issue #74 seasonal)

/// 限时内容阶段配置（阶段表契约）。
///
/// 数据源为 Supercell 官方公告，随版本化目录人工维护；APK 只用于校验条目
/// dataID，不从名称或发布时间推断阶段边界。空表表示该目录版本尚未配置阶段数据。
/// 判定不依赖 `specialAbility` 名称（不得从命名推断 seasonal）。
public struct SeasonalPhase: Codable, Hashable, Sendable {
    /// 日期编码契约：bundled JSON 走默认 JSONDecoder 日期策略
    ///（`.deferredToDate`，2001-01-01 起秒数）。人工维护/未来 APK 提取
    /// 若改用 ISO8601 字符串，`loadBundled` 的 decoder 必须同步配置
    ///（当前缺失 → 解码失败 → 空表 fail-safe）。
    public let phaseID: String
    /// 展示名（官方公告名）；nil 时 UI 回退 phaseID。
    public let name: String?
    /// 活动区间：`from <= now < until` 视为活动（from 含、until 不含）。
    public let from: Date
    public let until: Date
    /// 涉及条目键："section:dataID"（与 `CatalogItem.id` / 投影查询键同格式）。
    public let itemKeys: [String]
    /// 阶段日期的官方公告来源；nil 兼容旧表/测试注入。
    public let sourceURL: String?

    public init(
        phaseID: String,
        name: String?,
        from: Date,
        until: Date,
        itemKeys: [String],
        sourceURL: String? = nil
    ) {
        self.phaseID = phaseID
        self.name = name
        self.from = from
        self.until = until
        self.itemKeys = itemKeys
        self.sourceURL = sourceURL
    }
}

/// 阶段表（空表起步；schemaVersion 预留迁移）。
public struct SeasonalPhaseTable: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let phases: [SeasonalPhase]

    public static let empty = SeasonalPhaseTable(schemaVersion: 1, phases: [])

    /// 解析条目最相关阶段（统一入口，投影/UI 共用防漂移）：
    /// 1. 先过滤非法区间（from >= until）——畸形数据不得进入判定；
    /// 2. 活动阶段（from <= now < until）→ 取 from 最晚者；
    /// 3. 无活动且存在未来阶段（from > now）→ 取最近即将开始（from 最小）；
    /// 4. 全部已结束 → 取最近结束（until 最大）；
    /// 5. 无有效阶段 → nil（unconfigured 域）。
    public func phase(forItemKey key: String, at date: Date) -> SeasonalPhase? {
        let valid = phases.filter { $0.itemKeys.contains(key) && $0.from < $0.until }
        if let active = valid
            .filter({ $0.from <= date && date < $0.until })
            .max(by: { $0.from < $1.from }) {
            return active
        }
        if let future = valid
            .filter({ $0.from > date })
            .min(by: { $0.from < $1.from }) {
            return future
        }
        return valid.max(by: { $0.until < $1.until })
    }

    /// 条目可用性的单一映射入口。阶段选择与活动边界必须由同一张注入表和
    /// 同一个 `date` 决定，普通投影与精制台专用投影都复用此方法。
    public func availability(forItemKey key: String, at date: Date) -> CatalogAvailability {
        guard let phase = phase(forItemKey: key, at: date) else {
            return .unconfigured
        }
        let status: SeasonalStatus
        if date < phase.from {
            status = .notStarted
        } else if date < phase.until {
            status = .active
        } else {
            status = .ended
        }
        return .seasonal(phaseID: phase.phaseID, phaseName: phase.name, status: status)
    }

    /// bundled 加载：`GameCatalog/<version>/seasonal_phases.json`；
    /// 文件缺失或解码失败 → 空表（不报错——阶段信息是增强数据，缺失 = 未配置）。
    public static func loadBundled(version: String) -> SeasonalPhaseTable {
        guard let url = Bundle.module.url(
            forResource: "seasonal_phases",
            withExtension: "json",
            subdirectory: "GameCatalog/" + version
        ), let data = try? Data(contentsOf: url),
           let table = try? JSONDecoder().decode(SeasonalPhaseTable.self, from: data),
           table.schemaVersion == 1 else {
            return .empty
        }
        return table
    }
}

/// 阶段状态（由注入 clock 判定：`from <= now < until` 为活动）。
public enum SeasonalStatus: String, Codable, Hashable, Sendable {
    /// 活动期（from <= now < until）。
    case active
    /// 未开始（now < from）。
    case notStarted
    /// 已结束（now >= until）。
    case ended
}

/// 条目可用性状态（历史存在 vs 当前可用）。
///
/// 与 `VillageItemState.isCatalogDeprecated`（源目录标记）是**独立维度**：
/// deprecated 来自 `CatalogItem.missingReason`，availability 来自阶段表。
/// seasonal 判定完全由阶段表驱动——不配置不推断、不编造当前可用。
public enum CatalogAvailability: Codable, Hashable, Sendable {
    /// 非限时内容。
    case permanent
    /// 阶段表命中：状态由注入 clock 判定（活动/未开始/已结束）。
    case seasonal(phaseID: String, phaseName: String?, status: SeasonalStatus)
    /// 无阶段信息（UI：「阶段信息未配置」）。
    case unconfigured
}

extension CatalogAvailability {
    /// 详情页展示文案；nil = 不显示（permanent 无标记，避免噪音）。
    public var displayLabel: String? {
        switch self {
        case .permanent: return nil
        case .seasonal(let phaseID, let phaseName, let status):
            let name = phaseName ?? phaseID
            switch status {
            case .active: return "限时内容：\(name)（活动）"
            case .notStarted: return "限时内容：\(name)（未开始）"
            case .ended: return "限时内容：\(name)（已结束，仅历史数据）"
            }
        case .unconfigured: return "阶段信息未配置"
        }
    }
}

// MARK: - Compatibility (Issue #74a)

/// 目录与玩家客户端 build 的兼容性状态。
///
/// 玩家真实 build 数据源当前不存在（官方 CoC API 不返回客户端 build）；
/// 生产路径恒为 `.unverified`——UI 必须明确「未验证」，不得把目录自我比较
/// 伪装成「已验证」。`.verified`/`.mismatch` 仅在显式传入玩家 build 时产生。
public enum CatalogCompatibility: Hashable, Sendable {
    /// 无玩家 build 输入：目录可用但未验证。
    case unverified(gameVersion: String)
    /// 玩家 build == catalog.gameVersion。
    case verified(gameVersion: String)
    /// 玩家 build != catalog.gameVersion：`catalogIsUsable` 必须 false（fail-closed）。
    case mismatch(catalogVersion: String, expectedVersion: String)
    /// 目录不可用（catalog == nil）。
    case unavailable

    /// 是否处于「未验证」状态（UI 版本行后缀展示用；与 `isUsable` 对称）。
    public var isUnverified: Bool {
        if case .unverified = self { return true }
        return false
    }

    /// 完成度可用性（与 `VillageCatalogProjection.catalogIsUsable` 同语义）：
    /// unverified/verified 可用（玩家 build 数据源不存在，unverified 不阻断）；
    /// mismatch/unavailable fail-closed。投影层统一用它替换手写版本比较。
    public var isUsable: Bool {
        switch self {
        case .unverified, .verified: return true
        case .mismatch, .unavailable: return false
        }
    }

    /// 领域助手：投影与 UI 共用同一判定，防三态判定散落手搓。
    public static func resolve(
        catalog: GameCatalog?,
        expectedGameVersion: String?
    ) -> CatalogCompatibility {
        guard let catalog else { return .unavailable }
        guard let expectedGameVersion else {
            return .unverified(gameVersion: catalog.gameVersion)
        }
        if expectedGameVersion == catalog.gameVersion {
            return .verified(gameVersion: catalog.gameVersion)
        }
        return .mismatch(catalogVersion: catalog.gameVersion, expectedVersion: expectedGameVersion)
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
    /// Issue #74b（deprecated provenance）：来源级缺失原因（如
    /// `deprecated_in_source`）。旧目录缺键 → nil（向后兼容）；此前该字段
    /// 在 Swift 模型缺失，解码时被静默丢弃。
    public let missingReason: String?
    public let levels: [CatalogLevel]

    /// 显式 memberwise init：`missingReason` 带默认值 nil（既有调用点不传该
    /// 参数保持兼容——与 `CatalogLevel.requiredHeroTavernLevel` 同先例；
    /// 注意 Swift 合成 init 对「let 带默认值」显式传参会报错，故必须显式写）。
    public init(
        section: String,
        category: String,
        dataID: Int64,
        base: String?,
        baseMissingReason: String?,
        name: String,
        maxLevel: Int,
        icon: CatalogAssetRef?,
        levelVisual: CatalogAssetRef?,
        missingReason: String? = nil,
        levels: [CatalogLevel]
    ) {
        self.section = section
        self.category = category
        self.dataID = dataID
        self.base = base
        self.baseMissingReason = baseMissingReason
        self.name = name
        self.maxLevel = maxLevel
        self.icon = icon
        self.levelVisual = levelVisual
        self.missingReason = missingReason
        self.levels = levels
    }

    public var id: String { "\(section):\(dataID)" }
}

/// 单项升级费用（Issue #73：多资源升级费用）。
///
/// - resource: 资源标识 = 源表原始值（不做枚举映射，保留原始值）
/// - amount: 金额；解析失败为 nil（0 是真实费用）
/// - rawResource: 源 CSV 原始资源值，恒保留（审计/重解析）
/// - rawAmount: 源 CSV 原始金额串；正常解析时为 nil
/// - parseFailed: 该项解析失败（金额非数字 或 资源/金额配对缺失）
public struct CatalogUpgradeCost: Codable, Hashable, Sendable {
    public let resource: String
    public let amount: Int64?
    public let rawResource: String?
    public let rawAmount: String?
    public let parseFailed: Bool
}

public struct CatalogLevel: Codable, Identifiable, Hashable, Sendable {
    /// 源表原始等级号（可能不连续，如战斗直升机 15..35），查表必须按值匹配。
    public let level: Int
    /// 表语义见 `CatalogDurationSemantics`；缺失为 nil，不填 0。
    public let durationSeconds: Int64?
    /// 升级费用（多资源，Issue #73）。Python 侧无费用时输出 null；旧格式目录
    /// （无 upgradeCosts 键，upgradeResource/upgradeCost）兼容解码为 nil。
    public let upgradeCosts: [CatalogUpgradeCost]?
    public let requiredTownHallLevel: Int?
    public let requiredLaboratoryLevel: Int?
    /// 英雄殿堂门槛（issue #67，home 英雄 tavern 门槛 1-12；heroes2 源数据为
    /// 0 = 无门槛，恒满足）。缺键解码为 nil（旧目录向后兼容）。
    public let requiredHeroTavernLevel: Int?
    public let icon: CatalogAssetRef?
    public let levelVisual: CatalogAssetRef?
    public let missingReason: String?

    /// 显式 memberwise init：`requiredHeroTavernLevel` 带默认值 nil，
    /// 保持既有调用点（不传该参数）与 Codable 合成解码（缺键 → nil）兼容。
    public init(
        level: Int,
        durationSeconds: Int64?,
        upgradeCosts: [CatalogUpgradeCost]?,
        requiredTownHallLevel: Int?,
        requiredLaboratoryLevel: Int?,
        requiredHeroTavernLevel: Int? = nil,
        icon: CatalogAssetRef?,
        levelVisual: CatalogAssetRef?,
        missingReason: String?
    ) {
        self.level = level
        self.durationSeconds = durationSeconds
        self.upgradeCosts = upgradeCosts
        self.requiredTownHallLevel = requiredTownHallLevel
        self.requiredLaboratoryLevel = requiredLaboratoryLevel
        self.requiredHeroTavernLevel = requiredHeroTavernLevel
        self.icon = icon
        self.levelVisual = levelVisual
        self.missingReason = missingReason
    }

    /// 逐级视觉资产候选 URL（levelVisual → icon，运行时文件存在性过滤）；
    /// 与 `VillageItemState.preferredAssetURLs` 共用 `availableURLs` 实现，
    /// 防逐级行与列表行/详情头部优先级漂移（Issue #34 P2 评审）。
    public func preferredAssetURLs(version: String) -> [URL] {
        CatalogAssetRef.availableURLs([levelVisual, icon], version: version)
    }

    public var id: String { String(level) }
}

// MARK: - UpgradeRequirement（Issue #67）

/// 升级前置条件。village 语义在投影/展示层按 item.base 解析
///（home: townHall/laboratory/heroHall；builder: builderHall/starLaboratory）。
public enum UpgradeRequirement: Hashable, Sendable {
    case townHall(level: Int)
    case builderHall(level: Int)
    case laboratory(level: Int)
    case starLaboratory(level: Int)
    case heroHall(level: Int)

    /// 要求的解锁等级（如 `.townHall(level: 12)` 要求大本营 ≥ 12 级）。
    public var requiredLevel: Int {
        switch self {
        case .townHall(let level), .builderHall(let level), .laboratory(let level),
             .starLaboratory(let level), .heroHall(let level):
            return level
        }
    }
}

// MARK: - UpgradeRequirement 展示文案（Issue #68 Task 3）

extension UpgradeRequirement {
    /// 中文展示文案（Issue #68，UI 三处共用防漂移）。base 语义与
    /// `requirements(base:)` 一致：home → 大本营/实验室/英雄殿堂；
    /// builder → 建筑大师大本营/星空实验室。
    ///
    /// 与旧 LevelDetailSheet.unlockLabel 分支逐字一致：
    /// - builder base：`.townHall` → 建筑大师大本营、`.laboratory` → 星空实验室
    ///   （数据源字段复用，village 语义按 base 解析）；
    /// - 其他 base：`.townHall` → 大本营、`.laboratory` → 实验室；
    /// - `.builderHall`/`.starLaboratory`/`.heroHall` 自身语义固定，不随 base 变。
    public func displayLabel(base: String?) -> String {
        let name: String
        switch self {
        case .townHall:
            name = base == "builder" ? "建筑大师大本营" : "大本营"
        case .builderHall:
            name = "建筑大师大本营"
        case .laboratory:
            name = base == "builder" ? "星空实验室" : "实验室"
        case .starLaboratory:
            name = "星空实验室"
        case .heroHall:
            name = "英雄殿堂"
        }
        return "所需" + name + "等级 " + String(requiredLevel) + "级"
    }
}

extension Array where Element == UpgradeRequirement {
    /// 「A · B」连接（与旧 unlockLabel 措辞一致）；空数组 → 空串（调用方自行
    /// 处理「无解锁条件」文案）。
    public func displayLabels(base: String?) -> String {
        map { $0.displayLabel(base: base) }.joined(separator: " · ")
    }
}

extension CatalogLevel {
    /// 单级升级前置条件（Issue #67 Task 3）：按 item.base 解析 village 语义，
    /// 与 `CatalogItem.requirements`（item 级 flatMap）共用同一分支规则，防双实现漂移。
    /// tavern == 0 视为无英雄殿堂门槛（heroes2 源数据），不产生 .heroHall。
    public func requirements(base: String?) -> [UpgradeRequirement] {
        switch base {
        case "home":
            var out: [UpgradeRequirement] = []
            if let th = requiredTownHallLevel { out.append(.townHall(level: th)) }
            if let lab = requiredLaboratoryLevel { out.append(.laboratory(level: lab)) }
            if let ht = requiredHeroTavernLevel, ht > 0 { out.append(.heroHall(level: ht)) }
            return out
        case "builder":
            var out: [UpgradeRequirement] = []
            if let th = requiredTownHallLevel { out.append(.builderHall(level: th)) }
            if let lab = requiredLaboratoryLevel { out.append(.starLaboratory(level: lab)) }
            return out
        default:
            return []
        }
    }
}

extension CatalogItem {
    /// 本 item 各级升级前置条件的 village 语义列表（按 item.base 解析）。
    /// 无 requirement 的 item（equipment/guardians/capital 等）→ 空数组。
    /// base == nil（capital）→ 空数组（capital 无大本营门槛语义）。
    public var requirements: [UpgradeRequirement] {
        levels.flatMap { $0.requirements(base: base) }
    }
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
    /// Issue #74a：同版本 manifest（buildTag/sourceFingerprint/counts 等）；
    /// 测试注入或 manifest 缺失/损坏时 nil（增强信息，不阻塞目录加载）。
    public let manifest: CatalogManifest?

    private let itemsBySection: [String: [CatalogItem]]
    private let index: [String: CatalogItem]
    /// 实例数量宇宙（Issue #70 阶段 2）："section:dataID" → 每大本营等级
    /// （index = TH-1，恒 `universeTownHallCount` 个元素）的可建造实例数。
    /// nil = 旧目录无宇宙数据或解码校验失败（长度 ≠ 18 / 含负值 → fail-closed
    /// 视为无宇宙，不 crash）。
    private let instanceCounts: [String: [Int]]?

    /// 大本营等级上限（实例数量宇宙数组长度契约，Task 2 评审 nit 3：
    /// 魔法数字 18 单点化，init 校验与 universeCount 越界共用）。
    /// internal（评审 B-1：投影层 universeComplete 的 TH 范围守卫与
    /// universeCount 同源，防 TH19 窗口期 fail-open）。
    static let universeTownHallCount = 18

    /// 测试注入入口；`loadBundled` 只是其便捷包装。
    /// `instanceCounts` 带默认值 nil（设计评审 N2：不破坏既有构造调用点）；
    /// 校验在 init 内完成（见 `validatedInstanceCounts`），任一失败存 nil
    ///（无宇宙，fail-closed，不 crash）。
    public init(
        gameVersion: String,
        items: [CatalogItem],
        manifest: CatalogManifest? = nil,
        instanceCounts: [String: [Int]]? = nil
    ) {
        self.gameVersion = gameVersion
        self.manifest = manifest
        var bySection: [String: [CatalogItem]] = [:]
        var byKey: [String: CatalogItem] = [:]
        for item in items {
            bySection[item.section, default: []].append(item)
            byKey[Self.key(section: item.section, dataID: item.dataID)] = item
        }
        self.itemsBySection = bySection
        self.index = byKey
        // 宇宙完整性校验需要 items 索引（键存在性），故在 index 构建后执行。
        self.instanceCounts = Self.validatedInstanceCounts(instanceCounts, index: byKey)
    }

    /// 宇宙数据完整性校验（Issue #70 阶段 2 外部评审 P1-1 + 残留修复）：任一
    /// 失败 → nil（无宇宙，fail-closed——部分/畸形宇宙不得被标记为完整）：
    /// 1. 数组长度恒 `universeTownHallCount` 且值非负（原有契约）；
    /// 2. 键格式 "section:dataID"（split ":" 恰好 2 段、section 非空、
    ///    dataID 可解析 Int64）且 **canonical 重序列化一致**（修复 3：
    ///    `Int64("+0000002") == 2` 会被 Int64 接受但原始键非规范——归一化后
    ///    universeCount 查不到，键静默无效，拒绝）——畸形/非 canonical 键 → 拒绝；
    /// 3. 键存在性：每个宇宙键的 (section, dataID) 必须在 items 中存在
    ///    （手工裁剪/错配 → 拒绝）；
    /// 4. 全 0 键：数量型建筑不可能全 TH 0（手工篡改 → 拒绝）；
    /// 5. **正向完整 key 契约**（修复 2）：items 的 home 数量型（buildings/traps、
    ///    排除列表外，与 validate.py `_NON_COUNTABLE_DATA_IDS` 同源）必须全部
    ///    被宇宙覆盖——部分 instanceCounts（如 10/52）无法检测（只做反向
    ///    键存在性时裁剪不可见）。
    private static func validatedInstanceCounts(
        _ raw: [String: [Int]]?,
        index: [String: CatalogItem]
    ) -> [String: [Int]]? {
        guard let raw else { return nil }
        guard raw.allSatisfy({
            $0.value.count == Self.universeTownHallCount && $0.value.allSatisfy { $0 >= 0 }
        }) else { return nil }
        for values in raw.values where values.allSatisfy({ $0 == 0 }) {
            return nil  // 全 0 键（数量型建筑不可能全 TH 0）
        }
        var validKeys = Set<String>()
        for key in raw.keys {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty,
                  let dataID = Int64(parts[1]) else {
                return nil  // 畸形键
            }
            let section = String(parts[0])
            // canonical 重序列化（修复 3）：拒绝 "+0000002"/前导零等非规范格式
            guard key == "\(section):\(dataID)" else { return nil }
            guard index[Self.key(section: section, dataID: dataID)] != nil else {
                return nil  // 键不存在于 items（反向）
            }
            validKeys.insert(Self.key(section: section, dataID: dataID))
        }
        // 正向完整 key 契约（修复 2）：home 数量型（排除列表外）必须全部覆盖
        for item in index.values where !Self.nonCountableDataIDs.contains(item.dataID) {
            guard item.section == "buildings" || item.section == "traps" else { continue }
            guard item.base == "home" else { continue }
            guard validKeys.contains(Self.key(section: item.section, dataID: item.dataID)) else {
                return nil  // 数量型 item 无宇宙键（部分 instanceCounts）
            }
        }
        return raw
    }

    /// 数量型但不计入宇宙的 dataID（与 Tools/game_catalog/validate.py 的
    /// `_NON_COUNTABLE_DATA_IDS` 同源，逐项抄录，18.400.13 实证 37 项：
    /// 大本营/英雄神坛/哥布林单人内容/不祥洞窟/教学未使用事件变体/
    /// 笼子装饰/全空列事件陷阱等）。双端同步：validate 生成期 + 本校验运行时
    /// 双保险——任一端登记新非数量型项，另一端必须同步，否则 fail-closed
    /// 拒绝宇宙（正向契约防数量型静默丢失）。
    private static let nonCountableDataIDs: Set<Int64> = [
        // 大本营
        1_000_001, 1_000_103, 1_000_104,
        // 英雄神坛
        1_000_022, 1_000_025, 1_000_030, 1_000_066,
        // 哥布林/单人战役
        1_000_016, 1_000_017, 1_000_018, 1_000_061, 1_000_069,
        // 不祥洞窟（单人）
        1_000_062, 1_000_074, 1_000_076,
        // 教学/未使用/事件加农炮变体
        1_000_060, 1_000_087, 1_000_088, 1_000_094, 1_000_095, 1_000_096,
        // 笼子/装饰/事件建筑
        1_000_073, 1_000_075, 1_000_083, 1_000_090, 1_000_091, 1_000_092,
        1_000_098, 1_000_099, 1_000_100, 1_000_101,
        // 全空列事件陷阱 + 单机陷阱变体
        12_000_003, 12_000_004, 12_000_007, 12_000_017, 12_000_018, 12_000_019,
    ]

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
        // Issue #74a：manifest 是增强信息——缺失/解码失败不阻塞目录加载（nil）。
        // 纵深防御：manifest.gameVersion 与目录不一致时视为损坏（validate 在
        // 生成期已保证一致，此处仅防未来手工替换/版本错配）。
        // Issue #73 P1：fileCheck 校验 generatedFiles 全量存在性/size 与
        // 图标文件存在性（Bundle 内真实文件）。
        let manifest: CatalogManifest?
        if let manifestURL = Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "GameCatalog/" + version
        ), let manifestData = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode(CatalogManifest.self, from: manifestData),
           decoded.gameVersion == payload.gameVersion,
           decoded.validate(
               against: payload.items,
               catalogData: data,
               fileCheck: { relativePath, declaredSize in
                   Self.bundledFileExists(version: version, relativePath: relativePath,
                                          declaredSize: declaredSize)
               }
           ) {
            manifest = decoded
        } else {
            manifest = nil
        }
        return GameCatalog(
            gameVersion: payload.gameVersion,
            items: payload.items,
            manifest: manifest,
            instanceCounts: payload.instanceCounts
        )
    }

    /// Bundle 内文件存在性 + size 校验（Issue #73 P1：运行时完整性）。
    ///
    /// relativePath 形如 "icons/buildings/x.png" 或 "catalog.json"（manifest
    /// generatedFiles.path / renderedPath 同格式）。文件缺失或 size 与声明
    /// 不符 → false（fail-closed）。size 声明为 nil（图标引用场景）→ 只查存在。
    static func bundledFileExists(version: String, relativePath: String,
                                  declaredSize: Int?) -> Bool {
        let nsPath = relativePath as NSString
        let subdirectory = "GameCatalog/" + version + "/" + nsPath.deletingLastPathComponent
        let last = nsPath.lastPathComponent as NSString
        guard let url = Bundle.module.url(
            forResource: last.deletingPathExtension,
            withExtension: last.pathExtension,
            subdirectory: subdirectory
        ) else { return false }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return false
        }
        if let declaredSize, declaredSize != size {
            return false
        }
        return true
    }

    /// 主查询：`(section, dataID)` 精确匹配（catalog.section 与快照 section 同源）。
    public func item(section: String, dataID: Int64) -> CatalogItem? {
        index[Self.key(section: section, dataID: dataID)]
    }

    public func items(in section: String) -> [CatalogItem] {
        itemsBySection[section] ?? []
    }

    /// 「升级到 nextLevel 级的完整等级记录」（含 missingReason）；目录无该等级
    /// 记录返回 nil。Issue #74b：投影层用它单一查表，同时取 durationSeconds 与
    /// durationState，避免 `durationToUpgradeLevel`（只返回秒数）二次查表漂移。
    public func catalogLevel(toUpgrade nextLevel: Int, for item: CatalogItem) -> CatalogLevel? {
        guard nextLevel > 0 else { return nil }
        return item.levels.first(where: { $0.level == nextLevel })
    }

    /// 「升级到 nextLevel 级的完整时长」；目录无该等级记录时返回 nil。
    /// 所有表的 `levels[N].durationSeconds` 语义统一（见类型 doc comment）。
    /// 目录不存在 level <= 0 的记录，`nextLevel <= 0` 仅作非法输入防御；
    /// `nextLevel == 1` 时建筑系返回 0→1 建造时长、单位系返回 nil（初始等级）。
    public func durationToUpgradeLevel(nextLevel: Int, for item: CatalogItem) -> Int64? {
        catalogLevel(toUpgrade: nextLevel, for: item)?.durationSeconds
    }

    // MARK: - 实例数量宇宙（Issue #70 阶段 2）

    /// 目录是否携带可用宇宙数据：instanceCounts 非 nil 且非空（init 完整性
    /// 校验通过：长度/非负/键格式/canonical/键存在性/正向覆盖/非全 0）
    /// **且 manifest 非 nil 且 manifest 显式声明 catalog.json 的 sha256**。
    /// manifest 是宇宙完整性信任标记（Issue #70 阶段 2 外部评审 P1-1）：
    /// `loadBundled` 的 manifest sha256/fileCheck 校验保证 catalog.json（含
    /// instanceCounts）未被手工裁剪/篡改；注入路径显式传 manifest 表示数据
    /// 已通过生成管线完整性保证。**catalog.json sha256 声明要求**（P1-1 残留
    /// 修复）：`CatalogManifest.validate` 对 generatedFiles 无 catalog.json
    /// 条目或 sha256 nil 时跳过比对——条目存在 + sha256 格式合法时
    /// loadBundled 的 validate 必然执行了比对（manifest 非 nil = 比对通过），
    /// 否则 partial key set 可带非空 manifest 通过信任门。false = 旧目录 /
    /// 校验失败 / 无 manifest / 无 sha256 声明，调用方应走「已观测实例」
    /// 语义（无完整分母）。
    public var hasUniverseData: Bool {
        guard let instanceCounts, !instanceCounts.isEmpty else { return false }
        guard let manifest else { return false }
        let catalogEntry = manifest.generatedFiles.first { $0.path == "catalog.json" }
        return catalogEntry?.sha256?.hasPrefix("sha256:") == true
    }

    /// 宇宙查询：该 dataID 在指定大本营等级的可建造实例数。
    /// 目录无宇宙数据（hasUniverseData false）、dataID 不在宇宙表、TH 越界
    ///（< 1 或 > `universeTownHallCount`）→ nil（fail-closed）。
    public func universeCount(section: String, dataID: Int64, townHallLevel: Int) -> Int? {
        guard hasUniverseData,
              (1...Self.universeTownHallCount).contains(townHallLevel) else { return nil }
        return instanceCounts?[Self.key(section: section, dataID: dataID)]?[townHallLevel - 1]
    }

    /// 宇宙表全部键（section, dataID）——投影层合成差集项用（Issue #70 阶段 2）。
    /// 按 section 升序、同 section 按 dataID 升序（产出顺序确定，测试/UI 可预测）。
    /// 与 `hasUniverseData` 同一信任门（外部评审 P1-1）：旧目录 / 校验失败 /
    /// 无 manifest → 空数组（不可信宇宙的键不得暴露为可用数据）。
    public var universeKeys: [(section: String, dataID: Int64)] {
        guard hasUniverseData else { return [] }
        return (instanceCounts ?? [:]).keys.compactMap { key in
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let dataID = Int64(parts[1]) else { return nil }
            return (String(parts[0]), dataID)
        }
        .sorted { $0.section == $1.section ? $0.dataID < $1.dataID : $0.section < $1.section }
    }

    private static func key(section: String, dataID: Int64) -> String {
        section + ":" + String(dataID)
    }

    private struct Payload: Decodable {
        let gameVersion: String
        let items: [CatalogItem]
        /// Issue #70 阶段 2：旧目录缺键 → nil（向后兼容，解码不失败）。
        let instanceCounts: [String: [Int]]?
    }
}
