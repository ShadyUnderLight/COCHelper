import Foundation

/// Result of a quick connectivity check against the CoC API.
public enum CoAPISmokeResult: Equatable, Sendable {
    case success(locationCount: Int)
    case missingCredentials
    case authorizationFailed(reason: String)
    case rateLimited
    case notFound
    case serverError
    case networkFailure(detail: String)
}

/// Minimal HTTP client for the official Clash of Clans API.
///
/// - The token is read from `tokenProvider` on every attempt, so a refresh
///   between retries is picked up automatically.
/// - Retries happen only on HTTP 429 and retryable transport errors, with
///   exponential backoff capped by `config.maxRetryDelay`.
/// - Error payloads are sanitized: they never include request URLs, headers,
///   bodies or tokens, so they are safe to surface to users and logs.
public struct CoAPIClient: Sendable {
    public typealias TokenProvider = @Sendable () -> String?

    public let config: CoAPIConfig
    private let session: URLSession
    private let tokenProvider: TokenProvider

    public init(
        config: CoAPIConfig = CoAPIConfig(),
        session: URLSession? = nil,
        tokenProvider: @escaping TokenProvider
    ) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let urlConfiguration = URLSessionConfiguration.ephemeral
            urlConfiguration.timeoutIntervalForRequest = config.requestTimeout
            self.session = URLSession(configuration: urlConfiguration)
        }
        self.tokenProvider = tokenProvider
    }

    public func request(path: String) async throws -> Data {
        let url = CoAPIURLBuilder.endpoint(config: config, path: path)
        // Guard against a misconfigured negative retry count: a `0...(-1)`
        // closed range would trap at runtime.
        let maxRetries = max(0, config.maxRetryCount)

        for attempt in 0...maxRetries {
            guard let token = tokenProvider() else {
                throw CoAPIError.missingCredentials
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.timeoutInterval = config.requestTimeout
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await session.data(for: urlRequest)
                let code = statusCode(of: response)
                switch code {
                case 200..<300:
                    return data
                case 401:
                    throw CoAPIError.unauthorized
                case 403:
                    throw CoAPIError.accessDenied(reason: forbiddenReason(from: data))
                case 404:
                    throw CoAPIError.notFound
                case 429:
                    let retryAfter = retryAfterSeconds(from: response, body: data)
                    if attempt < maxRetries {
                        try await sleepForRetry(attempt: attempt, retryAfterSeconds: retryAfter)
                        continue
                    }
                    throw CoAPIError.rateLimited(retryAfterSeconds: retryAfter)
                case 500..<600:
                    throw CoAPIError.serverError(statusCode: code)
                default:
                    throw CoAPIError.network(underlying: "unexpected status \(code)")
                }
            } catch let error as CancellationError {
                // Task cancellation must propagate as-is (e.g. from Task.sleep
                // or a cancelled URLSession data task), never be misreported
                // as a network failure.
                throw error
            } catch let error as CoAPIError {
                throw error
            } catch let error as URLError {
                if error.code == .cancelled {
                    // URLSession surfaces task cancellation as URLError(.cancelled);
                    // pass it through unchanged so callers can distinguish
                    // cancellation from network failure.
                    throw error
                }
                if isRetryable(error), attempt < maxRetries {
                    try await sleepForRetry(attempt: attempt)
                    continue
                }
                // Sanitized: `localizedDescription` may embed request URLs/paths
                // (e.g. via FailingURLString userInfo); only the numeric code is
                // kept so diagnostics stay stable and never leak the target path.
                throw error.code == .timedOut
                    ? CoAPIError.timeout
                    : CoAPIError.network(underlying: "transport error (URLError code \(error.code.rawValue))")
            } catch {
                throw CoAPIError.network(underlying: "unknown transport error: \(type(of: error))")
            }
        }

        // Unreachable: every loop iteration returns or throws.
        throw CoAPIError.network(underlying: "unreachable")
    }

    public func fetchLocations() async throws -> LocationsResponse {
        let data = try await request(path: "/locations")
        do {
            return try JSONDecoder().decode(LocationsResponse.self, from: data)
        } catch {
            throw CoAPIError.malformedResponse(detail: "locations decode failed")
        }
    }

    public func smoke() async -> CoAPISmokeResult {
        do {
            let locations = try await fetchLocations()
            return .success(locationCount: locations.items.count)
        } catch let error as CoAPIError {
            switch error {
            case .missingCredentials:
                return .missingCredentials
            case .unauthorized:
                return .authorizationFailed(reason: "unauthorized")
            case .accessDenied(let reason):
                return .authorizationFailed(reason: reason)
            case .rateLimited:
                return .rateLimited
            case .notFound:
                return .notFound
            case .serverError:
                return .serverError
            case .timeout:
                return .networkFailure(detail: "timeout")
            case .network:
                return .networkFailure(detail: "network")
            case .malformedResponse:
                return .networkFailure(detail: "malformed response")
            }
        } catch {
            return .networkFailure(detail: "network")
        }
    }

    // MARK: - Helpers

    private func statusCode(of response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    private func sleepForRetry(attempt: Int, retryAfterSeconds: Int? = nil) async throws {
        let exponential = config.baseRetryDelay * pow(2.0, Double(attempt))
        let serverHint = retryAfterSeconds.map { Double(max(0, $0)) } ?? 0
        let cap = max(0, config.maxRetryDelay)
        // 429 时若服务器给出 Retry-After，尊重它（可超过本地 maxRetryDelay，
        // 避免以过短间隔连打烧光重试次数）；其他情况用本地指数退避。
        // 任何路径都不超过 1 小时绝对上限，且负数配置不会触发 UInt64 转换 trap。
        let delay = serverHint > 0
            ? min(max(exponential, serverHint), max(cap, serverHint))
            : min(max(0, exponential), cap)
        // NaN 配置（如 Double.nan 的 baseRetryDelay）一律退化为立即重试，
        // 避免 UInt64 转换 trap 或无限 sleep；任何路径不超过 1 小时。
        let seconds = delay.isFinite ? min(delay, 3600) : 0
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func forbiddenReason(from data: Data) -> String {
        // 服务器回显内容：截断到固定长度，避免超长 reason 进入日志/UI。
        let maxReasonLength = 200
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["reason"] as? String, !reason.isEmpty else {
            return "forbidden"
        }
        return String(reason.prefix(maxReasonLength))
    }

    private func retryAfterSeconds(from response: URLResponse, body: Data) -> Int? {
        if let headerValue = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Int(headerValue.trimmingCharacters(in: .whitespaces)) {
            return seconds
        }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let seconds = object["retryAfter"] as? Int {
            return seconds
        }
        return nil
    }
}
