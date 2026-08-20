import Foundation

/// Runtime-only witness that a verified proof was issued by module-trusted code paths.
///
/// Not serialized on the wire; decoded history metadata alone cannot reopen trust gates.
enum VerifiedCoverageRuntimeWitness: Hashable, Sendable {
    case moduleIssued
}

/// Auditable verified-coverage metadata. Construction is module-internal; callers outside
/// COCHelperCore cannot attach `moduleIssued` and therefore cannot satisfy `isVerified`.
public struct VerifiedCoverageEvidence: Hashable, Sendable {
    public let source: String
    public let adapterID: String
    public let protocolVersion: String
    public let expectedCount: Int?
    public let verificationReason: String?

    let runtimeWitness: VerifiedCoverageRuntimeWitness?

    init(
        source: String,
        adapterID: String,
        protocolVersion: String,
        expectedCount: Int?,
        verificationReason: String?,
        runtimeWitness: VerifiedCoverageRuntimeWitness
    ) {
        self.source = source
        self.adapterID = adapterID
        self.protocolVersion = protocolVersion
        self.expectedCount = expectedCount
        self.verificationReason = verificationReason
        self.runtimeWitness = runtimeWitness
    }

    init(decodedWire source: String,
         adapterID: String,
         protocolVersion: String,
         expectedCount: Int?,
         verificationReason: String?) {
        self.source = source
        self.adapterID = adapterID
        self.protocolVersion = protocolVersion
        self.expectedCount = expectedCount
        self.verificationReason = verificationReason
        self.runtimeWitness = nil
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case adapterID
        case protocolVersion
        case expectedCount
        case verificationReason
    }
}

extension VerifiedCoverageEvidence: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            decodedWire: try container.decode(String.self, forKey: .source),
            adapterID: try container.decode(String.self, forKey: .adapterID),
            protocolVersion: try container.decode(String.self, forKey: .protocolVersion),
            expectedCount: try container.decodeIfPresent(Int.self, forKey: .expectedCount),
            verificationReason: try container.decodeIfPresent(String.self, forKey: .verificationReason)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(expectedCount, forKey: .expectedCount)
        try container.encodeIfPresent(verificationReason, forKey: .verificationReason)
    }
}
