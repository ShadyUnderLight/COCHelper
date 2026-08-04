import Foundation

/// 官方部落信息的刷新核心：按 clan tag 去重、顺序执行。
///
/// 设计契约（Issue #7 stage 3a）：部落数据是**共享数据层**；相同 clan tag
/// 在一次刷新批次中只触发一次网络请求；顺序执行配合 `CoAPIClient` 429 退避；
/// 失败保留 last-good；只返回本次请求过的 tag。
/// 实现委托给共享 `EndpointRefresher`（stage 3c 泛化）。
public struct ClanRefresher: Sendable {
    public let client: CoAPIClient

    public init(client: CoAPIClient) {
        self.client = client
    }

    /// 批量刷新。`villageClanTags` 的每个元素是村庄的当前 clan tag
    /// （nil/无效值被忽略）。`previous` 是共享 last-good 来源。
    public func refreshClans(
        villageClanTags: [String?],
        previous: [String: ClanAPIState],
        now: Date = Date()
    ) async -> [String: ClanAPIState] {
        await EndpointRefresher.refresh(
            tags: villageClanTags,
            previous: previous,
            parserVersion: ClanAPIState.currentParserVersion,
            now: now
        ) { tag in
            try await client.fetchClan(tag: tag)
        }
    }
}
