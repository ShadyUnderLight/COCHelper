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
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "buildings", field: "timer"), .unavailable)
        XCTAssertEqual(entry.coverage.state(base: .home, rawSection: "units", field: "data"), .unavailable)
        XCTAssertEqual(entry.coverage.state(base: .unknown, rawSection: "$topLevel", field: "future_top_level"), .complete)
        XCTAssertEqual(entry.observation.items.first?.unknownFields["future_item_field"], .bool(true))
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
            catalog: makeCatalog(name: "known root", version: "18.400.13")
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

    private func canonicalize(
        _ snapshot: AccountSnapshot,
        catalog: GameCatalog? = nil
    ) throws -> SnapshotHistoryEntry {
        try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            lineageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            appliedAt: Date(timeIntervalSince1970: 1_700_100_000),
            snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            catalog: catalog
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
}
