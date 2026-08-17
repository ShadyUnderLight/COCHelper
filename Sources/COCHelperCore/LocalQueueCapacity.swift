import Foundation

/// Issue #145：本地队列类别。
///
/// `ManualUpgradeRecord.queueKind` 是自由字符串（#139 引入，仅透传存储）。
/// 本类型提供已知类别与未知类别的包装，按 `rawValue` 与 record 字段完全兼容。
/// 这是本地工作流标签，不是游戏官方队列类别；不推断 builder/lab/hero/
/// equipment 的官方容量和分配规则。
public struct LocalQueueKind: Codable, Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let builder = LocalQueueKind(rawValue: "builder")
    public static let laboratory = LocalQueueKind(rawValue: "laboratory")
    public static let hero = LocalQueueKind(rawValue: "hero")
    public static let equipment = LocalQueueKind(rawValue: "equipment")

    /// 已知类别清单（UI 选择器顺序）。
    public static let knownKinds: [LocalQueueKind] = [.builder, .laboratory, .hero, .equipment]

    public var isKnown: Bool {
        Self.knownKinds.contains(self)
    }

    /// 中文展示名；未知类别如实显示原始字符串。
    public var displayName: String {
        switch rawValue {
        case "builder": "建筑工人"
        case "laboratory": "实验室"
        case "hero": "英雄"
        case "equipment": "装备"
        default: rawValue
        }
    }

    public var description: String { rawValue }

    // 单值 Codable：JSON 直接是字符串，与 record.queueKind 同构。
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 容量配置来源。当前只有用户配置；未来出现其他来源（如官方数据）再扩展。
public enum LocalQueueCapacitySource: String, Codable, Hashable, Sendable {
    /// 用户在本机明确设置的本地工作流容量，不是游戏官方事实。
    case userConfigured
}

/// Issue #182：容量配置批量更新项。
///
/// 使用显式 case 而非 `Int?` 字典值，避免 `dict[key] = nil`（移除键）
/// 与"值为 nil"（键存在）语义混淆导致的静默丢失/失效问题。
/// `updates` 字典中未出现的类别保持原配置（含未知/未来 `queueKind`）。
public enum LocalQueueCapacityUpdate: Hashable, Sendable {
    /// 设置/更新为指定容量（`0` 合法，不允许任何本地 active）。
    case set(Int)
    /// 显式清除该类别配置（回到未配置）。
    case clear
}

/// Issue #145：用户配置的本地队列容量（source = userConfigured）。
public struct LocalQueueCapacityConfig: Codable, Hashable, Sendable {
    /// 容量上限（防御性：超过视为非法输入，避免无意义的大数）。
    public static let maximumCapacity = 10_000

    public let villageID: UUID
    public let queueKind: LocalQueueKind
    /// 本地手动记录同时进行的最大数量；0 合法（不允许任何本地 active）。
    public let capacity: Int
    public let updatedAt: Date
    public let source: LocalQueueCapacitySource

    public init(
        villageID: UUID,
        queueKind: LocalQueueKind,
        capacity: Int,
        updatedAt: Date,
        source: LocalQueueCapacitySource = .userConfigured
    ) throws {
        guard capacity >= 0, capacity <= Self.maximumCapacity else {
            throw LocalQueueCapacityConfigError.invalidCapacity(capacity)
        }
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LocalQueueCapacityConfigError.invalidTimestamp
        }
        self.villageID = villageID
        self.queueKind = queueKind
        self.capacity = capacity
        self.updatedAt = updatedAt
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            villageID: try container.decode(UUID.self, forKey: .villageID),
            queueKind: try container.decode(LocalQueueKind.self, forKey: .queueKind),
            capacity: try container.decode(Int.self, forKey: .capacity),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            source: try container.decodeIfPresent(
                LocalQueueCapacitySource.self, forKey: .source
            ) ?? .userConfigured
        )
    }

    private enum CodingKeys: String, CodingKey {
        case villageID
        case queueKind
        case capacity
        case updatedAt
        case source
    }
}

public enum LocalQueueCapacityConfigError: Error, Equatable, Sendable {
    case invalidCapacity(Int)
    case invalidTimestamp
}

/// Issue #192：本地队列占用投影的可信度状态。
///
/// 区分「已知 0」（available）与「当前未知」（unreconciled/unavailable），
/// 禁止把未知占用静默压成数字 0 或解释成空闲。UI 只在 available 时渲染
/// 占用数字与容量满结论。
public enum LocalQueueOccupancyStatus: String, Codable, Hashable, Sendable {
    /// 当前基线已对账，数字可用于容量视图。
    case available
    /// 配置可能存在，但当前占用来源不可比较（快照尚未对账）。
    case unreconciled
    /// 存储/历史不可用，无法投影。
    case unavailable
}

/// Issue #145：某个本地队列的占用摘要（纯投影，不写任何状态）。
public struct LocalQueueOccupancy: Codable, Hashable, Sendable {
    public let queueKind: LocalQueueKind
    /// 本地手动 active 记录数（只统计 `status == .active` 且 queueKind 匹配）。
    public let activeManualCount: Int
    /// Issue #183：用户确认（userAssigned）且属于当前 lineage 的导入观察
    /// overlay 数。调用方负责先按当前 lineage 过滤传入的 assignments。
    public let confirmedImportedCount: Int
    /// 用户配置的容量；nil = 未配置（不做容量校验）。
    public let capacity: Int?
    /// Issue #192：投影可信度状态。非 `.available` 时数字不反映当前事实，
    /// UI 不得渲染占用/容量满结论。
    public let status: LocalQueueOccupancyStatus

    public init(
        queueKind: LocalQueueKind,
        activeManualCount: Int,
        confirmedImportedCount: Int = 0,
        capacity: Int?,
        status: LocalQueueOccupancyStatus = .available
    ) {
        self.queueKind = queueKind
        self.activeManualCount = activeManualCount
        self.confirmedImportedCount = confirmedImportedCount
        self.capacity = capacity
        self.status = status
    }

    // 兼容旧编码数据：`status` 是 Issue #192 新增字段，缺失时按
    // `.available`（旧投影语义）处理，避免旧 JSON 解码失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.queueKind = try container.decode(LocalQueueKind.self, forKey: .queueKind)
        self.activeManualCount = try container.decode(Int.self, forKey: .activeManualCount)
        self.confirmedImportedCount = try container.decode(
            Int.self, forKey: .confirmedImportedCount)
        self.capacity = try container.decodeIfPresent(Int.self, forKey: .capacity)
        self.status = try container.decodeIfPresent(
            LocalQueueOccupancyStatus.self, forKey: .status
        ) ?? .available
    }

    private enum CodingKeys: String, CodingKey {
        case queueKind
        case activeManualCount
        case confirmedImportedCount
        case capacity
        case status
    }

    /// 手动 active + 用户确认的导入 overlay 总数。
    public var totalOccupancyCount: Int { activeManualCount + confirmedImportedCount }

    public var isCapacityConfigured: Bool { capacity != nil }

    /// 本地容量已满（仅当 `.available` 且配置了容量时判定）。
    /// Issue #194：非 `.available` 时占用未知（未对账/存储不可用），
    /// 不得基于旧数字给出「容量已满」结论，一律返回 false。
    public var isFull: Bool {
        guard status == .available, let capacity else { return false }
        return totalOccupancyCount >= capacity
    }

    /// 剩余可启动数量；仅 `.available` 且配置了容量时提供。
    /// Issue #194：非 `.available` 时返回 nil，不给出看似可用的数字。
    public var availableSlots: Int? {
        guard status == .available, let capacity else { return nil }
        return max(0, capacity - totalOccupancyCount)
    }
}

/// Issue #145：本地队列占用投影入口（纯函数）。
public enum LocalQueueOccupancyResolver {
    /// `capacityConfig` 的 villageID 与调用方村庄一致由调用方保证。
    ///
    /// `at now` 用于排除已到期（`expectedEndAt <= now`）但尚未 settle 的
    /// active 记录：它们即将完成，不应占用本地容量（review P2）。
    /// `confirmedAssignments` 只统计 `status == .userAssigned` 且 queueKind
    /// 匹配的 overlay；observedOnly/unknown/其他类别不占容量（#183）。
    public static func occupancy(
        queueKind: LocalQueueKind,
        activeRecords: [ManualUpgradeRecord],
        confirmedAssignments: [QueueAssignmentDecision] = [],
        capacityConfig: LocalQueueCapacityConfig?,
        at now: Date
    ) -> LocalQueueOccupancy {
        let count = activeRecords
            .filter {
                $0.status == .active
                    && $0.queueKind == queueKind.rawValue
                    && $0.expectedEndAt > now
            }
            .count
        let confirmed = confirmedAssignments
            .filter { $0.status == .userAssigned && $0.queueKind == queueKind }
            .count
        return LocalQueueOccupancy(
            queueKind: queueKind,
            activeManualCount: count,
            confirmedImportedCount: confirmed,
            capacity: capacityConfig?.capacity
        )
    }
}
