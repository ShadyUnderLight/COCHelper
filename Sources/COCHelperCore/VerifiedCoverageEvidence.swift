import Foundation

/// Runtime-only witness that a verified proof was issued by module-trusted code paths.
///
/// Not serialized on the wire; decoded history metadata alone cannot reopen trust gates.
enum VerifiedCoverageRuntimeWitness: Hashable, Sendable {
    case moduleIssued
}

/// Persisted trust decode outcome for verified wire metadata (Issue #224).
public enum VerifiedCoveragePersistedTrust: Equatable, Sendable {
    /// Module-issued witness present; destructive gates may open when completeness allows.
    case runtimeTrusted
    /// Wire metadata has persisted revalidation material but no runtime witness yet.
    case pendingRevalidation
    /// Persisted history lacks rule version; fail-closed.
    case insufficientPersistedEvidence
}

/// Auditable verified-coverage metadata. Construction is module-internal; callers outside
/// COCHelperCore cannot attach `moduleIssued` and therefore cannot satisfy `isVerified`.
public struct VerifiedCoverageEvidence: Hashable, Sendable {
    public let source: String
    public let adapterID: String
    public let protocolVersion: String
    public let expectedCount: Int?
    public let verificationReason: String?
    /// Frozen verification rule set used when the proof was issued.
    public let verificationRuleVersion: String?
    /// Module-issued bundled fixture identity (Issue #304 follow-up).
    ///
    /// Attached only at the controlled fixture load path (loader knows the
    /// fixture file); persisted on the wire. Reload revalidation requires a
    /// non-nil fixtureID AND a registry match — a rawJSON self-declaration of
    /// `source = perf-fixture` alone never authorizes trust. Nil for all
    /// non-fixture proofs.
    public let fixtureID: String?

    let runtimeWitness: VerifiedCoverageRuntimeWitness?

    init(
        source: String,
        adapterID: String,
        protocolVersion: String,
        expectedCount: Int?,
        verificationReason: String?,
        verificationRuleVersion: String?,
        fixtureID: String? = nil,
        runtimeWitness: VerifiedCoverageRuntimeWitness
    ) {
        self.source = source
        self.adapterID = adapterID
        self.protocolVersion = protocolVersion
        self.expectedCount = expectedCount
        self.verificationReason = verificationReason
        self.verificationRuleVersion = verificationRuleVersion
        self.fixtureID = fixtureID
        self.runtimeWitness = runtimeWitness
    }

    init(decodedWire source: String,
         adapterID: String,
         protocolVersion: String,
         expectedCount: Int?,
         verificationReason: String?,
         verificationRuleVersion: String?,
         fixtureID: String? = nil) {
        self.source = source
        self.adapterID = adapterID
        self.protocolVersion = protocolVersion
        self.expectedCount = expectedCount
        self.verificationReason = verificationReason
        self.verificationRuleVersion = verificationRuleVersion
        self.fixtureID = fixtureID
        self.runtimeWitness = nil
    }

    /// Separates wire metadata from runtime trust (Issue #224).
    public var persistedTrust: VerifiedCoveragePersistedTrust {
        if runtimeWitness == .moduleIssued {
            return .runtimeTrusted
        }
        if verificationRuleVersion == nil {
            return .insufficientPersistedEvidence
        }
        return .pendingRevalidation
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case adapterID
        case protocolVersion
        case expectedCount
        case verificationReason
        case verificationRuleVersion
        case fixtureID
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
            verificationReason: try container.decodeIfPresent(String.self, forKey: .verificationReason),
            verificationRuleVersion: try container.decodeIfPresent(String.self, forKey: .verificationRuleVersion),
            fixtureID: try container.decodeIfPresent(String.self, forKey: .fixtureID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(expectedCount, forKey: .expectedCount)
        try container.encodeIfPresent(verificationReason, forKey: .verificationReason)
        try container.encodeIfPresent(verificationRuleVersion, forKey: .verificationRuleVersion)
        try container.encodeIfPresent(fixtureID, forKey: .fixtureID)
    }
}
