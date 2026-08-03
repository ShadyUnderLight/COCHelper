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

        for attempt in 0...config.maxRetryCount {
            guard let token = tokenProvider() else {
                throw CoAPIError.missingCredentials
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.timeoutInterval = config.requestTimeout
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await session.data(for: urlRequest)
                switch statusCode(of: response) {
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
                    if attempt < config.maxRetryCount {
                        try await sleepForRetry(attempt: attempt)
                        continue
                    }
                    throw CoAPIError.rateLimited(retryAfterSeconds: retryAfter)
                case 500..<600:
                    throw CoAPIError.serverError(statusCode: statusCode(of: response))
                default:
                    throw CoAPIError.network(underlying: "unexpected status \(statusCode(of: response))")
                }
            } catch let error as CoAPIError {
                throw error
            } catch let error as URLError {
                if isRetryable(error), attempt < config.maxRetryCount {
                    try await sleepForRetry(attempt: attempt)
                    continue
                }
                throw error.code == .timedOut
                    ? CoAPIError.timeout
                    : CoAPIError.network(underlying: error.localizedDescription)
            } catch {
                throw CoAPIError.network(underlying: error.localizedDescription)
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
            return .success(locationCount: locations.items?.count ?? 0)
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

    private func sleepForRetry(attempt: Int) async throws {
        let exponential = config.baseRetryDelay * pow(2.0, Double(attempt))
        let delay = min(exponential, config.maxRetryDelay)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func forbiddenReason(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["reason"] as? String, !reason.isEmpty else {
            return "forbidden"
        }
        return reason
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
