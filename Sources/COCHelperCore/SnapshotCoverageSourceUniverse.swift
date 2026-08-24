import Foundation

/// Runtime-only witness that a source universe was issued by module-trusted code paths.
enum SourceUniverseRuntimeWitness: Hashable, Sendable {
    case moduleIssued
}

/// Whether a section belongs to a trusted source's coverage universe (Issue #236).
public enum SnapshotSectionRelevance: String, Codable, Hashable, Sendable {
    /// Source contract requires this section.
    case required
    /// Trusted source contract explicitly excludes this section.
    case notApplicable
    /// Relevance cannot be established; must not be ignored.
    case unknown
}

public struct SnapshotCoverageSourceSectionRelevance: Codable, Hashable, Sendable, Identifiable {
    public let base: SnapshotHistoryBase
    public let rawSection: String
    public let relevance: SnapshotSectionRelevance

    public init(
        base: SnapshotHistoryBase,
        rawSection: String,
        relevance: SnapshotSectionRelevance
    ) {
        self.base = base
        self.rawSection = rawSection
        self.relevance = relevance
    }

    public var id: String {
        [base.rawValue, rawSection].map { String($0.utf8.count) + ":" + $0 }.joined(separator: "|")
    }
}

/// Frozen source universe contract (Issue #236).
public struct SnapshotCoverageSourceUniverse: Hashable, Sendable {
    public let adapterID: String
    public let protocolVersion: String
    public let sections: [SnapshotCoverageSourceSectionRelevance]
    let runtimeWitness: SourceUniverseRuntimeWitness?

    public init(
        adapterID: String,
        protocolVersion: String,
        sections: [SnapshotCoverageSourceSectionRelevance]
    ) {
        self.adapterID = adapterID
        self.protocolVersion = protocolVersion
        self.sections = sections.sorted { $0.id < $1.id }
        self.runtimeWitness = nil
    }

    init(
        adapterID: String,
        protocolVersion: String,
        sections: [SnapshotCoverageSourceSectionRelevance],
        runtimeWitness: SourceUniverseRuntimeWitness
    ) {
        self.adapterID = adapterID
        self.protocolVersion = protocolVersion
        self.sections = sections.sorted { $0.id < $1.id }
        self.runtimeWitness = runtimeWitness
    }

    public func relevance(for rawSection: String) -> SnapshotSectionRelevance {
        sections.first { $0.rawSection == rawSection }?.relevance ?? .unknown
    }

    package var hasRequiredSection: Bool {
        sections.contains { $0.relevance == .required }
    }

    package var isWellFormedWireContract: Bool {
        SnapshotCoverageSourceUniverseIssuer.isRegistered(
            adapterID: adapterID,
            protocolVersion: protocolVersion
        )
    }

    public static func == (lhs: SnapshotCoverageSourceUniverse, rhs: SnapshotCoverageSourceUniverse) -> Bool {
        lhs.adapterID == rhs.adapterID
            && lhs.protocolVersion == rhs.protocolVersion
            && lhs.sections == rhs.sections
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(adapterID)
        hasher.combine(protocolVersion)
        hasher.combine(sections)
    }

    private enum CodingKeys: String, CodingKey {
        case adapterID
        case protocolVersion
        case sections
    }
}

extension SnapshotCoverageSourceUniverse: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            adapterID: try container.decode(String.self, forKey: .adapterID),
            protocolVersion: try container.decode(String.self, forKey: .protocolVersion),
            sections: try container.decode(
                [SnapshotCoverageSourceSectionRelevance].self,
                forKey: .sections
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(sections, forKey: .sections)
    }
}

/// Module-controlled factories for trusted source universe contracts.
package enum SnapshotCoverageSourceUniverseIssuer {
    static func issueTestFixture(requiredSections: Set<String>) -> SnapshotCoverageSourceUniverse {
        issueModuleIssued(
            adapterID: SnapshotCoverageVerifier.testFixtureAdapterID,
            protocolVersion: "1",
            requiredSections: requiredSections
        )
    }

    package static func issuePerfFixture(snapshot: AccountSnapshot) -> SnapshotCoverageSourceUniverse? {
        guard BundledPerfFixtureRegistry.recognizesAccountSnapshot(rawJSON: snapshot.originalText) else {
            return nil
        }
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot)
        let requiredSections = Set(
            proofs.compactMap { section, proof -> String? in
                switch proof {
                case .declared(let source, let version, _)
                    where source == SnapshotCoverageVerifier.perfFixtureAdapterID && version == "1":
                    return section
                default:
                    return nil
                }
            }
        )
        guard !requiredSections.isEmpty else { return nil }
        return issueModuleIssued(
            adapterID: SnapshotCoverageVerifier.perfFixtureAdapterID,
            protocolVersion: "1",
            requiredSections: requiredSections
        )
    }

    private static func issueModuleIssued(
        adapterID: String,
        protocolVersion: String,
        requiredSections: Set<String>
    ) -> SnapshotCoverageSourceUniverse {
        let sections = SnapshotHistoryKnownSections.all.sorted().map { section in
            let relevance: SnapshotSectionRelevance = requiredSections.contains(section)
                ? .required
                : .notApplicable
            return SnapshotCoverageSourceSectionRelevance(
                base: SnapshotHistoryBase(section: section),
                rawSection: section,
                relevance: relevance
            )
        }
        return SnapshotCoverageSourceUniverse(
            adapterID: adapterID,
            protocolVersion: protocolVersion,
            sections: sections,
            runtimeWitness: .moduleIssued
        )
    }

    static func isRegistered(adapterID: String, protocolVersion: String) -> Bool {
        switch adapterID {
        case SnapshotCoverageVerifier.testFixtureAdapterID,
             SnapshotCoverageVerifier.perfFixtureAdapterID:
            return protocolVersion == "1"
        default:
            return false
        }
    }
}

/// Restart-time revalidation for frozen source universe contracts.
enum SnapshotCoverageSourceUniverseRevalidators {
    static func revalidate(
        universe: SnapshotCoverageSourceUniverse,
        snapshot: AccountSnapshot,
        coverage: SnapshotObservationCoverage,
        policy: SnapshotCoverageRevalidationPolicy
    ) -> SourceUniverseRuntimeTrust {
        guard universe.isWellFormedWireContract else {
            return .rejected("source universe wire contract 无效。")
        }
        switch universe.adapterID {
        case SnapshotCoverageVerifier.testFixtureAdapterID:
            guard policy == .testsAllowTestFixture else {
                return .rejected("production load 不得恢复 test-fixture source universe。")
            }
            return revalidateTestFixture(universe: universe, coverage: coverage)
        case SnapshotCoverageVerifier.perfFixtureAdapterID:
            return revalidatePerfFixture(universe: universe, snapshot: snapshot)
        default:
            return .rejected("未注册的 source universe adapter。")
        }
    }

    private static func revalidateTestFixture(
        universe: SnapshotCoverageSourceUniverse,
        coverage: SnapshotObservationCoverage
    ) -> SourceUniverseRuntimeTrust {
        let authorizedRequired = Set(
            coverage.sections.compactMap { section in
                section.proof.hasVerifiedWireMetadata ? section.rawSection : nil
            }
        )
        let expected = SnapshotCoverageSourceUniverseIssuer.issueTestFixture(
            requiredSections: authorizedRequired
        )
        guard expected == universe else {
            return .rejected("test-fixture source universe 与 verified section proofs 不一致。")
        }
        return .trusted
    }

    private static func revalidatePerfFixture(
        universe: SnapshotCoverageSourceUniverse,
        snapshot: AccountSnapshot
    ) -> SourceUniverseRuntimeTrust {
        guard let expected = SnapshotCoverageSourceUniverseIssuer.issuePerfFixture(snapshot: snapshot) else {
            return .rejected("rawJSON 不是受信任的 bundled perf fixture。")
        }
        guard expected == universe else {
            return .rejected("perf fixture source universe 与 adapter 契约不一致。")
        }
        return .trusted
    }
}
