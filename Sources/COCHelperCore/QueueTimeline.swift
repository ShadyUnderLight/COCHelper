import Foundation

/// Issue #17：队列时间线边界契约。
///
/// 真实账号 JSON（anonymized_account_snapshot.json 实测）不提供队列身份
/// （queueID/queueKind/assignedItemID）、目标等级（targetLevel）或排程
/// （startedAt/totalDurationSeconds）。本类型是「请求精确队列时间线」的唯一
/// 契约入口：当前一律返回结构化不可用状态，禁止编造队列信息；未来 JSON
/// 出现明确队列字段时另开 Issue 扩展 `QueueTimelineResolution`。
public struct QueueTimelineUnavailable: Codable, Hashable, Sendable {
    /// 已知的队列相关字段；当前解码器不读取，fixture 实测 0 处。
    public static let missingQueueFields: [String] = [
        "queueID", "queueKind", "assignedItemID",
        "targetLevel", "startedAt", "totalDurationSeconds",
    ]

    /// 不可用原因（含请求项目名，便于定位）。
    public let reason: String
    /// 缺失的队列字段清单（`missingQueueFields`）。
    public let missingFields: [String]
    /// 快照捕获时间；快照无 timestamp 时 nil（如实透传，不伪造）。
    public let snapshotCapturedAt: Date?
    /// 静态目录版本；目录不可用时 nil。
    public let catalogVersion: String?

    public init(
        reason: String,
        missingFields: [String],
        snapshotCapturedAt: Date?,
        catalogVersion: String?
    ) {
        self.reason = reason
        self.missingFields = missingFields
        self.snapshotCapturedAt = snapshotCapturedAt
        self.catalogVersion = catalogVersion
    }
}

/// 队列时间线请求结果。当前只有 `.unavailable`；未来队列字段出现时再扩展。
public enum QueueTimelineResolution: Codable, Hashable, Sendable {
    /// 当前账号 JSON 不提供队列身份/目标等级，无法生成精确队列时间线。
    case unavailable(QueueTimelineUnavailable)
}

/// 纯函数契约：请求某条升级记录的精确队列时间线。
///
/// `snapshotCapturedAt` 来源：`VillageProfile.accountSnapshot?.capturedAt`；
/// `catalogVersion` 来源：`VillageCatalogProjection.catalogVersion`（或
/// `UpgradeDisplayRecord.catalogVersion`）。
public enum QueueTimelineResolver {
    /// 当前解码器不提供任何队列字段，恒返回 `.unavailable`（禁止编造）。
    public static func resolve(
        for item: VillageItemState,
        snapshotCapturedAt: Date?,
        catalogVersion: String?
    ) -> QueueTimelineResolution {
        .unavailable(QueueTimelineUnavailable(
            reason: "当前账号 JSON 不提供队列身份/目标等级（\(item.name)），无法生成精确队列时间线。",
            missingFields: QueueTimelineUnavailable.missingQueueFields,
            snapshotCapturedAt: snapshotCapturedAt,
            catalogVersion: catalogVersion
        ))
    }
}
