import Foundation

/// Issue #49 Task 1：玩家村庄身份投影（名称优先级链 + 官方状态透传）。
///
/// 名称优先级（照 issue 契约）：`lastGood.name`（trim 非空）→ 本地名 → tag → "未命名村庄"。
/// 注意："未命名村庄" 是"无名字"占位（`VillageProfile.init` 对空白名的归一化结果），
/// 在链中视为缺失，继续向 tag 回退（与 `AppModel.applyPendingAccountSnapshot` 对占位名的
/// 处理一致）。官方名若为非空白（含字面"未命名村庄"）则按官方昵称对待。
public enum VillageIdentitySource: Equatable, Hashable, Sendable {
    /// 官方昵称（`lastGood.name` 非空白）
    case officialName
    /// 本地 `VillageProfile.name` 回退
    case localName
    /// tag 回退
    case tagFallback
    /// "未命名村庄"
    case unnamed
}

/// 村庄身份投影结果：UI 直接消费的纯值类型。
public struct VillageDisplayIdentity: Equatable, Hashable, Sendable {
    public let primaryName: String
    /// 展示用 tag：`officialState.playerTag ?? village.tag`
    public let tag: String?
    /// 本地别名：仅当官方昵称存在且本地名不同、非占位"未命名村庄"时提供
    public let localAlias: String?
    public let source: VillageIdentitySource
    /// 官方 API 展示状态（`state?.displayStatus ?? .never`，stale 派生使用注入的 `now`）
    public let officialStatus: OfficialAPIDisplayStatus
    /// 官方 API 上次成功抓取时间（UI "官方 API 已更新"行）
    public let officialFetchedAt: Date?

    /// 显式 public init（隐式 memberwise 为 internal，UI 层无法跨模块构造）。
    public init(
        primaryName: String,
        tag: String?,
        localAlias: String?,
        source: VillageIdentitySource,
        officialStatus: OfficialAPIDisplayStatus,
        officialFetchedAt: Date?
    ) {
        self.primaryName = primaryName
        self.tag = tag
        self.localAlias = localAlias
        self.source = source
        self.officialStatus = officialStatus
        self.officialFetchedAt = officialFetchedAt
    }
}

/// 身份投影入口：纯函数（village, state）→ identity，无全局状态，天然多村庄隔离。
public enum VillageDisplayIdentityProjection {
    /// 占位名：`VillageProfile.init` 对空白名的归一化结果，链中视为"无名字"。
    private static let placeholderName = "未命名村庄"

    public static func project(
        village: VillageProfile,
        officialState: OfficialAPIState?,
        at now: Date = Date()
    ) -> VillageDisplayIdentity {
        let officialName = nonBlank(officialState?.lastGood?.name)
        let localName = nonBlank(village.name)
        let localTag = nonBlank(village.tag)

        let primaryName: String
        let source: VillageIdentitySource
        if let officialName {
            primaryName = officialName
            source = .officialName
        } else if let localName, localName != placeholderName {
            primaryName = localName
            source = .localName
        } else if let localTag {
            primaryName = localTag
            source = .tagFallback
        } else {
            primaryName = placeholderName
            source = .unnamed
        }

        let localAlias: String?
        if source == .officialName,
           let localName,
           localName != placeholderName,
           localName != officialName {
            localAlias = localName
        } else {
            localAlias = nil
        }

        return VillageDisplayIdentity(
            primaryName: primaryName,
            tag: officialState?.playerTag ?? village.tag,
            localAlias: localAlias,
            source: source,
            officialStatus: displayStatus(of: officialState, at: now),
            officialFetchedAt: officialState?.fetchedAt
        )
    }

    /// trim 后为空视为缺失；返回的均为首尾无空白的展示值。
    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 与 `OfficialAPIState.displayStatus` 语义一致，但 stale 派生使用注入的 `now`：
    /// `displayStatus` 内部取 `Date()`，会让投影不可复现（测试无法固定 stale 边界）；
    /// `isStale(at:)` 已支持注入，这里按同一规则重算。
    private static func displayStatus(of state: OfficialAPIState?, at now: Date) -> OfficialAPIDisplayStatus {
        guard let state else { return .never }
        switch state.status {
        case .never: return .never
        case .loading: return .loading
        case .success: return state.isStale(at: now) ? .stale : .success
        case .failed: return .failed
        case .skipped: return .skipped
        }
    }
}
