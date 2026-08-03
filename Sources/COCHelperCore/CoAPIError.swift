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
}
