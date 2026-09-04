import Foundation

/// Issue #205 / #224: module-internal factories and persisted revalidation for trusted coverage.
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
        verificationReason: String,
        fixtureID: String?
    ) -> SnapshotCoverageProof {
        // Issue #304 follow-up：perf fixture 签发必须携带受控 fixture 身份
        //（loader 签发的 fixture 文件名）；无身份不得签发 verified 证据。
        guard let fixtureID, !fixtureID.isEmpty else {
            return .unavailable(
                reason: "perf fixture 缺少受控 fixture 身份，不得签发 verified 证据。"
            )
        }
        return issueVerified(
            source: source,
            adapterID: perfFixtureAdapterID,
            protocolVersion: protocolVersion,
            expectedCount: expectedCount,
            verificationReason: verificationReason,
            fixtureID: fixtureID
        )
    }

    package static func promoteBundledPerfFixtureDeclaredProofs(
        _ proofs: [String: SnapshotCoverageProof],
        fixtureID: String
    ) -> [String: SnapshotCoverageProof] {
        // 无受控 fixture 身份不得提升：原样返回 declared proofs（fail-closed）。
        guard !fixtureID.isEmpty else { return proofs }
        return proofs.mapValues { proof in
            switch proof {
            case .declared(let source, let version, let expectedCount)
                where source == perfFixtureAdapterID:
                return issuePerfFixture(
                    source: source,
                    protocolVersion: version,
                    expectedCount: expectedCount,
                    verificationReason: "bundled perf fixture",
                    fixtureID: fixtureID
                )
            default:
                return proof
            }
        }
    }

    /// Attach persisted revalidation material to a live module-issued verified proof.
    /// Issue #304：只附加 rule version，不再计算内容 inputBinding 摘要。
    static func attachPersistedBinding(
        to proof: SnapshotCoverageProof
    ) -> SnapshotCoverageProof {
        guard case .verified(let evidence) = proof,
              evidence.runtimeWitness == .moduleIssued else {
            return proof
        }
        return .verified(
            VerifiedCoverageEvidence(
                source: evidence.source,
                adapterID: evidence.adapterID,
                protocolVersion: evidence.protocolVersion,
                expectedCount: evidence.expectedCount,
                verificationReason: evidence.verificationReason,
                verificationRuleVersion: currentVerificationRuleVersion,
                fixtureID: evidence.fixtureID,
                runtimeWitness: .moduleIssued
            )
        )
    }

    static func validatesModuleIssuedProof(_ proof: SnapshotCoverageProof) -> Bool {
        guard case .verified(let evidence) = proof,
              evidence.runtimeWitness == .moduleIssued else {
            return false
        }
        return isWellFormedVerifiedWireEvidence(evidence)
    }

    static func isWellFormedVerifiedWireProof(_ proof: SnapshotCoverageProof) -> Bool {
        guard case .verified(let evidence) = proof else { return false }
        return isWellFormedVerifiedWireEvidence(evidence)
    }

    static func isWellFormedVerifiedWireEvidence(_ evidence: VerifiedCoverageEvidence) -> Bool {
        guard let verificationReason = evidence.verificationReason else {
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

    static func validatePersistedSectionStructure(
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

    private static func issueVerified(
        source: String,
        adapterID: String,
        protocolVersion: String,
        expectedCount: Int?,
        verificationReason: String,
        fixtureID: String? = nil
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
                fixtureID: fixtureID,
                runtimeWitness: .moduleIssued
            )
        )
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
