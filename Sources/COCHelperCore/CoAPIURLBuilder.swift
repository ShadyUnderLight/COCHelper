import Foundation

/// Builds endpoint URLs for the official Clash of Clans API.
public enum CoAPIURLBuilder {
    /// Builds an endpoint URL from a config and a path.
    ///
    /// The path is split into segments which are each percent-encoded
    /// individually, so a `#` inside a segment becomes `%23` while `/` stays a
    /// segment separator. The result is `scheme://host/<apiVersion>/<segments>`
    /// and its encoded path never contains a bare `#` (which would otherwise be
    /// parsed as a fragment delimiter).
    public static func endpoint(config: CoAPIConfig, path: String) -> URL {
        var components = URLComponents()
        components.scheme = config.scheme
        components.host = config.host

        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let encodedSegments = trimmedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .map(encodePathComponent)
        let versionedPath = "/" + config.apiVersion
            + (encodedSegments.isEmpty ? "" : "/" + encodedSegments.joined(separator: "/"))
        components.percentEncodedPath = versionedPath

        guard let url = components.url else {
            preconditionFailure("CoAPIURLBuilder could not build a URL for path: \(path)")
        }
        return url
    }

    /// Percent-encodes a single path segment.
    ///
    /// Pass the *raw* value (e.g. `#ABC`), never a pre-encoded one: a
    /// pre-encoded `%23ABC` would have its `%` encoded to `%25` (double
    /// encoding), which is intentional and the caller's responsibility to avoid.
    public static func encodePathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }
}
