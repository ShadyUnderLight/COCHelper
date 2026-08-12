import CryptoKit
import Foundation

/// Builds the Issue #135 Core contract from the existing imported snapshot.
///
/// This adapter intentionally does not mutate `AccountSnapshot`, `VillageProfile`
/// or persistence.  It reparses the retained source text so fields that the
/// legacy importer does not yet model remain available to history consumers.
/// `catalog` supplies the root/numeric dataID universe; `craftTableCatalog`
/// supplies the separate `types/modules` universe.  Both are needed for
/// complete dataID validation and immutable display binding of bundled
/// craft-table snapshots.
public enum SnapshotHistoryCanonicalizer {
    public static func canonicalize(
        snapshot: AccountSnapshot,
        villageID: UUID,
        lineageID: UUID,
        appliedAt: Date,
        snapshotID: UUID = UUID(),
        isBaseline: Bool = false,
        baselineReason: SnapshotLineageReason? = nil,
        catalog: GameCatalog? = nil,
        craftTableCatalog: CraftTableCatalog? = nil
    ) throws -> SnapshotHistoryEntry {
        let source = try canonicalSource(snapshot.originalText)
        let observation = makeObservation(
            source: source,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog
        )
        let coverage = makeCoverage(
            source: source,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog
        )
        let fingerprint = fingerprint(for: observation)

        return SnapshotHistoryEntry(
            snapshotID: snapshotID,
            villageID: villageID,
            lineageID: lineageID,
            normalizedPlayerTag: OfficialPlayerTagValidator.normalized(snapshot.tag),
            appliedAt: appliedAt,
            sourceTimestamp: snapshot.capturedAt,
            parserVersion: AccountSnapshotImporter.parserVersion,
            canonicalFingerprint: fingerprint,
            rawJSON: snapshot.originalText,
            observation: observation,
            coverage: coverage,
            isBaseline: isBaseline,
            baselineReason: baselineReason
        )
    }

    public static func canonicalize(
        snapshot: AccountSnapshot,
        villageID: UUID,
        lineage: SnapshotLineageResolution,
        appliedAt: Date,
        snapshotID: UUID = UUID(),
        catalog: GameCatalog? = nil,
        craftTableCatalog: CraftTableCatalog? = nil
    ) throws -> SnapshotHistoryEntry {
        try canonicalize(
            snapshot: snapshot,
            villageID: villageID,
            lineageID: lineage.lineageID,
            appliedAt: appliedAt,
            snapshotID: snapshotID,
            isBaseline: lineage.isBaseline,
            baselineReason: lineage.isBaseline ? lineage.reason : nil,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog
        )
    }

    public static func fingerprint(for observation: CanonicalSnapshotObservation) -> String {
        var items = observation.items.map(fingerprintValue(for:))
        items.sort { $0.canonicalData.lexicographicallyPrecedes($1.canonicalData) }

        let material: CanonicalJSONValue = .object([
            "observationSchemaVersion": .number(String(observation.schemaVersion)),
            "rawTopLevelFields": .object(observation.rawTopLevelFields),
            "unknownTopLevelFields": .object(observation.unknownTopLevelFields),
            "items": .array(items)
        ])
        let digest = SHA256.hash(data: material.canonicalData)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct CanonicalSource {
        let fields: [String: CanonicalJSONValue]
        let unknownFields: [String: CanonicalJSONValue]
    }

    private struct NestedCoverageAnalysis {
        let state: SnapshotCoverageState
        let diagnostics: [String]
    }

    private static func canonicalSource(_ originalText: String) throws -> CanonicalSource {
        let prepared = prepare(originalText)
        guard !prepared.isEmpty else { throw SnapshotHistoryCanonicalizationError.emptySource }

        let source: CanonicalJSONValue
        do {
            guard let data = prepared.data(using: .utf8) else {
                throw SnapshotHistoryCanonicalizationError.invalidJSON("文本不是有效的 UTF-8。")
            }
            source = try CanonicalJSONValue.fromJSONData(data).canonicalized
        } catch let error as SnapshotHistoryCanonicalizationError {
            throw error
        } catch {
            throw SnapshotHistoryCanonicalizationError.invalidJSON(error.localizedDescription)
        }

        guard case .object(var fields) = source else {
            throw SnapshotHistoryCanonicalizationError.topLevelMustBeObject
        }

        // Player tag and source timestamp are stored as entry metadata.  They
        // are not observations and therefore cannot change a content digest.
        fields.removeValue(forKey: "tag")
        fields.removeValue(forKey: "timestamp")
        let unknown = fields.filter { key, _ in
            !SnapshotHistoryKnownSections.all.contains(key)
                && key != "boosts"
        }
        return CanonicalSource(fields: fields, unknownFields: unknown)
    }

    private static func makeObservation(
        source: CanonicalSource,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?
    ) -> CanonicalSnapshotObservation {
        var items: [SnapshotObservationItem] = []

        for section in SnapshotHistoryKnownSections.object.sorted() {
            guard case .array(let values) = source.fields[section] else { continue }
            for value in values {
                guard case .object(let object) = value else { continue }
                appendObjectItem(
                    object,
                    section: section,
                    nestedKind: .root,
                    rootIdentity: nil,
                    rootDataID: nil,
                    parentPath: [],
                    catalog: catalog,
                    craftTableCatalog: craftTableCatalog,
                    into: &items
                )
            }
        }

        for section in SnapshotHistoryKnownSections.numeric.sorted() {
            guard case .array(let values) = source.fields[section] else { continue }
            for value in values {
                guard let dataID = integer(value) else { continue }
                let identity = SnapshotItemIdentity(
                    base: SnapshotHistoryBase(section: section),
                    rawSection: section,
                    dataID: dataID
                )
                items.append(SnapshotObservationItem(
                    identity: identity,
                    display: displayBinding(
                        for: identity,
                        catalog: catalog,
                        craftTableCatalog: craftTableCatalog
                    )
                ))
            }
        }

        items.sort { lhs, rhs in
            let left = fingerprintValue(for: lhs).canonicalData
            let right = fingerprintValue(for: rhs).canonicalData
            return left.lexicographicallyPrecedes(right)
        }

        return CanonicalSnapshotObservation(
            rawTopLevelFields: source.fields,
            unknownTopLevelFields: source.unknownFields,
            items: items
        )
    }

    private static func appendObjectItem(
        _ object: [String: CanonicalJSONValue],
        section: String,
        nestedKind: SnapshotNestedKind,
        rootIdentity: String?,
        rootDataID: Int64?,
        parentPath: [SnapshotNestedPathComponent],
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?,
        into items: inout [SnapshotObservationItem]
    ) {
        guard let dataID = integer(object["data"]) else { return }

        let identity = SnapshotItemIdentity(
            base: SnapshotHistoryBase(section: section),
            rawSection: section,
            dataID: dataID,
            nestedKind: nestedKind,
            nestedRootIdentity: rootIdentity,
            nestedRootDataID: rootDataID,
            nestedParentPath: parentPath
        )

        let knownFields = SnapshotHistoryKnownSections.itemFields
        let unknownFields = object.filter { key, _ in !knownFields.contains(key) }
        let timerEvidence = object.filter { key, _ in
            let normalized = key.lowercased()
            return normalized.contains("timer") || normalized.contains("cooldown")
        }

        items.append(SnapshotObservationItem(
            identity: identity,
            level: integer(object["lvl"]).flatMap(Int.init),
            count: integer(object["cnt"]).flatMap(Int.init),
            rawTimerEvidence: timerEvidence,
            helperRecurrent: boolean(object["helper_recurrent"]),
            gearUp: integer(object["gear_up"]).flatMap(Int.init),
            weapon: integer(object["weapon"]).flatMap(Int.init),
            unknownFields: unknownFields,
            display: displayBinding(
                for: identity,
                catalog: catalog,
                craftTableCatalog: craftTableCatalog
            )
        ))

        // A nested record keeps the identity of the outermost root.  Passing
        // the current identity here would make a module nested under a type
        // look rooted at that type instead of at the building record.
        let childRootIdentity = rootIdentity ?? identity.key
        let childRootDataID = rootDataID ?? dataID
        let childParentPath = parentPath + [
            SnapshotNestedPathComponent(kind: nestedKind, dataID: dataID)
        ]

        appendChildren(
            object["types"],
            section: section,
            kind: .type,
            rootIdentity: childRootIdentity,
            rootDataID: childRootDataID,
            parentPath: childParentPath,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog,
            into: &items
        )
        appendChildren(
            object["modules"],
            section: section,
            kind: .module,
            rootIdentity: childRootIdentity,
            rootDataID: childRootDataID,
            parentPath: childParentPath,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog,
            into: &items
        )
    }

    private static func appendChildren(
        _ value: CanonicalJSONValue?,
        section: String,
        kind: SnapshotNestedKind,
        rootIdentity: String,
        rootDataID: Int64,
        parentPath: [SnapshotNestedPathComponent],
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?,
        into items: inout [SnapshotObservationItem]
    ) {
        guard case .array(let values) = value else { return }
        for child in values {
            guard case .object(let object) = child else { continue }
            appendObjectItem(
                object,
                section: section,
                nestedKind: kind,
                rootIdentity: rootIdentity,
                rootDataID: rootDataID,
                parentPath: parentPath,
                catalog: catalog,
                craftTableCatalog: craftTableCatalog,
                into: &items
            )
        }
    }

    private static func displayBinding(
        for identity: SnapshotItemIdentity,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?
    ) -> SnapshotDisplayBinding {
        if let craftTableBinding = craftTableDisplayBinding(
            for: identity,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog
        ) {
            return craftTableBinding
        }

        guard let catalog else { return SnapshotDisplayBinding() }

        // Display binding belongs to the observed record itself.  Nested
        // records may have their own catalog entry; using rootDataID here
        // would make every child inherit the root building's label.
        let item = catalog.item(section: identity.rawSection, dataID: identity.dataID)
        return SnapshotDisplayBinding(
            displayName: item?.name,
            category: item?.category,
            displayCategory: item?.displayCategory,
            catalogVersion: catalog.gameVersion,
            catalogFingerprint: catalog.manifest?.sourceFingerprint
        )
    }

    private static func craftTableDisplayBinding(
        for identity: SnapshotItemIdentity,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?
    ) -> SnapshotDisplayBinding? {
        guard let craftTableCatalog else { return nil }

        let name: String?
        switch identity.nestedKind {
        case .type:
            name = craftTableCatalog.defense(dataID: identity.dataID)?.name
        case .module:
            name = craftTableCatalog.module(dataID: identity.dataID)?.name
        case .root, .unknown:
            name = nil
        }
        guard let name else { return nil }

        let rootItem = identity.nestedRootDataID.flatMap {
            catalog?.item(section: identity.rawSection, dataID: $0)
        }
        return SnapshotDisplayBinding(
            displayName: name,
            category: rootItem?.category ?? TrackerCategory.from(section: identity.rawSection)?.rawValue,
            displayCategory: TrackerDisplayCategory.craftTable.rawValue,
            catalogVersion: craftTableCatalog.gameVersion,
            catalogFingerprint: craftTableCatalog.sourceFingerprint
        )
    }

    private static func makeCoverage(
        source: CanonicalSource,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?
    ) -> SnapshotObservationCoverage {
        var fields: [SnapshotCoverageField] = []
        var diagnostics: [String] = []

        for section in SnapshotHistoryKnownSections.object.sorted() {
            let base = SnapshotHistoryBase(section: section)
            guard let value = source.fields[section] else {
                appendUnavailable(
                    base: base,
                    section: section,
                    fields: &fields
                )
                continue
            }

            guard case .array(let values) = value else {
                appendPartial(
                    base: base,
                    section: section,
                    fields: &fields
                )
                diagnostics.append("\(section): 顶层值不是数组。")
                continue
            }

            fields.append(SnapshotCoverageField(
                base: base,
                rawSection: section,
                field: "presence",
                state: .complete
            ))
            let records: [(index: Int, object: [String: CanonicalJSONValue]?)] = values.enumerated().map {
                element in
                guard case .object(let object) = element.element else {
                    return (index: element.offset, object: nil)
                }
                return (index: element.offset, object: object)
            }
            let objects = records.compactMap { $0.object }
            let invalidRootRecords = records.filter { $0.object == nil }
            if !invalidRootRecords.isEmpty {
                diagnostics.append("\(section): 数组中存在非对象记录。")
                diagnostics.append(contentsOf: invalidRootRecords.map {
                    "\(section)[\($0.index)]: 根记录不是对象，无法验证 nested fields。"
                })
            }
            for record in records {
                guard let object = record.object else { continue }
                if integer(object["data"]) == nil {
                    diagnostics.append(
                        "\(section)[\(record.index)].data: 缺少有效 dataID，记录未纳入 canonical observation。"
                    )
                }
            }
            for field in SnapshotHistoryKnownSections.itemFields {
                let state: SnapshotCoverageState
                if field == "types" || field == "modules" {
                    let nested = nestedFieldState(
                        records: records,
                        field: field,
                        section: section,
                        catalog: catalog,
                        craftTableCatalog: craftTableCatalog
                    )
                    state = nested.state
                    diagnostics.append(contentsOf: nested.diagnostics)
                } else if field == "data" {
                    state = dataFieldState(
                        records: records,
                        section: section,
                        catalog: catalog,
                        nestedKind: nil,
                        craftTableCatalog: craftTableCatalog,
                        diagnostics: &diagnostics
                    )
                } else {
                    state = fieldState(
                        objects: objects,
                        invalidObjectCount: values.count - objects.count,
                        field: field,
                        isValid: { value in
                            switch field {
                            case "data", "lvl", "cnt", "timer", "helper_timer", "helper_cooldown", "gear_up", "weapon":
                                return integer(value) != nil
                            case "helper_recurrent":
                                return boolean(value) != nil
                            default:
                                return true
                            }
                        }
                    )
                }
                fields.append(SnapshotCoverageField(
                    base: base,
                    rawSection: section,
                    field: field,
                    state: state
                ))
            }
        }

        for section in SnapshotHistoryKnownSections.numeric.sorted() {
            let base = SnapshotHistoryBase(section: section)
            guard let value = source.fields[section] else {
                fields.append(SnapshotCoverageField(
                    base: base,
                    rawSection: section,
                    field: "presence",
                    state: .unavailable
                ))
                fields.append(SnapshotCoverageField(
                    base: base,
                    rawSection: section,
                    field: "data",
                    state: .unavailable
                ))
                continue
            }
            guard case .array(let values) = value else {
                fields.append(SnapshotCoverageField(
                    base: base,
                    rawSection: section,
                    field: "presence",
                    state: .partial
                ))
                fields.append(SnapshotCoverageField(
                    base: base,
                    rawSection: section,
                    field: "data",
                    state: .partial
                ))
                diagnostics.append("\(section): 顶层值不是数组。")
                continue
            }
            fields.append(SnapshotCoverageField(
                base: base,
                rawSection: section,
                field: "presence",
                state: .complete
            ))
            fields.append(SnapshotCoverageField(
                base: base,
                rawSection: section,
                field: "data",
                state: numericDataState(
                    values,
                    section: section,
                    catalog: catalog,
                    nestedKind: nil,
                    craftTableCatalog: craftTableCatalog,
                    diagnostics: &diagnostics
                )
            ))
        }

        for key in source.unknownFields.keys.sorted() {
            fields.append(SnapshotCoverageField(
                base: .unknown,
                rawSection: "$topLevel",
                field: key,
                state: .complete
            ))
        }

        return SnapshotObservationCoverage(fields: fields, diagnostics: diagnostics)
    }

    private static func nestedFieldState(
        records: [(index: Int, object: [String: CanonicalJSONValue]?)],
        field: String,
        section: String,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?
    ) -> NestedCoverageAnalysis {
        guard !records.isEmpty else {
            return NestedCoverageAnalysis(state: .unavailable, diagnostics: [])
        }

        let present = records.compactMap {
            record -> (index: Int, object: [String: CanonicalJSONValue])? in
            guard let object = record.object, object[field] != nil else { return nil }
            return (index: record.index, object: object)
        }
        let hasInvalidRoot = records.contains { record in
            guard let object = record.object else { return true }
            return integer(object["data"]) == nil
        }
        guard !present.isEmpty else {
            return NestedCoverageAnalysis(
                state: hasInvalidRoot ? .partial : .unavailable,
                diagnostics: []
            )
        }

        var state: SnapshotCoverageState = hasInvalidRoot || present.count != records.count
            ? .partial
            : .complete
        var diagnostics: [String] = []
        for record in present {
            let path = "\(section)[\(record.index)].\(field)"
            guard case .array(let values) = record.object[field] else {
                state = .partial
                diagnostics.append("\(path): 嵌套值不是数组。")
                continue
            }
            let nested = validateNestedArray(
                values,
                path: path,
                section: section,
                nestedKind: field == "types" ? .type : .module,
                catalog: catalog,
                craftTableCatalog: craftTableCatalog
            )
            diagnostics.append(contentsOf: nested.diagnostics)
            if nested.state != .complete {
                state = .partial
            }
        }
        return NestedCoverageAnalysis(state: state, diagnostics: diagnostics)
    }

    private static func validateNestedArray(
        _ values: [CanonicalJSONValue],
        path: String,
        section: String,
        nestedKind: SnapshotNestedKind,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?
    ) -> NestedCoverageAnalysis {
        var diagnostics: [String] = []
        var complete = true

        for (index, value) in values.enumerated() {
            let childPath = "\(path)[\(index)]"
            guard case .object(let object) = value else {
                complete = false
                diagnostics.append("\(childPath): 子项不是对象。")
                continue
            }
            if let dataID = integer(object["data"]) {
                if let known = isKnownDataID(
                    dataID,
                    section: section,
                    nestedKind: nestedKind,
                    catalog: catalog,
                    craftTableCatalog: craftTableCatalog
                ), !known {
                    complete = false
                    diagnostics.append(
                        "\(childPath).data: 未知 dataID \(dataID)，不在传入 known dataID universe 中。"
                    )
                }
            } else {
                complete = false
                diagnostics.append(
                    "\(childPath).data: 缺少有效 dataID，记录未纳入 canonical observation。"
                )
            }

            for nestedField in ["types", "modules"] {
                guard let nestedValue = object[nestedField] else { continue }
                let nestedPath = childPath + "." + nestedField
                guard case .array(let nestedValues) = nestedValue else {
                    complete = false
                    diagnostics.append("\(nestedPath): 嵌套值不是数组。")
                    continue
                }
                let nested = validateNestedArray(
                    nestedValues,
                    path: nestedPath,
                    section: section,
                    nestedKind: nestedField == "types" ? .type : .module,
                    catalog: catalog,
                    craftTableCatalog: craftTableCatalog
                )
                diagnostics.append(contentsOf: nested.diagnostics)
                if nested.state != .complete {
                    complete = false
                }
            }
        }

        return NestedCoverageAnalysis(
            state: complete ? .complete : .partial,
            diagnostics: diagnostics
        )
    }

    private static func dataFieldState(
        records: [(index: Int, object: [String: CanonicalJSONValue]?)],
        section: String,
        catalog: GameCatalog?,
        nestedKind: SnapshotNestedKind?,
        craftTableCatalog: CraftTableCatalog?,
        diagnostics: inout [String]
    ) -> SnapshotCoverageState {
        guard !records.isEmpty else { return .complete }

        var state: SnapshotCoverageState = .complete
        for record in records {
            guard let object = record.object else {
                state = .partial
                continue
            }
            guard let dataID = integer(object["data"]) else {
                state = .partial
                continue
            }
            guard let known = isKnownDataID(
                dataID,
                section: section,
                nestedKind: nestedKind,
                catalog: catalog,
                craftTableCatalog: craftTableCatalog
            ) else {
                continue
            }
            guard known else {
                state = .partial
                diagnostics.append(
                    "\(section)[\(record.index)].data: 未知 dataID \(dataID)，不在传入 known dataID universe 中。"
                )
                continue
            }
        }
        return state
    }

    private static func numericDataState(
        _ values: [CanonicalJSONValue],
        section: String,
        catalog: GameCatalog?,
        nestedKind: SnapshotNestedKind?,
        craftTableCatalog: CraftTableCatalog?,
        diagnostics: inout [String]
    ) -> SnapshotCoverageState {
        guard !values.isEmpty else { return .complete }

        var state: SnapshotCoverageState = .complete
        for (index, value) in values.enumerated() {
            guard let dataID = integer(value) else {
                state = .partial
                diagnostics.append("\(section)[\(index)]: 不是有效 dataID。")
                continue
            }
            guard let known = isKnownDataID(
                dataID,
                section: section,
                nestedKind: nestedKind,
                catalog: catalog,
                craftTableCatalog: craftTableCatalog
            ) else {
                continue
            }
            guard known else {
                state = .partial
                diagnostics.append(
                    "\(section)[\(index)]: 未知 dataID \(dataID)，不在传入 known dataID universe 中。"
                )
                continue
            }
        }
        return state
    }

    private static func appendUnavailable(
        base: SnapshotHistoryBase,
        section: String,
        fields: inout [SnapshotCoverageField]
    ) {
        fields.append(SnapshotCoverageField(base: base, rawSection: section, field: "presence", state: .unavailable))
        for field in SnapshotHistoryKnownSections.itemFields {
            fields.append(SnapshotCoverageField(base: base, rawSection: section, field: field, state: .unavailable))
        }
    }

    private static func appendPartial(
        base: SnapshotHistoryBase,
        section: String,
        fields: inout [SnapshotCoverageField]
    ) {
        fields.append(SnapshotCoverageField(base: base, rawSection: section, field: "presence", state: .partial))
        for field in SnapshotHistoryKnownSections.itemFields {
            fields.append(SnapshotCoverageField(base: base, rawSection: section, field: field, state: .partial))
        }
    }

    private static func fieldState(
        objects: [[String: CanonicalJSONValue]],
        invalidObjectCount: Int,
        field: String,
        isValid: (CanonicalJSONValue?) -> Bool
    ) -> SnapshotCoverageState {
        guard !objects.isEmpty else {
            // An empty, well-formed section is complete for required identity
            // data, but provides no evidence for optional fields.
            return invalidObjectCount == 0
                ? (field == "data" ? .complete : .unavailable)
                : .partial
        }
        let present = objects.filter { $0[field] != nil }
        guard !present.isEmpty else {
            return field == "data" ? .partial : .unavailable
        }
        guard invalidObjectCount == 0,
              present.count == objects.count,
              objects.allSatisfy({ isValid($0[field]) }) else {
            return .partial
        }
        return .complete
    }

    private static func fingerprintValue(for item: SnapshotObservationItem) -> CanonicalJSONValue {
        var value: [String: CanonicalJSONValue] = [
            "identity": .object([
                "base": .string(item.identity.base.rawValue),
                "rawSection": .string(item.identity.rawSection),
                "dataID": .number(String(item.identity.dataID)),
                "nestedKind": .string(item.identity.nestedKind.rawValue),
                "nestedRootIdentity": item.identity.nestedRootIdentity.map(CanonicalJSONValue.string) ?? .null,
                "nestedRootDataID": item.identity.nestedRootDataID.map { .number(String($0)) } ?? .null,
                "nestedParentPath": .array(item.identity.nestedParentPath.map {
                    .object([
                        "kind": .string($0.kind.rawValue),
                        "dataID": .number(String($0.dataID))
                    ])
                })
            ]),
            "level": item.level.map { .number(String($0)) } ?? .null,
            "count": item.count.map { .number(String($0)) } ?? .null,
            "rawTimerEvidence": .object(item.rawTimerEvidence),
            "helperRecurrent": item.helperRecurrent.map(CanonicalJSONValue.bool) ?? .null,
            "gearUp": item.gearUp.map { .number(String($0)) } ?? .null,
            "weapon": item.weapon.map { .number(String($0)) } ?? .null,
            "unknownFields": .object(item.unknownFields)
        ]
        // Keep the local variable construction explicit: display metadata is
        // intentionally not fingerprint material, so catalog updates cannot
        // turn the same source snapshot into a different observation.
        value.removeValue(forKey: "display")
        return .object(value)
    }

    private static func integer(_ value: CanonicalJSONValue?) -> Int64? {
        guard case .number(let raw) = value else { return nil }
        return Int64(raw)
    }

    private static func isKnownDataID(
        _ dataID: Int64,
        section: String,
        nestedKind: SnapshotNestedKind?,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?
    ) -> Bool? {
        if let nestedKind, nestedKind != .root {
            guard let craftTableCatalog else { return nil }
            switch nestedKind {
            case .type:
                return craftTableCatalog.defense(dataID: dataID) != nil
            case .module:
                return craftTableCatalog.module(dataID: dataID) != nil
            case .root, .unknown:
                return nil
            }
        }

        guard let catalog, !catalog.items(in: section).isEmpty else { return nil }
        return catalog.item(section: section, dataID: dataID) != nil
    }

    private static func boolean(_ value: CanonicalJSONValue?) -> Bool? {
        guard case .bool(let raw) = value else { return nil }
        return raw
    }

    private static func prepare(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3,
              lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        else {
            return trimmed
        }
        return lines.dropFirst().dropLast().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
