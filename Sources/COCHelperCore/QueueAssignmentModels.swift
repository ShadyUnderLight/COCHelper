import Foundation

/// Issue #183：用户对某条导入观察的本地队列分配决定状态。
///
/// - `userAssigned`：用户明确确认该导入计时属于本地某个队列，占本地容量；
/// - `observedOnly`：只观察到计时但无法证明本地队列归属（如 timer 消失、
///   当前未确认），保留记录但不占容量；
/// - `unknown`：身份/lineage 不可靠（旧 lineage 历史证据），保留但不占容量。
///
/// 没有记录即 `unassigned`（未分配），不需要持久化状态。
public enum QueueAssignmentStatus: String, Codable, Hashable, Sendable {
    case userAssigned
    case observedOnly
    case unknown
}

/// Issue #183：用户确认的本地队列映射（overlay）。
///
/// 独立于原始快照与 `ManualUpgradeCore` 的本地工作流判断。绑定可审计观察
/// 身份（itemKey + baseline revision/fingerprint/lineage），不改写任何原始
/// JSON、不自动创建/完成/取消本地记录。
public struct QueueAssignmentDecision: Codable, Hashable, Sendable, Identifiable {
    public let decisionID: UUID
    public let villageID: UUID
    public let itemKey: TrackerItemKey
    public let baselineReference: ManualBaselineReference
    public let queueKind: LocalQueueKind
    public let source: LocalQueueCapacitySource
    public let decidedAt: Date
    public var status: QueueAssignmentStatus

    public init(
        decisionID: UUID = UUID(),
        villageID: UUID,
        itemKey: TrackerItemKey,
        baselineReference: ManualBaselineReference,
        queueKind: LocalQueueKind,
        source: LocalQueueCapacitySource = .userConfigured,
        decidedAt: Date,
        status: QueueAssignmentStatus = .userAssigned
    ) throws {
        guard itemKey.isStructurallyValid else {
            throw QueueAssignmentError.invalidItemKey
        }
        guard baselineReference.isStructurallyValid else {
            throw QueueAssignmentError.invalidBaselineReference
        }
        guard decidedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw QueueAssignmentError.invalidTimestamp
        }
        self.decisionID = decisionID
        self.villageID = villageID
        self.itemKey = itemKey
        self.baselineReference = baselineReference
        self.queueKind = queueKind
        self.source = source
        self.decidedAt = decidedAt
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            decisionID: try container.decode(UUID.self, forKey: .decisionID),
            villageID: try container.decode(UUID.self, forKey: .villageID),
            itemKey: try container.decode(TrackerItemKey.self, forKey: .itemKey),
            baselineReference: try container.decode(
                ManualBaselineReference.self, forKey: .baselineReference),
            queueKind: try container.decode(LocalQueueKind.self, forKey: .queueKind),
            source: try container.decodeIfPresent(
                LocalQueueCapacitySource.self, forKey: .source) ?? .userConfigured,
            decidedAt: try container.decode(Date.self, forKey: .decidedAt),
            status: try container.decodeIfPresent(
                QueueAssignmentStatus.self, forKey: .status) ?? .userAssigned
        )
    }

    private enum CodingKeys: String, CodingKey {
        case decisionID
        case villageID
        case itemKey
        case baselineReference
        case queueKind
        case source
        case decidedAt
        case status
    }

    public var id: UUID { decisionID }
}

public enum QueueAssignmentError: Error, Equatable, Sendable {
    case invalidItemKey
    case invalidBaselineReference
    case invalidTimestamp
    case villageMismatch
}
