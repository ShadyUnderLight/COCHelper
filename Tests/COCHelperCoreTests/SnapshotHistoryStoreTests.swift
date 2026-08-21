import Foundation
import XCTest
@testable import COCHelperCore

final class SnapshotHistoryStoreTests: XCTestCase {
    private let firstTag = "#2QJQ8J88"
    private let secondTag = "#2QJQ8J89"

    private func snapshot(
        tag: String?,
        text: String = "{}",
        capturedAt: Date? = nil,
        importedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> AccountSnapshot {
        AccountSnapshot(
            tag: tag,
            capturedAt: capturedAt,
            importedAt: importedAt,
            ageSeconds: nil,
            originalText: text,
            objectSections: [:],
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
    }

    func testMigrationCreatesOneBaselinePerExistingSnapshotAndIsIdempotent() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let now = Date(timeIntervalSince1970: 100)
        let firstID = UUID()
        let secondID = UUID()
        let villages = [
            VillageProfile(
                id: firstID,
                name: "主村",
                accountSnapshot: snapshot(tag: firstTag, text: "{\"tag\":\"\(firstTag)\",\"buildings\":[]}")
            ),
            VillageProfile(id: secondID, name: "未导入村")
        ]

        let migrated = try service.loadOrMigrate(villages: villages, now: now)

        XCTAssertTrue(migrated.isMigrated)
        XCTAssertEqual(migrated.migrationMarker?.version, SnapshotHistorySchema.envelope)
        XCTAssertEqual(migrated.entries.count, 1)
        XCTAssertEqual(migrated.entries[0].villageID, firstID)
        XCTAssertEqual(migrated.entries[0].rawJSON, villages[0].accountSnapshot?.originalText)
        XCTAssertTrue(migrated.entries[0].isBaseline)
        XCTAssertEqual(migrated.entries[0].baselineReason, .initial)
        XCTAssertEqual(migrated.lineages.count, 1)
        XCTAssertEqual(migrated.activeLineage(for: firstID)?.lastEntryID, migrated.entries[0].snapshotID)
        XCTAssertNil(migrated.activeLineage(for: secondID))

        let reloaded = try service.loadOrMigrate(villages: villages, now: now.addingTimeInterval(10))
        XCTAssertEqual(reloaded.entries, migrated.entries)
        XCTAssertEqual(reloaded.lineages, migrated.lineages)
        XCTAssertEqual(reloaded.migrationMarker, migrated.migrationMarker)
        XCTAssertEqual(try store.load()?.entries.count, 1)
    }

    func testSameLineageDuplicateUpdatesMetadataWithoutAppendingImmutableEntry() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let base = snapshot(
            tag: firstTag,
            text: "{\"tag\":\"\(firstTag)\",\"buildings\":[]}",
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let envelope = try service.loadOrMigrate(
            villages: [VillageProfile(id: villageID, name: "主村", accountSnapshot: base)],
            now: Date(timeIntervalSince1970: 20)
        )

        let firstDuplicate = try service.planImport(
            snapshot: snapshot(
                tag: firstTag,
                text: "{\"buildings\":[],\"tag\":\"\(firstTag)\"}",
                capturedAt: Date(timeIntervalSince1970: 30)
            ),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: envelope,
            appliedAt: Date(timeIntervalSince1970: 31)
        )

        XCTAssertTrue(firstDuplicate.duplicate)
        XCTAssertFalse(firstDuplicate.appended)
        XCTAssertEqual(firstDuplicate.envelope.entries.count, 1)
        let entryID = firstDuplicate.entry.snapshotID.uuidString
        XCTAssertEqual(firstDuplicate.envelope.duplicateMetadata[entryID]?.duplicateImportCount, 1)
        XCTAssertEqual(
            firstDuplicate.envelope.duplicateMetadata[entryID]?.lastSourceTimestamp,
            Date(timeIntervalSince1970: 30)
        )

        let secondDuplicate = try service.planImport(
            snapshot: snapshot(
                tag: firstTag,
                text: "{\"tag\":\"\(firstTag)\",\"buildings\":[]}",
                capturedAt: Date(timeIntervalSince1970: 40)
            ),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: firstDuplicate.envelope,
            appliedAt: Date(timeIntervalSince1970: 41)
        )

        XCTAssertTrue(secondDuplicate.duplicate)
        XCTAssertEqual(secondDuplicate.envelope.entries.count, 1)
        XCTAssertEqual(secondDuplicate.envelope.duplicateMetadata[entryID]?.duplicateImportCount, 2)
        XCTAssertEqual(secondDuplicate.envelope.activeLineage(for: villageID)?.lastEntryID, entryID.asUUID)
    }

    func testCoverageProofChangeAppendsEntryInsteadOfHidingEvidenceChangeAsDuplicate() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let text = "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let base = snapshot(tag: firstTag, text: text)
        let envelope = try service.loadOrMigrate(
            villages: [VillageProfile(id: villageID, name: "主村", accountSnapshot: base)],
            now: Date(timeIntervalSince1970: 1),
            sectionProofs: [:]
        )

        let decision = try service.planImport(
            snapshot: base,
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: envelope,
            appliedAt: Date(timeIntervalSince1970: 2),
            sectionProofs: proof,
            sourceUniverse: testSourceUniverse(for: proof)
        )

        XCTAssertTrue(decision.appended)
        XCTAssertFalse(decision.duplicate)
        XCTAssertEqual(decision.envelope.entries.count, 2)
        let expectedProof = try XCTUnwrap(
            try SnapshotHistoryCanonicalizer.canonicalize(
                snapshot: base,
                villageID: villageID,
                lineageID: try XCTUnwrap(decision.envelope.activeLineage(for: villageID)?.lineageID),
                appliedAt: Date(timeIntervalSince1970: 2),
                sectionProofs: proof,
                sourceUniverse: testSourceUniverse(for: proof)
            ).coverage.section(base: .home, rawSection: "heroes")?.proof
        )
        XCTAssertEqual(
            decision.entry.coverage.section(base: .home, rawSection: "heroes")?.proof,
            expectedProof
        )
    }

    func testDuplicateKeyIgnoresParserVersionAndTimestamps() throws {
        let villageID = UUID()
        let lineageID = UUID()
        let base = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag, text: timerJSON(), capturedAt: Date(timeIntervalSince1970: 10)),
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 1),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let shifted = SnapshotHistoryEntry(
            schemaVersion: base.schemaVersion,
            observationVersion: base.observationVersion,
            fingerprintVersion: base.fingerprintVersion,
            integrityVersion: base.integrityVersion,
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            villageID: base.villageID,
            lineageID: base.lineageID,
            normalizedPlayerTag: base.normalizedPlayerTag,
            appliedAt: Date(timeIntervalSince1970: 99),
            sourceTimestamp: Date(timeIntervalSince1970: 50),
            parserVersion: "account-json-9.9",
            canonicalFingerprint: base.canonicalFingerprint,
            rawJSON: base.rawJSON,
            observation: base.observation,
            coverage: base.coverage,
            isBaseline: base.isBaseline,
            baselineReason: base.baselineReason,
            timerSchema: base.timerSchema
        )
        XCTAssertEqual(
            SnapshotHistoryDuplicateKey(entry: base),
            SnapshotHistoryDuplicateKey(entry: shifted),
            "parserVersion / appliedAt / sourceTimestamp 不是 Diff 语义，不得拆成新 snapshot"
        )
    }

    func testVerifiedCoverageSurvivesSaveReloadWithPersistedRevalidation() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let text = "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let base = snapshot(tag: firstTag, text: text)
        let live = try service.loadOrMigrate(
            villages: [VillageProfile(id: villageID, name: "主村", accountSnapshot: base)],
            now: Date(timeIntervalSince1970: 1),
            sectionProofs: [villageID: proof],
            sourceUniverses: testSourceUniverses(from: [villageID: proof])
        )
        let liveEntry = try XCTUnwrap(live.entries.first)
        XCTAssertEqual(live.entries.count, 1)
        let liveHeroes = try XCTUnwrap(liveEntry.coverage.section(base: .home, rawSection: "heroes"))
        XCTAssertTrue(liveHeroes.isComplete)
        if case .verified(let evidence) = liveHeroes.proof {
            XCTAssertEqual(evidence.runtimeWitness, .moduleIssued)
            XCTAssertEqual(evidence.verificationRuleVersion, "1")
            XCTAssertNotNil(evidence.inputBinding)
        } else {
            XCTFail("live entry 必须带 module-issued verified proof")
        }

        try store.save(live)
        let reloaded = try XCTUnwrap(try store.load())
        let decodedEntry = try XCTUnwrap(reloaded.entries.first)
        let reloadedHeroes = try XCTUnwrap(
            decodedEntry.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(reloadedHeroes.runtimeTrust, .trusted)
        XCTAssertTrue(reloadedHeroes.opensTrustGates)
        if case .verified(let evidence) = reloadedHeroes.proof {
            XCTAssertNil(evidence.runtimeWitness, "witness 仍不序列化；runtime trust 在 section 层")
            if case .verified(let liveEvidence) = liveHeroes.proof {
                XCTAssertEqual(evidence.inputBinding, liveEvidence.inputBinding)
            }
        } else {
            XCTFail("reloaded entry 必须保留 verified wire metadata")
        }
        XCTAssertTrue(reloadedHeroes.isComplete)
        XCTAssertEqual(
            SnapshotHistoryDuplicateKey(entry: liveEntry),
            SnapshotHistoryDuplicateKey(entry: decodedEntry)
        )

        let decision = try service.planImport(
            snapshot: base,
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: reloaded,
            appliedAt: Date(timeIntervalSince1970: 2),
            sectionProofs: proof,
            sourceUniverse: testSourceUniverse(for: proof)
        )
        XCTAssertTrue(decision.duplicate)
        XCTAssertFalse(decision.appended)
        XCTAssertEqual(decision.envelope.entries.count, 1)
    }

    func testRestartAcceptanceProjectionReportsVerifiedTrustAfterDoubleLoad() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let text = "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let base = snapshot(tag: firstTag, text: text)
        let live = try service.loadOrMigrate(
            villages: [VillageProfile(id: villageID, name: "主村", accountSnapshot: base)],
            now: Date(timeIntervalSince1970: 1),
            sectionProofs: [villageID: proof],
            sourceUniverses: testSourceUniverses(from: [villageID: proof])
        )
        try store.save(live)

        let firstReload = try XCTUnwrap(try store.load())
        try store.save(firstReload)
        let secondReload = try XCTUnwrap(try store.load())

        let projection = SnapshotHistoryProjection.project(
            envelope: secondReload,
            villageID: villageID,
            hasCurrentSnapshot: true,
            referenceDate: Date(timeIntervalSince1970: 2),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(projection.coverageTrustState, .verified)
        let heroes = try XCTUnwrap(
            secondReload.entries.first?.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(heroes.runtimeTrust, .trusted)
        XCTAssertTrue(heroes.opensTrustGates)
    }

    func testVerifiedCoverageWireDecodeWithoutLoadHydrationStaysFailClosed() throws {
        let villageID = UUID()
        let text = "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag, text: text),
            villageID: villageID,
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: proof,
            sourceUniverse: testSourceUniverse(for: proof)
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SnapshotHistoryEntry.self, from: data)
        let heroes = try XCTUnwrap(decoded.coverage.section(base: .home, rawSection: "heroes"))
        if case .verified(let evidence) = heroes.proof {
            XCTAssertNil(evidence.runtimeWitness, "裸 decode 不得直接恢复 runtime witness")
            XCTAssertEqual(heroes.runtimeTrust, .pending)
            XCTAssertEqual(heroes.verifiedPersistedTrust, .pendingRevalidation)
        } else {
            XCTFail("wire metadata 应保留")
        }
        XCTAssertFalse(heroes.isComplete)
        XCTAssertEqual(decoded.coverage.sourceUniverseRuntimeTrust, .pending)
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: decoded.coverage),
            .pendingRevalidation
        )
    }

    func testSourceUniverseRequiresObservationV6AtCanonicalize() throws {
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        XCTAssertThrowsError(
            try SnapshotHistoryCanonicalizer.canonicalize(
                snapshot: snapshot(
                    tag: firstTag,
                    text: "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
                ),
                villageID: UUID(),
                lineageID: UUID(),
                appliedAt: Date(timeIntervalSince1970: 1),
                sectionProofs: proof,
                sourceUniverse: testSourceUniverse(for: proof),
                observationVersion: SnapshotHistorySchema.observationWithoutCoverageMetadata
            )
        ) { error in
            XCTAssertEqual(
                error as? SnapshotHistoryCanonicalizationError,
                .sourceUniverseRequiresObservationV6
            )
        }
    }

    func testTamperedSourceUniverseShrinksRequiredSectionsFailsTrustProjection() throws {
        let text = "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}],\"buildings\":[{\"data\":1,\"lvl\":1}]}"
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1),
            "buildings": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let live = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag, text: text),
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: proof,
            sourceUniverse: testSourceUniverse(for: proof)
        )
        let decoded = try JSONDecoder().decode(
            SnapshotHistoryEntry.self,
            from: try JSONEncoder().encode(live)
        )
        let tamperedUniverse = SnapshotCoverageSourceUniverse(
            adapterID: SnapshotCoverageVerifier.testFixtureAdapterID,
            protocolVersion: "1",
            sections: SnapshotHistoryTestCoverage.testFixtureUniverse(
                requiredSections: ["heroes"]
            ).sections
        )
        let tamperedCoverage = SnapshotObservationCoverage(
            schemaVersion: decoded.coverage.schemaVersion,
            fields: decoded.coverage.fields,
            sections: decoded.coverage.sections.map { section in
                SnapshotSectionCoverage(
                    base: section.base,
                    rawSection: section.rawSection,
                    presence: section.presence,
                    completeness: section.completeness,
                    proof: section.proof,
                    observedCount: section.observedCount,
                    runtimeTrust: .trusted
                )
            },
            diagnostics: decoded.coverage.diagnostics,
            sourceUniverse: tamperedUniverse
        )
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: tamperedCoverage),
            .pendingRevalidation
        )
        let hydrated = SnapshotCoverageTrustHydration.hydrate(
            coverage: tamperedCoverage,
            rawJSON: text,
            policy: .testsAllowTestFixture
        )
        if case .rejected = hydrated.sourceUniverseRuntimeTrust {
            XCTAssertTrue(true)
        } else {
            XCTFail("tampered universe 应被拒绝")
        }
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: hydrated),
            .insufficientCoverage
        )
    }

    func testVerifiedCoverageTamperedBindingFailsRevalidation() throws {
        let text = "{\"tag\":\"#ABC123\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: "#ABC123", text: text),
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: proof,
            sourceUniverse: testSourceUniverse(for: proof)
        )
        guard case .verified(let evidence) = entry.coverage.section(
            base: .home,
            rawSection: "heroes"
        )?.proof else {
            return XCTFail("expected verified proof")
        }
        let trust = SnapshotCoverageProofRevalidators.revalidate(
            evidence: evidence,
            rawJSON: text,
            section: "heroes",
            policy: .testsAllowTestFixture
        )
        XCTAssertEqual(trust, .trusted)
        let tamperedEvidence = VerifiedCoverageEvidence(
            decodedWire: evidence.source,
            adapterID: evidence.adapterID,
            protocolVersion: evidence.protocolVersion,
            expectedCount: evidence.expectedCount,
            verificationReason: evidence.verificationReason,
            verificationRuleVersion: evidence.verificationRuleVersion,
            inputBinding: "sha256:deadbeef"
        )
        let tamperedTrust = SnapshotCoverageProofRevalidators.revalidate(
            evidence: tamperedEvidence,
            rawJSON: text,
            section: "heroes",
            policy: .testsAllowTestFixture
        )
        if case .rejected = tamperedTrust {
            XCTAssertTrue(true)
        } else {
            XCTFail("篡改 binding 后 revalidation 必须 fail-closed")
        }
    }

    func testLegacyVerifiedWireWithoutPersistedEvidenceStaysFailClosed() throws {
        let json = """
        {"kind":"verified","source":"test-export","adapterID":"test-fixture","protocolVersion":"1","expectedCount":1,"verificationReason":"legacy"}
        """.data(using: .utf8)!
        let proof = try JSONDecoder().decode(SnapshotCoverageProof.self, from: json)
        guard case .verified(let evidence) = proof else {
            return XCTFail("expected verified wire")
        }
        let trust = SnapshotCoverageProofRevalidators.revalidate(
            evidence: evidence,
            rawJSON: "{\"heroes\":[{\"data\":1,\"lvl\":1}]}",
            section: "heroes",
            policy: .testsAllowTestFixture
        )
        if case .rejected = trust {
            XCTAssertTrue(true)
        } else {
            XCTFail("legacy wire 缺 persisted 材料不得恢复 trust")
        }
        XCTAssertFalse(proof.isVerified)
    }

    func testProductionLoadRejectsTestFixtureVerifiedHistoryEvenWithValidBinding() throws {
        let text = "{\"tag\":\"#ABC123\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: "#ABC123", text: text),
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: proof,
            sourceUniverse: testSourceUniverse(for: proof)
        )
        let raw = try JSONEncoder().encode(entry)
        let decodedEntry = try JSONDecoder().decode(SnapshotHistoryEntry.self, from: raw)
        let envelope = try SnapshotHistoryEnvelope(
            entries: [decodedEntry],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: entry.villageID,
                    lineageID: entry.lineageID,
                    normalizedPlayerTag: entry.normalizedPlayerTag,
                    lastEntryID: entry.snapshotID,
                    lastFingerprint: entry.canonicalFingerprint,
                    lastAppliedAt: entry.appliedAt,
                    hasConflict: false
                )
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: Date(timeIntervalSince1970: 1))
        ).validated()
        let hydrated = envelope.hydratingVerifiedCoverage(policy: .production)
        let heroes = try XCTUnwrap(
            hydrated.entries.first?.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertTrue(heroes.proof.hasVerifiedWireMetadata)
        XCTAssertFalse(heroes.opensTrustGates)
        if case .rejected = heroes.runtimeTrust {
            XCTAssertTrue(true)
        } else {
            XCTFail("production load 不得信任 test-fixture verified metadata")
        }
    }

    func testProductionLoadRejectsForgedPerfFixtureWithoutBundledProvenance() throws {
        let text = "{\"tag\":\"#ABC123\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let binding = try XCTUnwrap(
            SnapshotCoverageTrustHydration.sectionInputBinding(rawJSON: text, section: "heroes")
        )
        let proof: SnapshotCoverageProof = .verified(
            VerifiedCoverageEvidence(
                decodedWire: SnapshotCoverageVerifier.perfFixtureAdapterID,
                adapterID: SnapshotCoverageVerifier.perfFixtureAdapterID,
                protocolVersion: "1",
                expectedCount: 1,
                verificationReason: "bundled perf fixture",
                verificationRuleVersion: "1",
                inputBinding: binding
            )
        )
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: "#ABC123", text: text),
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: [:]
        )
        let forgedCoverage = SnapshotObservationCoverage(
            schemaVersion: entry.coverage.schemaVersion,
            fields: entry.coverage.fields,
            sections: entry.coverage.sections.map { section in
                guard section.rawSection == "heroes" else { return section }
                return SnapshotSectionCoverage(
                    base: section.base,
                    rawSection: section.rawSection,
                    presence: .presentNonEmpty,
                    completeness: .complete,
                    proof: proof,
                    observedCount: 1
                )
            },
            diagnostics: entry.coverage.diagnostics
        )
        let forgedEntry = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            fingerprintVersion: entry.fingerprintVersion,
            integrityVersion: entry.integrityVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: entry.canonicalFingerprint,
            rawJSON: text,
            observation: entry.observation,
            coverage: forgedCoverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
        let raw = try JSONEncoder().encode(forgedEntry)
        let decodedEntry = try JSONDecoder().decode(SnapshotHistoryEntry.self, from: raw)
        let envelope = try SnapshotHistoryEnvelope(
            entries: [decodedEntry],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: forgedEntry.villageID,
                    lineageID: forgedEntry.lineageID,
                    normalizedPlayerTag: forgedEntry.normalizedPlayerTag,
                    lastEntryID: forgedEntry.snapshotID,
                    lastFingerprint: forgedEntry.canonicalFingerprint,
                    lastAppliedAt: forgedEntry.appliedAt,
                    hasConflict: false
                )
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: Date(timeIntervalSince1970: 1))
        ).validated()
        let hydrated = envelope.hydratingVerifiedCoverage(policy: .production)
        let heroes = try XCTUnwrap(
            hydrated.entries.first?.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertFalse(heroes.opensTrustGates)
        if case .rejected = heroes.runtimeTrust {
            XCTAssertTrue(true)
        } else {
            XCTFail("非 bundled perf fixture 不得恢复 perf-fixture trust")
        }
    }

    func testFailedProductionRevalidationPreservesPersistedEvidenceAndSaveRoundTrip() throws {
        let store = TestSnapshotHistoryStore()
        let villageID = UUID()
        let text = "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let live = try SnapshotHistoryService(store: store).loadOrMigrate(
            villages: [VillageProfile(id: villageID, name: "主村", accountSnapshot: snapshot(tag: firstTag, text: text))],
            now: Date(timeIntervalSince1970: 1),
            sectionProofs: [villageID: proof],
            sourceUniverses: testSourceUniverses(from: [villageID: proof])
        )
        try store.save(live)
        let raw = try XCTUnwrap(store.readRawData())
        let decodedEnvelope = try JSONDecoder().decode(SnapshotHistoryEnvelope.self, from: raw).validated()
        let productionHydrated = decodedEnvelope.hydratingVerifiedCoverage(policy: .production)
        let heroes = try XCTUnwrap(
            productionHydrated.entries.first?.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertTrue(heroes.proof.hasVerifiedWireMetadata)
        XCTAssertFalse(heroes.opensTrustGates)
        let productionCoverage = try XCTUnwrap(productionHydrated.entries.first?.coverage)
        if case .rejected = productionCoverage.sourceUniverseRuntimeTrust {
            XCTAssertTrue(true)
        } else {
            XCTFail("production load 不得恢复 test-fixture source universe")
        }
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(coverage: productionCoverage),
            .insufficientCoverage
        )
        try store.save(productionHydrated)
        let reloaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(
            reloaded.entries.first?.integrityFingerprint,
            productionHydrated.entries.first?.integrityFingerprint
        )
        let testReloadedHeroes = try XCTUnwrap(
            reloaded.entries.first?.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(testReloadedHeroes.runtimeTrust, .trusted)
        XCTAssertTrue(testReloadedHeroes.opensTrustGates)
    }

    func testTimerSchemaVersionChangeAppendsAndKeepsOldEntryImmutable() throws {
        try assertSchemaChangeAppends(
            previousSchema: timerSchema(version: "account-json-timer-0"),
            expectedNewSchema: AccountSnapshotImporter.timerSchema
        )
    }

    func testTimerUnitChangeAppendsInsteadOfDuplicate() throws {
        try assertSchemaChangeAppends(
            previousSchema: timerSchema(version: "account-json-timer-ms", unit: .milliseconds)
        )
    }

    func testTimerSemanticsChangeAppendsInsteadOfDuplicate() throws {
        try assertSchemaChangeAppends(
            previousSchema: timerSchema(version: "account-json-timer-abs", semantics: .absolute)
        )
    }

    func testTimerRangeChangeAppendsEvenWhenCurrentValuesRemainValid() throws {
        try assertSchemaChangeAppends(
            previousSchema: timerSchema(version: "account-json-timer-capped", maxValue: 10_000)
        )
    }

    func testLegacyV3EntryDoesNotReceiveCurrentTimerSchemaOnReimport() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let lineageID = UUID()
        let raw = timerJSON()
        let v3 = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag, text: raw, capturedAt: Date(timeIntervalSince1970: 100)),
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 1),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            isBaseline: true,
            baselineReason: .initial,
            observationVersion: 3
        )
        XCTAssertNil(v3.timerSchema)
        XCTAssertEqual(v3.observationVersion, 3)

        let decision = try service.planImport(
            snapshot: snapshot(tag: firstTag, text: raw, capturedAt: Date(timeIntervalSince1970: 100)),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: migratedEnvelope(for: v3),
            appliedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertTrue(decision.appended)
        XCTAssertFalse(decision.duplicate)
        XCTAssertEqual(decision.envelope.entries.count, 2)
        XCTAssertNil(decision.envelope.entries[0].timerSchema)
        XCTAssertEqual(decision.envelope.entries[0].observationVersion, 3)
        XCTAssertEqual(decision.envelope.entries[1].timerSchema, AccountSnapshotImporter.timerSchema)
        XCTAssertEqual(decision.envelope.entries[1].observationVersion, SnapshotHistorySchema.observation)
    }

    func testProvenanceOnlyAppendDoesNotFabricateUpgradeThenAllowsLaterContentDiff() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let lineageID = UUID()
        let heroProof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let previousSchema = timerSchema(version: "account-json-timer-ms", unit: .milliseconds)
        let previous = try canonicalizeTimerEntry(
            villageID: villageID,
            lineageID: lineageID,
            schema: previousSchema,
            json: timerJSON(level: 1),
            sectionProofs: heroProof,
            sourceUniverse: testSourceUniverse(for: heroProof)
        )
        let provenance = try service.planImport(
            snapshot: snapshot(tag: firstTag, text: timerJSON(level: 1), capturedAt: Date(timeIntervalSince1970: 100)),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: migratedEnvelope(for: previous),
            appliedAt: Date(timeIntervalSince1970: 2),
            sectionProofs: heroProof,
            sourceUniverse: testSourceUniverse(for: heroProof)
        )
        XCTAssertTrue(provenance.appended)
        XCTAssertEqual(provenance.envelope.entries[0].timerSchema, previousSchema)

        let diffs = SnapshotDiffEngine.adjacentDiffs(in: provenance.envelope)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertTrue(diffs[0].changes.isEmpty, "provenance-only append 不得伪造 level/timer change")
        XCTAssertEqual(diffs[0].comparisonState, .provenanceOnly)
        XCTAssertEqual(diffs[0].diagnostics.filter { $0.kind == .incomparableTimerSchema }.count, 1)

        let projection = SnapshotHistoryProjection.project(
            envelope: provenance.envelope.hydratingVerifiedCoverage(policy: .production),
            villageID: villageID,
            hasCurrentSnapshot: true,
            referenceDate: Date(timeIntervalSince1970: 2),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(projection.timeline[0].summary, "来源信息变化，无业务变化")
        XCTAssertFalse(projection.timeline[0].changes.contains { $0.changeKind == .levelIncreased || $0.changeKind == .upgradeCompleted })
        XCTAssertEqual(projection.statistics.today.heroLevelGrowth.state, .available)
        XCTAssertEqual(projection.statistics.today.heroLevelGrowth.value, 0)

        let content = try service.planImport(
            snapshot: snapshot(tag: firstTag, text: timerJSON(level: 2), capturedAt: Date(timeIntervalSince1970: 100)),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: provenance.envelope,
            appliedAt: Date(timeIntervalSince1970: 3)
        )
        XCTAssertTrue(content.appended)
        XCTAssertEqual(content.envelope.entries.count, 3)
        let contentDiff = SnapshotDiffEngine.compare(
            from: content.envelope.entries[1],
            to: content.envelope.entries[2]
        )
        XCTAssertEqual(contentDiff.changes.count, 1)
        XCTAssertEqual(contentDiff.changes.first?.changeKind, .levelIncreased)
        XCTAssertEqual(content.envelope.entries[1].timerSchema, AccountSnapshotImporter.timerSchema)
        XCTAssertEqual(content.envelope.entries[2].timerSchema, AccountSnapshotImporter.timerSchema)
    }

    func testProvenanceOnlyDiffAndStatisticsStableAcrossSaveLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-ProvenanceSaveLoad-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSnapshotHistoryStore(fileURL: url)
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let lineageID = UUID()
        let heroProof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let previousSchema = timerSchema(version: "account-json-timer-ms", unit: .milliseconds)
        let previous = try canonicalizeTimerEntry(
            villageID: villageID,
            lineageID: lineageID,
            schema: previousSchema,
            json: timerJSON(level: 1),
            sectionProofs: heroProof,
            sourceUniverse: testSourceUniverse(for: heroProof)
        )
        let provenance = try service.planImport(
            snapshot: snapshot(tag: firstTag, text: timerJSON(level: 1), capturedAt: Date(timeIntervalSince1970: 100)),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: migratedEnvelope(for: previous),
            appliedAt: Date(timeIntervalSince1970: 2),
            sectionProofs: heroProof,
            sourceUniverse: testSourceUniverse(for: heroProof)
        )
        let beforeEnvelope = try productionHydratedEnvelope(provenance.envelope)
        let beforeDiffs = SnapshotDiffEngine.adjacentDiffs(in: beforeEnvelope.entries)
        let beforeStats = SnapshotHistoryStatistics.calculate(
            diffs: beforeDiffs,
            referenceDate: Date(timeIntervalSince1970: 2),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        try store.save(provenance.envelope.validated())
        let afterEnvelope = try XCTUnwrap(try store.load())
        let afterDiffs = SnapshotDiffEngine.adjacentDiffs(in: afterEnvelope.entries)
        let afterStats = SnapshotHistoryStatistics.calculate(
            diffs: afterDiffs,
            referenceDate: Date(timeIntervalSince1970: 2),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(beforeDiffs, afterDiffs)
        XCTAssertEqual(beforeDiffs.count, 1)
        XCTAssertEqual(beforeDiffs.first?.comparisonState, .provenanceOnly)
        XCTAssertEqual(afterDiffs.first?.comparisonState, .provenanceOnly)
        XCTAssertEqual(beforeStats, afterStats)
    }

    private func productionHydratedEnvelope(
        _ envelope: SnapshotHistoryEnvelope
    ) throws -> SnapshotHistoryEnvelope {
        let data = try envelope.validated().encodedData()
        let decoded = try JSONDecoder().decode(SnapshotHistoryEnvelope.self, from: data)
        return try decoded.validated().hydratingVerifiedCoverage(policy: .production)
    }

    func testChangedContentAppendsAndTagChangeStartsNewActiveLineage() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let envelope = try service.loadOrMigrate(
            villages: [VillageProfile(
                id: villageID,
                name: "主村",
                accountSnapshot: snapshot(tag: firstTag, text: "{\"buildings\":[]}")
            )],
            now: Date(timeIntervalSince1970: 1)
        )

        let changed = try service.planImport(
            snapshot: snapshot(tag: firstTag, text: "{\"buildings\":[],\"unknown\":1}"),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: envelope,
            appliedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertTrue(changed.appended)
        XCTAssertFalse(changed.duplicate)
        XCTAssertEqual(changed.envelope.entries.count, 2)
        XCTAssertEqual(changed.lineage.outcome, .continued)
        XCTAssertEqual(changed.envelope.activeLineage(for: villageID)?.lineageID, envelope.activeLineage(for: villageID)?.lineageID)

        let reverted = try service.planImport(
            snapshot: snapshot(tag: firstTag, text: "{\"buildings\":[]}"),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: changed.envelope,
            appliedAt: Date(timeIntervalSince1970: 2.5)
        )
        XCTAssertTrue(reverted.appended, "A→B→A 必须保留第三条 immutable entry")
        XCTAssertEqual(reverted.envelope.entries.count, 3)
        XCTAssertEqual(reverted.lineage.outcome, .continued)

        let changedTag = try service.planImport(
            snapshot: snapshot(tag: secondTag, text: "{\"buildings\":[],\"unknown\":2}"),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: reverted.envelope,
            appliedAt: Date(timeIntervalSince1970: 3)
        )
        XCTAssertTrue(changedTag.appended)
        XCTAssertEqual(changedTag.lineage.outcome, .newLineage)
        XCTAssertEqual(changedTag.envelope.entries.count, 4)
        XCTAssertEqual(changedTag.envelope.lineages.filter(\.isActive).count, 1)
        XCTAssertEqual(changedTag.envelope.activeLineage(for: villageID)?.normalizedPlayerTag, secondTag)
        XCTAssertNotEqual(changedTag.envelope.activeLineage(for: villageID)?.lineageID, changed.envelope.activeLineage(for: villageID)?.lineageID)
    }

    func testCurrentTagMismatchFailsClosedBeforeCanonicalizingImport() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let envelope = try service.loadOrMigrate(
            villages: [VillageProfile(
                id: villageID,
                name: "主村",
                accountSnapshot: snapshot(tag: firstTag)
            )],
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertThrowsError(try service.planImport(
            snapshot: snapshot(tag: firstTag, text: "{\"unknown\":1}"),
            villageID: villageID,
            currentTag: secondTag,
            hasCurrentSnapshot: true,
            envelope: envelope,
            appliedAt: Date(timeIntervalSince1970: 2)
        )) { error in
            XCTAssertEqual(
                error as? SnapshotHistoryServiceError,
                .lineageConflict("当前村庄 Tag 与历史 active lineage 不一致。")
            )
        }
    }

    func testVillageIDKeepsIdenticalTagsAndFingerprintsInSeparateHistories() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let firstID = UUID()
        let secondID = UUID()
        let sameSnapshot = snapshot(tag: firstTag, text: "{\"buildings\":[]}")
        let envelope = try service.loadOrMigrate(
            villages: [
                VillageProfile(id: firstID, name: "村庄 A", accountSnapshot: sameSnapshot),
                VillageProfile(id: secondID, name: "村庄 B", accountSnapshot: sameSnapshot)
            ],
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(envelope.entries.count, 2)
        XCTAssertEqual(envelope.lineages.count, 2)
        XCTAssertEqual(Set(envelope.entries.map(\.villageID)), Set([firstID, secondID]))

        let updated = try service.planImport(
            snapshot: snapshot(tag: firstTag, text: "{\"buildings\":[],\"unknown\":1}"),
            villageID: firstID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: envelope,
            appliedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertTrue(updated.appended)
        XCTAssertEqual(updated.envelope.entries.filter { $0.villageID == firstID }.count, 2)
        XCTAssertEqual(updated.envelope.entries.filter { $0.villageID == secondID }.count, 1)
        XCTAssertEqual(updated.envelope.activeLineage(for: secondID)?.lastAppliedAt, Date(timeIntervalSince1970: 1))
    }

    func testMissingTagStartsUnknownLineageAndDoesNotJoinKnownTag() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let envelope = try service.loadOrMigrate(
            villages: [VillageProfile(
                id: villageID,
                name: "主村",
                accountSnapshot: snapshot(tag: firstTag, text: "{\"buildings\":[]}")
            )],
            now: Date(timeIntervalSince1970: 1)
        )

        let decision = try service.planImport(
            snapshot: snapshot(tag: nil, text: "{\"buildings\":[],\"unknown\":1}"),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: envelope,
            appliedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertTrue(decision.appended)
        XCTAssertEqual(decision.lineage.reason, .missingTag)
        XCTAssertFalse(decision.lineage.comparisonAllowed)
        XCTAssertTrue(decision.envelope.activeLineage(for: villageID)?.hasConflict == true)
        XCTAssertNotEqual(decision.entry.lineageID, envelope.activeLineage(for: villageID)?.lineageID)
    }

    func testFileStorePreservesCorruptBytesAndRejectsUnsupportedSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-SnapshotHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSnapshotHistoryStore(fileURL: url)
        let corrupt = Data("not-json".utf8)
        try store.writeRawData(corrupt)

        XCTAssertThrowsError(try store.load()) { error in
            guard case .corrupt = error as? SnapshotHistoryStoreError else {
                return XCTFail("损坏文件应被拒绝，实际为 \(error)")
            }
        }
        XCTAssertEqual(try store.readRawData(), corrupt)

        let unsupported = try JSONEncoder().encode(SnapshotHistoryEnvelope(schemaVersion: 2))
        try store.writeRawData(unsupported)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? SnapshotHistoryStoreError, .unsupportedSchema(2))
        }
    }

    func testMissingEntryAndInvalidFingerprintNeverBecomeAnEmptyHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-SnapshotHistoryInvalidEntryTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSnapshotHistoryStore(fileURL: url)
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag),
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1)
        )
        let marker = SnapshotHistoryMigrationMarker(completedAt: Date(timeIntervalSince1970: 1))

        let invalidFingerprint = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            fingerprintVersion: entry.fingerprintVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: "not-a-sha256",
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason
        )
        try store.writeRawData(try JSONEncoder().encode(SnapshotHistoryEnvelope(
            entries: [invalidFingerprint],
            migrationMarker: marker
        )))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? SnapshotHistoryStoreError,
                .invalidEntry("历史 entry 的 fingerprint 格式无效。")
            )
        }

        let legalButWrongFingerprint = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            fingerprintVersion: entry.fingerprintVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: "sha256:" + String(repeating: "0", count: 64),
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason
        )
        try store.writeRawData(try JSONEncoder().encode(SnapshotHistoryEnvelope(
            entries: [legalButWrongFingerprint],
            migrationMarker: marker
        )))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? SnapshotHistoryStoreError,
                .invalidEntry("历史 entry 的 observation 与 canonicalFingerprint 不一致。")
            )
        }

        let tamperedRawJSON = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            fingerprintVersion: entry.fingerprintVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: entry.canonicalFingerprint,
            rawJSON: "{\"buildings\":[],\"unknown\":1}",
            observation: entry.observation,
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason
        )
        try store.writeRawData(try JSONEncoder().encode(SnapshotHistoryEnvelope(
            entries: [tamperedRawJSON],
            migrationMarker: marker
        )))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? SnapshotHistoryStoreError,
                .invalidEntry("历史 entry 的 rawJSON 与 canonicalFingerprint 不一致。")
            )
        }

        let unsupportedFingerprintVersion = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            fingerprintVersion: 2,
            snapshotID: UUID(),
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: entry.canonicalFingerprint,
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason
        )
        try store.writeRawData(try JSONEncoder().encode(SnapshotHistoryEnvelope(
            entries: [unsupportedFingerprintVersion],
            migrationMarker: marker
        )))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? SnapshotHistoryStoreError, .unsupportedSchema(2))
        }

        let missingEntry = Data("""
        {
          "schemaVersion": 1,
          "entries": [{}],
          "lineages": [],
          "duplicateMetadata": {},
          "migrationMarker": {"version": 1, "completedAt": 1},
          "lastDiagnostic": null
        }
        """.utf8)
        try store.writeRawData(missingEntry)
        XCTAssertThrowsError(try store.load()) { error in
            guard case .corrupt = error as? SnapshotHistoryStoreError else {
                return XCTFail("缺字段 entry 应被视为损坏，实际为 \(error)")
            }
        }
        XCTAssertEqual(try store.readRawData(), missingEntry)
    }

    func testLegacyObservationVersionRemainsReadableWithoutSectionProof() throws {
        let store = TestSnapshotHistoryStore()
        let current = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(
                tag: firstTag,
                text: "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
            ),
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            observationVersion: 1
        )
        let legacyCoverage = SnapshotObservationCoverage(
            schemaVersion: 1,
            fields: current.coverage.fields,
            sections: [],
            diagnostics: current.coverage.diagnostics
        )
        let legacyObservation = CanonicalSnapshotObservation(
            schemaVersion: 1,
            rawTopLevelFields: current.observation.rawTopLevelFields,
            unknownTopLevelFields: current.observation.unknownTopLevelFields,
            items: current.observation.items
        )
        let legacy = SnapshotHistoryEntry(
            observationVersion: 1,
            snapshotID: current.snapshotID,
            villageID: current.villageID,
            lineageID: current.lineageID,
            normalizedPlayerTag: current.normalizedPlayerTag,
            appliedAt: current.appliedAt,
            sourceTimestamp: current.sourceTimestamp,
            parserVersion: current.parserVersion,
            canonicalFingerprint: SnapshotHistoryCanonicalizer.fingerprint(for: legacyObservation),
            rawJSON: current.rawJSON,
            observation: legacyObservation,
            coverage: legacyCoverage,
            isBaseline: current.isBaseline,
            baselineReason: current.baselineReason
        )
        let envelope = SnapshotHistoryEnvelope(
            entries: [legacy],
            lineages: [SnapshotHistoryLineageMetadata(
                villageID: legacy.villageID,
                lineageID: legacy.lineageID,
                normalizedPlayerTag: legacy.normalizedPlayerTag,
                lastEntryID: legacy.snapshotID,
                lastFingerprint: legacy.canonicalFingerprint,
                lastAppliedAt: legacy.appliedAt,
                hasConflict: false
            )],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: legacy.appliedAt)
        )

        let encoded = try envelope.encodedData()
        // The v1 entry must serialize in the exact legacy shape: no `sections`
        // key anywhere, so stored bytes and integrity digests stay identical
        // to the format written by the pre-164 build.
        let rawJSONString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(rawJSONString.contains("\"sections\""))
        try store.writeRawData(encoded)
        let restored = try XCTUnwrap(try store.load())
        let restoredEntry = try XCTUnwrap(restored.entries.first)

        XCTAssertEqual(restoredEntry.observationVersion, 1)
        XCTAssertTrue(restoredEntry.coverage.hasLegacySectionCoverage)
        XCTAssertNil(restoredEntry.coverage.section(base: .home, rawSection: "heroes"))
    }

    func testObservationVersionTwoEntryWithUnknownTimerFieldsSurvivesReload() throws {
        // Issue #175 review P1：v2 历史 entry 由宽松匹配保存，可能包含
        // 未知 timer-like 字段。升级后 load() 必须按 entry 的 observationVersion
        // 用旧规则重建，否则 rawJSON 与 canonicalFingerprint 校验会拒绝加载。
        let store = TestSnapshotHistoryStore()
        let raw = "{\"tag\":\"\(firstTag)\",\"timestamp\":100,\"buildings\":[{\"data\":1,\"lvl\":2,\"timer\":90,\"timer_state\":\"upgrading\"}]}"
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag, text: raw),
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333331")!,
            observationVersion: 2
        )
        XCTAssertEqual(
            entry.observation.items.first?.rawTimerEvidence["timer_state"],
            .string("upgrading"),
            "前置条件：v2 语义必须把未知字段收进 rawTimerEvidence"
        )
        let envelope = SnapshotHistoryEnvelope(
            entries: [entry],
            lineages: [SnapshotHistoryLineageMetadata(
                villageID: entry.villageID,
                lineageID: entry.lineageID,
                normalizedPlayerTag: entry.normalizedPlayerTag,
                lastEntryID: entry.snapshotID,
                lastFingerprint: entry.canonicalFingerprint,
                lastAppliedAt: entry.appliedAt,
                hasConflict: false
            )],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: entry.appliedAt)
        )

        try store.writeRawData(envelope.encodedData())
        let restored = try XCTUnwrap(try store.load())
        XCTAssertEqual(restored.entries.first?.observationVersion, 2)
        XCTAssertEqual(restored.entries.first?.canonicalFingerprint, entry.canonicalFingerprint)
    }

    func testObservationVersionFourEntryWithSchemaSurvivesReload() throws {
        // Issue #175：v4 entry 冻结 timer schema 契约；load 校验重建时
        // 必须用 entry 内冻结的契约（而非当前默认契约），fingerprint 稳定。
        let store = TestSnapshotHistoryStore()
        let raw = "{\"tag\":\"\(firstTag)\",\"timestamp\":100,\"buildings\":[{\"data\":1,\"lvl\":2,\"timer\":90,\"helper_timer\":30,\"timer_state\":\"upgrading\"}]}"
        let schema = SnapshotTimerSchema(
            version: "account-json-timer-1",
            fields: [
                "timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining),
                "helper_timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining)
            ]
        )
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag, text: raw),
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333331")!,
            observationVersion: SnapshotHistorySchema.observationWithTimerSchema,
            timerSchema: schema
        )
        XCTAssertEqual(entry.observationVersion, SnapshotHistorySchema.observationWithTimerSchema)
        XCTAssertEqual(entry.timerSchema, schema)
        XCTAssertNil(entry.observation.items.first?.rawTimerEvidence["timer_state"])
        let envelope = SnapshotHistoryEnvelope(
            entries: [entry],
            lineages: [SnapshotHistoryLineageMetadata(
                villageID: entry.villageID,
                lineageID: entry.lineageID,
                normalizedPlayerTag: entry.normalizedPlayerTag,
                lastEntryID: entry.snapshotID,
                lastFingerprint: entry.canonicalFingerprint,
                lastAppliedAt: entry.appliedAt,
                hasConflict: false
            )],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: entry.appliedAt)
        )

        try store.writeRawData(envelope.encodedData())
        let restored = try XCTUnwrap(try store.load())
        XCTAssertEqual(restored.entries.first?.timerSchema, schema)
        XCTAssertEqual(restored.entries.first?.canonicalFingerprint, entry.canonicalFingerprint)
    }

    func testObservationVersionFourCoverageEntrySurvivesReload() throws {
        let store = TestSnapshotHistoryStore()
        let envelope = try makePreIssue218V4CoverageEnvelope()
        let entry = envelope.entries[0]
        XCTAssertEqual(entry.observationVersion, SnapshotHistorySchema.observationWithTimerSchema)
        XCTAssertNotNil(entry.observation.unknownTopLevelFields["coverage"])
        XCTAssertNotNil(entry.observation.rawTopLevelFields["coverage"])

        try store.writeRawData(envelope.encodedData())
        let restored = try XCTUnwrap(try store.load())
        XCTAssertEqual(restored.entries.first?.observationVersion, 4)
        XCTAssertEqual(restored.entries.first?.canonicalFingerprint, entry.canonicalFingerprint)
        XCTAssertNotNil(restored.entries.first?.observation.unknownTopLevelFields["coverage"])
    }

    func testPreIssue218V4CoverageFixtureSurvivesUpgrade() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "history_v4_coverage_entry", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let store = TestSnapshotHistoryStore()
        try store.writeRawData(data)

        let restored = try XCTUnwrap(try store.load())
        let entry = try XCTUnwrap(restored.entries.first)
        XCTAssertEqual(entry.observationVersion, 4)
        XCTAssertEqual(
            entry.canonicalFingerprint,
            "sha256:795c19ff99cf854725e1b23205c8c5e247f2b8df721030c03f3c95061c10c777"
        )
        XCTAssertNotNil(entry.observation.unknownTopLevelFields["coverage"])
        XCTAssertNotNil(entry.observation.rawTopLevelFields["coverage"])
        XCTAssertTrue(entry.coverage.fields.contains {
            $0.base == .unknown && $0.rawSection == "$topLevel" && $0.field == "coverage"
        })
        XCTAssertTrue(entry.rawJSON.contains("\"coverage\""))
        XCTAssertEqual(
            entry.coverage.section(base: .home, rawSection: "buildings")?.proof,
            .declared(source: "u.coc", version: "1", expectedCount: 1)
        )
    }

    func testV5IdenticalBuildingsDifferentCoverageDeclarationAppends() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let without = snapshot(
            tag: firstTag,
            text: "{\"tag\":\"\(firstTag)\",\"buildings\":[{\"data\":1,\"lvl\":1}]}"
        )
        let withCoverage = snapshot(
            tag: firstTag,
            text: """
            {"tag":"\(firstTag)","buildings":[{"data":1,"lvl":1}],\
            "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
            """
        )
        let envelope = try service.loadOrMigrate(
            villages: [VillageProfile(id: villageID, name: "主村", accountSnapshot: without)],
            now: Date(timeIntervalSince1970: 1)
        )
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: withCoverage)
        let decision = try service.planImport(
            snapshot: withCoverage,
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: envelope,
            appliedAt: Date(timeIntervalSince1970: 2),
            sectionProofs: proofs
        )

        XCTAssertEqual(envelope.entries.first?.observationVersion, SnapshotHistorySchema.observation)
        XCTAssertTrue(decision.appended)
        XCTAssertFalse(decision.duplicate)
        XCTAssertEqual(decision.envelope.entries.count, 2)
        XCTAssertEqual(
            envelope.entries.first?.canonicalFingerprint,
            decision.entry.canonicalFingerprint
        )
        XCTAssertNotEqual(envelope.entries.first?.coverage, decision.entry.coverage)
        XCTAssertNotEqual(
            SnapshotHistoryDuplicateKey(entry: try XCTUnwrap(envelope.entries.first)),
            SnapshotHistoryDuplicateKey(entry: decision.entry)
        )
        XCTAssertEqual(
            decision.entry.coverage.section(base: .home, rawSection: "buildings")?.proof,
            .declared(source: "u.coc", version: "1", expectedCount: 1)
        )
    }

    func testLegacyAuthoritativeProofPreservesIntegrityFingerprintOnLoad() throws {
        let store = TestSnapshotHistoryStore()
        let villageID = UUID()
        let lineageID = UUID()
        let snapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[{\"data\":1,\"lvl\":1}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let legacyProof = ["heroes": SnapshotHistoryTestCoverage.verified(source: "legacy-export", expectedCount: 1)]
        let verifiedEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            sectionProofs: legacyProof,
            sourceUniverse: testSourceUniverse(for: legacyProof)
        )
        guard let heroes = verifiedEntry.coverage.section(base: .home, rawSection: "heroes") else {
            return XCTFail("缺少 heroes section")
        }
        let legacySection = SnapshotSectionCoverage(
            base: heroes.base,
            rawSection: heroes.rawSection,
            presence: heroes.presence,
            completeness: .complete,
            proof: .legacyAuthoritative(source: "legacy-export", version: "1", expectedCount: 1),
            observedCount: heroes.observedCount
        )
        let legacyCoverage = SnapshotObservationCoverage(
            schemaVersion: verifiedEntry.coverage.schemaVersion,
            fields: verifiedEntry.coverage.fields,
            sections: verifiedEntry.coverage.sections.map {
                $0.base == heroes.base && $0.rawSection == heroes.rawSection ? legacySection : $0
            },
            diagnostics: verifiedEntry.coverage.diagnostics
        )
        let legacyEntry = SnapshotHistoryEntry(
            schemaVersion: verifiedEntry.schemaVersion,
            observationVersion: verifiedEntry.observationVersion,
            fingerprintVersion: verifiedEntry.fingerprintVersion,
            integrityVersion: verifiedEntry.integrityVersion,
            snapshotID: verifiedEntry.snapshotID,
            villageID: verifiedEntry.villageID,
            lineageID: verifiedEntry.lineageID,
            normalizedPlayerTag: verifiedEntry.normalizedPlayerTag,
            appliedAt: verifiedEntry.appliedAt,
            sourceTimestamp: verifiedEntry.sourceTimestamp,
            parserVersion: verifiedEntry.parserVersion,
            canonicalFingerprint: verifiedEntry.canonicalFingerprint,
            rawJSON: verifiedEntry.rawJSON,
            observation: verifiedEntry.observation,
            coverage: legacyCoverage,
            isBaseline: verifiedEntry.isBaseline,
            baselineReason: verifiedEntry.baselineReason,
            timerSchema: verifiedEntry.timerSchema,
            integrityFingerprint: SnapshotHistoryCanonicalizer.integrityFingerprint(
                integrityVersion: verifiedEntry.integrityVersion,
                schemaVersion: verifiedEntry.schemaVersion,
                observationVersion: verifiedEntry.observationVersion,
                fingerprintVersion: verifiedEntry.fingerprintVersion,
                snapshotID: verifiedEntry.snapshotID,
                villageID: verifiedEntry.villageID,
                lineageID: verifiedEntry.lineageID,
                normalizedPlayerTag: verifiedEntry.normalizedPlayerTag,
                appliedAt: verifiedEntry.appliedAt,
                sourceTimestamp: verifiedEntry.sourceTimestamp,
                parserVersion: verifiedEntry.parserVersion,
                canonicalFingerprint: verifiedEntry.canonicalFingerprint,
                rawJSON: verifiedEntry.rawJSON,
                observation: verifiedEntry.observation,
                coverage: legacyCoverage,
                isBaseline: verifiedEntry.isBaseline,
                baselineReason: verifiedEntry.baselineReason,
                timerSchema: verifiedEntry.timerSchema
            )
        )
        XCTAssertFalse(legacyEntry.coverage.section(base: .home, rawSection: "heroes")?.isComplete ?? true)

        let envelope = SnapshotHistoryEnvelope(
            entries: [legacyEntry],
            lineages: [SnapshotHistoryLineageMetadata(
                villageID: legacyEntry.villageID,
                lineageID: legacyEntry.lineageID,
                normalizedPlayerTag: legacyEntry.normalizedPlayerTag,
                lastEntryID: legacyEntry.snapshotID,
                lastFingerprint: legacyEntry.canonicalFingerprint,
                lastAppliedAt: legacyEntry.appliedAt,
                hasConflict: false
            )],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: legacyEntry.appliedAt)
        )
        try store.writeRawData(try envelope.encodedData())
        let restored = try XCTUnwrap(try store.load())
        XCTAssertEqual(restored.entries.count, 1)
        guard case .legacyAuthoritative = restored.entries[0]
            .coverage
            .section(base: .home, rawSection: "heroes")?
            .proof else {
            return XCTFail("legacy authoritative wire 应解码为 legacyAuthoritative")
        }
    }

    func testFullIntegrityDigestRejectsMetadataDisplayAndCoverageTampering() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-SnapshotHistoryIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSnapshotHistoryStore(fileURL: url)
        let raw = "{\"tag\":\"\(firstTag)\",\"timestamp\":100,\"buildings\":[{\"data\":1,\"lvl\":2}]}"
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(
                tag: firstTag,
                text: raw,
                capturedAt: Date(timeIntervalSince1970: 100)
            ),
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 101)
        )
        let marker = SnapshotHistoryMigrationMarker(completedAt: Date(timeIntervalSince1970: 101))

        let tamperedTag = copy(
            entry,
            rawJSON: "{\"tag\":\"#2QJQ8J89\",\"timestamp\":100,\"buildings\":[{\"data\":1,\"lvl\":2}]}"
        )
        let tamperedTimestamp = copy(
            entry,
            rawJSON: "{\"tag\":\"\(firstTag)\",\"timestamp\":101,\"buildings\":[{\"data\":1,\"lvl\":2}]}"
        )

        var displayItems = entry.observation.items
        let originalItem = try XCTUnwrap(displayItems.first)
        displayItems[0] = SnapshotObservationItem(
            identity: originalItem.identity,
            level: originalItem.level,
            count: originalItem.count,
            rawTimerEvidence: originalItem.rawTimerEvidence,
            helperRecurrent: originalItem.helperRecurrent,
            gearUp: originalItem.gearUp,
            weapon: originalItem.weapon,
            unknownFields: originalItem.unknownFields,
            display: SnapshotDisplayBinding(
                displayName: "篡改显示名",
                category: originalItem.display.category,
                displayCategory: originalItem.display.displayCategory,
                catalogVersion: originalItem.display.catalogVersion,
                catalogFingerprint: originalItem.display.catalogFingerprint
            )
        )
        let tamperedDisplay = copy(
            entry,
            observation: CanonicalSnapshotObservation(
                schemaVersion: entry.observation.schemaVersion,
                rawTopLevelFields: entry.observation.rawTopLevelFields,
                unknownTopLevelFields: entry.observation.unknownTopLevelFields,
                items: displayItems
            )
        )
        let tamperedCoverage = copy(
            entry,
            coverage: SnapshotObservationCoverage(
                schemaVersion: entry.coverage.schemaVersion,
                fields: entry.coverage.fields,
                sections: entry.coverage.sections,
                diagnostics: entry.coverage.diagnostics + ["篡改 coverage"]
            )
        )

        for tampered in [tamperedTag, tamperedTimestamp, tamperedDisplay, tamperedCoverage] {
            try store.writeRawData(try JSONEncoder().encode(SnapshotHistoryEnvelope(
                entries: [tampered],
                migrationMarker: marker
            )))
            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual(
                    error as? SnapshotHistoryStoreError,
                    .invalidEntry("历史 entry 的完整性摘要不一致。")
                )
            }
        }
    }

    private func makePreIssue218V4CoverageEnvelope() throws -> SnapshotHistoryEnvelope {
        let raw = """
        {"tag":"\(firstTag)","timestamp":100,"buildings":[{"data":1,"lvl":1}],\
        "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
        """
        let snapshot = snapshot(tag: firstTag, text: raw, capturedAt: Date(timeIntervalSince1970: 100))
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot)
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            lineageID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            appliedAt: Date(timeIntervalSince1970: 200),
            snapshotID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            sectionProofs: proofs,
            observationVersion: SnapshotHistorySchema.observationWithTimerSchema
        )
        return SnapshotHistoryEnvelope(
            entries: [entry],
            lineages: [SnapshotHistoryLineageMetadata(
                villageID: entry.villageID,
                lineageID: entry.lineageID,
                normalizedPlayerTag: entry.normalizedPlayerTag,
                lastEntryID: entry.snapshotID,
                lastFingerprint: entry.canonicalFingerprint,
                lastAppliedAt: entry.appliedAt,
                hasConflict: false
            )],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: entry.appliedAt)
        )
    }

    private func assertSchemaChangeAppends(
        previousSchema: SnapshotTimerSchema,
        expectedNewSchema: SnapshotTimerSchema = AccountSnapshotImporter.timerSchema
    ) throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()
        let lineageID = UUID()
        let raw = timerJSON()
        let previous = try canonicalizeTimerEntry(
            villageID: villageID,
            lineageID: lineageID,
            schema: previousSchema,
            json: raw
        )
        XCTAssertEqual(previous.timerSchema, previousSchema)
        XCTAssertNotEqual(previous.timerSchema, expectedNewSchema)

        let decision = try service.planImport(
            snapshot: snapshot(tag: firstTag, text: raw, capturedAt: Date(timeIntervalSince1970: 100)),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: migratedEnvelope(for: previous),
            appliedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertTrue(decision.appended)
        XCTAssertFalse(decision.duplicate)
        XCTAssertEqual(decision.envelope.entries.count, 2)
        XCTAssertEqual(decision.envelope.entries[0].snapshotID, previous.snapshotID)
        XCTAssertEqual(decision.envelope.entries[0].timerSchema, previousSchema)
        XCTAssertEqual(decision.envelope.entries[0].parserVersion, previous.parserVersion)
        XCTAssertEqual(decision.envelope.entries[1].timerSchema, expectedNewSchema)
        XCTAssertEqual(decision.envelope.entries[0].canonicalFingerprint, decision.envelope.entries[1].canonicalFingerprint)
        XCTAssertEqual(decision.envelope.entries[0].coverage, decision.envelope.entries[1].coverage)
        XCTAssertNotEqual(
            SnapshotHistoryDuplicateKey(entry: decision.envelope.entries[0]),
            SnapshotHistoryDuplicateKey(entry: decision.envelope.entries[1])
        )
    }

    private func canonicalizeTimerEntry(
        villageID: UUID,
        lineageID: UUID,
        schema: SnapshotTimerSchema,
        json: String,
        sectionProofs: [String: SnapshotCoverageProof] = [:],
        sourceUniverse: SnapshotCoverageSourceUniverse? = nil
    ) throws -> SnapshotHistoryEntry {
        try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag, text: json, capturedAt: Date(timeIntervalSince1970: 100)),
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 1),
            snapshotID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            isBaseline: true,
            baselineReason: .initial,
            sectionProofs: sectionProofs,
            sourceUniverse: sourceUniverse ?? testSourceUniverse(for: sectionProofs),
            timerSchema: schema
        )
    }

    private func migratedEnvelope(for entry: SnapshotHistoryEntry) -> SnapshotHistoryEnvelope {
        SnapshotHistoryEnvelope(
            entries: [entry],
            lineages: [
                SnapshotHistoryLineageMetadata(
                    villageID: entry.villageID,
                    lineageID: entry.lineageID,
                    normalizedPlayerTag: entry.normalizedPlayerTag,
                    lastEntryID: entry.snapshotID,
                    lastFingerprint: entry.canonicalFingerprint,
                    lastAppliedAt: entry.appliedAt,
                    hasConflict: false
                )
            ],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: entry.appliedAt)
        )
    }

    private func timerJSON(level: Int = 1) -> String {
        "{\"tag\":\"\(firstTag)\",\"timestamp\":100,\"heroes\":[{\"data\":1,\"lvl\":\(level),\"timer\":90}]}"
    }

    private func timerSchema(
        version: String,
        unit: SnapshotTimerUnit = .seconds,
        semantics: SnapshotTimerSemantics = .remaining,
        minValue: Int64? = 0,
        maxValue: Int64? = nil
    ) -> SnapshotTimerSchema {
        let spec = SnapshotTimerFieldSpec(
            unit: unit,
            semantics: semantics,
            minValue: minValue,
            maxValue: maxValue
        )
        return SnapshotTimerSchema(
            version: version,
            fields: [
                "timer": spec,
                "helper_timer": spec,
                "helper_cooldown": spec
            ]
        )
    }

    private func testSourceUniverse(
        for sectionProofs: [String: SnapshotCoverageProof]
    ) -> SnapshotCoverageSourceUniverse? {
        let required = sectionProofs.contains { _, proof in
            SnapshotCoverageVerifier.validatesModuleIssuedProof(proof)
        }
        guard required else { return nil }
        return SnapshotHistoryTestCoverage.testFixtureUniverse(for: sectionProofs)
    }

    private func testSourceUniverses(
        from proofs: [UUID: [String: SnapshotCoverageProof]]
    ) -> [UUID: SnapshotCoverageSourceUniverse] {
        proofs.compactMapValues(testSourceUniverse(for:))
    }

    private func copy(
        _ entry: SnapshotHistoryEntry,
        rawJSON: String? = nil,
        observation: CanonicalSnapshotObservation? = nil,
        coverage: SnapshotObservationCoverage? = nil
    ) -> SnapshotHistoryEntry {
        SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            fingerprintVersion: entry.fingerprintVersion,
            integrityVersion: entry.integrityVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            canonicalFingerprint: entry.canonicalFingerprint,
            rawJSON: rawJSON ?? entry.rawJSON,
            observation: observation ?? entry.observation,
            coverage: coverage ?? entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            integrityFingerprint: entry.integrityFingerprint
        )
    }
}

private extension String {
    var asUUID: UUID? { UUID(uuidString: self) }
}
