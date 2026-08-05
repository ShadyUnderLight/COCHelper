import Foundation

/// 端点解析器版本协议：每个快照类型声明自己的 parserVersion
/// （如 "clan-snapshot-0.1"）。`OfficialEndpointState` 的 init 默认值
/// 引用它，恢复旧构造语义（`ClanAPIState(...)` 默认端点版本）。
public protocol EndpointParserVersioning {
    static var currentParserVersion: String { get }
}

/// 官方 API 端点状态的**泛型实现**（Issue #7 stage 3c 泛化前置承诺）。
///
/// 3a/3b 的 `ClanAPIState`/`ClanWarAPIState` 是同构拷贝；第三、四个端点
/// （warlog / capitalraidseasons）来临前泛化为单一实现，旧类型保留为
/// typealias（**编码键完全一致 → 旧持久化数据兼容**，由 205 测试回归验证）。
///
/// 契约（与旧实现逐字一致）：
/// - `lastGood` 在任何失败后保留；`notInWar` 等合法空状态也是成功快照。
/// - `lastErrorReason` 只含脱敏原因。
/// - `unrecognizedKeys` 为最近一次成功解码时官方新增的顶层字段。
/// - `parserVersion` 默认取 `Snapshot.currentParserVersion`（协议），
///   恢复旧构造语义（旧默认值即端点版本）。
public struct OfficialEndpointState<Snapshot: Codable & Hashable & Sendable & EndpointParserVersioning>: Codable, Hashable, Sendable {
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
    /// 解码器版本（各端点约束扩展提供当前值；构造时传入并持久化）。
    public var parserVersion: String
    /// 最近一次成功解码的快照（失败后保留）。
    public var lastGood: Snapshot?
    /// 最近一次解码发现的未知顶层字段。
    public var unrecognizedKeys: [String]

    /// 超过该时长视为 stale（不自动刷新，仅展示提示）。
    /// computed（泛型类型不支持 static stored property）。
    public static var staleThreshold: TimeInterval { 24 * 3600 }

    /// `parserVersion` 默认取 `Snapshot.currentParserVersion`（协议静态成员），
    /// 恢复旧构造语义：`ClanAPIState(status:...)` 默认即端点版本，
    /// 不会产生无法审计的 "endpoint-state" 值。
    public init(
        status: OfficialAPIRequestStatus,
        clanTag: String? = nil,
        fetchedAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastErrorReason: String? = nil,
        lastHTTPStatus: Int? = nil,
        parserVersion: String = Snapshot.currentParserVersion,
        lastGood: Snapshot? = nil,
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

    /// 来源标签（各共享卡片共用）。
    public var sourceLabel: String? {
        OfficialAPISourceLabeling.label(status: status, hasLastGood: lastGood != nil)
    }
}

// MARK: - 各端点 parserVersion（协议遵守）

extension OfficialClanSnapshot: EndpointParserVersioning {
    public static var currentParserVersion: String { "clan-snapshot-0.1" }
}

extension OfficialClanWarSnapshot: EndpointParserVersioning {
    /// 0.2：成员级攻击表解析范围（Issue #20，Task 1 新增 ClanWarMember 解码）。
    public static var currentParserVersion: String { "clan-war-0.2" }
}

// 分页包装类型（OfficialWarLogPage / OfficialCapitalRaidPage）在
// ClanPaginationModels.swift 中遵守 EndpointParserVersioning。

// MARK: - 端点 typealias（保持既有 public API 与持久化格式）

/// 部落档案状态（3a）：parserVersion "clan-snapshot-0.1"。
public typealias ClanAPIState = OfficialEndpointState<OfficialClanSnapshot>

/// 部落当前战争状态（3b）：parserVersion "clan-war-0.2"（0.2 = 成员级攻击表解析范围）。
public typealias ClanWarAPIState = OfficialEndpointState<OfficialClanWarSnapshot>

/// 部落战争日志状态（3c）：parserVersion "clan-war-log-0.3"。
public typealias ClanWarLogAPIState = OfficialEndpointState<OfficialWarLogPage>

/// 部落资本赛季状态（3c）：parserVersion "clan-capital-0.3"。
public typealias ClanCapitalAPIState = OfficialEndpointState<OfficialCapitalRaidPage>

// MARK: - typealias 的 currentParserVersion 兼容（无约束转发：未来端点零样板）

public extension OfficialEndpointState {
    static var currentParserVersion: String { Snapshot.currentParserVersion }
}
