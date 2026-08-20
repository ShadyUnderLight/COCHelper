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
            "heroes": .makeVerified(source: "test-export", expectedCount: 1)
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
            sectionProofs: proof
        )

        XCTAssertTrue(decision.appended)
        XCTAssertFalse(decision.duplicate)
        XCTAssertEqual(decision.envelope.entries.count, 2)
        XCTAssertEqual(
            decision.entry.coverage.section(base: .home, rawSection: "heroes")?.proof,
            proof["heroes"]
        )
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
            timerSchema: schema
        )
        XCTAssertEqual(entry.observationVersion, SnapshotHistorySchema.observation)
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

    func testLegacyAuthoritativeProofPreservesIntegrityFingerprintOnLoad() throws {
        let store = TestSnapshotHistoryStore()
        let villageID = UUID()
        let lineageID = UUID()
        let snapshot = try AccountSnapshotImporter.parse(
            "{\"heroes\":[{\"data\":1,\"lvl\":1}]}",
            now: Date(timeIntervalSince1970: 100)
        )
        let verifiedEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: Date(timeIntervalSince1970: 100),
            sectionProofs: ["heroes": .makeVerified(source: "legacy-export", expectedCount: 1)]
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
