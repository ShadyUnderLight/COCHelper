import XCTest
@testable import COCHelperCore

final class SnapshotCoverageVerifierTests: XCTestCase {
    func testTestFixtureFactoryIssuesVerifiedProof() {
        let proof = SnapshotCoverageVerifier.issueTestFixture(
            source: "test-export",
            expectedCount: 2
        )
        XCTAssertTrue(proof.isVerified)
    }

    func testPerfFixtureFactoryIssuesVerifiedProof() {
        let proof = SnapshotCoverageVerifier.issuePerfFixture(
            source: "perf-fixture",
            protocolVersion: "1",
            expectedCount: 1,
            verificationReason: "bundled perf fixture",
            fixtureID: "perf_account_snapshot_home"
        )
        XCTAssertTrue(proof.isVerified)
    }

    func testPerfFixtureFactoryRefusesMissingFixtureIdentity() {
        let proof = SnapshotCoverageVerifier.issuePerfFixture(
            source: "perf-fixture",
            protocolVersion: "1",
            expectedCount: 1,
            verificationReason: "bundled perf fixture",
            fixtureID: nil
        )
        guard case .unavailable = proof else {
            return XCTFail("无 fixture 身份不得签发 perf verified 证据")
        }
        XCTAssertFalse(proof.isVerified)
    }

    func testUnsupportedProtocolVersionFailsClosed() {
        let proof = SnapshotCoverageVerifier.issueTestFixture(
            source: "test-export",
            protocolVersion: "99",
            expectedCount: 1
        )
        guard case .unavailable = proof else {
            return XCTFail("不支持的协议版本应 fail-closed")
        }
        XCTAssertFalse(proof.isVerified)
    }

    func testDecodedVerifiedWireWithRegisteredAdapterIsNotTrusted() throws {
        let json = """
        {"kind":"verified","source":"evil","adapterID":"perf-fixture","protocolVersion":"1","expectedCount":1,"verificationReason":"forged"}
        """.data(using: .utf8)!
        let proof = try JSONDecoder().decode(SnapshotCoverageProof.self, from: json)
        XCTAssertFalse(proof.isVerified)
    }

    func testDecodedVerifiedWireWithUnregisteredAdapterIsNotTrusted() throws {
        let json = """
        {"kind":"verified","source":"evil","adapterID":"evil","protocolVersion":"1","expectedCount":1,"verificationReason":"forged"}
        """.data(using: .utf8)!
        let proof = try JSONDecoder().decode(SnapshotCoverageProof.self, from: json)
        XCTAssertFalse(proof.isVerified)
    }

    func testIssuedVerifiedProofRoundTripsWireMetadataButLosesRuntimeTrust() throws {
        let issued = SnapshotCoverageVerifier.issueTestFixture(
            source: "test-export",
            expectedCount: 2
        )
        let data = try JSONEncoder().encode(issued)
        let decoded = try JSONDecoder().decode(SnapshotCoverageProof.self, from: data)
        guard case .verified(let evidence) = decoded else {
            return XCTFail("verified wire metadata 应保留")
        }
        XCTAssertEqual(evidence.adapterID, SnapshotCoverageVerifier.testFixtureAdapterID)
        XCTAssertFalse(decoded.isVerified)
    }

    func testBlankVerificationReasonIsNotTrusted() {
        let proof = SnapshotCoverageVerifier.issueTestFixture(
            source: "test-export",
            expectedCount: 1,
            verificationReason: "   "
        )
        guard case .unavailable = proof else {
            return XCTFail("空白 verificationReason 应 fail-closed")
        }
        XCTAssertFalse(proof.isVerified)
    }
}
