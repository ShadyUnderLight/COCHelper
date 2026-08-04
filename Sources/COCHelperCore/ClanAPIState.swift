import Foundation

/// 部落维度的官方 API 抓取状态（**共享数据层**：一个 clan tag 一份，不随村庄复制）。
///
/// 与 `OfficialAPIState`（玩家维度）同构，契约一致：
/// - `lastGood` 在任何失败后保留（首期失败时为 nil，后续失败保留上次成功值）。
/// - `lastErrorReason` 只含脱敏原因（来自 `CoAPIError`，不含 URL/token/正文）。
/// - `unrecognizedKeys` 为最近一次成功解码时官方新增的顶层字段（审计用途）。
///
/// 存储位置：独立于 `VillageProfile` 的共享字典 `[String: ClanAPIState]`
/// （clan tag → 状态），避免同部落多村庄产生重复且互相矛盾的副本。
public struct ClanAPIState: Codable, Hashable, Sendable {
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
    /// 最近一次成功解码的快照（失败后保留）。
    public var lastGood: OfficialClanSnapshot?
    /// 最近一次解码发现的未知顶层字段。
    public var unrecognizedKeys: [String]

    /// 当前实现版本；schema 变更时递增。
    public static let currentParserVersion = "clan-snapshot-0.1"

    /// 超过该时长视为 stale（不自动刷新，仅展示提示）。
    public static let staleThreshold: TimeInterval = 24 * 3600

    public init(
        status: OfficialAPIRequestStatus,
        clanTag: String? = nil,
        fetchedAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastErrorReason: String? = nil,
        lastHTTPStatus: Int? = nil,
        parserVersion: String = ClanAPIState.currentParserVersion,
        lastGood: OfficialClanSnapshot? = nil,
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
}

/// 部落共享数据层的持久化容器。
///
/// 存储格式为单元素字典数组（`[ [tag: state], ... ]`），解码时**逐条容错**：
/// 一条记录损坏只丢弃该条，不株连整库（部落数据是全量共享层，单条 schema
/// 漂移不应造成所有部落数据一次性丢失）。
///
/// `merging` 语义：只覆盖本次请求过的 tag，未请求的旧部落数据保留
/// （玩家换部落后旧快照不丢失、不冒充当前归属）。
public struct ClanStateStore: Codable, Hashable, Sendable {
    public private(set) var states: [String: ClanAPIState]

    public init(states: [String: ClanAPIState] = [:]) {
        self.states = states
    }

    /// 覆盖 `refreshed` 中的 tag，其余保留。
    public func merging(_ refreshed: [String: ClanAPIState]) -> ClanStateStore {
        var merged = states
        for (tag, state) in refreshed {
            merged[tag] = state
        }
        return ClanStateStore(states: merged)
    }

    // MARK: - Codable（逐条容错）

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [String: ClanAPIState] = [:]
        // 防御兜底：坏数据可能让游标无法推进，限制循环次数避免无限循环。
        var guardCounter = 0
        let maxEntries = 10_000
        while !container.isAtEnd && guardCounter < maxEntries {
            guardCounter += 1
            if let entry = try? container.decode([String: ClanAPIState].self) {
                // decode 成功（游标已推进）：空字典条目 `{}` 是合法 JSON 但
                // 无有效键，直接丢弃自身；不得执行 skip（会吞掉下一个好条目）。
                if let (tag, state) = entry.first {
                    decoded[tag] = state
                }
            } else {
                // 坏条目：JSONDecoder 在元素解码失败时不推进游标，
                // 用 JSONSkipper（任意 JSON 值都解码成功）强制消费该元素。
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

/// 任意 JSON 值（bool/string/number/array/object/null）都能解码成功的哨兵类型，
/// 用于跳过损坏条目时保证解码游标推进。
private struct JSONSkipper: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode([String: JSONSkipper].self)) != nil { return }
        if (try? container.decode([JSONSkipper].self)) != nil { return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "无法识别的 JSON 值"
        )
    }
}
