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
            diagnostics: []
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
            diagnostics: []
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
            diagnostics: []
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
        SnapshotObservationCoverage(
            fields: [],
            sections: [
                makeSection(
                    rawSection: "heroes",
                    proof: SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
                    completeness: .complete,
                    runtimeTrust: heroesTrust
                ),
                makeSection(
                    rawSection: "buildings",
                    proof: SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 2),
                    completeness: .complete,
                    runtimeTrust: buildingsTrust
                )
            ],
            diagnostics: []
        )
    }

    private func makeSection(
        rawSection: String,
        proof: SnapshotCoverageProof,
        completeness: SnapshotCoverageState,
        presence: SnapshotSectionPresence = .presentNonEmpty,
        runtimeTrust: SectionCoverageRuntimeTrust
    ) -> SnapshotSectionCoverage {
        SnapshotSectionCoverage(
            base: .home,
            rawSection: rawSection,
            presence: presence,
            completeness: completeness,
            proof: proof,
            observedCount: 1,
            runtimeTrust: runtimeTrust
        )
    }
}
