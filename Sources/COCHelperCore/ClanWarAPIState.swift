import Foundation

/// 部落当前战争（currentwar）的抓取状态（**共享数据层**：一个 clan tag
/// 一份，不随村庄复制）。
///
/// 与 `ClanAPIState` 同构，契约一致：
/// - `lastGood` 在任何失败后保留；`notInWar`（无战争）是**成功**快照，
///   同样存入 lastGood，UI 据此显示空状态而非失败。
/// - `lastErrorReason` 只含脱敏原因。
/// - `unrecognizedKeys` 为最近一次成功解码时官方新增的顶层字段。
///
/// 存储位置：独立于 clan profile 的共享字典 `[String: ClanWarAPIState]`
/// （key `coc-helper.clan-wars.v1`）：战争与档案是不同端点、不同新鲜度，
/// 各自按需刷新。
public struct ClanWarAPIState: Codable, Hashable, Sendable {
    public var status: OfficialAPIRequestStatus
    /// 请求使用的规范化 clan tag。
    public var clanTag: String?
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
    /// 最近一次成功解码的快照（失败后保留；notInWar 也是成功快照）。
    public var lastGood: OfficialClanWarSnapshot?
    /// 最近一次解码发现的未知顶层字段。
    public var unrecognizedKeys: [String]

    /// 当前实现版本；schema 变更时递增。
    public static let currentParserVersion = "clan-war-0.1"

    /// 超过该时长视为 stale（不自动刷新，仅展示提示）。
    public static let staleThreshold: TimeInterval = 24 * 3600

    public init(
        status: OfficialAPIRequestStatus,
        clanTag: String? = nil,
        fetchedAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastErrorReason: String? = nil,
        lastHTTPStatus: Int? = nil,
        parserVersion: String = ClanWarAPIState.currentParserVersion,
        lastGood: OfficialClanWarSnapshot? = nil,
        unrecognizedKeys: [String] = []
    ) {
        self.status = status
        self.clanTag = clanTag
        self.fetchedAt = fetchedAt
        self.lastAttemptAt = lastAttemptAt
        self.lastErrorReason = lastErrorReason
        self.lastHTTPStatus = lastHTTPStatus
        self.parserVersion = parserVersion
        self.lastGood = lastGood
        self.unrecognizedKeys = unrecognizedKeys
    }

    /// 供展示的状态：success 但超过 `staleThreshold` 未刷新时显示 stale。
    public var displayStatus: OfficialAPIDisplayStatus {
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

    /// 来源标签（与 ClanAPIState 共用纯函数）。
    public var sourceLabel: String? {
        OfficialAPISourceLabeling.label(status: status, hasLastGood: lastGood != nil)
    }
}

/// 部落战争共享数据层的持久化容器。
///
/// 与 `ClanStateStore` 同构：单元素字典数组存储 + 逐条容错解码（一条坏记录
/// 只丢弃该条，不株连全库）+ `merging` 只覆盖本次请求过的 tag。
public struct ClanWarStateStore: Codable, Hashable, Sendable {
    public private(set) var states: [String: ClanWarAPIState]

    public init(states: [String: ClanWarAPIState] = [:]) {
        self.states = states
    }

    /// 覆盖 `refreshed` 中的 tag，其余保留。
    public func merging(_ refreshed: [String: ClanWarAPIState]) -> ClanWarStateStore {
        var merged = states
        for (tag, state) in refreshed {
            merged[tag] = state
        }
        return ClanWarStateStore(states: merged)
    }

    // MARK: - Codable（逐条容错）

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [String: ClanWarAPIState] = [:]
        var guardCounter = 0
        let maxEntries = 10_000
        while !container.isAtEnd && guardCounter < maxEntries {
            guardCounter += 1
            if let entry = try? container.decode([String: ClanWarAPIState].self) {
                // decode 成功（游标已推进）：空字典条目 `{}` 丢弃自身，
                // 不得执行 skip（会吞掉下一个好条目）。
                if let (tag, state) = entry.first {
                    decoded[tag] = state
                }
            } else {
                // 坏条目：JSONDecoder 在元素解码失败时不推进游标，
                // 用 JSONSkipper 强制消费该元素。
                _ = try? container.decode(JSONSkipper.self)
            }
        }
        states = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for tag in states.keys.sorted() {
            try container.encode([tag: states[tag]!])
        }
    }
}
