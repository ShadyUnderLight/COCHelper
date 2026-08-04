import Foundation

/// 官方部落信息的刷新核心：按 clan tag 去重、顺序执行。
///
/// 设计契约（Issue #7 stage 3a）：
/// - 部落数据是**共享数据层**：输入是每个村庄的当前 clan tag，输出是
///   `[clanTag: ClanAPIState]`，不包含村庄维度。
/// - 相同 clan tag 在一次刷新批次中只触发一次网络请求，结果供所有
///   同部落村庄共享（验收标准：重复 clan tag 只产生一次请求）。
/// - 顺序执行（非无限并发），配合 `CoAPIClient` 内部的 429 退避。
/// - 无效/缺失 clan tag 被忽略，不发起请求，也不产生状态。
/// - 失败返回 `failed` 并保留 `previous` 中该 tag 的 last-good；首次失败
///   无 last-good。
/// - 本类型不管理存储：只返回本次请求过的 tag 的新状态；未被请求的 tag
///   是否保留由调用方决定（refresher 不隐式删除数据）。
public struct ClanRefresher: Sendable {
    public let client: CoAPIClient

    public init(client: CoAPIClient) {
        self.client = client
    }

    /// 批量刷新。`villageClanTags` 的每个元素是村庄的当前 clan tag
    /// （nil/无效值被忽略）。`previous` 是共享 last-good 来源。
    /// `now` 可注入便于测试。
    public func refreshClans(
        villageClanTags: [String?],
        previous: [String: ClanAPIState],
        now: Date = Date()
    ) async -> [String: ClanAPIState] {
        // 按规范化后的 tag 去重（sorted 保证确定性，便于测试与审计）。
        var tags = Set<String>()
        for rawTag in villageClanTags {
            guard let normalized = OfficialPlayerTagValidator.normalized(rawTag),
                  OfficialPlayerTagValidator.isValid(normalized) else {
                continue
            }
            tags.insert(normalized)
        }

        var result: [String: ClanAPIState] = [:]
        for tag in tags.sorted() {
            if Task.isCancelled { break }
            result[tag] = await refreshState(for: tag, previous: previous[tag], now: now)
        }
        return result
    }

    // MARK: - 内部

    private func refreshState(for tag: String, previous: ClanAPIState?, now: Date) async -> ClanAPIState {
        do {
            let snapshot = try await client.fetchClan(tag: tag)
            return ClanAPIState(
                status: .success,
                clanTag: tag,
                fetchedAt: now,
                lastAttemptAt: now,
                lastErrorReason: nil,
                lastHTTPStatus: nil,
                parserVersion: ClanAPIState.currentParserVersion,
                lastGood: snapshot,
                unrecognizedKeys: snapshot.unrecognizedKeys
            )
        } catch let error as CoAPIError {
            return ClanAPIState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: error.userFacingReason,
                lastHTTPStatus: error.httpStatus,
                parserVersion: ClanAPIState.currentParserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        } catch is CancellationError {
            // CoAPIClient 原样传播 CancellationError；不得以"未知错误：
            // CancellationError"呈现给用户。
            return ClanAPIState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: "已取消",
                lastHTTPStatus: nil,
                parserVersion: ClanAPIState.currentParserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        } catch {
            return ClanAPIState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: "未知错误：\(type(of: error))",
                lastHTTPStatus: nil,
                parserVersion: ClanAPIState.currentParserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        }
    }
}
