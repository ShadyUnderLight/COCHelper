import Foundation

/// Decoded payload of `GET /locations`.
///
/// Codable synthesis ignores unknown fields by default, which keeps decoding
/// lenient when the API adds new keys.
public struct LocationsResponse: Codable, Sendable, Equatable {
    public let items: [Location]?

    public init(items: [Location]?) {
        self.items = items
    }
}

/// A single location entry returned by the locations endpoint.
public struct Location: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String?
    public let isCountry: Bool?

    public init(id: Int, name: String?, isCountry: Bool?) {
        self.id = id
        self.name = name
        self.isCountry = isCountry
    }
}
