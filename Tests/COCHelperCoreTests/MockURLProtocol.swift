import Foundation

/// Intercepts every request of the injected `URLSession` and routes it to a
/// test-provided handler, so client tests never touch the network.
///
/// `handler` is static (URLProtocol instances are created by Foundation, not by
/// the test) and shared across threads, so every access is guarded by `lock`.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var storedLastRequest: URLRequest?

    /// Handler for the next request; set it before starting any request.
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedHandler = newValue
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        MockURLProtocol.lock.lock()
        handler = MockURLProtocol.storedHandler
        MockURLProtocol.storedLastRequest = request
        MockURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "MockURLProtocol",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "MockURLProtocol.handler is not set"]
                )
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error as NSError)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The most recently intercepted request, for assertions.
    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequest
    }
}
