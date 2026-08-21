import COCHelperCore
import XCTest

/// Issue #234: public API boundary — external modules cannot mint runtime trust.
final class SnapshotSectionCoveragePublicBoundaryTests: XCTestCase {
    func testDecodedVerifiedWireNeverOpensTrustGatesViaPublicConstructor() throws {
        let proofJSON = """
        {
          "kind": "verified",
          "source": "test-export",
          "adapterID": "test-fixture",
          "protocolVersion": "1",
          "expectedCount": 1,
          "verificationReason": "external forge attempt",
          "verificationRuleVersion": "1",
          "inputBinding": "sha256:deadbeef"
        }
        """
        let decodedProof = try JSONDecoder().decode(
            SnapshotCoverageProof.self,
            from: Data(proofJSON.utf8)
        )
        XCTAssertTrue(decodedProof.hasVerifiedWireMetadata)
        XCTAssertFalse(decodedProof.isVerified)

        let publicSection = SnapshotSectionCoverage(
            base: .home,
            rawSection: "heroes",
            presence: .presentNonEmpty,
            completeness: .complete,
            proof: decodedProof,
            observedCount: 1
        )
        XCTAssertFalse(publicSection.opensTrustGates)
        XCTAssertFalse(publicSection.isComplete)
    }

    func testDecodeRoundTripAndPublicReconstructNeverOpenTrustGates() throws {
        let proofJSON = """
        {
          "kind": "verified",
          "source": "test-export",
          "adapterID": "test-fixture",
          "protocolVersion": "1",
          "expectedCount": 1,
          "verificationReason": "external forge attempt",
          "verificationRuleVersion": "1",
          "inputBinding": "sha256:deadbeef"
        }
        """
        let decodedProof = try JSONDecoder().decode(
            SnapshotCoverageProof.self,
            from: Data(proofJSON.utf8)
        )
        let encodedSection = SnapshotSectionCoverage(
            base: .home,
            rawSection: "heroes",
            presence: .presentNonEmpty,
            completeness: .complete,
            proof: decodedProof,
            observedCount: 1
        )
        let roundTrip = try JSONDecoder().decode(
            SnapshotSectionCoverage.self,
            from: try JSONEncoder().encode(encodedSection)
        )
        XCTAssertFalse(roundTrip.opensTrustGates)

        let reconstructed = SnapshotSectionCoverage(
            base: roundTrip.base,
            rawSection: roundTrip.rawSection,
            presence: roundTrip.presence,
            completeness: roundTrip.completeness,
            proof: roundTrip.proof,
            observedCount: roundTrip.observedCount
        )
        XCTAssertFalse(reconstructed.opensTrustGates)
        XCTAssertFalse(reconstructed.isComplete)
    }
}
