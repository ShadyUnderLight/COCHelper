import Foundation

/// 官方部落当前战争的刷新核心：按 clan tag 去重、顺序执行（按需语义）。
///
/// 设计契约（Issue #7 stage 3b）：`notInWar`（无战争，200 响应）是**成功**；
/// 失败保留 last-good；无效 tag 忽略。
/// 实现委托给共享 `EndpointRefresher`（stage 3c 泛化）。
public struct ClanWarRefresher: Sendable {
    public let client: CoAPIClient

    public init(client: CoAPIClient) {
        self.client = client
    }

    /// 批量刷新。`villageClanTags` 的每个元素是村庄的当前 clan tag。
    public func refreshClanWars(
        villageClanTags: [String?],
        previous: [String: ClanWarAPIState],
        now: Date = Date()
    ) async -> [String: ClanWarAPIState] {
        await EndpointRefresher.refresh(
            tags: villageClanTags,
            previous: previous,
            parserVersion: ClanWarAPIState.currentParserVersion,
            now: now
        ) { tag in
            try await client.fetchClanWar(tag: tag)
        }
    }
}
