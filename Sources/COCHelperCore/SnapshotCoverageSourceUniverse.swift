import Foundation

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

/// Frozen, module-issued source universe contract (Issue #236).
public struct SnapshotCoverageSourceUniverse: Codable, Hashable, Sendable {
    public let adapterID: String
    public let protocolVersion: String
    public let sections: [SnapshotCoverageSourceSectionRelevance]

    public init(
        adapterID: String,
        protocolVersion: String,
        sections: [SnapshotCoverageSourceSectionRelevance]
    ) {
        self.adapterID = adapterID
        self.protocolVersion = protocolVersion
        self.sections = sections.sorted { $0.id < $1.id }
    }

    public func relevance(for rawSection: String) -> SnapshotSectionRelevance {
        sections.first { $0.rawSection == rawSection }?.relevance ?? .unknown
    }

    package var isModuleIssued: Bool {
        SnapshotCoverageSourceUniverseIssuer.isRegistered(
            adapterID: adapterID,
            protocolVersion: protocolVersion
        )
    }

    package var hasRequiredSection: Bool {
        sections.contains { $0.relevance == .required }
    }
}

/// Module-controlled factories for trusted source universe contracts.
package enum SnapshotCoverageSourceUniverseIssuer {
    static func issueTestFixture(requiredSections: Set<String>) -> SnapshotCoverageSourceUniverse {
        issue(
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
        return issue(
            adapterID: SnapshotCoverageVerifier.perfFixtureAdapterID,
            protocolVersion: "1",
            requiredSections: requiredSections
        )
    }

    static func issue(
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
            sections: sections
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
        policy: SnapshotCoverageRevalidationPolicy
    ) -> Bool {
        guard universe.isModuleIssued else { return false }
        switch universe.adapterID {
        case SnapshotCoverageVerifier.testFixtureAdapterID:
            guard policy == .testsAllowTestFixture else { return false }
            return revalidateTestFixture(universe: universe)
        case SnapshotCoverageVerifier.perfFixtureAdapterID:
            return revalidatePerfFixture(universe: universe, snapshot: snapshot)
        default:
            return false
        }
    }

    private static func revalidateTestFixture(universe: SnapshotCoverageSourceUniverse) -> Bool {
        let required = Set(
            universe.sections.compactMap { entry in
                entry.relevance == .required ? entry.rawSection : nil
            }
        )
        let expected = SnapshotCoverageSourceUniverseIssuer.issueTestFixture(
            requiredSections: required
        )
        return expected == universe
    }

    private static func revalidatePerfFixture(
        universe: SnapshotCoverageSourceUniverse,
        snapshot: AccountSnapshot
    ) -> Bool {
        guard let expected = SnapshotCoverageSourceUniverseIssuer.issuePerfFixture(snapshot: snapshot) else {
            return false
        }
        return expected == universe
    }
}
