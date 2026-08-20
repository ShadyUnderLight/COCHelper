import Foundation

/// Issue #205: frozen registry for trusted coverage adapters.
///
/// Only adapter/protocol pairs registered here may produce `isVerified == true`.
/// Pasted JSON, arbitrary internal callers, and unregistered wire `verified`
/// payloads must fail closed even when field shapes are valid.
public enum SnapshotCoverageVerifier {
    public static let testFixtureAdapterID = "test-fixture"
    public static let perfFixtureAdapterID = "perf-fixture"

    private static let registeredProtocols: [String: Set<String>] = [
        testFixtureAdapterID: ["1"],
        perfFixtureAdapterID: ["1"],
    ]

    public static func isRegistered(adapterID: String, protocolVersion: String) -> Bool {
        guard let versions = registeredProtocols[adapterID] else { return false }
        return versions.contains(protocolVersion)
    }

    /// Issue verified coverage proof for a registered adapter/protocol pair.
    public static func issue(
        source: String,
        adapterID: String,
        protocolVersion: String,
        expectedCount: Int?,
        verificationReason: String
    ) -> SnapshotCoverageProof {
        guard isRegistered(adapterID: adapterID, protocolVersion: protocolVersion) else {
            return .unavailable(
                reason: "coverage adapter 未注册或不支持协议版本：\(adapterID)@\(protocolVersion)。"
            )
        }
        guard isNonBlank(source),
              isParsableProtocolVersion(protocolVersion),
              expectedCount == nil || expectedCount! >= 0,
              isNonBlank(verificationReason) else {
            return .unavailable(reason: "verified coverage 证据格式无效。")
        }
        return .verified(
            source: source,
            adapterID: adapterID,
            protocolVersion: protocolVersion,
            expectedCount: expectedCount,
            verificationReason: verificationReason
        )
    }

    private static func isNonBlank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isParsableProtocolVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return false }
        return components.allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber)
        }
    }
}
