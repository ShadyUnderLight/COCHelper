import CryptoKit
import COCHelperCore
import Foundation
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

    func testForgedTestFixtureWireStaysFailClosedThroughProductionStoreLoad() throws {
        let text = "{\"tag\":\"#ABC123\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let binding = try XCTUnwrap(sectionInputBinding(rawJSON: text, section: "heroes"))
        let proofJSON = """
        {
          "kind": "verified",
          "source": "test-export",
          "adapterID": "test-fixture",
          "protocolVersion": "1",
          "expectedCount": 1,
          "verificationReason": "external forge attempt",
          "verificationRuleVersion": "1",
          "inputBinding": "\(binding)"
        }
        """
        let forgedProof = try JSONDecoder().decode(
            SnapshotCoverageProof.self,
            from: Data(proofJSON.utf8)
        )
        XCTAssertTrue(forgedProof.hasVerifiedWireMetadata)
        XCTAssertFalse(forgedProof.isVerified)

        let snapshot = AccountSnapshot(
            tag: "#ABC123",
            capturedAt: nil,
            importedAt: Date(timeIntervalSince1970: 1),
            ageSeconds: nil,
            originalText: text,
            objectSections: [:],
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
        let villageID = UUID()
        let lineageID = UUID()
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: [:]
        )
        let forgedCoverage = SnapshotObservationCoverage(
            schemaVersion: entry.coverage.schemaVersion,
            fields: entry.coverage.fields,
            sections: entry.coverage.sections.map { section in
                guard section.rawSection == "heroes" else { return section }
                return SnapshotSectionCoverage(
                    base: section.base,
                    rawSection: section.rawSection,
                    presence: .presentNonEmpty,
                    completeness: .complete,
                    proof: forgedProof,
                    observedCount: section.observedCount
                )
            },
            diagnostics: entry.coverage.diagnostics
        )
        let forgedEntry = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            fingerprintVersion: entry.fingerprintVersion,
            integrityVersion: entry.integrityVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: entry.canonicalFingerprint,
            rawJSON: text,
            observation: entry.observation,
            coverage: forgedCoverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
        let envelope = try SnapshotHistoryEnvelope(
            entries: [forgedEntry],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: forgedEntry.villageID,
                    lineageID: forgedEntry.lineageID,
                    normalizedPlayerTag: forgedEntry.normalizedPlayerTag,
                    lastEntryID: forgedEntry.snapshotID,
                    lastFingerprint: forgedEntry.canonicalFingerprint,
                    lastAppliedAt: forgedEntry.appliedAt,
                    hasConflict: false
                )
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: Date(timeIntervalSince1970: 1))
        ).validated()

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("public-api-boundary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = FileSnapshotHistoryStore(fileURL: fileURL)
        try store.save(envelope)
        let loaded = try XCTUnwrap(try store.load())
        let heroes = try XCTUnwrap(
            loaded.entries.first?.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertFalse(heroes.opensTrustGates)
        XCTAssertFalse(heroes.isComplete)
    }

    private func sectionInputBinding(rawJSON: String, section: String) throws -> String? {
        guard let data = rawJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[section],
              JSONSerialization.isValidJSONObject(value) else {
            return nil
        }
        let sectionData = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let digest = SHA256.hash(data: sectionData)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
