import Foundation

/// 官方端点刷新的**共享实现**（Issue #7 stage 3c 泛化前置承诺）。
///
/// 3a/3b 的 `ClanRefresher`/`ClanWarRefresher` 是同构拷贝（去重、顺序执行、
/// last-good、取消传播），提取为单一函数；原 struct 保留为薄包装（public
/// API 不变）。
///
/// 契约：
/// - 相同 tag 一次请求（Set 去重 + sorted 顺序执行）。
/// - 无效/缺失 tag 被忽略。
/// - 失败保留 `previous` 中该 tag 的 last-good；首次失败无 last-good。
/// - `CancellationError` / `URLError(.cancelled)` → "已取消"（不泄漏类型名）。
/// - 只返回本次请求过的 tag；未请求的 tag 由调用方决定保留。
public enum EndpointRefresher {
    public static func refresh<Snapshot>(
        tags: [String?],
        previous: [String: OfficialEndpointState<Snapshot>],
        parserVersion: String,
        now: Date = Date(),
        fetch: @Sendable (String) async throws -> Snapshot
    ) async -> [String: OfficialEndpointState<Snapshot>]
    where Snapshot: Codable & Hashable & Sendable & UnrecognizedKeysProviding {
        var uniqueTags = Set<String>()
        for rawTag in tags {
            guard let normalized = OfficialPlayerTagValidator.normalized(rawTag),
                  OfficialPlayerTagValidator.isValid(normalized) else {
                continue
            }
            uniqueTags.insert(normalized)
        }

        var result: [String: OfficialEndpointState<Snapshot>] = [:]
        for tag in uniqueTags.sorted() {
            if Task.isCancelled { break }
            result[tag] = await refreshState(
                for: tag,
                previous: previous[tag],
                parserVersion: parserVersion,
                now: now,
                fetch: fetch
            )
        }
        return result
    }

    /// 单 tag 分页 fetch（stage 3c：warlog / capitalraidseasons 首屏与
    /// 加载更多共用）。返回**未合并**的状态（lastGood = 本次 fetch 的页）；
    /// 累计页合并由调用方用 `PaginationMerge` 完成（刷新=替换、续页=合并）。
    /// 失败时保留 `previous` 的 last-good（含已累计的页）。
    public static func fetchSingle<Snapshot>(
        tag: String,
        previous: OfficialEndpointState<Snapshot>?,
        parserVersion: String,
        now: Date = Date(),
        fetch: @Sendable (String) async throws -> Snapshot
    ) async -> OfficialEndpointState<Snapshot>
    where Snapshot: Codable & Hashable & Sendable & UnrecognizedKeysProviding {
        await refreshState(
            for: tag,
            previous: previous,
            parserVersion: parserVersion,
            now: now,
            fetch: fetch
        )
    }

    private static func refreshState<Snapshot>(
        for tag: String,
        previous: OfficialEndpointState<Snapshot>?,
        parserVersion: String,
        now: Date,
        fetch: @Sendable (String) async throws -> Snapshot
    ) async -> OfficialEndpointState<Snapshot>
    where Snapshot: Codable & Hashable & Sendable & UnrecognizedKeysProviding {
        do {
            let snapshot = try await fetch(tag)
            return OfficialEndpointState(
                status: .success,
                clanTag: tag,
                fetchedAt: now,
                lastAttemptAt: now,
                lastErrorReason: nil,
                lastHTTPStatus: nil,
                parserVersion: parserVersion,
                lastGood: snapshot,
                unrecognizedKeys: snapshot.unrecognizedKeys
            )
        } catch let error as CoAPIError {
            return OfficialEndpointState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: error.userFacingReason,
                lastHTTPStatus: error.httpStatus,
                parserVersion: parserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        } catch is CancellationError {
            return OfficialEndpointState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: "已取消",
                lastHTTPStatus: nil,
                parserVersion: parserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        } catch let error as URLError where error.code == .cancelled {
            return OfficialEndpointState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: "已取消",
                lastHTTPStatus: nil,
                parserVersion: parserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        } catch {
            return OfficialEndpointState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: "未知错误：\(type(of: error))",
                lastHTTPStatus: nil,
                parserVersion: parserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        }
    }
}
