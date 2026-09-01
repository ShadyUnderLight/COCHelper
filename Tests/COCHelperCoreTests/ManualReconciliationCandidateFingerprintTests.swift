import XCTest
@testable import COCHelperCore

final class ManualReconciliationCandidateFingerprintTests: XCTestCase {
    private let key = TrackerItemKey.root(base: .home, rawSection: "buildings", dataID: 100)

    func testNonDuplicateFingerprintIgnoresEphemeralRevisionAndLineageID() {
        let item = ManualReconciliationItem(
            itemKey: key,
            displayName: key.stableID,
            classification: .newObservation,
            message: "新观察",
            observedDistributionComplete: true,
            observedSectionTrustGatesOpen: true
        )
        let referenceA = ManualBaselineReference(
            revision: "00000000-0000-0000-0000-000000000201",
            fingerprint: "sha256:stable-fp",
            lineageID: "00000000-0000-0000-0000-000000000301"
        )
        let referenceB = ManualBaselineReference(
            revision: "00000000-0000-0000-0000-000000000202",
            fingerprint: "sha256:stable-fp",
            lineageID: "00000000-0000-0000-0000-000000000302"
        )
        let fingerprintA = ManualReconciliationCandidateFingerprint.compute(
            duplicate: false,
            lineageComparable: true,
            timeConfidence: .reliableSourceTimestamp,
            newReference: referenceA,
            newNormalizedPlayerTag: "#P1",
            sourceTimestampMs: 1_700_000_200_000,
            items: [item]
        )
        let fingerprintB = ManualReconciliationCandidateFingerprint.compute(
            duplicate: false,
            lineageComparable: true,
            timeConfidence: .reliableSourceTimestamp,
            newReference: referenceB,
            newNormalizedPlayerTag: "#P1",
            sourceTimestampMs: 1_700_000_200_000,
            items: [item]
        )
        XCTAssertEqual(fingerprintA, fingerprintB)
    }

    func testDuplicateFingerprintIncludesRevision() {
        let item = ManualReconciliationItem(
            itemKey: key,
            displayName: key.stableID,
            classification: .duplicate,
            message: "重复",
            observedDistributionComplete: true,
            observedSectionTrustGatesOpen: true
        )
        let fingerprintA = ManualReconciliationCandidateFingerprint.compute(
            duplicate: true,
            lineageComparable: true,
            timeConfidence: .reliableSourceTimestamp,
            newReference: ManualBaselineReference(
                revision: "00000000-0000-0000-0000-000000000401:observation:1",
                fingerprint: "sha256:dup-fp",
                lineageID: "lineage-dup"
            ),
            newNormalizedPlayerTag: "#P1",
            sourceTimestampMs: 1_700_000_200_000,
            items: [item]
        )
        let fingerprintB = ManualReconciliationCandidateFingerprint.compute(
            duplicate: true,
            lineageComparable: true,
            timeConfidence: .reliableSourceTimestamp,
            newReference: ManualBaselineReference(
                revision: "00000000-0000-0000-0000-000000000401:observation:2",
                fingerprint: "sha256:dup-fp",
                lineageID: "lineage-dup"
            ),
            newNormalizedPlayerTag: "#P1",
            sourceTimestampMs: 1_700_000_200_000,
            items: [item]
        )
        XCTAssertNotEqual(fingerprintA, fingerprintB)
    }

    func testEncodingMaterialJsonEscapesControlCharactersInNormalizedPlayerTag() throws {
        let json = try XCTUnwrap(
            ManualReconciliationCandidateFingerprint.encodingMaterialJson(
                duplicate: false,
                lineageComparable: true,
                timeConfidence: .reliableSourceTimestamp,
                newReference: ManualBaselineReference(
                    revision: "ignored-revision",
                    fingerprint: "sha256:fp",
                    lineageID: "ignored-lineage"
                ),
                newNormalizedPlayerTag: "tag\u{01}name",
                sourceTimestampMs: 1_700_000_200_000,
                items: [
                    ManualReconciliationItem(
                        itemKey: key,
                        displayName: key.stableID,
                        classification: .newObservation,
                        message: "新观察",
                        observedDistributionComplete: true,
                        observedSectionTrustGatesOpen: true
                    ),
                ]
            )
        )
        XCTAssertTrue(json.contains(#"\u0001"#))
    }
}
