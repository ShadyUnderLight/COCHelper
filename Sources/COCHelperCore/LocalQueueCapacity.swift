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

/// Issue #145：某个本地队列的占用摘要（纯投影，不写任何状态）。
public struct LocalQueueOccupancy: Codable, Hashable, Sendable {
    public let queueKind: LocalQueueKind
    /// 本地手动 active 记录数（只统计 `status == .active` 且 queueKind 匹配）。
    public let activeManualCount: Int
    /// 用户配置的容量；nil = 未配置（不做容量校验）。
    public let capacity: Int?

    public init(queueKind: LocalQueueKind, activeManualCount: Int, capacity: Int?) {
        self.queueKind = queueKind
        self.activeManualCount = activeManualCount
        self.capacity = capacity
    }

    public var isCapacityConfigured: Bool { capacity != nil }

    /// 本地容量已满（仅当配置了容量时判定）。
    public var isFull: Bool {
        guard let capacity else { return false }
        return activeManualCount >= capacity
    }

    /// 剩余可启动数量；未配置容量时 nil。
    public var availableSlots: Int? {
        guard let capacity else { return nil }
        return max(0, capacity - activeManualCount)
    }
}

/// Issue #145：本地队列占用投影入口（纯函数）。
public enum LocalQueueOccupancyResolver {
    /// `capacityConfig` 的 villageID 与调用方村庄一致由调用方保证。
    ///
    /// `at now` 用于排除已到期（`expectedEndAt <= now`）但尚未 settle 的
    /// active 记录：它们即将完成，不应占用本地容量（review P2）。
    public static func occupancy(
        queueKind: LocalQueueKind,
        activeRecords: [ManualUpgradeRecord],
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
        return LocalQueueOccupancy(
            queueKind: queueKind,
            activeManualCount: count,
            capacity: capacityConfig?.capacity
        )
    }
}
