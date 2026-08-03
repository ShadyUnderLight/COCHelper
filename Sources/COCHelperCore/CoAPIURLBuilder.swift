import Foundation

/// Builds endpoint URLs for the official Clash of Clans API.
public enum CoAPIURLBuilder {
    /// Builds an endpoint URL from a config and a raw path.
    ///
    /// The path is split into segments which are each percent-encoded
    /// individually, so a `#` inside a segment becomes `%23` while `/` stays a
    /// segment separator. Callers pass the *raw* tag (e.g. `#ABC`, never a
    /// pre-encoded `%23ABC`): `endpoint` handles the encoding itself. The
    /// result is `scheme://host/<apiVersion>/<segments>` and its encoded path
    /// never contains a bare `#` (which would otherwise be parsed as a fragment
    /// delimiter).
    ///
    /// Limitation: `.` and `..` segments are preserved as-is (no normalization).
    /// Current callers only pass fixed internal paths or COC tags (alphabet
    /// `[A-Z0-9#]`, which cannot contain `.`), so there is no injection surface.
    /// If external path input is ever accepted, normalize `..` first.
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
    /// Internal: callers pass raw values to `endpoint`, which applies this
    /// encoding automatically. Calling this first and then passing the result
    /// to `endpoint` would double-encode `%` as `%25` and silently break the
    /// request on the wire.
    static func encodePathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }
}
