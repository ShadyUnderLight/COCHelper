import Foundation

/// Errors surfaced by `CoAPIClient`, already mapped from HTTP status codes and
/// transport failures.
///
/// Associated values are sanitized: they never contain request URLs, headers,
/// raw bodies or tokens, so they are safe to log.
public enum CoAPIError: Error, Equatable, Sendable {
    case missingCredentials
    case unauthorized
    case accessDenied(reason: String)
    case notFound
    case rateLimited(retryAfterSeconds: Int?)
    case serverError(statusCode: Int)
    case timeout
    case network(underlying: String)
    case malformedResponse(detail: String)

    /// 结构化错误类别（Issue #252）：覆盖本类型全部 case **外加取消**
    /// （`EndpointRefresher` 单独捕获 `CancellationError` / `URLError(.cancelled)`，
    /// 不经由 `CoAPIError` 传递，故此处不包含 `.cancelled`）。
    ///
    /// 不含 associated value，可作为 `OfficialEndpointState.failureKind`
    /// 安全持久化——不泄露 `reason` / `detail` / `underlying` / `statusCode`
    /// 等脱敏细节，也不依赖中文文案稳定性。展示层仍由
    /// `lastErrorReason`（脱敏文本）承担，本属性只用于**分类判定**。
    public var kind: OfficialEndpointFailureKind {
        switch self {
        case .missingCredentials: return .missingCredentials
        case .unauthorized: return .unauthorized
        case .accessDenied: return .accessDenied
        case .notFound: return .notFound
        case .rateLimited: return .rateLimited
        case .serverError: return .serverError
        case .timeout: return .timeout
        case .network: return .network
        case .malformedResponse: return .malformedResponse
        }
    }
}
