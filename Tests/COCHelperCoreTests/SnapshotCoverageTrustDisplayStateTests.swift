import Foundation
import XCTest
@testable import COCHelperCore

final class SnapshotCoverageTrustDisplayStateTests: XCTestCase {
    func testEvaluateVerifiedWhenRuntimeTrustOpensGates() {
        let coverage = makeCoverage(runtimeTrust: .trusted)
        XCTAssertEqual(SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage), .verified)
    }

    func testEvaluatePendingWhenWireVerifiedButRuntimePending() {
        let coverage = makeCoverage(runtimeTrust: .pending)
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: coverage),
            .pendingRevalidation
        )
    }

    func testEvaluateInsufficientWhenVerifiedRejectedOrAbsent() {
        let rejected = makeCoverage(runtimeTrust: .rejected("revalidation failed"))
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: rejected),
            .insufficientCoverage
        )

        let unavailableOnly = SnapshotObservationCoverage(
            fields: [],
            sections: [
                SnapshotSectionCoverage(
                    base: .home,
                    rawSection: "heroes",
                    presence: .presentEmpty,
                    completeness: .unavailable,
                    proof: .unavailable(reason: "无证明"),
                    observedCount: 0
                )
            ],
            diagnostics: []
        )
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: unavailableOnly),
            .insufficientCoverage
        )
    }

    private func makeCoverage(runtimeTrust: SectionCoverageRuntimeTrust) -> SnapshotObservationCoverage {
        SnapshotObservationCoverage(
            fields: [],
            sections: [
                SnapshotSectionCoverage(
                    base: .home,
                    rawSection: "heroes",
                    presence: .presentNonEmpty,
                    completeness: .complete,
                    proof: SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
                    observedCount: 1,
                    runtimeTrust: runtimeTrust
                )
            ],
            diagnostics: []
        )
    }
}
