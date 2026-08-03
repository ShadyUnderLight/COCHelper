import Foundation

/// Connection settings for the official Clash of Clans API.
public struct CoAPIConfig: Sendable, Equatable {
    public var scheme: String
    public var host: String
    public var apiVersion: String
    public var requestTimeout: TimeInterval
    public var maxRetryCount: Int
    public var baseRetryDelay: TimeInterval
    public var maxRetryDelay: TimeInterval

    public init(
        scheme: String = "https",
        host: String = "api.clashofclans.com",
        apiVersion: String = "v1",
        requestTimeout: TimeInterval = 20,
        maxRetryCount: Int = 2,
        baseRetryDelay: TimeInterval = 0.5,
        maxRetryDelay: TimeInterval = 8
    ) {
        self.scheme = scheme
        self.host = host
        self.apiVersion = apiVersion
        self.requestTimeout = requestTimeout
        self.maxRetryCount = maxRetryCount
        self.baseRetryDelay = baseRetryDelay
        self.maxRetryDelay = maxRetryDelay
    }
}
