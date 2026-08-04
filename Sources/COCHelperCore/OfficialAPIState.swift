import Foundation

/// 官方 API 请求的存储基础状态。
///
/// 注意：`stale` 不是存储状态——它是 `fetchedAt` 与当前时间的派生结果，
/// 避免持久化一个必然过期的判定（见 `displayStatus`）。
public enum OfficialPlayerRequestStatus: String, Codable, Hashable, Sendable {
    /// 从未发起过请求
    case never
    /// 请求进行中
    case loading
    /// 最近一次请求成功
    case success
    /// 最近一次请求失败（`lastErrorReason` 含脱敏原因）
    case failed
    /// 未发起请求（缺 tag / tag 无效 / 批量刷新跳过）
    case skipped
}

/// 展示给用户的状态：在存储状态之上叠加 `stale` 派生。
public enum OfficialPlayerDisplayStatus: Equatable, Hashable, Sendable {
    case never
    case loading
    case success
    case stale
    case failed
    case skipped
}

/// 村庄的官方玩家信息抓取状态，独立于本地导入快照存储。
///
/// 契约：
/// - `lastGood` 在任何失败后保留（首期失败时为 nil，后续失败保留上次成功值）。
/// - `lastErrorReason` 只含脱敏原因（来自 `CoAPIError`，不含 URL/token/正文）。
/// - `unrecognizedKeys` 为最近一次成功解码时官方新增的顶层字段（审计用途）。
public struct OfficialAPIState: Codable, Hashable, Sendable {
    public var status: OfficialPlayerRequestStatus
    /// 请求使用的规范化 tag（可能与该村庄导入 tag 不同，例如去空白）。
    public var playerTag: String?
    /// 上次成功抓取时间。
    public var fetchedAt: Date?
    /// 上次尝试时间（含失败）。
    public var lastAttemptAt: Date?
    /// 最近失败的脱敏原因。
    public var lastErrorReason: String?
    /// 最近失败的 HTTP 状态码（若来自传输层则为 nil）。
    public var lastHTTPStatus: Int?
    /// 解码器版本，用于将来 schema 变更审计。
    public var parserVersion: String
    /// 最近一次成功解码的快照（失败后保留）。
    public var lastGood: OfficialPlayerSnapshot?
    /// 最近一次解码发现的未知顶层字段。
    public var unrecognizedKeys: [String]

    /// 当前实现版本；schema 变更时递增。
    public static let currentParserVersion = "player-snapshot-0.1"

    /// 超过该时长视为 stale（不自动刷新，仅展示提示）。
    public static let staleThreshold: TimeInterval = 24 * 3600

    public init(
        status: OfficialPlayerRequestStatus,
        playerTag: String? = nil,
        fetchedAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastErrorReason: String? = nil,
        lastHTTPStatus: Int? = nil,
        parserVersion: String = OfficialAPIState.currentParserVersion,
        lastGood: OfficialPlayerSnapshot? = nil,
        unrecognizedKeys: [String] = []
    ) {
        self.status = status
        self.playerTag = playerTag
        self.fetchedAt = fetchedAt
        self.lastAttemptAt = lastAttemptAt
        self.lastErrorReason = lastErrorReason
        self.lastHTTPStatus = lastHTTPStatus
        self.parserVersion = parserVersion
        self.lastGood = lastGood
        self.unrecognizedKeys = unrecognizedKeys
    }

    /// 供展示的状态：success 但超过 `staleThreshold` 未刷新时显示 stale。
    public var displayStatus: OfficialPlayerDisplayStatus {
        switch status {
        case .never: return .never
        case .loading: return .loading
        case .success: return isStale ? .stale : .success
        case .failed: return .failed
        case .skipped: return .skipped
        }
    }

    /// 距上次成功抓取是否超过 `staleThreshold`。
    public var isStale: Bool {
        isStale(at: Date())
    }

    public func isStale(at now: Date) -> Bool {
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) > Self.staleThreshold
    }
}
