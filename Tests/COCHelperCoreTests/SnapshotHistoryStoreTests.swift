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
            snapshotID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            villageID: base.villageID,
            lineageID: base.lineageID,
            normalizedPlayerTag: base.normalizedPlayerTag,
            appliedAt: Date(timeIntervalSince1970: 99),
            sourceTimestamp: Date(timeIntervalSince1970: 50),
            parserVersion: "account-json-9.9",
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
                XCTAssertEqual(evidence.verificationRuleVersion, liveEvidence.verificationRuleVersion)
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

        let entry = try XCTUnwrap(secondReload.entries.first)
        XCTAssertEqual(entry.coverage.sourceUniverseRuntimeTrust, .trusted,
            "两次 load 后 source universe runtime trust 应恢复为 trusted")
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

    func testObservationV5WireIgnoresInjectedSourceUniverse() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "perf_account_snapshot_home",
                withExtension: "json"
            )
        )
        let text = try String(contentsOf: fixtureURL, encoding: .utf8)
        let snapshot = try AccountSnapshotImporter.parse(text, now: Date(timeIntervalSince1970: 1))
        let proofs = SnapshotCoverageVerifier.promoteBundledPerfFixtureDeclaredProofs(
            JSONSnapshotCoverageAdapter.proofs(for: snapshot),
            fixtureID: "perf_account_snapshot_home"
        )
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: proofs,
            observationVersion: SnapshotHistorySchema.observationWithoutCoverageMetadata
        )
        XCTAssertNil(entry.coverage.sourceUniverse)
        XCTAssertEqual(entry.observationVersion, SnapshotHistorySchema.observationWithoutCoverageMetadata)

        var envelopeObject = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(
                SnapshotHistoryEnvelope(
                    entries: [entry],
                    lineages: [],
                    migrationMarker: SnapshotHistoryMigrationMarker(completedAt: entry.appliedAt)
                )
            )
        ) as! [String: Any]
        var entries = envelopeObject["entries"] as! [[String: Any]]
        var coverage = entries[0]["coverage"] as! [String: Any]
        coverage["sourceUniverse"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                try XCTUnwrap(SnapshotCoverageSourceUniverseIssuer.issuePerfFixture(snapshot: snapshot))
            )
        )
        entries[0]["coverage"] = coverage
        envelopeObject["entries"] = entries
        let tamperedData = try JSONSerialization.data(
            withJSONObject: envelopeObject,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder().decode(SnapshotHistoryEnvelope.self, from: tamperedData)
        let decodedEntry = try XCTUnwrap(decoded.entries.first)
        XCTAssertNil(decodedEntry.coverage.sourceUniverse)
        XCTAssertEqual(decodedEntry.coverage.sourceUniverseRuntimeTrust, .notApplicable)
        let hydrated = decoded.hydratingVerifiedCoverage(policy: .production)
        XCTAssertNil(hydrated.entries.first?.coverage.sourceUniverse)
        XCTAssertEqual(
            SnapshotCoverageTrustDisplayState.evaluate(
                coverage: try XCTUnwrap(hydrated.entries.first?.coverage)
            ),
            .insufficientCoverage
        )
    }

    func testObservationV5EntryWithSourceUniverseRejectedByValidation() throws {
        let text = "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}]}"
        let proof: [String: SnapshotCoverageProof] = [
            "heroes": SnapshotHistoryTestCoverage.verified(source: "test-export", expectedCount: 1)
        ]
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag, text: text),
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1),
            sectionProofs: proof,
            observationVersion: SnapshotHistorySchema.observationWithoutCoverageMetadata
        )
        let tamperedCoverage = SnapshotObservationCoverage(
            schemaVersion: entry.coverage.schemaVersion,
            fields: entry.coverage.fields,
            sections: entry.coverage.sections,
            diagnostics: entry.coverage.diagnostics,
            sourceUniverse: testSourceUniverse(for: proof),
            sourceUniverseRuntimeTrust: .pending
        )
        let tamperedEntry = SnapshotHistoryEntry(
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
            coverage: tamperedCoverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason
        )
        let envelope = SnapshotHistoryEnvelope(
            entries: [tamperedEntry],
            lineages: [],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: entry.appliedAt)
        )
        XCTAssertThrowsError(try envelope.validated()) { error in
            guard case SnapshotHistoryStoreError.invalidEntry(let message) = error else {
                return XCTFail("expected invalidEntry, got \(error)")
            }
            XCTAssertTrue(message.contains("source universe"))
        }
    }

    func testVerifiedCoverageTamperedRuleVersionFailsRevalidation() throws {
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
            verificationRuleVersion: "999"
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
            XCTFail("篡改 rule version 后 revalidation 必须 fail-closed")
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
        let proof: SnapshotCoverageProof = .verified(
            VerifiedCoverageEvidence(
                decodedWire: SnapshotCoverageVerifier.perfFixtureAdapterID,
                adapterID: SnapshotCoverageVerifier.perfFixtureAdapterID,
                protocolVersion: "1",
                expectedCount: 1,
                verificationReason: "bundled perf fixture",
                verificationRuleVersion: "1"
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
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
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
                villageID: entry.villageID,
                lineageID: entry.lineageID,
                normalizedPlayerTag: entry.normalizedPlayerTag,
                lastEntryID: entry.snapshotID,
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
            reloaded.entries.first.map {
                SnapshotHistoryCanonicalizer.observationIdentityKey(for: $0.observation)
            },
            productionHydrated.entries.first.map {
                SnapshotHistoryCanonicalizer.observationIdentityKey(for: $0.observation)
            }
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

        // provenance-only diff 不产生升级统计；直接通过 Statistics.calculate 验证。
        let statistics = SnapshotHistoryStatistics.calculate(
            diffs: diffs,
            referenceDate: Date(timeIntervalSince1970: 2),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(statistics.today.heroLevelGrowth.state, .available)
        XCTAssertEqual(statistics.today.heroLevelGrowth.value, 0)

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

        let unsupported = try JSONEncoder().encode(SnapshotHistoryEnvelope(schemaVersion: 999))
        try store.writeRawData(unsupported)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? SnapshotHistoryStoreError, .unsupportedSchema(999))
        }
    }

    func testMissingEntryAndInvalidObservationNeverBecomeAnEmptyHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("COCHelper-SnapshotHistoryInvalidEntryTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSnapshotHistoryStore(fileURL: url)
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot(tag: firstTag, text: "{\"tag\":\"\(firstTag)\",\"buildings\":[{\"data\":1,\"lvl\":1}]}"),
            villageID: UUID(),
            lineageID: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1)
        )
        let marker = SnapshotHistoryMigrationMarker(completedAt: Date(timeIntervalSince1970: 1))

        // Issue #304：observation 被篡改（与 rawJSON 重建不一致）必须拒绝。
        let tamperedObservation = SnapshotHistoryEntry(
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
            observation: CanonicalSnapshotObservation(
                schemaVersion: entry.observation.schemaVersion,
                rawTopLevelFields: entry.observation.rawTopLevelFields,
                unknownTopLevelFields: entry.observation.unknownTopLevelFields,
                items: Array(entry.observation.items.dropFirst())
            ),
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason
        )
        try store.writeRawData(try JSONEncoder().encode(SnapshotHistoryEnvelope(
            entries: [tamperedObservation],
            migrationMarker: marker
        )))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? SnapshotHistoryStoreError,
                .invalidEntry("历史 entry 的 rawJSON 与 observation 不一致。")
            )
        }

        let tamperedRawJSON = SnapshotHistoryEntry(
            schemaVersion: entry.schemaVersion,
            observationVersion: entry.observationVersion,
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
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
                .invalidEntry("历史 entry 的 rawJSON 与 observation 不一致。")
            )
        }

        let unsupportedEntryVersion = SnapshotHistoryEntry(
            schemaVersion: 999,
            observationVersion: entry.observationVersion,
            snapshotID: UUID(),
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            rawJSON: entry.rawJSON,
            observation: entry.observation,
            coverage: entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason
        )
        try store.writeRawData(try JSONEncoder().encode(SnapshotHistoryEnvelope(
            entries: [unsupportedEntryVersion],
            migrationMarker: marker
        )))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? SnapshotHistoryStoreError, .unsupportedSchema(999))
        }

        let missingEntry = Data("""
        {
          "schemaVersion": 2,
          "entries": [{}],
          "lineages": [],
          "duplicateMetadata": {},
          "migrationMarker": {"version": 2, "completedAt": 1},
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
        // 用旧规则重建，否则 rawJSON 与 observation 校验会拒绝加载。
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
                lastAppliedAt: entry.appliedAt,
                hasConflict: false
            )],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: entry.appliedAt)
        )

        try store.writeRawData(envelope.encodedData())
        let restored = try XCTUnwrap(try store.load())
        XCTAssertEqual(restored.entries.first?.observationVersion, 2)
        XCTAssertEqual(
            restored.entries.first.map {
                SnapshotHistoryCanonicalizer.observationIdentityKey(for: $0.observation)
            },
            SnapshotHistoryCanonicalizer.observationIdentityKey(for: entry.observation)
        )
    }

    func testObservationVersionFourEntryWithSchemaSurvivesReload() throws {
        // Issue #175：v4 entry 冻结 timer schema 契约；load 校验重建时
        // 必须用 entry 内冻结的契约（而非当前默认契约），observation 身份稳定。
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
                lastAppliedAt: entry.appliedAt,
                hasConflict: false
            )],
            migrationMarker: SnapshotHistoryMigrationMarker(completedAt: entry.appliedAt)
        )

        try store.writeRawData(envelope.encodedData())
        let restored = try XCTUnwrap(try store.load())
        XCTAssertEqual(restored.entries.first?.timerSchema, schema)
        XCTAssertEqual(
            restored.entries.first.map {
                SnapshotHistoryCanonicalizer.observationIdentityKey(for: $0.observation)
            },
            SnapshotHistoryCanonicalizer.observationIdentityKey(for: entry.observation)
        )
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
        XCTAssertEqual(
            restored.entries.first.map {
                SnapshotHistoryCanonicalizer.observationIdentityKey(for: $0.observation)
            },
            SnapshotHistoryCanonicalizer.observationIdentityKey(for: entry.observation)
        )
        XCTAssertNotNil(restored.entries.first?.observation.unknownTopLevelFields["coverage"])
    }

    func testLegacyV1EnvelopeIsRejectedAsUnsupported() throws {
        // Issue #304 数据策略：旧 wire 形状不迁移、不 fallback；
        // 保留原文件并报告 unsupported，由用户重新导入。
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "history_v4_coverage_entry", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let store = TestSnapshotHistoryStore()
        try store.writeRawData(data)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? SnapshotHistoryStoreError, .unsupportedSchema(1))
        }
        XCTAssertEqual(try store.readRawData(), data, "旧文件必须原样保留，不得静默重写")
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
            envelope.entries.first.map {
                SnapshotHistoryCanonicalizer.observationIdentityKey(for: $0.observation)
            },
            SnapshotHistoryCanonicalizer.observationIdentityKey(for: decision.entry.observation)
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

    func testLegacyAuthoritativeProofSurvivesReload() throws {
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
            snapshotID: verifiedEntry.snapshotID,
            villageID: verifiedEntry.villageID,
            lineageID: verifiedEntry.lineageID,
            normalizedPlayerTag: verifiedEntry.normalizedPlayerTag,
            appliedAt: verifiedEntry.appliedAt,
            sourceTimestamp: verifiedEntry.sourceTimestamp,
            parserVersion: verifiedEntry.parserVersion,
            rawJSON: verifiedEntry.rawJSON,
            observation: verifiedEntry.observation,
            coverage: legacyCoverage,
            isBaseline: verifiedEntry.isBaseline,
            baselineReason: verifiedEntry.baselineReason,
            timerSchema: verifiedEntry.timerSchema
        )
        XCTAssertFalse(legacyEntry.coverage.section(base: .home, rawSection: "heroes")?.isComplete ?? true)

        let envelope = SnapshotHistoryEnvelope(
            entries: [legacyEntry],
            lineages: [SnapshotHistoryLineageMetadata(
                villageID: legacyEntry.villageID,
                lineageID: legacyEntry.lineageID,
                normalizedPlayerTag: legacyEntry.normalizedPlayerTag,
                lastEntryID: legacyEntry.snapshotID,
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

    func testObservationIdentityRejectsContentTampering() throws {
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

        // Issue #304：不再有完整性摘要；影响 observation 的内容篡改被拒绝。
        let tamperedContent = copy(
            entry,
            rawJSON: "{\"tag\":\"\(firstTag)\",\"timestamp\":100,\"buildings\":[{\"data\":1,\"lvl\":99}]}"
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
                catalogVersion: originalItem.display.catalogVersion
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

        try store.writeRawData(try JSONEncoder().encode(SnapshotHistoryEnvelope(
            entries: [tamperedContent],
            migrationMarker: marker
        )))
        XCTAssertThrowsError(try store.load()) { error in
            guard case .invalidEntry = error as? SnapshotHistoryStoreError else {
                return XCTFail("篡改内容必须被拒绝，实际为 \(error)")
            }
        }

        // 展示信息（display binding）是历史渲染快照，不属于 observation 身份；
        // 其漂移不阻止加载（与删除 catalogFingerprint 摘要一致）。
        try store.writeRawData(try JSONEncoder().encode(SnapshotHistoryEnvelope(
            entries: [tamperedDisplay],
            migrationMarker: marker
        )))
        XCTAssertNoThrow(try store.load())
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
        XCTAssertEqual(
            SnapshotHistoryCanonicalizer.observationIdentityKey(
                for: decision.envelope.entries[0].observation
            ),
            SnapshotHistoryCanonicalizer.observationIdentityKey(
                for: decision.envelope.entries[1].observation
            )
        )
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

    // MARK: - #260 review: lineage 隔离与 diff 方向回归测试

    /// tag 变化创建新 lineage 后，active-lineage 过滤必须排除旧 lineage 的 entries。
    /// 旧 SnapshotHistoryProjection 有 testProjectionShowsOnlyActiveLineageAfterTagChange 覆盖此语义，
    /// 移除 UI projection 后在此以 envelope/Diff Engine 直接验证。
    func testActiveLineageFilterExcludesInactiveLineageAfterTagChange() throws {
        let store = TestSnapshotHistoryStore()
        let service = SnapshotHistoryService(store: store)
        let villageID = UUID()

        // 导入 tag A → baseline，创建 lineage 1
        let base = snapshot(
            tag: firstTag,
            text: "{\"tag\":\"\(firstTag)\",\"heroes\":[{\"data\":1,\"lvl\":1}]}",
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let envelopeAfterA = try service.loadOrMigrate(
            villages: [VillageProfile(id: villageID, name: "主村", accountSnapshot: base)],
            now: Date(timeIntervalSince1970: 20)
        )
        let lineage1ID = try XCTUnwrap(envelopeAfterA.activeLineage(for: villageID)?.lineageID)

        // 导入 tag B（currentTag=A）→ 创建新 lineage 2，lineage 1 变为 inactive
        let decisionB = try service.planImport(
            snapshot: snapshot(
                tag: secondTag,
                text: "{\"tag\":\"\(secondTag)\",\"heroes\":[{\"data\":1,\"lvl\":2}]}",
                capturedAt: Date(timeIntervalSince1970: 30)
            ),
            villageID: villageID,
            currentTag: firstTag,
            hasCurrentSnapshot: true,
            envelope: envelopeAfterA,
            appliedAt: Date(timeIntervalSince1970: 31)
        )
        XCTAssertTrue(decisionB.appended, "tag 变化应追加新 entry 而非 duplicate")
        let envelopeAfterB = decisionB.envelope
        let activeLineageID = try XCTUnwrap(envelopeAfterB.activeLineage(for: villageID)?.lineageID)
        XCTAssertNotEqual(activeLineageID, lineage1ID, "tag 变化应创建新 active lineage")
        XCTAssertEqual(envelopeAfterB.lineages.count, 2, "应保留旧 lineage 记录")

        // 过滤 active lineage 后只包含新 lineage 的 entries
        let activeEntries = envelopeAfterB.entries.filter {
            $0.villageID == villageID && $0.lineageID == activeLineageID
        }
        XCTAssertEqual(activeEntries.count, 1)
        XCTAssertEqual(activeEntries[0].normalizedPlayerTag, secondTag)

        // 旧 lineage 的 entry 仍存在但不属于 active lineage
        let inactiveEntries = envelopeAfterB.entries.filter {
            $0.villageID == villageID && $0.lineageID == lineage1ID
        }
        XCTAssertEqual(inactiveEntries.count, 1)
        XCTAssertEqual(inactiveEntries[0].normalizedPlayerTag, firstTag)

        // adjacent diff 只在 active lineage 内比较，不得跨 lineage
        let diffs = SnapshotDiffEngine.adjacentDiffs(in: envelopeAfterB, villageID: villageID, lineageID: activeLineageID)
        XCTAssertEqual(diffs.count, 0, "active lineage 只有一个 entry，不应产生 diff")
    }

    /// adjacent diff 必须吃 envelope append order（旧→新），增长统计方向不得反转。
    /// #260 review 发现 SanitizedVillageHistory 先按 appliedAt 倒序再 adjacentDiffs，
    /// 会把 A1→A2 比较成 A2→A1，levelDelta 从 +1 变成 -1。
    func testAdjacentDiffDirectionPreservesGrowthSign() throws {
        let villageID = UUID()
        let lineageID = UUID()
        let identity = SnapshotItemIdentity(base: .home, rawSection: "buildings", dataID: 1)
        let display = SnapshotDisplayBinding(displayName: "城墙", category: "buildings", displayCategory: "walls")

        // 构造完整的 buildings coverage（trusted + complete + cnt），确保 Diff 引擎输出可比变化。
        let fields = ["presence", "data", "lvl", "cnt"].map {
            SnapshotCoverageField(base: .home, rawSection: "buildings", field: $0, state: .complete)
        }
        let section = SnapshotHistoryTestCoverage.trustedSection(
            base: .home,
            rawSection: "buildings",
            presence: .presentNonEmpty,
            completeness: .complete,
            proof: SnapshotHistoryTestCoverage.verified(),
            observedCount: 2
        )
        let coverage = SnapshotObservationCoverage(fields: fields, sections: [section])

        // baseline: Lv.12 ×100 + Lv.13 ×50（append order 第一个，总数 150）
        let itemOld1 = SnapshotObservationItem(identity: identity, level: 12, count: 100, display: display)
        let itemOld2 = SnapshotObservationItem(identity: identity, level: 13, count: 50, display: display)
        let entry1 = SnapshotHistoryEntry(
            snapshotID: UUID(),
            villageID: villageID,
            lineageID: lineageID,
            normalizedPlayerTag: "#TEST",
            appliedAt: Date(timeIntervalSince1970: 10),
            sourceTimestamp: nil,
            parserVersion: "test",
            rawJSON: "{}",
            observation: CanonicalSnapshotObservation(rawTopLevelFields: [:], items: [itemOld1, itemOld2]),
            coverage: coverage,
            isBaseline: false,
            baselineReason: nil
        )
        // second: Lv.13 ×70 + Lv.12 ×80（append order 第二个，总数 150，Lv.12→Lv.13 迁移 20）
        let itemNew1 = SnapshotObservationItem(identity: identity, level: 13, count: 70, display: display)
        let itemNew2 = SnapshotObservationItem(identity: identity, level: 12, count: 80, display: display)
        let entry2 = SnapshotHistoryEntry(
            snapshotID: UUID(),
            villageID: villageID,
            lineageID: lineageID,
            normalizedPlayerTag: "#TEST",
            appliedAt: Date(timeIntervalSince1970: 20),
            sourceTimestamp: nil,
            parserVersion: "test",
            rawJSON: "{}",
            observation: CanonicalSnapshotObservation(rawTopLevelFields: [:], items: [itemNew1, itemNew2]),
            coverage: coverage,
            isBaseline: false,
            baselineReason: nil
        )

        // adjacent diff 吃 append order：[entry1(level12), entry2(level13)]
        let diffs: [SnapshotDiff] = SnapshotDiffEngine.adjacentDiffs(in: [entry1, entry2])
        XCTAssertEqual(diffs.count, 1)
        let diff: SnapshotDiff = diffs[0]
        let wallChanges: [SnapshotChange] = diff.changes.filter { $0.identity == identity }
        XCTAssertEqual(wallChanges.count, 1, "应检测到唯一的 wall level 迁移变化")
        let wallChange = try XCTUnwrap(wallChanges.first)
        XCTAssertEqual(wallChange.changeKind, .levelIncreased, "Lv.12→Lv.13 迁移 20 个，应为 levelIncreased")
        XCTAssertEqual(wallChange.oldLevel, 12)
        XCTAssertEqual(wallChange.newLevel, 13)
        XCTAssertEqual(wallChange.levelDelta, 1, "levelDelta 应为 +1；若先倒序再 diff 会变成 -1")
        XCTAssertEqual(wallChange.movedQuantity, 20)

        // 反向验证：倒序传入时结果方向必须与正向不同，证明顺序确实影响 diff 语义。
        let reversedDiffs: [SnapshotDiff] = SnapshotDiffEngine.adjacentDiffs(in: [entry2, entry1])
        let reversedWallChanges = reversedDiffs.first?.changes.filter { $0.identity == identity } ?? []
        let reversedWallChange = try XCTUnwrap(reversedWallChanges.first)
        XCTAssertNotEqual(reversedWallChange.changeKind, .levelIncreased, "倒序传入时不应仍是 levelIncreased")
        XCTAssertNotEqual(reversedWallChange.levelDelta, 1, "倒序传入时 levelDelta 不应仍是 +1")
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
            snapshotID: entry.snapshotID,
            villageID: entry.villageID,
            lineageID: entry.lineageID,
            normalizedPlayerTag: entry.normalizedPlayerTag,
            appliedAt: entry.appliedAt,
            sourceTimestamp: entry.sourceTimestamp,
            parserVersion: entry.parserVersion,
            rawJSON: rawJSON ?? entry.rawJSON,
            observation: observation ?? entry.observation,
            coverage: coverage ?? entry.coverage,
            isBaseline: entry.isBaseline,
            baselineReason: entry.baselineReason,
            timerSchema: entry.timerSchema
        )
    }
}

private extension String {
    var asUUID: UUID? { UUID(uuidString: self) }
}
