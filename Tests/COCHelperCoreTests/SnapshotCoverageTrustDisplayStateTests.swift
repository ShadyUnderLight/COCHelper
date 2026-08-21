import Foundation
import XCTest
@testable import COCHelperCore

final class SnapshotCoverageTrustDisplayStateTests: XCTestCase {
    func testEvaluateVerifiedWhenAllSectionsTrustedAndComplete() {
        let coverage = makeCoverage(
            heroesTrust: .trusted,
            buildingsTrust: .trusted
        )
        XCTAssertEqual(SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage), .verified)
    }

    func testEvaluatePendingWhenAnySectionPendingAndNoneBlockVerified() {
        let coverage = makeCoverage(
            heroesTrust: .trusted,
            buildingsTrust: .pending
        )
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .pendingRevalidation
        )
    }

    func testEvaluateInsufficientWhenTrustedMixedWithRejected() {
        let coverage = makeCoverage(
            heroesTrust: .trusted,
            buildingsTrust: .rejected("binding mismatch")
        )
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .insufficientCoverage
        )
    }

    func testEvaluateInsufficientWhenTrustedMixedWithUnavailableSection() {
        let coverage = SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
                    completeness: .complete,
                    runtimeTrust: .trusted
                ),
                makeSection(
                    rawSection: "buildings",
                    proof: .unavailable(reason: "来源未提供 section 完整性证明。"),
                    completeness: .unavailable,
                    presence: .presentEmpty,
                    runtimeTrust: .notApplicable
                )
            ],
            diagnostics: [],
            sourceUniverse: SnapshotHistoryTestCoverage.testFixtureUniverse(
                requiredSections: ["heroes", "buildings"]
            )
        )
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .insufficientCoverage
        )
    }

    func testEvaluateVerifiedWhenIrrelevantSectionAbsent() {
        let coverage = SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
                    completeness: .complete,
                    runtimeTrust: .trusted
                ),
                makeSection(
                    rawSection: "buildings",
                    proof: .unavailable(reason: "源 JSON 缺少 section。"),
                    completeness: .unavailable,
                    presence: .missing,
                    runtimeTrust: .notApplicable
                )
            ],
            diagnostics: [],
            sourceUniverse: SnapshotHistoryTestCoverage.testFixtureUniverse(requiredSections: ["heroes"])
        )
        XCTAssertEqual(SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage), .verified)
    }

    func testEvaluateInsufficientWhenUniverseMissing() {
        let proofs: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
            "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 2)
        ]
        let coverage = SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: proofs["heroes"]!,
                    completeness: .complete,
                    runtimeTrust: .trusted
                ),
                makeSection(
                    rawSection: "buildings",
                    proof: proofs["buildings"]!,
                    completeness: .complete,
                    runtimeTrust: .trusted
                )
            ],
            diagnostics: [],
            sourceUniverse: nil
        )
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .insufficientCoverage
        )
    }

    func testEvaluateInsufficientWhenNoVerifiedSections() {
        let unavailableOnly = SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: .unavailable(reason: "无证明"),
                    completeness: .unavailable,
                    runtimeTrust: .notApplicable
                )
            ],
            diagnostics: []
        )
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: unavailableOnly),
            .insufficientCoverage
        )
    }

    func testEvaluateVerifiedWhenUnprovedMissingSectionsAreOutsideRelevantUniverse() {
        let coverage = SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
                    completeness: .complete,
                    runtimeTrust: .trusted
                ),
                makeSection(
                    rawSection: "heroes2",
                    proof: .unavailable(reason: "源中不存在该 section。"),
                    completeness: .unavailable,
                    presence: .missing,
                    runtimeTrust: .notApplicable
                )
            ],
            diagnostics: [],
            sourceUniverse: SnapshotHistoryTestCoverage.testFixtureUniverse(requiredSections: ["heroes"])
        )

        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .verified
        )
    }

    func testEvaluateInsufficientWhenRelevantMissingSectionHasVerifiedProof() {
        let coverage = SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
                    completeness: .complete,
                    runtimeTrust: .trusted
                ),
                makeSection(
                    rawSection: "heroes2",
                    proof: SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
                    completeness: .unavailable,
                    presence: .missing,
                    runtimeTrust: .trusted
                )
            ],
            diagnostics: [],
            sourceUniverse: SnapshotHistoryTestCoverage.testFixtureUniverse(
                requiredSections: ["heroes", "heroes2"]
            )
        )

        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .insufficientCoverage
        )
    }

    func testEvaluateInsufficientWhenMalformedExplicitProofIsMissing() {
        let malformedVerified = SnapshotCoverageProof.verified(
            VerifiedCoverageEvidence(
                decodedWire: "",
                adapterID: "",
                protocolVersion: "invalid",
                expectedCount: nil,
                verificationReason: nil,
                verificationRuleVersion: nil,
                inputBinding: nil
            )
        )
        let coverage = SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
                    completeness: .complete,
                    runtimeTrust: .trusted
                ),
                makeSection(
                    rawSection: "heroes2",
                    proof: .declared(source: "", version: "invalid", expectedCount: nil),
                    completeness: .unavailable,
                    presence: .missing,
                    observedCount: 0,
                    runtimeTrust: .notApplicable
                ),
                makeSection(
                    rawSection: "units2",
                    proof: malformedVerified,
                    completeness: .unavailable,
                    presence: .missing,
                    observedCount: 0,
                    runtimeTrust: .notApplicable
                )
            ],
            diagnostics: [],
            sourceUniverse: SnapshotHistoryTestCoverage.testFixtureUniverse(
                requiredSections: ["heroes", "heroes2", "units2"]
            )
        )

        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .insufficientCoverage
        )
    }

    func testEvaluatePendingWhenUniverseWireMetadataPendingAndSectionsTrusted() {
        let proofs: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let coverage = SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: proofs["heroes"]!,
                    completeness: .complete,
                    runtimeTrust: .trusted
                )
            ],
            diagnostics: [],
            sourceUniverse: SnapshotCoverageSourceUniverse(
                adapterID: SnapshotCoverageVerifier.testFixtureAdapterID,
                protocolVersion: "1",
                sections: SnapshotHistoryTestCoverage.testFixtureUniverse(for: proofs).sections
            ),
            sourceUniverseRuntimeTrust: .pending
        )
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .pendingRevalidation
        )
    }

    func testEvaluateInsufficientWhenUniverseRejectedEvenIfSectionsTrusted() {
        let proofs: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let coverage = SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: proofs["heroes"]!,
                    completeness: .complete,
                    runtimeTrust: .trusted
                )
            ],
            diagnostics: [],
            sourceUniverse: SnapshotHistoryTestCoverage.testFixtureUniverse(for: proofs),
            sourceUniverseRuntimeTrust: .rejected("tampered")
        )
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .insufficientCoverage
        )
    }

    func testEvaluateInsufficientWhenSectionsEmpty() {
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(
                coverage: SnapshotObservationCoverage(fields: [], sections: [], diagnostics: [])
            ),
            .insufficientCoverage
        )
    }

    private func makeCoverage(
        heroesTrust: SectionCoverageRuntimeTrust,
        buildingsTrust: SectionCoverageRuntimeTrust
    ) -> SnapshotObservationCoverage {
        let proofs: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
            "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 2)
        ]
        return SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: proofs["heroes"]!,
                    completeness: .complete,
                    runtimeTrust: heroesTrust
                ),
                makeSection(
                    rawSection: "buildings",
                    proof: proofs["buildings"]!,
                    completeness: .complete,
                    runtimeTrust: buildingsTrust
                )
            ],
            diagnostics: [],
            sourceUniverse: SnapshotHistoryTestCoverage.testFixtureUniverse(for: proofs)
        )
    }

    private func makeSection(
        rawSection: String,
        proof: SnapshotCoverageProof,
        completeness: SnapshotCoverageState,
        presence: SnapshotSectionPresence = .presentNonEmpty,
        observedCount: Int = 1,
        runtimeTrust: SectionCoverageRuntimeTrust
    ) -> SnapshotSectionCoverage {
        SnapshotSectionCoverage(
            base: .home,
            rawSection: rawSection,
            presence: presence,
            completeness: completeness,
            proof: proof,
            observedCount: observedCount,
            runtimeTrust: runtimeTrust
        )
    }
}
