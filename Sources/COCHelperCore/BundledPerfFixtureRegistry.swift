import CryptoKit
import Foundation

/// Fingerprints of bundled perf account snapshot fixtures (Issue #197 / #224).
///
/// Revalidation must prove the immutable `rawJSON` is one of these known bundled
/// texts — not merely self-consistent attacker metadata.
enum BundledPerfFixtureRegistry {
  /// SHA-256 of `AccountSnapshotImporter.prepare(text).text` for each bundled fixture.
    static let accountSnapshotFingerprints: Set<String> = [
        "sha256:6f9e5155e1a21b712269f43f28203545ccde5931ddd5372b2addbbfdd497edfe",
        "sha256:1bf0e2d0884d1b23f056d72e73c16d16b0983360169cc39ac9b262bfc6da954c",
        "sha256:9b672aa5e19919507b8ab8cfba18da048fe877870b03b0d3368b465c3a76d767",
        "sha256:096ec82f811475e6256d0d4bed7d7a13c2220a2548505fe354f0284846ff739c",
    ]

    static func recognizesAccountSnapshot(rawJSON: String) -> Bool {
        guard let fingerprint = preparedFingerprint(of: rawJSON) else { return false }
        return accountSnapshotFingerprints.contains(fingerprint)
    }

    static func preparedFingerprint(of rawJSON: String) -> String? {
        let prepared = AccountSnapshotImporter.prepare(rawJSON).text
        let digest = SHA256.hash(data: Data(prepared.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
