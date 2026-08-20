import Foundation

/// Issue #205: module-internal factories for trusted coverage proofs.
///
/// Trust comes from code-path provenance, not wire metadata or caller-supplied
/// adapter IDs. Only proofs returned by the factories below carry a runtime witness
/// and may evaluate to `isVerified == true`.
package enum SnapshotCoverageVerifier {
    static let testFixtureAdapterID = "test-fixture"
    static let perfFixtureAdapterID = "perf-fixture"

    private static let registeredProtocols: [String: Set<String>] = [
        testFixtureAdapterID: ["1"],
        perfFixtureAdapterID: ["1"],
    ]

    static func issueTestFixture(
        source: String = "test-export",
        protocolVersion: String = "1",
        expectedCount: Int? = nil,
        verificationReason: String = "test injection"
    ) -> SnapshotCoverageProof {
        issueVerified(
            source: source,
            adapterID: testFixtureAdapterID,
            protocolVersion: protocolVersion,
            expectedCount: expectedCount,
            verificationReason: verificationReason
        )
    }

    static func issuePerfFixture(
        source: String,
        protocolVersion: String,
        expectedCount: Int?,
        verificationReason: String
    ) -> SnapshotCoverageProof {
        issueVerified(
            source: source,
            adapterID: perfFixtureAdapterID,
            protocolVersion: protocolVersion,
            expectedCount: expectedCount,
            verificationReason: verificationReason
        )
    }

    package static func promoteBundledPerfFixtureDeclaredProofs(
        _ proofs: [String: SnapshotCoverageProof]
    ) -> [String: SnapshotCoverageProof] {
        proofs.mapValues { proof in
            switch proof {
            case .declared(let source, let version, let expectedCount)
                where source == perfFixtureAdapterID:
                return issuePerfFixture(
                    source: source,
                    protocolVersion: version,
                    expectedCount: expectedCount,
                    verificationReason: "bundled perf fixture"
                )
            default:
                return proof
            }
        }
    }

    static func validatesVerifiedProof(_ proof: SnapshotCoverageProof) -> Bool {
        guard case .verified(let evidence) = proof,
              evidence.runtimeWitness == .moduleIssued,
              let verificationReason = evidence.verificationReason else {
            return false
        }
        guard isNonBlank(evidence.source),
              isNonBlank(verificationReason),
              isParsableProtocolVersion(evidence.protocolVersion),
              isRegistered(adapterID: evidence.adapterID, protocolVersion: evidence.protocolVersion) else {
            return false
        }
        return evidence.expectedCount == nil || evidence.expectedCount! >= 0
    }

    private static func issueVerified(
        source: String,
        adapterID: String,
        protocolVersion: String,
        expectedCount: Int?,
        verificationReason: String
    ) -> SnapshotCoverageProof {
        guard isRegistered(adapterID: adapterID, protocolVersion: protocolVersion) else {
            return .unavailable(
                reason: "coverage adapter 未注册或不支持协议版本：\(adapterID)@\(protocolVersion)。"
            )
        }
        guard isNonBlank(source),
              isParsableProtocolVersion(protocolVersion),
              expectedCount == nil || expectedCount! >= 0,
              isNonBlank(verificationReason) else {
            return .unavailable(reason: "verified coverage 证据格式无效。")
        }
        return .verified(
            VerifiedCoverageEvidence(
                source: source,
                adapterID: adapterID,
                protocolVersion: protocolVersion,
                expectedCount: expectedCount,
                verificationReason: verificationReason,
                runtimeWitness: .moduleIssued
            )
        )
    }

    private static func isRegistered(adapterID: String, protocolVersion: String) -> Bool {
        guard let versions = registeredProtocols[adapterID] else { return false }
        return versions.contains(protocolVersion)
    }

    private static func isNonBlank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isParsableProtocolVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return false }
        return components.allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber)
        }
    }
}
