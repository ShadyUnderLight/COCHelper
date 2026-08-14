import XCTest
@testable import COCHelperCore

final class QueueAssignmentModelsTests: XCTestCase {
    private let villageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_000)

    private func validKey() -> TrackerItemKey {
        .root(base: .home, rawSection: "buildings", dataID: 123)
    }

    private func validReference() -> ManualBaselineReference {
        ManualBaselineReference(
            revision: "rev-1",
            fingerprint: "fp-1",
            lineageID: "lineage-1"
        )
    }

    func testDefaultsToUserAssignedUserConfigured() throws {
        let decision = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: validKey(),
            baselineReference: validReference(),
            queueKind: .builder,
            decidedAt: now
        )
        XCTAssertEqual(decision.status, .userAssigned)
        XCTAssertEqual(decision.source, .userConfigured)
        XCTAssertEqual(decision.queueKind, .builder)
        XCTAssertEqual(decision.baselineReference.lineageID, "lineage-1")
    }

    func testRejectsInvalidItemKey() {
        XCTAssertThrowsError(
            try QueueAssignmentDecision(
                villageID: villageID,
                itemKey: .root(base: .home, rawSection: "", dataID: 0),
                baselineReference: validReference(),
                queueKind: .builder,
                decidedAt: now
            )
        ) { error in
            XCTAssertEqual(error as? QueueAssignmentError, .invalidItemKey)
        }
    }

    func testRejectsInvalidBaselineReference() {
        XCTAssertThrowsError(
            try QueueAssignmentDecision(
                villageID: villageID,
                itemKey: validKey(),
                baselineReference: ManualBaselineReference(revision: "  "),
                queueKind: .builder,
                decidedAt: now
            )
        ) { error in
            XCTAssertEqual(error as? QueueAssignmentError, .invalidBaselineReference)
        }
    }

    func testRejectsInvalidTimestamp() {
        XCTAssertThrowsError(
            try QueueAssignmentDecision(
                villageID: villageID,
                itemKey: validKey(),
                baselineReference: validReference(),
                queueKind: .builder,
                decidedAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        ) { error in
            XCTAssertEqual(error as? QueueAssignmentError, .invalidTimestamp)
        }
    }

    func testCodableRoundTripPreservesAllFields() throws {
        let decision = try QueueAssignmentDecision(
            villageID: villageID,
            itemKey: validKey(),
            baselineReference: validReference(),
            queueKind: .laboratory,
            decidedAt: now,
            status: .observedOnly
        )
        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(QueueAssignmentDecision.self, from: data)
        XCTAssertEqual(decoded, decision)
        XCTAssertEqual(decoded.status, .observedOnly)
        XCTAssertEqual(decoded.decidedAt, now)
    }

    func testStatusesAreDistinct() {
        XCTAssertNotEqual(QueueAssignmentStatus.userAssigned, .observedOnly)
        XCTAssertNotEqual(QueueAssignmentStatus.userAssigned, .unknown)
        XCTAssertNotEqual(QueueAssignmentStatus.observedOnly, .unknown)
    }
}
