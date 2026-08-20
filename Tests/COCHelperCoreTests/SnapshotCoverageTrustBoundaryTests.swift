import XCTest
import COCHelperCore

/// API-boundary tests that must compile without `@testable import COCHelperCore`.
final class SnapshotCoverageTrustBoundaryTests: XCTestCase {
    func testDecodedVerifiedWireCannotImpersonateRegisteredAdapter() throws {
        let json = """
        {"kind":"verified","source":"evil","adapterID":"perf-fixture","protocolVersion":"1","expectedCount":1,"verificationReason":"forged"}
        """.data(using: .utf8)!
        let proof = try JSONDecoder().decode(SnapshotCoverageProof.self, from: json)
        XCTAssertFalse(proof.isVerified)
    }
}
