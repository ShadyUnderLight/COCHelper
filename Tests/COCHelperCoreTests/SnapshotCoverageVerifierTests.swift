import XCTest
@testable import COCHelperCore

final class SnapshotCoverageVerifierTests: XCTestCase {
    func testRegisteredAdapterIssuesVerifiedProof() {
        let proof = SnapshotCoverageVerifier.issue(
            source: "test-export",
            adapterID: SnapshotCoverageVerifier.testFixtureAdapterID,
            protocolVersion: "1",
            expectedCount: 2,
            verificationReason: "test injection"
        )
        XCTAssertTrue(proof.isVerified)
    }

    func testUnknownAdapterFailsClosed() {
        let proof = SnapshotCoverageVerifier.issue(
            source: "evil",
            adapterID: "evil",
            protocolVersion: "1",
            expectedCount: 1,
            verificationReason: "forged"
        )
        guard case .unavailable = proof else {
            return XCTFail("未注册 adapter 应 fail-closed 为 unavailable")
        }
        XCTAssertFalse(proof.isVerified)
    }

    func testUnsupportedProtocolVersionFailsClosed() {
        let proof = SnapshotCoverageVerifier.issue(
            source: "test-export",
            adapterID: SnapshotCoverageVerifier.testFixtureAdapterID,
            protocolVersion: "99",
            expectedCount: 1,
            verificationReason: "test injection"
        )
        guard case .unavailable = proof else {
            return XCTFail("不支持的协议版本应 fail-closed")
        }
        XCTAssertFalse(proof.isVerified)
    }

    func testDirectVerifiedConstructionWithUnregisteredAdapterIsNotTrusted() throws {
        let proof = SnapshotCoverageProof.verified(
            source: "evil",
            adapterID: "evil",
            protocolVersion: "1",
            expectedCount: 1,
            verificationReason: "forged",
            verificationDigest: nil
        )
        XCTAssertFalse(proof.isVerified)
    }

    func testDirectVerifiedConstructionCannotImpersonateRegisteredAdapter() {
        let forged = SnapshotCoverageProof.verified(
            source: "evil",
            adapterID: SnapshotCoverageVerifier.perfFixtureAdapterID,
            protocolVersion: "1",
            expectedCount: 1,
            verificationReason: "forged",
            verificationDigest: nil
        )
        XCTAssertFalse(forged.isVerified)
    }

    func testDecodedVerifiedWireWithUnregisteredAdapterIsNotTrusted() throws {
        let json = """
        {"kind":"verified","source":"evil","adapterID":"evil","protocolVersion":"1","expectedCount":1,"verificationReason":"forged"}
        """.data(using: .utf8)!
        let proof = try JSONDecoder().decode(SnapshotCoverageProof.self, from: json)
        XCTAssertFalse(proof.isVerified)
    }

    func testDecodedVerifiedWireWithRegisteredAdapterButNoDigestIsNotTrusted() throws {
        let json = """
        {"kind":"verified","source":"evil","adapterID":"perf-fixture","protocolVersion":"1","expectedCount":1,"verificationReason":"forged"}
        """.data(using: .utf8)!
        let proof = try JSONDecoder().decode(SnapshotCoverageProof.self, from: json)
        XCTAssertFalse(proof.isVerified)
    }

    func testIssuedVerifiedProofRoundTripsThroughJSON() throws {
        let issued = SnapshotCoverageVerifier.issue(
            source: "test-export",
            adapterID: SnapshotCoverageVerifier.testFixtureAdapterID,
            protocolVersion: "1",
            expectedCount: 2,
            verificationReason: "test injection"
        )
        let data = try JSONEncoder().encode(issued)
        let decoded = try JSONDecoder().decode(SnapshotCoverageProof.self, from: data)
        XCTAssertTrue(decoded.isVerified)
    }

    func testMissingVerificationReasonIsNotTrusted() {
        let proof = SnapshotCoverageProof.verified(
            source: "test-export",
            adapterID: SnapshotCoverageVerifier.testFixtureAdapterID,
            protocolVersion: "1",
            expectedCount: 1,
            verificationReason: nil,
            verificationDigest: nil
        )
        XCTAssertFalse(proof.isVerified)
    }

    func testBlankVerificationReasonIsNotTrusted() {
        let proof = SnapshotCoverageVerifier.issue(
            source: "test-export",
            adapterID: SnapshotCoverageVerifier.testFixtureAdapterID,
            protocolVersion: "1",
            expectedCount: 1,
            verificationReason: "   "
        )
        guard case .unavailable = proof else {
            return XCTFail("空白 verificationReason 应 fail-closed")
        }
        XCTAssertFalse(proof.isVerified)
    }
}
