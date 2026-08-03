import Foundation

/// Decoded payload of `GET /locations`.
///
/// `items` is required: the official endpoint always returns the array (it may
/// be empty). A missing or `null` `items` means the response does not match the
/// locations schema (API drift, proxy tampering) and must fail decoding rather
/// than be reported as a successful connectivity check.
/// Codable synthesis ignores unknown fields by default, which keeps decoding
/// lenient when the API adds new keys.
public struct LocationsResponse: Codable, Sendable, Equatable {
    public let items: [Location]

    public init(items: [Location]) {
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
