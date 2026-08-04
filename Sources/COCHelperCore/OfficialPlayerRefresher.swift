import Foundation

/// 官方玩家信息的刷新核心：单村庄与批量（按 tag 去重、顺序执行）刷新。
///
/// 设计契约（Issue #6）：
/// - 相同 tag 在批量刷新中只触发一次网络请求，结果复用到所有同 tag 村庄。
/// - 批量采用顺序策略（非无限并发），配合 `CoAPIClient` 内部的 429 退避。
/// - 缺 tag / tag 无效的村庄返回 `skipped`，不发起请求。
/// - 失败返回 `failed` 并保留该村庄既有 `lastGood`（last-good 语义）。
/// - 本类型不修改 `VillageProfile`，只返回新的 `OfficialAPIState` 供调用方落盘。
public struct OfficialPlayerRefresher: Sendable {
    public let client: CoAPIClient

    public init(client: CoAPIClient) {
        self.client = client
    }

    /// 单村庄刷新。`now` 可注入便于测试。
    public func refresh(village: VillageProfile, now: Date = Date()) async -> OfficialAPIState {
        guard let tag = village.officialTag else {
            // 缺 tag 也保留上次成功数据（与失败路径的 last-good 语义一致）。
            return skippedState(reason: "缺少有效的玩家 tag，已跳过")
                .mergingLastGood(from: village.officialAPIState)
        }
        return await refreshState(for: tag, previous: village.officialAPIState, now: now)
    }

    /// 批量刷新所有村庄。返回每个村庄 ID 对应的新状态；调用方负责写回与持久化。
    public func refreshAll(villages: [VillageProfile], now: Date = Date()) async -> [UUID: OfficialAPIState] {
        var byTag: [String: [UUID]] = [:]
        var result: [UUID: OfficialAPIState] = [:]

        for village in villages {
            if let tag = village.officialTag {
                byTag[tag, default: []].append(village.id)
            } else {
                // 缺 tag 也保留该村庄上次成功数据（last-good 语义）。
                result[village.id] = skippedState(reason: "缺少有效的玩家 tag，已跳过")
                    .mergingLastGood(from: village.officialAPIState)
            }
        }

        // 容忍重复村庄 ID（来自损坏的持久化数据）：保留首个值，绝不 fatal。
        var previousByID: [UUID: OfficialAPIState] = [:]
        for village in villages {
            if previousByID[village.id] == nil {
                previousByID[village.id] = village.officialAPIState
            }
        }

        // 顺序执行：每个唯一 tag 一次请求（sorted 保证确定性，便于测试与审计）。
        for tag in byTag.keys.sorted() {
            let state = await refreshState(for: tag, previous: nil, now: now)
            for id in byTag[tag] ?? [] {
                // 失败时每个村庄保留自己的 last-good；成功时统一为新快照。
                if state.status == .failed {
                    result[id] = state.mergingLastGood(from: previousByID[id])
                } else {
                    result[id] = state
                }
            }
        }
        return result
    }

    // MARK: - 内部

    private func refreshState(for tag: String, previous: OfficialAPIState?, now: Date) async -> OfficialAPIState {
        do {
            let snapshot = try await client.fetchPlayer(tag: tag)
            return OfficialAPIState(
                status: .success,
                playerTag: tag,
                fetchedAt: now,
                lastAttemptAt: now,
                lastErrorReason: nil,
                lastHTTPStatus: nil,
                parserVersion: OfficialAPIState.currentParserVersion,
                lastGood: snapshot,
                unrecognizedKeys: snapshot.unrecognizedKeys
            )
        } catch let error as CoAPIError {
            return OfficialAPIState(
                status: .failed,
                playerTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: error.userFacingReason,
                lastHTTPStatus: error.httpStatus,
                parserVersion: OfficialAPIState.currentParserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        } catch {
            return OfficialAPIState(
                status: .failed,
                playerTag: tag,
                fetchedAt: previous?.fetchedAt,
                lastAttemptAt: now,
                lastErrorReason: "未知错误：\(type(of: error))",
                lastHTTPStatus: nil,
                parserVersion: OfficialAPIState.currentParserVersion,
                lastGood: previous?.lastGood,
                unrecognizedKeys: previous?.unrecognizedKeys ?? []
            )
        }
    }

    private func skippedState(reason: String) -> OfficialAPIState {
        OfficialAPIState(
            status: .skipped,
            lastErrorReason: reason,
            parserVersion: OfficialAPIState.currentParserVersion
        )
    }
}

extension OfficialAPIState {
    /// 失败状态下用 `previous` 的 last-good / 未识别键覆盖自身（保持各村庄独立审计）。
    fileprivate func mergingLastGood(from previous: OfficialAPIState?) -> OfficialAPIState {
        guard let previous else { return self }
        var merged = self
        merged.lastGood = previous.lastGood
        merged.unrecognizedKeys = previous.unrecognizedKeys
        merged.fetchedAt = previous.fetchedAt
        return merged
    }
}

extension CoAPIError {
    /// 展示给用户的脱敏原因（不含 URL、token、原始正文）。
    public var userFacingReason: String {
        switch self {
        case .missingCredentials:
            return "未配置 API token"
        case .unauthorized:
            return "认证失败（401）"
        case .accessDenied(let reason):
            return "访问被拒绝：\(reason)"
        case .notFound:
            return "未找到该玩家或该部落（404）"
        case .rateLimited:
            return "请求被限流（429），请稍后再试"
        case .serverError(let code):
            return "服务器错误（\(code)）"
        case .timeout:
            return "请求超时"
        case .network(let underlying):
            return "网络错误（\(underlying)）"
        case .malformedResponse(let detail):
            return "响应解析失败（\(detail)）"
        }
    }

    /// 对应的 HTTP 状态码（传输层/解析错误为 nil）。
    public var httpStatus: Int? {
        switch self {
        case .unauthorized: 401
        case .accessDenied: 403
        case .notFound: 404
        case .rateLimited: 429
        case .serverError(let code): code
        case .missingCredentials, .timeout, .network, .malformedResponse: nil
        }
    }
}
