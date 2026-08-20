import Foundation

/// Issue #205 / #224: module-internal factories and persisted revalidation for trusted coverage.
///
/// Trust comes from code-path provenance plus load-time revalidation, not wire metadata
/// or caller-supplied adapter IDs. Only proofs with a module witness or successful
/// persisted revalidation may evaluate to `isVerified == true`.
package enum SnapshotCoverageVerifier {
    static let testFixtureAdapterID = "test-fixture"
    static let perfFixtureAdapterID = "perf-fixture"
    static let currentVerificationRuleVersion = "1"

    private static let registeredProtocols: [String: Set<String>] = [
        testFixtureAdapterID: ["1"],
        perfFixtureAdapterID: ["1"],
    ]

    static func issueTestFixture(
        source: String = "test-export",
        protocolVersion: String = "1",
        expectedCount: Int? = nil,
        verificationReason: String = "test injection"
    ) -> SnapshotCoverageProof {
        issueVerified(
            source: source,
            adapterID: testFixtureAdapterID,
            protocolVersion: protocolVersion,
            expectedCount: expectedCount,
            verificationReason: verificationReason
        )
    }

    static func issuePerfFixture(
        source: String,
        protocolVersion: String,
        expectedCount: Int?,
        verificationReason: String
    ) -> SnapshotCoverageProof {
        issueVerified(
            source: source,
            adapterID: perfFixtureAdapterID,
            protocolVersion: protocolVersion,
            expectedCount: expectedCount,
            verificationReason: verificationReason
        )
    }

    package static func promoteBundledPerfFixtureDeclaredProofs(
        _ proofs: [String: SnapshotCoverageProof]
    ) -> [String: SnapshotCoverageProof] {
        proofs.mapValues { proof in
            switch proof {
            case .declared(let source, let version, let expectedCount)
                where source == perfFixtureAdapterID:
                return issuePerfFixture(
                    source: source,
                    protocolVersion: version,
                    expectedCount: expectedCount,
                    verificationReason: "bundled perf fixture"
                )
            default:
                return proof
            }
        }
    }

    /// Attach persisted revalidation material to a live module-issued verified proof.
    static func attachPersistedBinding(
        to proof: SnapshotCoverageProof,
        rawJSON: String,
        section: String
    ) -> SnapshotCoverageProof {
        guard case .verified(let evidence) = proof,
              evidence.runtimeWitness == .moduleIssued else {
            return proof
        }
        guard let binding = SnapshotCoverageTrustHydration.sectionInputBinding(
            rawJSON: rawJSON,
            section: section
        ) else {
            return .unavailable(reason: "无法绑定 verified coverage 验证输入：\(section)。")
        }
        return .verified(
            VerifiedCoverageEvidence(
                source: evidence.source,
                adapterID: evidence.adapterID,
                protocolVersion: evidence.protocolVersion,
                expectedCount: evidence.expectedCount,
                verificationReason: evidence.verificationReason,
                verificationRuleVersion: currentVerificationRuleVersion,
                inputBinding: binding,
                runtimeWitness: .moduleIssued
            )
        )
    }

    /// Revalidate decoded wire metadata against immutable raw JSON (Issue #224).
    static func revalidatePersistedProof(
        _ proof: SnapshotCoverageProof,
        rawJSON: String,
        section: String
    ) -> SnapshotCoverageProof {
        guard case .verified(let evidence) = proof else { return proof }
        if evidence.runtimeWitness == .moduleIssued {
            return proof
        }

        guard let ruleVersion = evidence.verificationRuleVersion,
              let binding = evidence.inputBinding else {
            return proof
        }
        guard ruleVersion == currentVerificationRuleVersion else {
            return .unavailable(
                reason: "verified coverage 规则版本不受支持：\(ruleVersion)。"
            )
        }
        guard let computedBinding = SnapshotCoverageTrustHydration.sectionInputBinding(
            rawJSON: rawJSON,
            section: section
        ), computedBinding == binding else {
            return .unavailable(reason: "verified coverage 验证输入绑定不匹配：\(section)。")
        }
        guard validatePersistedSection(
            rawJSON: rawJSON,
            section: section,
            expectedCount: evidence.expectedCount
        ) else {
            return .unavailable(reason: "verified coverage 重验证失败：\(section)。")
        }
        guard isNonBlank(evidence.source),
              let verificationReason = evidence.verificationReason,
              isNonBlank(verificationReason),
              isParsableProtocolVersion(evidence.protocolVersion),
              isRegistered(
                  adapterID: evidence.adapterID,
                  protocolVersion: evidence.protocolVersion
              ) else {
            return .unavailable(reason: "verified coverage 持久化证据无效：\(section)。")
        }

        return .verified(
            VerifiedCoverageEvidence(
                source: evidence.source,
                adapterID: evidence.adapterID,
                protocolVersion: evidence.protocolVersion,
                expectedCount: evidence.expectedCount,
                verificationReason: verificationReason,
                verificationRuleVersion: ruleVersion,
                inputBinding: binding,
                runtimeWitness: .moduleIssued
            )
        )
    }

    static func validatesVerifiedProof(_ proof: SnapshotCoverageProof) -> Bool {
        guard case .verified(let evidence) = proof,
              evidence.runtimeWitness == .moduleIssued,
              let verificationReason = evidence.verificationReason else {
            return false
        }
        guard isNonBlank(evidence.source),
              isNonBlank(verificationReason),
              isParsableProtocolVersion(evidence.protocolVersion),
              isRegistered(adapterID: evidence.adapterID, protocolVersion: evidence.protocolVersion) else {
            return false
        }
        return evidence.expectedCount == nil || evidence.expectedCount! >= 0
    }

    private static func issueVerified(
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
            VerifiedCoverageEvidence(
                source: source,
                adapterID: adapterID,
                protocolVersion: protocolVersion,
                expectedCount: expectedCount,
                verificationReason: verificationReason,
                verificationRuleVersion: nil,
                inputBinding: nil,
                runtimeWitness: .moduleIssued
            )
        )
    }

    private static func validatePersistedSection(
        rawJSON: String,
        section: String,
        expectedCount: Int?
    ) -> Bool {
        guard let topLevel = try? topLevelObject(of: rawJSON),
              let value = topLevel[section] else {
            return false
        }
        guard let array = value as? [Any] else { return false }
        if let expectedCount, expectedCount != array.count {
            return false
        }
        for element in array {
            if SnapshotHistoryKnownSections.numeric.contains(section) {
                guard integer(element) != nil else { return false }
                continue
            }
            guard let object = element as? [String: Any] else { return false }
            guard integer(object["data"]) != nil else { return false }
            for nestedField in ["types", "modules"] {
                guard let nestedValue = object[nestedField] else { continue }
                guard let children = nestedValue as? [Any] else { return false }
                for child in children {
                    guard let childObject = child as? [String: Any],
                          integer(childObject["data"]) != nil else {
                        return false
                    }
                }
            }
        }
        return true
    }

    private static func topLevelObject(of text: String) throws -> [String: Any] {
        let prepared = AccountSnapshotImporter.prepare(text).text
        guard let data = prepared.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SnapshotHistoryCanonicalizationError.invalidJSON("顶层必须是 JSON 对象。")
        }
        return object
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as Double:
            guard number.isFinite, number >= 0, number.rounded() == number else { return nil }
            return Int(number)
        case let text as String:
            guard let number = Int(text), number >= 0 else { return nil }
            return number
        default:
            return nil
        }
    }

    private static func isRegistered(adapterID: String, protocolVersion: String) -> Bool {
        guard let versions = registeredProtocols[adapterID] else { return false }
        return versions.contains(protocolVersion)
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
