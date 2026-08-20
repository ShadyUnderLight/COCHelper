import CryptoKit
import Foundation

/// Issue #205: frozen registry for trusted coverage adapters.
///
/// Only proofs returned by `issue(...)` carry a module-private verification
/// digest and may evaluate to `isVerified == true`. Direct construction of
/// `.verified(...)`, pasted JSON, and wire payloads without a valid digest
/// remain fail-closed even when adapter IDs are registered.
public enum SnapshotCoverageVerifier {
    static let testFixtureAdapterID = "test-fixture"
    static let perfFixtureAdapterID = "perf-fixture"

    private static let registeredProtocols: [String: Set<String>] = [
        testFixtureAdapterID: ["1"],
        perfFixtureAdapterID: ["1"],
    ]

    private static let digestSeed = Data("COCHelper.SnapshotCoverageVerifier.v1".utf8)

    static func isRegistered(adapterID: String, protocolVersion: String) -> Bool {
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
        let digest = makeVerificationDigest(
            source: source,
            adapterID: adapterID,
            protocolVersion: protocolVersion,
            expectedCount: expectedCount,
            verificationReason: verificationReason
        )
        return .verified(
            source: source,
            adapterID: adapterID,
            protocolVersion: protocolVersion,
            expectedCount: expectedCount,
            verificationReason: verificationReason,
            verificationDigest: digest
        )
    }

    static func validatesVerifiedProof(_ proof: SnapshotCoverageProof) -> Bool {
        guard case .verified(
            let source,
            let adapterID,
            let protocolVersion,
            let expectedCount,
            let verificationReason,
            let verificationDigest
        ) = proof else {
            return false
        }
        guard let verificationReason,
              isNonBlank(source),
              isNonBlank(verificationReason),
              isParsableProtocolVersion(protocolVersion),
              isRegistered(adapterID: adapterID, protocolVersion: protocolVersion),
              expectedCount == nil || expectedCount! >= 0 else {
            return false
        }
        return verificationDigest == makeVerificationDigest(
            source: source,
            adapterID: adapterID,
            protocolVersion: protocolVersion,
            expectedCount: expectedCount,
            verificationReason: verificationReason
        )
    }

    private static func makeVerificationDigest(
        source: String,
        adapterID: String,
        protocolVersion: String,
        expectedCount: Int?,
        verificationReason: String
    ) -> String {
        var material = Data()
        material.append(Data("v1|".utf8))
        material.append(Data(adapterID.utf8))
        material.append(0x1C)
        material.append(Data(protocolVersion.utf8))
        material.append(0x1C)
        material.append(Data(source.utf8))
        material.append(0x1C)
        material.append(Data(verificationReason.utf8))
        material.append(0x1C)
        if let expectedCount {
            material.append(Data(String(expectedCount).utf8))
        }
        let key = SymmetricKey(data: digestSeed)
        let mac = HMAC<SHA256>.authenticationCode(for: material, using: key)
        return "hmac-sha256:" + mac.map { String(format: "%02x", $0) }.joined()
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
