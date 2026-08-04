import Foundation

/// 官方部落当前战争的刷新核心：按 clan tag 去重、顺序执行（按需语义）。
///
/// 设计契约（Issue #7 stage 3b）：
/// - 与 `ClanRefresher` 同构：相同 clan tag 一次请求，结果供同部落村庄共享。
/// - **按需刷新**：由用户显式触发（战争卡片按钮），不自动联动、不在启动时
///   全量拉取（issue：用户打开战争面板时才请求 currentwar）。
/// - `notInWar`（无战争，200 响应）是**成功**：refresher 只按 HTTP 层判定
///   成败，notInWar 快照存入 lastGood，UI 显示明确空状态。
/// - 失败保留 `previous` 中该 tag 的 last-good；首次失败无 last-good。
/// - 无效/缺失 clan tag 被忽略，不发起请求。
/// - 只返回本次请求过的 tag 的新状态；未被请求的 tag 是否保留由调用方决定。
public struct ClanWarRefresher: Sendable {
    public let client: CoAPIClient

    public init(client: CoAPIClient) {
        self.client = client
    }

    /// 批量刷新。`villageClanTags` 的每个元素是村庄的当前 clan tag
    /// （nil/无效值被忽略）。`previous` 是共享 last-good 来源。
    public func refreshClanWars(
        villageClanTags: [String?],
        previous: [String: ClanWarAPIState],
        now: Date = Date()
    ) async -> [String: ClanWarAPIState] {
        var tags = Set<String>()
        for rawTag in villageClanTags {
            guard let normalized = OfficialPlayerTagValidator.normalized(rawTag),
                  OfficialPlayerTagValidator.isValid(normalized) else {
                continue
            }
            tags.insert(normalized)
        }

        var result: [String: ClanWarAPIState] = [:]
        for tag in tags.sorted() {
            if Task.isCancelled { break }
            result[tag] = await refreshState(for: tag, previous: previous[tag], now: now)
        }
        return result
    }

    // MARK: - 内部

    private func refreshState(for tag: String, previous: ClanWarAPIState?, now: Date) async -> ClanWarAPIState {
        do {
            let snapshot = try await client.fetchClanWar(tag: tag)
            return ClanWarAPIState(
                status: .success,
                clanTag: tag,
                fetchedAt: now,
                lastAttemptAt: now,
                lastErrorReason: nil,
                lastHTTPStatus: nil,
                parserVersion: ClanWarAPIState.currentParserVersion,
                lastGood: snapshot,
                unrecognizedKeys: snapshot.unrecognizedKeys
            )
        } catch let error as CoAPIError {
            return ClanWarAPIState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: error.userFacingReason,
                lastHTTPStatus: error.httpStatus,
                parserVersion: ClanWarAPIState.currentParserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        } catch is CancellationError {
            return ClanWarAPIState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: "已取消",
                lastHTTPStatus: nil,
                parserVersion: ClanWarAPIState.currentParserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        } catch let error as URLError where error.code == .cancelled {
            return ClanWarAPIState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: "已取消",
                lastHTTPStatus: nil,
                parserVersion: ClanWarAPIState.currentParserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        } catch {
            return ClanWarAPIState(
                status: .failed,
                clanTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: "未知错误：\(type(of: error))",
                lastHTTPStatus: nil,
                parserVersion: ClanWarAPIState.currentParserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        }
    }
}
