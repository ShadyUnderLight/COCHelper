import XCTest
@testable import COCHelperCore

/// Issue #304 follow-up (P1)：bundled fixture provenance 必须来自 module-owned
/// registry，不能由 persisted rawJSON.coverage 自证。
///
/// 覆盖：正向（合法 fixture reload 恢复 trust）+ 协同篡改（reviewer 场景：
/// rawJSON 声明与 persisted proof 一起改）+ fixtureID 移植 + 未知 ID +
/// 仅声明篡改 + universe 篡改 + 签发期门控。
final class PerfFixtureProvenanceTests: XCTestCase {
    private let homeFixtureID = "perf_account_snapshot_home"
    private let builderFixtureID = "perf_account_snapshot_builder"

    // MARK: - Helpers

    private func fixtureText(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parse(_ text: String) throws -> AccountSnapshot {
        try AccountSnapshotImporter.parse(text, now: Date(timeIntervalSince1970: 1))
    }

    /// 合法签发：parse → promote（loader 签发 fixtureID）→ universe → canonicalize。
    private func issueFixtureEntry(
        name: String,
        text: String? = nil
    ) throws -> SnapshotHistoryEntry {
        let snapshot = try parse(text ?? fixtureText(name))
        let proofs = SnapshotCoverageVerifier.promoteBundledPerfFixtureDeclaredProofs(
            JSONSnapshotCoverageAdapter.proofs(for: snapshot),
            fixtureID: name
        )
        let universe = SnapshotCoverageSourceUniverseIssuer.issuePerfFixture(snapshot: snapshot)
        return try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: proofs,
            sourceUniverse: universe
        )
    }

    /// 模拟 persist：JSON round-trip（runtimeWitness 丢失）→ validated →
    /// production hydrate。validated() 本身证明 rawJSON↔observation 一致。
    private func reloadProduction(
        _ entry: SnapshotHistoryEntry
    ) throws -> SnapshotHistoryEntry {
        let decoded = try JSONDecoder().decode(
            SnapshotHistoryEntry.self,
            from: JSONEncoder().encode(entry)
        )
        let envelope = try SnapshotHistoryEnvelope(
            entries: [decoded],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: decoded.villageID,
                    lineageID: decoded.lineageID,
                    normalizedPlayerTag: decoded.normalizedPlayerTag,
                    lastEntryID: decoded.snapshotID,
                    lastAppliedAt: decoded.appliedAt,
                    hasConflict: false
                ),
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: decoded.appliedAt)
        ).validated()
        let hydrated = envelope.hydratingVerifiedCoverage(policy: .production)
        return try XCTUnwrap(hydrated.entries.first)
    }

    private func verifiedPerfProof(
        expectedCount: Int?,
        fixtureID: String?
    ) -> SnapshotCoverageProof {
        .verified(
            VerifiedCoverageEvidence(
                decodedWire: SnapshotCoverageVerifier.perfFixtureAdapterID,
                adapterID: SnapshotCoverageVerifier.perfFixtureAdapterID,
                protocolVersion: "1",
                expectedCount: expectedCount,
                verificationReason: "bundled perf fixture",
                verificationRuleVersion: SnapshotCoverageVerifier.currentVerificationRuleVersion,
                fixtureID: fixtureID
            )
        )
    }

    private func withFixtureID(
        _ entry: SnapshotHistoryEntry,
        _ fixtureID: String?
    ) -> SnapshotHistoryEntry {
        let sections = entry.coverage.sections.map { section -> SnapshotSectionCoverage in
            guard case .verified(let evidence) = section.proof,
                  evidence.adapterID == SnapshotCoverageVerifier.perfFixtureAdapterID else {
                return section
            }
            return SnapshotSectionCoverage(
                base: section.base,
                rawSection: section.rawSection,
                presence: section.presence,
                completeness: section.completeness,
                proof: .verified(
                    VerifiedCoverageEvidence(
                        decodedWire: evidence.source,
                        adapterID: evidence.adapterID,
                        protocolVersion: evidence.protocolVersion,
                        expectedCount: evidence.expectedCount,
                        verificationReason: evidence.verificationReason,
                        verificationRuleVersion: evidence.verificationRuleVersion,
                        fixtureID: fixtureID
                    )
                ),
                observedCount: section.observedCount
            )
        }
        return SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: SnapshotObservationCoverage(
                schemaVersion: entry.coverage.schemaVersion,
                fields: entry.coverage.fields,
                sections: sections,
                diagnostics: entry.coverage.diagnostics,
                sourceUniverse: entry.coverage.sourceUniverse,
                sourceUniverseRuntimeTrust: entry.coverage.sourceUniverseRuntimeTrust
            ),
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
    }

    // MARK: - Positive

    func testUntamperedFixtureReloadRestoresTrust() throws {
        let entry = try issueFixtureEntry(name: homeFixtureID)
        let reloaded = try reloadProduction(entry)
        let trustedSections = reloaded.coverage.sections.filter {
            $0.runtimeTrust == .trusted
        }
        XCTAssertTrue(trustedSections.allSatisfy(\.opensTrustGates))
        XCTAssertEqual(
            reloaded.coverage.sourceUniverseRuntimeTrust,
            .trusted,
            "合法 fixture reload 后 universe 应恢复 trusted"
        )
        let heroes = try XCTUnwrap(
            reloaded.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(heroes.runtimeTrust, .trusted)
    }

    // MARK: - Reviewer co-tampering scenario

    /// 正常 entry + 伪造声明（rawJSON.coverage 自报 perf-fixture）+
    /// 完全匹配的 persisted proof（含真实 fixtureID）：observation 对不上
    /// registry，必须拒绝。
    func testCoTamperedDeclarationAndProofRejected() throws {
        let text = """
        {"tag":"#ABC123","heroes":[{"data":1,"lvl":1}],"coverage":{"heroes":{"kind":"declared","source":"perf-fixture","version":"1","expectedCount":1}}}
        """
        let snapshot = try parse(text)
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: [:],
            sourceUniverse: SnapshotCoverageSourceUniverseIssuer.issuePerfFixtureUniverse(
                requiredSections: ["heroes"]
            )
        )
        let forgedSections = entry.coverage.sections.map { section -> SnapshotSectionCoverage in
            guard section.rawSection == "heroes" else { return section }
            return SnapshotSectionCoverage(
                base: section.base,
                rawSection: section.rawSection,
                presence: .presentNonEmpty,
                completeness: .complete,
                proof: verifiedPerfProof(expectedCount: 1, fixtureID: homeFixtureID),
                observedCount: 1
            )
        }
        let forged = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: SnapshotObservationCoverage(
                schemaVersion: entry.coverage.schemaVersion,
                fields: entry.coverage.fields,
                sections: forgedSections,
                diagnostics: entry.coverage.diagnostics,
                sourceUniverse: entry.coverage.sourceUniverse,
                sourceUniverseRuntimeTrust: entry.coverage.sourceUniverseRuntimeTrust
            ),
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
        let reloaded = try reloadProduction(forged)
        let heroes = try XCTUnwrap(
            reloaded.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertFalse(heroes.opensTrustGates)
        XCTAssertEqual(heroes.runtimeTrust, .rejected("perf fixture 身份与 registry 记录不一致。"))
        XCTAssertNotEqual(
            reloaded.coverage.sourceUniverseRuntimeTrust,
            .trusted,
            "无背书 section 时 universe 不得恢复 trusted"
        )
    }

    /// 真实 fixtureID 移植到另一份内容上：registry 比对失败。
    func testTransplantedFixtureIDRejected() throws {
        let home = try issueFixtureEntry(name: homeFixtureID)
        let builderSnapshot = try parse(fixtureText(builderFixtureID))
        let transplanted = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: builderSnapshot,
            villageID: home.villageID,
            lineageID: home.lineageID,
            appliedAt: home.appliedAt,
            snapshotID: home.snapshotID,
            sectionProofs: Dictionary(
                uniqueKeysWithValues: home.coverage.sections.compactMap { section -> (String, SnapshotCoverageProof)? in
                    guard case .verified = section.proof else { return nil }
                    return (section.rawSection, section.proof)
                }
            ),
            sourceUniverse: home.coverage.sourceUniverse
        )
        let reloaded = try reloadProduction(transplanted)
        XCTAssertFalse(
            reloaded.coverage.sections.contains(where: \.opensTrustGates),
            "移植的 fixture 身份不得打开任何 trust gate"
        )
        XCTAssertNotEqual(reloaded.coverage.sourceUniverseRuntimeTrust, .trusted)
    }

    func testUnknownFixtureIDRejected() throws {
        let entry = try issueFixtureEntry(name: homeFixtureID)
        let reloaded = try reloadProduction(withFixtureID(entry, "no-such-fixture"))
        XCTAssertFalse(
            reloaded.coverage.sections.contains(where: \.opensTrustGates)
        )
        XCTAssertNotEqual(reloaded.coverage.sourceUniverseRuntimeTrust, .trusted)
    }

    /// 仅篡改 coverage 声明块（observation 不变）：registry 通过，
    /// 但声明一致性门必须拒绝该 section，其他 section 不受影响。
    func testDeclarationOnlyTamperRejectedForThatSection() throws {
        let entry = try issueFixtureEntry(name: homeFixtureID)
        var top = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(entry.rawJSON.utf8)) as? [String: Any]
        )
        var coverage = try XCTUnwrap(top["coverage"] as? [String: Any])
        var heroes = try XCTUnwrap(coverage["heroes"] as? [String: Any])
        heroes["version"] = "2"
        coverage["heroes"] = heroes
        top["coverage"] = coverage
        let tamperedRawJSON = String(
            data: try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys]),
            encoding: .utf8
        )
        let tampered = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            rawJSON: try XCTUnwrap(tamperedRawJSON),
            observation: entry.observation,
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
        // coverage 块不进 observation：validated() 必须通过（否则测试本身
        // 假设错误），拒绝发生在 hydration 的声明门。
        let reloaded = try reloadProduction(tampered)
        let heroesSection = try XCTUnwrap(
            reloaded.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertFalse(heroesSection.opensTrustGates)
        if case .rejected = heroesSection.runtimeTrust {
            XCTAssertTrue(true)
        } else {
            XCTFail("声明被篡改的 section 不得恢复 trust")
        }
        XCTAssertTrue(
            reloaded.coverage.sections.contains {
                $0.rawSection != "heroes" && $0.opensTrustGates
            },
            "未篡改的 section 应保持 trusted（registry 通过）"
        )
    }

    /// universe 被加料（一个 required 被降级）：section 背书集合对不上
    /// persisted universe，universe 拒绝但 section 保持 trusted。
    func testUniverseTamperRejectedWhileSectionsStayTrusted() throws {
        let entry = try issueFixtureEntry(name: homeFixtureID)
        let universe = try XCTUnwrap(entry.coverage.sourceUniverse)
        XCTAssertTrue(universe.sections.contains { $0.relevance == .required })
        var flipped = false
        let tamperedSections = universe.sections.map { section in
            // 只降级第一个 required，保证与背书集合不同。
            guard !flipped, section.relevance == .required else { return section }
            flipped = true
            return SnapshotCoverageSourceSectionRelevance(
                base: section.base,
                rawSection: section.rawSection,
                relevance: .notApplicable
            )
        }
        XCTAssertTrue(flipped)
        let tamperedUniverse = SnapshotCoverageSourceUniverse(
            adapterID: universe.adapterID,
            protocolVersion: universe.protocolVersion,
            sections: tamperedSections
        )
        let tampered = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: SnapshotObservationCoverage(
                schemaVersion: entry.coverage.schemaVersion,
                fields: entry.coverage.fields,
                sections: entry.coverage.sections,
                diagnostics: entry.coverage.diagnostics,
                sourceUniverse: tamperedUniverse,
                sourceUniverseRuntimeTrust: entry.coverage.sourceUniverseRuntimeTrust
            ),
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
        let reloaded = try reloadProduction(tampered)
        XCTAssertNotEqual(reloaded.coverage.sourceUniverseRuntimeTrust, .trusted)
        XCTAssertTrue(
            reloaded.coverage.sections.contains(where: \.opensTrustGates),
            "section 背书本身未被篡改，应保持 trusted"
        )
    }

    // MARK: - Issue-time gate (migration path)

    /// 无 loader 上下文的签发路径不得给任意自报 JSON 签发 universe。
    func testIssuePerfFixtureUniverseRefusesNonFixtureSnapshot() throws {
        let text = """
        {"tag":"#ABC123","heroes":[{"data":1,"lvl":1}],"coverage":{"heroes":{"kind":"declared","source":"perf-fixture","version":"1","expectedCount":1}}}
        """
        let snapshot = try parse(text)
        XCTAssertNil(
            SnapshotCoverageSourceUniverseIssuer.issuePerfFixture(snapshot: snapshot),
            "非 registry fixture 不得签发 perf universe"
        )
    }

    func testIssuePerfFixtureUniverseAcceptsRegisteredFixture() throws {
        let snapshot = try parse(fixtureText(homeFixtureID))
        XCTAssertNotNil(
            SnapshotCoverageSourceUniverseIssuer.issuePerfFixture(snapshot: snapshot)
        )
    }

    /// P1（issue-time gap）：真实 registered business content + 只篡改 coverage
    /// metadata。business membership 成立（registry 仍可识别），但 coverage
    /// authorization 不成立——签发必须拒绝，而不是按篡改后的声明签出 universe。
    func testIssuePerfFixtureUniverseRefusesCoverageOnlyMutation() throws {
        var top = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(fixtureText(homeFixtureID).utf8))
                as? [String: Any]
        )
        var coverage = try XCTUnwrap(top["coverage"] as? [String: Any])
        // 只删 spells 的 perf-fixture declaration：business observation 不变。
        coverage.removeValue(forKey: "spells")
        top["coverage"] = coverage
        let mutatedRawJSON = String(
            data: try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys]),
            encoding: .utf8
        )
        let snapshot = try parse(try XCTUnwrap(mutatedRawJSON))
        XCTAssertEqual(
            PerfFixtureIdentityRegistry.fixtureID(for: snapshot),
            homeFixtureID,
            "coverage-only 篡改不得改变 business membership 识别"
        )
        XCTAssertNil(
            SnapshotCoverageSourceUniverseIssuer.issuePerfFixture(snapshot: snapshot),
            "声明集与 registry 授权集不一致时不得签发 universe"
        )
    }

    // MARK: - Registry invariant (P2): no authorization aliasing

    /// observation 身份在 registry 中必须全局唯一：若两个 fixtureID 共享同一
    /// observation digest 但授权 section 集不同，攻击者只需替换 persisted
    /// fixtureID 即可完成合法 ID substitution（authorization aliasing）。
    /// 当前 4 个 fixture 天然满足；此测试锁住 invariant，使新增 fixture 时
    /// 无法无意中制造 alias。
    func testRegistryObservationIdentityIsGloballyUnique() {
        let ids = PerfFixtureIdentityRegistry.allRegisteredFixtureIDs
        XCTAssertFalse(ids.isEmpty, "registry 不得为空表")
        let digests = ids.compactMap {
            PerfFixtureIdentityRegistry.expectedObservationDigest(for: $0)
        }
        XCTAssertEqual(
            digests.count, ids.count,
            "每个已登记 fixtureID 必须有期望记录"
        )
        XCTAssertEqual(
            Set(digests).count, digests.count,
            "observation 身份必须全局唯一：共享 digest 的 fixtureID 会允许合法 ID substitution"
        )
    }
}
