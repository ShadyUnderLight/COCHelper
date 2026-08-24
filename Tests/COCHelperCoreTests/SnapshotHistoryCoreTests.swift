import XCTest
@testable import COCHelperCore

final class SnapshotHistoryCoreTests: XCTestCase {
    func testFingerprintIgnoresFormattingKeyOrderArrayOrderTimestampsAndDiagnostics() throws {
        let first = try makeSnapshot(
            """
            {
              "tag": "#TEST",
              "timestamp": 1700000000,
              "boosts": {"clocktower_cooldown": 50},
              "buildings": [
                {"data": 1000001, "lvl": 10, "timer": 90,
                 "types": [{"data": 200, "lvl": 1, "modules": [{"data": 300, "lvl": 2}]}]},
                {"data": 1000001, "lvl": 11, "cnt": 2}
              ],
              "units": [{"cnt": 3, "data": 4000000, "lvl": 4}],
              "future_field": {"array": [2, 1], "object": {"b": 2, "a": 1}}
            }
            """,
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let second = try makeSnapshot(
            """
            {
              "future_field": {"object": {"a": 1, "b": 2}, "array": [1, 2]},
              "units": [{"lvl": 4, "data": 4000000, "cnt": 3}],
              "buildings": [
                {"cnt": 2, "lvl": 11, "data": 1000001},
                {"types": [{"modules": [{"lvl": 2, "data": 300}], "lvl": 1, "data": 200}],
                 "timer": 90, "lvl": 10, "data": 1000001}
              ],
              "boosts": {"clocktower_cooldown": 50},
              "timestamp": 1700000999,
              "tag": "  #TEST  "
            }
            """,
            now: Date(timeIntervalSince1970: 1_700_000_300)
        )

        let firstEntry = try canonicalize(first)
        let secondEntry = try canonicalize(second)

        XCTAssertEqual(firstEntry.canonicalFingerprint, secondEntry.canonicalFingerprint)
        XCTAssertEqual(firstEntry.observation.rawTopLevelFields, secondEntry.observation.rawTopLevelFields)
        XCTAssertEqual(firstEntry.observation.items, secondEntry.observation.items)
        XCTAssertNotEqual(first.importedAt, second.importedAt)
        XCTAssertNotEqual(first.capturedAt, second.capturedAt)
        XCTAssertNotEqual(first.diagnostics.first?.id, second.diagnostics.first?.id)
    }

    func testCanonicalJSONStringEscapingMatchesJSONSerialization() throws {
        var samples: [String] = [
            "",
            "plain",
            #"quote " slash / backslash \ tab\#t newline"#,
            "路径/城墙",
            "emoji 🏰",
            String(UnicodeScalar(0x7F)!),
            String(UnicodeScalar(0x2028)!),
            String(UnicodeScalar(0x2029)!),
        ]
        for scalar in 0...0x1F {
            samples.append(String(UnicodeScalar(scalar)!))
        }

        for sample in samples {
            let expected = try foundationJSONStringData(sample)
            XCTAssertEqual(
                CanonicalJSONValue.string(sample).canonicalData,
                expected,
                "canonical string bytes 必须与 JSONSerialization 一致: \(Array(sample.unicodeScalars))"
            )
        }
    }

    func testCanonicalJSONArrayOrderDuplicatesAndNestedObjectKeys() throws {
        let scrambled = try CanonicalJSONValue.fromJSONData(Data("""
        {"z":[{"b":2,"a":1},1,1,{"a":1,"b":2}],"a":[2,1,1]}
        """.utf8))
        let canonical = scrambled.canonicalized

        XCTAssertEqual(
            String(data: canonical.canonicalData, encoding: .utf8),
            #"{"a":[1,1,2],"z":[1,1,{"a":1,"b":2},{"a":1,"b":2}]}"#
        )

        let duplicates = try CanonicalJSONValue.fromJSONData(Data("[1,1]".utf8)).canonicalized
        let singleton = try CanonicalJSONValue.fromJSONData(Data("[1]".utf8)).canonicalized
        XCTAssertNotEqual(duplicates.canonicalData, singleton.canonicalData)

        let reorderedDuplicates = try CanonicalJSONValue.fromJSONData(Data("[1,2,1]".utf8))
        let otherOrder = try CanonicalJSONValue.fromJSONData(Data("[2,1,1]".utf8))
        XCTAssertEqual(
            reorderedDuplicates.canonicalized.canonicalData,
            otherOrder.canonicalized.canonicalData
        )
    }

    func testLargeWallsCanonicalizeFingerprintIsStable() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "perf_account_snapshot_large_walls_before", withExtension: "json")
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        let snapshot = try makeSnapshot(text)
        let first = try canonicalize(snapshot)
        let second = try canonicalize(snapshot)
        XCTAssertEqual(first.canonicalFingerprint, second.canonicalFingerprint)
        XCTAssertEqual(
            SnapshotHistoryCanonicalizer.fingerprint(for: first.observation),
            first.canonicalFingerprint
        )
    }

    func testRawTimerDifferenceChangesFingerprint() throws {
        let first = try makeSnapshot(
            "{\"timestamp\":1700000000,\"buildings\":[{\"data\":1000001,\"timer\":90}]}",
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let second = try makeSnapshot(
            "{\"timestamp\":1700000000,\"buildings\":[{\"data\":1000001,\"timer\":91}]}",
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let firstEntry = try canonicalize(first)
        let secondEntry = try canonicalize(second)

        XCTAssertNotEqual(firstEntry.canonicalFingerprint, secondEntry.canonicalFingerprint)
        XCTAssertEqual(firstEntry.observation.items.first?.rawTimerEvidence["timer"], .number("90"))
        XCTAssertEqual(secondEntry.observation.items.first?.rawTimerEvidence["timer"], .number("91"))
    }

    func testUnknownTimerLikeItemFieldsStayOutOfRawTimerEvidence() throws {
        // Issue #175：rawTimerEvidence 只收 source contract 确认的 timer 字段，
        // 未知 key 即使名字包含 timer/cooldown 也不能进入，只保留在 unknownFields。
        let snapshot = try makeSnapshot(
            #"{"timestamp":1700000000,"buildings":[{"data":1000001,"timer":90,"timer_state":"upgrading","cooldown_remaining":5}],"buildings2":[{"data":1000002,"timer":300,"cooldown_left":12}],"traps":[{"data":2000001,"helper_timer":45,"cooldown_remaining":9}],"traps2":[{"data":2000002,"helper_cooldown":60,"timer_state":"idle"}]}"#
        )
        let entry = try canonicalize(snapshot)

        let building = try XCTUnwrap(entry.observation.items.first { $0.identity.dataID == 1000001 })
        XCTAssertEqual(building.rawTimerEvidence, ["timer": .number("90")])
        XCTAssertEqual(building.unknownFields["timer_state"], .string("upgrading"))
        XCTAssertEqual(building.unknownFields["cooldown_remaining"], .number("5"))

        let builderBuilding = try XCTUnwrap(entry.observation.items.first { $0.identity.dataID == 1000002 })
        XCTAssertEqual(builderBuilding.rawTimerEvidence, ["timer": .number("300")])
        XCTAssertEqual(builderBuilding.unknownFields["cooldown_left"], .number("12"))

        let trap = try XCTUnwrap(entry.observation.items.first { $0.identity.dataID == 2000001 })
        XCTAssertEqual(trap.rawTimerEvidence, ["helper_timer": .number("45")])
        XCTAssertEqual(trap.unknownFields["cooldown_remaining"], .number("9"))

        let builderTrap = try XCTUnwrap(entry.observation.items.first { $0.identity.dataID == 2000002 })
        XCTAssertEqual(builderTrap.rawTimerEvidence, ["helper_cooldown": .number("60")])
        XCTAssertEqual(builderTrap.unknownFields["timer_state"], .string("idle"))
    }

    func testUnknownTimerLikeFieldsDoNotDriveBusinessChangesAfterCanonicalization() throws {
        // Issue #175：canonicalize 后未知 timer-like 字段不进入 rawTimerEvidence，
        // 真实 timer 的自然倒计时不产生业务变化（也不会被未知字段降级为 unknown）。
        let old = try makeSnapshot(
            #"{"timestamp":1700000000,"heroes":[{"data":1000001,"lvl":1,"timer":90,"timer_state":"upgrading","cooldown_remaining":5}]}"#,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let new = try makeSnapshot(
            #"{"timestamp":1700000005,"heroes":[{"data":1000001,"lvl":1,"timer":85,"timer_state":"upgrading","cooldown_remaining":5}]}"#,
            now: Date(timeIntervalSince1970: 1_700_000_005)
        )

        let oldEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: old,
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333331")!
        )
        let newEntry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: new,
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_005),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333332")!
        )
        let diff = SnapshotDiffEngine.compare(from: oldEntry, to: newEntry)

        XCTAssertTrue(diff.changes.isEmpty, "未知 timer-like 字段不得驱动业务变化")
    }

    func testObservationVersionFourCollectsOnlySchemaDeclaredTimerFields() throws {
        // Issue #175：v4 的 timer evidence 由 source adapter 的版本化契约决定，
        // 只有契约声明的字段进入 rawTimerEvidence；未声明字段（即使名字含
        // timer/cooldown）只保留在 unknownFields。
        let snapshot = try makeSnapshot(
            #"{"timestamp":1700000000,"buildings":[{"data":1000001,"timer":90,"helper_timer":30,"helper_cooldown":60,"timer_state":"upgrading","cooldown_left":12}]}"#
        )
        let schema = SnapshotTimerSchema(
            version: "test-schema-1",
            fields: [
                "timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining),
                "helper_timer": SnapshotTimerFieldSpec(unit: .seconds, semantics: .remaining)
            ]
        )
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333331")!,
            timerSchema: schema
        )
        XCTAssertEqual(entry.observationVersion, SnapshotHistorySchema.observation)
        let evidence = entry.observation.items.first?.rawTimerEvidence ?? [:]
        XCTAssertEqual(evidence, [
            "timer": .number("90"),
            "helper_timer": .number("30")
        ])
        XCTAssertEqual(entry.observation.items.first?.unknownFields["timer_state"], .string("upgrading"))
        XCTAssertEqual(entry.observation.items.first?.unknownFields["cooldown_left"], .number("12"))
        XCTAssertEqual(entry.timerSchema, schema, "契约必须冻结进 entry 供 provenance 审计")
    }

    func testObservationVersionFourWithoutSchemaCollectsNoTimerEvidence() throws {
        // Issue #175：v4 下 source 未声明 timer 契约时 fail-closed——
        // 字段名不再自动权威，rawTimerEvidence 为空，不得驱动业务判定。
        let snapshot = try makeSnapshot(
            #"{"timestamp":1700000000,"buildings":[{"data":1000001,"timer":90,"helper_cooldown":60,"cooldown_left":12}]}"#
        )
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333331")!,
            timerSchema: nil
        )
        XCTAssertTrue(
            entry.observation.items.first?.rawTimerEvidence.isEmpty ?? false,
            "无契约时必须 fail-closed，不收集任何 timer 字段"
        )
        XCTAssertEqual(entry.observation.items.first?.unknownFields["cooldown_left"], .number("12"))
        XCTAssertNil(
            entry.observation.items.first?.unknownFields["timer"],
            "timer 是已知 item 字段；无契约时只是不作为 timer evidence，不按未知字段处理"
        )
        XCTAssertNil(entry.timerSchema, "无契约时 entry 不冻结 schema")
    }

    func testObservationVersionThreeKeepsGlobalAllowlistCollection() throws {
        // Issue #175：v3 entry（全局 timerFields allowlist）重建必须沿用
        // v3 规则，否则历史 fingerprint 漂移。契约字段集合 = 全局 allowlist
        // 时，v3 与 v4 的收集结果一致。
        let snapshot = try makeSnapshot(
            #"{"timestamp":1700000000,"buildings":[{"data":1000001,"timer":90,"helper_timer":30,"timer_state":"upgrading"}]}"#
        )
        let v3 = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333331")!,
            observationVersion: 3
        )
        XCTAssertEqual(v3.observationVersion, 3)
        XCTAssertEqual(v3.observation.items.first?.rawTimerEvidence["timer"], .number("90"))
        XCTAssertEqual(v3.observation.items.first?.rawTimerEvidence["helper_timer"], .number("30"))
        XCTAssertNil(v3.observation.items.first?.rawTimerEvidence["timer_state"])
        XCTAssertNil(v3.timerSchema, "v3 entry 不冻结契约字段")

        let rebuilt = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333331")!,
            observationVersion: 3
        )
        XCTAssertEqual(rebuilt.canonicalFingerprint, v3.canonicalFingerprint)
    }

    func testObservationVersionTwoKeepsLegacyLooseTimerCollection() throws {
        // Issue #175 review P1：v2 历史 entry 保存时使用宽松匹配收集
        // rawTimerEvidence。canonicalizer 必须按 observationVersion 分叉，
        // 旧版本重建时沿用旧规则，否则 load 校验的 fingerprint 会漂移。
        let snapshot = try makeSnapshot(
            #"{"timestamp":1700000000,"buildings":[{"data":1000001,"timer":90,"timer_state":"upgrading"}]}"#
        )
        func canonicalizeV2() throws -> SnapshotHistoryEntry {
            try SnapshotHistoryCanonicalizer.canonicalize(
                snapshot: snapshot,
                villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
                snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333331")!,
                observationVersion: 2
            )
        }

        let v2 = try canonicalizeV2()
        XCTAssertEqual(v2.observation.schemaVersion, 2)
        XCTAssertEqual(v2.observation.items.first?.rawTimerEvidence["timer"], .number("90"))
        XCTAssertEqual(
            v2.observation.items.first?.rawTimerEvidence["timer_state"],
            .string("upgrading"),
            "v2 语义必须保留宽松匹配，才能与旧历史 entry 的 fingerprint 一致"
        )

        let rebuilt = try canonicalizeV2()
        XCTAssertEqual(rebuilt.canonicalFingerprint, v2.canonicalFingerprint)
    }

    func testStableIdentitySeparatesBasesNestedKindsAndRootsWithoutArrayIndexes() throws {
        let snapshot = try makeSnapshot(
            """
            {
              "buildings": [
                {"data": 1000001, "types": [{"data": 777, "modules": [{"data": 888}]}]},
                {"data": 1000002, "types": [{"data": 777}]}
              ],
              "buildings2": [{"data": 1000001, "types": [{"data": 777}]}]
            }
            """
        )
        let entry = try canonicalize(snapshot)
        let items = entry.observation.items

        let homeRoot = try XCTUnwrap(items.first {
            $0.identity.base == .home && $0.identity.nestedKind == .root && $0.identity.dataID == 1000001
        })
        let builderRoot = try XCTUnwrap(items.first {
            $0.identity.base == .builder && $0.identity.nestedKind == .root
        })
        let homeTypes = items.filter {
            $0.identity.base == .home && $0.identity.nestedKind == .type
        }
        let module = try XCTUnwrap(items.first { $0.identity.nestedKind == .module })

        XCTAssertNotEqual(homeRoot.identity.key, builderRoot.identity.key)
        XCTAssertEqual(homeTypes.count, 2)
        XCTAssertNotEqual(homeTypes[0].identity.key, homeTypes[1].identity.key)
        XCTAssertNotEqual(homeTypes[0].identity.key, module.identity.key)
        XCTAssertEqual(module.identity.nestedRootDataID, 1000001)
        XCTAssertEqual(module.identity.nestedRootIdentity, homeRoot.identity.key)
        XCTAssertEqual(module.identity.nestedParentPath.map(\.kind), [.root, .type])
        XCTAssertFalse(items.contains { $0.identity.key.contains(".types.") })
    }

    func testDuplicateRecordsKeepMultiplicityAndOrderIndependentFingerprint() throws {
        let first = try makeSnapshot(
            """
            {"buildings":[{"data":1000001,"lvl":10},{"data":1000001,"lvl":11}]}
            """
        )
        let second = try makeSnapshot(
            """
            {"buildings":[{"data":1000001,"lvl":11},{"data":1000001,"lvl":10}]}
            """
        )

        let firstEntry = try canonicalize(first)
        let secondEntry = try canonicalize(second)
        let records = firstEntry.observation.items.filter { $0.identity.dataID == 1000001 }

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.identity.key)).count, 1)
        XCTAssertEqual(firstEntry.canonicalFingerprint, secondEntry.canonicalFingerprint)
    }

    /// Issue #208：coverage 是 snapshot metadata，不得进入 observation / fingerprint。
    func testCoverageDeclarationDoesNotChangeCanonicalFingerprintOrUnknownFields() throws {
        let buildingsJSON = "{\"buildings\":[{\"data\":1,\"lvl\":1}]}"
        let declaredJSON = """
        {"buildings":[{"data":1,"lvl":1}],\
        "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
        """
        let withoutCoverage = try makeSnapshot(buildingsJSON)
        let withCoverage = try makeSnapshot(declaredJSON)
        let withoutEntry = try canonicalize(withoutCoverage)
        let withEntry = try canonicalize(
            withCoverage,
            sectionProofs: JSONSnapshotCoverageAdapter.proofs(for: withCoverage)
        )

        XCTAssertEqual(withoutEntry.canonicalFingerprint, withEntry.canonicalFingerprint)
        XCTAssertEqual(withEntry.observationVersion, SnapshotHistorySchema.observation)
        XCTAssertNil(withEntry.observation.unknownTopLevelFields["coverage"])
        XCTAssertNil(withEntry.observation.rawTopLevelFields["coverage"])
        XCTAssertFalse(withEntry.coverage.fields.contains {
            $0.base == .unknown
                && $0.rawSection == "$topLevel"
                && $0.field == "coverage"
        })
        XCTAssertTrue(withEntry.rawJSON.contains("\"coverage\""))
        XCTAssertEqual(
            withEntry.coverage.section(base: .home, rawSection: "buildings")?.proof,
            .declared(source: "u.coc", version: "1", expectedCount: 1)
        )
        XCTAssertNotEqual(
            withoutEntry.coverage.section(base: .home, rawSection: "buildings")?.proof,
            withEntry.coverage.section(base: .home, rawSection: "buildings")?.proof
        )

        let withUnknown = try makeSnapshot(
            """
            {"buildings":[{"data":1,"lvl":1}],"future_field":true,\
            "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
            """
        )
        let unknownEntry = try canonicalize(withUnknown)
        XCTAssertEqual(unknownEntry.observation.unknownTopLevelFields["future_field"], .bool(true))
        XCTAssertNil(unknownEntry.observation.unknownTopLevelFields["coverage"])
        XCTAssertNotEqual(unknownEntry.canonicalFingerprint, withEntry.canonicalFingerprint)
    }

    func testObservationVersionFourKeepsCoverageInUnknownTopLevelFields() throws {
        let withCoverage = try makeSnapshot(
            """
            {"buildings":[{"data":1,"lvl":1}],\
            "coverage":{"buildings":{"kind":"authoritative","source":"u.coc","version":"1","expectedCount":1}}}
            """
        )
        let withoutCoverage = try makeSnapshot("{\"buildings\":[{\"data\":1,\"lvl\":1}]}")
        let v4With = try canonicalize(
            withCoverage,
            observationVersion: SnapshotHistorySchema.observationWithTimerSchema,
            sectionProofs: JSONSnapshotCoverageAdapter.proofs(for: withCoverage)
        )
        let v4Without = try canonicalize(
            withoutCoverage,
            observationVersion: SnapshotHistorySchema.observationWithTimerSchema
        )

        XCTAssertEqual(v4With.observationVersion, SnapshotHistorySchema.observationWithTimerSchema)
        XCTAssertNotNil(v4With.observation.unknownTopLevelFields["coverage"])
        XCTAssertNotNil(v4With.observation.rawTopLevelFields["coverage"])
        XCTAssertTrue(v4With.coverage.fields.contains {
            $0.base == .unknown
                && $0.rawSection == "$topLevel"
                && $0.field == "coverage"
        })
        XCTAssertNotEqual(v4With.canonicalFingerprint, v4Without.canonicalFingerprint)
        XCTAssertEqual(
            v4With.coverage.section(base: .home, rawSection: "buildings")?.proof,
            .declared(source: "u.coc", version: "1", expectedCount: 1)
        )
    }

    func testCoverageDistinguishesCompletePartialUnavailableAndUnknownFields() throws {
        let snapshot = try makeSnapshot(
            """
            {
              "buildings": [
                {"data": 1000001, "lvl": 10, "future_item_field": true},
                {"data": 1000002}
              ],
              "future_top_level": {"enabled": true}
            }
            """
        )
        let entry = try canonicalize(snapshot)

        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "data"), .complete)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "lvl"), .partial)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "timer"), .complete)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "units", field: "data"), .unavailable)
        XCTAssertEqual(entry.coverage.state(base: .unknown, rawSection: "$topLevel", field: "future_top_level"), .complete)
        XCTAssertEqual(entry.observation.items.first?.unknownFields["future_item_field"], .bool(true))
    }

    func testSectionCoverageRequiresExplicitProofAndPreservesAuthoritativeEmpty() throws {
        let withoutProof = try canonicalize(
            makeRawSnapshot("{\"heroes\":[]}")
        )
        let noProof = try XCTUnwrap(
            withoutProof.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(noProof.presence, .presentEmpty)
        XCTAssertEqual(noProof.completeness, .unavailable)
        XCTAssertFalse(noProof.isComplete)
        XCTAssertEqual(
            noProof.proof,
            .unavailable(reason: "来源未提供 section 完整性证明。")
        )
        let nonEmpty = try canonicalize(
            makeRawSnapshot("{\"heroes\":[{\"data\":1,\"lvl\":1}]}")
        )
        let nonEmptySection = try XCTUnwrap(
            nonEmpty.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(nonEmptySection.presence, .presentNonEmpty)
        XCTAssertEqual(nonEmptySection.completeness, .unavailable)
        XCTAssertFalse(nonEmptySection.isComplete)

        let withProof = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: makeRawSnapshot("{\"heroes\":[]}"),
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1_700_100_000),
            sectionProofs: [
                "heroes": SnapshotHistoryTestCoverage.verified(
                    source: "test-export",
                    expectedCount: 0
                )
            ]
        )
        let verifiedSection = try XCTUnwrap(
            withProof.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(verifiedSection.presence, .presentEmpty)
        XCTAssertEqual(verifiedSection.completeness, .complete)
        XCTAssertTrue(verifiedSection.isComplete)
        XCTAssertTrue(verifiedSection.proof.isVerified)

        let encoded = try JSONEncoder().encode(verifiedSection)
        let restored = try JSONDecoder().decode(SnapshotSectionCoverage.self, from: encoded)
        XCTAssertEqual(restored.presence, verifiedSection.presence)
        XCTAssertEqual(restored.completeness, verifiedSection.completeness)
        guard case .verified(let evidence) = restored.proof else {
            return XCTFail("verified wire metadata 应保留")
        }
        XCTAssertEqual(evidence.adapterID, "test-fixture")
        XCTAssertNotNil(evidence.inputBinding)
        XCTAssertEqual(evidence.verificationRuleVersion, "1")
        XCTAssertNil(evidence.runtimeWitness)
        XCTAssertEqual(evidence.persistedTrust, .pendingRevalidation)
        XCTAssertFalse(restored.proof.isVerified)
        XCTAssertFalse(restored.isComplete)

        let encodedEntry = try JSONEncoder().encode(withProof)
        let decodedEntry = try JSONDecoder().decode(SnapshotHistoryEntry.self, from: encodedEntry)
        let hydratedEntry = SnapshotCoverageTrustHydration.hydrate(
            entry: decodedEntry,
            policy: .testsAllowTestFixture
        )
        let hydratedSection = try XCTUnwrap(
            hydratedEntry.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(hydratedSection.runtimeTrust, .trusted)
        XCTAssertTrue(hydratedSection.opensTrustGates)

        let invalid = try canonicalize(
            makeRawSnapshot("{\"heroes\":{}}")
        )
        let invalidSection = try XCTUnwrap(
            invalid.coverage.section(base: .home, rawSection: "heroes")
        )
        XCTAssertEqual(invalidSection.presence, .invalid)
        XCTAssertEqual(invalidSection.completeness, .partial)
    }

    func testLegacyCoverageDecodesWithoutSectionProofAndRemainsUnavailable() throws {
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "fields": [
            {"base":"home","rawSection":"heroes","field":"presence","state":"complete"},
            {"base":"home","rawSection":"heroes","field":"data","state":"complete"}
          ],
          "diagnostics": []
        }
        """
        let coverage = try JSONDecoder().decode(
            SnapshotObservationCoverage.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(coverage.schemaVersion, 1)
        XCTAssertTrue(coverage.hasLegacySectionCoverage)
        XCTAssertNil(coverage.section(base: .home, rawSection: "heroes"))
    }

    func testNestedCoverageRequiresDataAndReportsStableSourcePaths() throws {
        let snapshot = makeRawSnapshot(
            """
            {
              "buildings": [{
                "data": 1000001,
                "types": [
                  {"lvl": 1},
                  {"data": 777, "modules": [{}]}
                ]
              }]
            }
            """
        )
        let entry = try canonicalize(snapshot)

        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "types"), .partial)
        let missingDataDiagnostics = entry.coverage.diagnostics.filter { $0.contains("缺少有效 dataID") }
        XCTAssertEqual(missingDataDiagnostics.count, 2)
        XCTAssertTrue(missingDataDiagnostics.contains { $0.contains("buildings[0].types[") && $0.hasSuffix("canonical observation。") })
        XCTAssertTrue(missingDataDiagnostics.contains { $0.contains(".modules[") && $0.hasSuffix("canonical observation。") })
        XCTAssertFalse(entry.observation.items.contains { $0.identity.dataID == 0 })
    }

    func testNonObjectRootMakesNestedCoveragePartialAndReportsPath() throws {
        let snapshot = makeRawSnapshot(
            """
            {
              "buildings": [
                {"data": 1000001, "types": []},
                "not-an-object"
              ]
            }
            """
        )
        let entry = try canonicalize(snapshot)

        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "types"), .partial)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "modules"), .partial)
        XCTAssertTrue(entry.coverage.diagnostics.contains {
            $0.contains("buildings[") && $0.contains("根记录不是对象")
        })
    }

    func testInvalidRootDataMakesNestedCoveragePartial() throws {
        let snapshot = makeRawSnapshot(
            """
            {
              "buildings": [{
                "types": [{"data": 777}]
              }]
            }
            """
        )
        let entry = try canonicalize(snapshot)

        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "data"), .partial)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "types"), .partial)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "modules"), .partial)
        XCTAssertTrue(entry.coverage.diagnostics.contains {
            $0.contains("buildings[0].data") && $0.contains("缺少有效 dataID")
        })
        XCTAssertTrue(entry.observation.items.isEmpty)
    }

    func testNestedCoverageContinuesAfterInvalidParentData() throws {
        let snapshot = makeRawSnapshot(
            """
            {
              "buildings": [{
                "data": 1000001,
                "types": [{
                  "modules": [{
                    "types": [{}]
                  }]
                }]
              }]
            }
            """
        )
        let entry = try canonicalize(snapshot)
        let missingDataDiagnostics = entry.coverage.diagnostics.filter {
            $0.contains("缺少有效 dataID")
        }

        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "types"), .partial)
        XCTAssertTrue(missingDataDiagnostics.contains {
            $0.contains("buildings[0].types[0].data")
        })
        XCTAssertTrue(missingDataDiagnostics.contains {
            $0.contains("buildings[0].types[0].modules[0].data")
        })
        XCTAssertTrue(missingDataDiagnostics.contains {
            $0.contains("buildings[0].types[0].modules[0].types[0].data")
        })
    }

    func testCoverageUsesCatalogToRejectUnknownRootAndNestedDataIDs() throws {
        let snapshot = makeRawSnapshot(
            """
            {
              "buildings": [{
                "data": 9999999,
                "types": [{"data": 777}]
              }]
            }
            """
        )
        let entry = try canonicalize(
            snapshot,
            catalog: makeCatalog(name: "known root", version: "18.400.13"),
            craftTableCatalog: makeCraftTableCatalog(defenseIDs: [888])
        )

        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "data"), .partial)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "types"), .partial)
        XCTAssertTrue(entry.coverage.diagnostics.contains {
            $0.contains("buildings[0].data") && $0.contains("未知 dataID 9999999")
        })
        XCTAssertTrue(entry.coverage.diagnostics.contains {
            $0.contains("buildings[0].types[0].data") && $0.contains("未知 dataID 777")
        })
    }

    func testBundledCatalogPairRecognizesCraftTableNestedRows() throws {
        let gameCatalog = try XCTUnwrap(GameCatalog.loadBundled())
        let craftTableCatalog = try XCTUnwrap(CraftTableCatalog.loadBundled())
        let snapshot = makeRawSnapshot(
            """
            {
              "buildings": [{
                "data": 1000097,
                "types": [{"data": 103000011, "modules": [{"data": 102000033}]}],
                "modules": []
              }]
            }
            """
        )
        let entry = try canonicalize(
            snapshot,
            catalog: gameCatalog,
            craftTableCatalog: craftTableCatalog
        )

        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "data"), .complete)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "types"), .complete)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "modules"), .complete)
        XCTAssertFalse(entry.coverage.diagnostics.contains { $0.contains("未知 dataID") })

        let type = try XCTUnwrap(entry.observation.items.first {
            $0.identity.nestedKind == .type && $0.identity.dataID == 103_000_011
        })
        let module = try XCTUnwrap(entry.observation.items.first {
            $0.identity.nestedKind == .module && $0.identity.dataID == 102_000_033
        })
        for item in [type, module] {
            XCTAssertEqual(item.display.category, "buildings")
            XCTAssertEqual(item.display.displayCategory, "craftTable")
            XCTAssertEqual(item.display.catalogVersion, craftTableCatalog.gameVersion)
            XCTAssertEqual(item.display.catalogFingerprint, craftTableCatalog.sourceFingerprint)
            XCTAssertNotNil(item.display.catalogFingerprint)
        }
        XCTAssertEqual(type.display.displayName, "火热蜡烛")
        XCTAssertEqual(module.display.displayName, "火热蜡烛生命值模组")
    }

    func testDeepNestedIdentityKeepsOutermostRoot() throws {
        let snapshot = try makeSnapshot(
            """
            {
              "buildings": [{
                "data": 1000001,
                "types": [{
                  "data": 777,
                  "modules": [{
                    "data": 888,
                    "modules": [{"data": 999}]
                  }]
                }]
              }]
            }
            """
        )
        let entry = try canonicalize(snapshot)

        let root = try XCTUnwrap(entry.observation.items.first { $0.identity.nestedKind == .root })
        let type = try XCTUnwrap(entry.observation.items.first { $0.identity.nestedKind == .type })
        let parentModule = try XCTUnwrap(entry.observation.items.first {
            $0.identity.nestedKind == .module && $0.identity.dataID == 888
        })
        let deepModule = try XCTUnwrap(entry.observation.items.first {
            $0.identity.nestedKind == .module && $0.identity.dataID == 999
        })

        XCTAssertEqual(type.identity.nestedRootIdentity, root.identity.key)
        XCTAssertEqual(parentModule.identity.nestedRootIdentity, root.identity.key)
        XCTAssertEqual(deepModule.identity.nestedRootIdentity, root.identity.key)
        XCTAssertNotEqual(deepModule.identity.nestedRootIdentity, type.identity.key)
        XCTAssertEqual(deepModule.identity.nestedParentPath.map(\.kind), [.root, .type, .module])
    }

    func testDisplayBindingIsCopiedAtCreationAndDoesNotAffectFingerprint() throws {
        let snapshot = try makeSnapshot(
            "{" +
                "\"buildings\":[{\"data\":1000001,\"lvl\":10}]" +
            "}"
        )
        let firstCatalog = makeCatalog(name: "旧目录名称", version: "18.400.13")
        let secondCatalog = makeCatalog(name: "新目录名称", version: "18.500.0")

        let firstEntry = try canonicalize(snapshot, catalog: firstCatalog)
        let secondEntry = try canonicalize(snapshot, catalog: secondCatalog)

        XCTAssertEqual(firstEntry.canonicalFingerprint, secondEntry.canonicalFingerprint)
        XCTAssertEqual(firstEntry.observation.items.first?.display.displayName, "旧目录名称")
        XCTAssertEqual(firstEntry.observation.items.first?.display.catalogVersion, "18.400.13")
        XCTAssertEqual(secondEntry.observation.items.first?.display.displayName, "新目录名称")
    }

    func testNestedDisplayBindingUsesObservedItemDataID() throws {
        let snapshot = try makeSnapshot(
            """
            {"buildings":[{"data":1000001,"types":[{"data":777,"modules":[{"data":888}]}]}]}
            """
        )
        let catalog = makeCatalog(name: "root", version: "18.400.13", includeNested: true)
        let entry = try canonicalize(snapshot, catalog: catalog)

        let root = try XCTUnwrap(entry.observation.items.first { $0.identity.nestedKind == .root })
        let type = try XCTUnwrap(entry.observation.items.first { $0.identity.nestedKind == .type })
        let module = try XCTUnwrap(entry.observation.items.first { $0.identity.nestedKind == .module })

        XCTAssertEqual(root.display.displayName, "root")
        XCTAssertEqual(type.display.displayName, "type")
        XCTAssertEqual(module.display.displayName, "module")
    }

    func testUnknownCraftNestedIDsDoNotFallbackToGameCatalogCollision() throws {
        let snapshot = try makeSnapshot(
            """
            {"buildings":[{"data":1000001,"types":[{"data":777,"modules":[{"data":888}]}],"modules":[{"data":888}]}]}
            """
        )
        let gameCatalog = makeCatalog(name: "root", version: "18.400.13", includeNested: true)
        let craftTableCatalog = makeCraftTableCatalog(defenseIDs: [])
        let entry = try canonicalize(
            snapshot,
            catalog: gameCatalog,
            craftTableCatalog: craftTableCatalog
        )

        let type = try XCTUnwrap(entry.observation.items.first {
            $0.identity.nestedKind == .type && $0.identity.dataID == 777
        })
        let module = try XCTUnwrap(entry.observation.items.first {
            $0.identity.nestedKind == .module && $0.identity.dataID == 888
        })

        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "types"), .partial)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "modules"), .partial)
        XCTAssertTrue(entry.coverage.diagnostics.contains {
            $0.contains("buildings[0].types[0].data") && $0.contains("未知 dataID 777")
        })
        XCTAssertTrue(entry.coverage.diagnostics.contains {
            $0.contains("buildings[0].types[0].modules[0].data") && $0.contains("未知 dataID 888")
        })
        XCTAssertEqual(type.identity.dataID, 777)
        XCTAssertEqual(module.identity.dataID, 888)
        XCTAssertNil(type.display.displayName)
        XCTAssertNil(type.display.category)
        XCTAssertNil(type.display.catalogVersion)
        XCTAssertNil(module.display.displayName)
        XCTAssertNil(module.display.category)
        XCTAssertNil(module.display.catalogVersion)
    }

    func testLineageRulesDoNotJoinMissingOrConflictingIdentity() {
        let villageID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let first = SnapshotLineageResolver.resolve(
            villageID: villageID,
            normalizedPlayerTag: "  #ABC  ",
            previous: nil
        )
        let context = SnapshotLineageContext(
            villageID: villageID,
            lineageID: first.lineageID,
            normalizedPlayerTag: "#ABC"
        )

        let continued = SnapshotLineageResolver.resolve(
            villageID: villageID,
            normalizedPlayerTag: "#ABC",
            previous: context
        )
        let changed = SnapshotLineageResolver.resolve(
            villageID: villageID,
            normalizedPlayerTag: "#DEF",
            previous: context
        )
        let missing = SnapshotLineageResolver.resolve(
            villageID: villageID,
            normalizedPlayerTag: nil,
            previous: context
        )
        let invalid = SnapshotLineageResolver.resolve(
            villageID: villageID,
            normalizedPlayerTag: "not-a-tag",
            previous: context
        )
        let conflict = SnapshotLineageResolver.resolve(
            villageID: villageID,
            normalizedPlayerTag: "#ABC",
            previous: SnapshotLineageContext(
                villageID: villageID,
                lineageID: first.lineageID,
                normalizedPlayerTag: "#ABC",
                hasConflict: true
            )
        )

        XCTAssertEqual(continued.lineageID, first.lineageID)
        XCTAssertEqual(continued.outcome, .continued)
        XCTAssertTrue(continued.comparisonAllowed)
        XCTAssertNotEqual(changed.lineageID, first.lineageID)
        XCTAssertEqual(changed.reason, .tagChanged)
        XCTAssertTrue(changed.isBaseline)
        XCTAssertEqual(missing.reason, .missingTag)
        XCTAssertFalse(missing.comparisonAllowed)
        XCTAssertEqual(invalid.outcome, .unknown)
        XCTAssertEqual(invalid.reason, .invalidTag)
        XCTAssertFalse(invalid.comparisonAllowed)
        XCTAssertEqual(conflict.reason, .previousConflict)
        XCTAssertFalse(conflict.comparisonAllowed)
    }

    func testHistoryEntryCodableRoundTripPreservesImmutableContract() throws {
        let snapshot = try makeSnapshot(
            "{\"tag\":\"#ABC\",\"timestamp\":1700000000,\"buildings\":[{\"data\":1000001,\"timer\":90}]}"
        )
        let villageID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let lineageID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let appliedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: villageID,
            lineageID: lineageID,
            appliedAt: appliedAt,
            snapshotID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            isBaseline: true,
            baselineReason: .initial
        )

        let data = try JSONEncoder().encode(entry)
        let restored = try JSONDecoder().decode(SnapshotHistoryEntry.self, from: data)

        XCTAssertEqual(restored, entry)
        XCTAssertEqual(restored.rawJSON, snapshot.originalText)
        XCTAssertEqual(restored.appliedAt, appliedAt)
    }

    private func foundationJSONStringData(_ value: String) throws -> Data {
        let encoded = try JSONSerialization.data(withJSONObject: [value])
        return Data(encoded.dropFirst().dropLast())
    }

    private func canonicalize(
        _ snapshot: AccountSnapshot,
        catalog: GameCatalog? = nil,
        craftTableCatalog: CraftTableCatalog? = nil,
        observationVersion: Int = SnapshotHistorySchema.observation,
        sectionProofs: [String: SnapshotCoverageProof] = [:]
    ) throws -> SnapshotHistoryEntry {
        try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1_700_100_000),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog,
            sectionProofs: sectionProofs,
            observationVersion: observationVersion
        )
    }

    private func makeSnapshot(
        _ text: String,
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> AccountSnapshot {
        try AccountSnapshotImporter.parse(text, now: now)
    }

    private func makeRawSnapshot(_ text: String) -> AccountSnapshot {
        AccountSnapshot(
            tag: "#ABC",
            capturedAt: nil,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            ageSeconds: nil,
            originalText: text,
            objectSections: [:],
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
    }

    private func makeCatalog(
        name: String,
        version: String,
        includeNested: Bool = false
    ) -> GameCatalog {
        var items = [makeCatalogItem(dataID: 1000001, name: name)]
        if includeNested {
            items.append(makeCatalogItem(dataID: 777, name: "type"))
            items.append(makeCatalogItem(dataID: 888, name: "module"))
        }
        return GameCatalog(gameVersion: version, items: items)
    }

    private func makeCatalogItem(dataID: Int64, name: String) -> CatalogItem {
        let level = CatalogLevel(
            level: 10,
            durationSeconds: nil,
            upgradeCosts: nil,
            requiredTownHallLevel: nil,
            requiredLaboratoryLevel: nil,
            icon: nil,
            levelVisual: nil,
            missingReason: nil
        )
        return CatalogItem(
            section: "buildings",
            category: "buildings",
            dataID: dataID,
            base: "home",
            baseMissingReason: nil,
            name: name,
            maxLevel: 10,
            icon: nil,
            levelVisual: nil,
            levels: [level]
        )
    }

    private func makeCraftTableCatalog(defenseIDs: [Int64]) -> CraftTableCatalog {
        CraftTableCatalog(
            schemaVersion: 1,
            gameVersion: "18.400.13",
            buildTag: "test",
            defenses: defenseIDs.map {
                CraftTableDefenseSpec(
                    dataID: $0,
                    name: "defense-\($0)",
                    sourceName: "test",
                    specialAbility: "",
                    moduleIDs: [],
                    totalModuleLevelThresholds: []
                )
            },
            modules: []
        )
    }
}
