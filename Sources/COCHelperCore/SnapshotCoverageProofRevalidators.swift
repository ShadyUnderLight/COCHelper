import Foundation

/// Adapter-specific persisted proof revalidation (Issue #224).
///
/// Registry entries re-run the original provenance checks; static adapter ID
/// allowlists and section SHA alone are insufficient.
enum SnapshotCoverageProofRevalidators {
    static func revalidate(
        evidence: VerifiedCoverageEvidence,
        rawJSON: String,
        section: String,
        policy: SnapshotCoverageRevalidationPolicy
    ) -> SectionCoverageRuntimeTrust {
        // Issue #304：不再比较内容 inputBinding 摘要；保留 rule 版本门、
        // section 结构校验与 adapter 来源校验。
        guard let ruleVersion = evidence.verificationRuleVersion else {
            return .rejected("缺少 persisted revalidation 材料。")
        }
        guard ruleVersion == SnapshotCoverageVerifier.currentVerificationRuleVersion else {
            return .rejected("verification rule 版本不受支持：\(ruleVersion)。")
        }
        guard SnapshotCoverageVerifier.validatePersistedSectionStructure(
            rawJSON: rawJSON,
            section: section,
            expectedCount: evidence.expectedCount
        ) else {
            return .rejected("section 结构校验失败。")
        }

        let key = RevalidatorKey(
            adapterID: evidence.adapterID,
            protocolVersion: evidence.protocolVersion,
            ruleVersion: ruleVersion
        )
        guard let revalidator = registry(policy: policy)[key] else {
            return .rejected("未注册的 coverage revalidator：\(evidence.adapterID)@\(evidence.protocolVersion)。")
        }
        return revalidator.revalidate(evidence, rawJSON, section)
    }

    private struct RevalidatorKey: Hashable {
        let adapterID: String
        let protocolVersion: String
        let ruleVersion: String
    }

    private struct Revalidator {
        let revalidate: (
            VerifiedCoverageEvidence,
            String,
            String
        ) -> SectionCoverageRuntimeTrust
    }

    private static func registry(
        policy: SnapshotCoverageRevalidationPolicy
    ) -> [RevalidatorKey: Revalidator] {
        var entries: [RevalidatorKey: Revalidator] = [
            RevalidatorKey(
                adapterID: SnapshotCoverageVerifier.perfFixtureAdapterID,
                protocolVersion: "1",
                ruleVersion: SnapshotCoverageVerifier.currentVerificationRuleVersion
            ): Revalidator(revalidate: perfFixtureRevalidate)
        ]
        if policy == .testsAllowTestFixture {
            entries[RevalidatorKey(
                adapterID: SnapshotCoverageVerifier.testFixtureAdapterID,
                protocolVersion: "1",
                ruleVersion: SnapshotCoverageVerifier.currentVerificationRuleVersion
            )] = Revalidator(revalidate: testFixtureRevalidate)
        }
        return entries
    }

    private static func perfFixtureRevalidate(
        evidence: VerifiedCoverageEvidence,
        rawJSON: String,
        section: String
    ) -> SectionCoverageRuntimeTrust {
        guard evidence.adapterID == SnapshotCoverageVerifier.perfFixtureAdapterID else {
            return .rejected("adapterID 与 perf fixture 契约不一致。")
        }
        guard evidence.source == SnapshotCoverageVerifier.perfFixtureAdapterID else {
            return .rejected("perf fixture source 不匹配。")
        }
        guard evidence.verificationReason == "bundled perf fixture" else {
            return .rejected("perf fixture verificationReason 不匹配。")
        }
        // Issue #304：不再用内容 hash allowlist 判定 perf fixture 是否可信；
        // rawJSON 仍须按 adapter 契约声明该 section（业务来源表达）。
        guard perfFixtureDeclaresSection(
            section: section,
            in: rawJSON,
            expectedCount: evidence.expectedCount
        ) else {
            return .rejected("perf fixture coverage 声明与 section 不一致。")
        }
        return .trusted
    }

    private static func testFixtureRevalidate(
        evidence: VerifiedCoverageEvidence,
        rawJSON: String,
        section: String
    ) -> SectionCoverageRuntimeTrust {
        guard evidence.adapterID == SnapshotCoverageVerifier.testFixtureAdapterID else {
            return .rejected("adapterID 与 test fixture 契约不一致。")
        }
        guard SnapshotCoverageVerifier.isWellFormedVerifiedWireEvidence(evidence) else {
            return .rejected("test fixture wire evidence 无效。")
        }
        return .trusted
    }

    private static func perfFixtureDeclaresSection(
        section: String,
        in rawJSON: String,
        expectedCount: Int?
    ) -> Bool {
        guard let snapshot = try? AccountSnapshotImporter.parse(
            rawJSON,
            now: Date(timeIntervalSince1970: 1)
        ) else {
            return false
        }
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot)
        guard let proof = proofs[section] else { return false }
        switch proof {
        case .declared(
            let source,
            let version,
            let declaredExpectedCount
        ):
            return source == SnapshotCoverageVerifier.perfFixtureAdapterID
                && version == "1"
                && declaredExpectedCount == expectedCount
        default:
            return false
        }
    }
}
