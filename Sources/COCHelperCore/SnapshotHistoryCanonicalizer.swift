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
        craftTableCatalog: CraftTableCatalog? = nil,
        sectionProofs: [String: SnapshotCoverageProof] = [:],
        sourceUniverse: SnapshotCoverageSourceUniverse? = nil,
        observationVersion: Int = SnapshotHistorySchema.observation,
        timerSchema: SnapshotTimerSchema? = AccountSnapshotImporter.timerSchema
    ) throws -> SnapshotHistoryEntry {
        if sourceUniverse != nil,
           observationVersion < SnapshotHistorySchema.observationWithSourceUniverse {
            throw SnapshotHistoryCanonicalizationError.sourceUniverseRequiresObservationV6
        }
        let source = try canonicalSource(
            snapshot.originalText,
            observationVersion: observationVersion
        )
        let observation = makeObservation(
            source: source,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog,
            observationVersion: observationVersion,
            timerSchema: timerSchema
        )
        let coverage = makeCoverage(
            source: source,
            originalText: snapshot.originalText,
            catalog: catalog,
            craftTableCatalog: craftTableCatalog,
            sectionProofs: sectionProofs,
            sourceUniverse: sourceUniverse,
            schemaVersion: observationVersion,
            timerSchema: timerSchema
        )
        let normalizedObservation = CanonicalSnapshotObservation(
            schemaVersion: observationVersion,
            rawTopLevelFields: observation.rawTopLevelFields,
            unknownTopLevelFields: observation.unknownTopLevelFields,
            items: observation.items
        )
        let fingerprint = fingerprint(for: normalizedObservation)

        return SnapshotHistoryEntry(
            observationVersion: observationVersion,
            snapshotID: snapshotID,
            villageID: villageID,
            lineageID: lineageID,
            normalizedPlayerTag: OfficialPlayerTagValidator.normalized(snapshot.tag),
            appliedAt: appliedAt,
            sourceTimestamp: snapshot.capturedAt,
            parserVersion: AccountSnapshotImporter.parserVersion,
            canonicalFingerprint: fingerprint,
            rawJSON: snapshot.originalText,
            observation: normalizedObservation,
            coverage: coverage,
            isBaseline: isBaseline,
            baselineReason: baselineReason,
            timerSchema: observationVersion >= SnapshotHistorySchema.observationWithTimerSchema ? timerSchema : nil
        )
    }

    public static func canonicalize(
        snapshot: AccountSnapshot,
        villageID: UUID,
        lineage: SnapshotLineageResolution,
        appliedAt: Date,
        snapshotID: UUID = UUID(),
        catalog: GameCatalog? = nil,
        craftTableCatalog: CraftTableCatalog? = nil,
        sectionProofs: [String: SnapshotCoverageProof] = [:],
        sourceUniverse: SnapshotCoverageSourceUniverse? = nil,
        observationVersion: Int = SnapshotHistorySchema.observation,
        timerSchema: SnapshotTimerSchema? = AccountSnapshotImporter.timerSchema
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
            craftTableCatalog: craftTableCatalog,
            sectionProofs: sectionProofs,
            sourceUniverse: sourceUniverse,
            observationVersion: observationVersion,
            timerSchema: timerSchema
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

    static func integrityFingerprint(
        integrityVersion: Int,
        schemaVersion: Int,
        observationVersion: Int,
        fingerprintVersion: Int,
        snapshotID: UUID,
        villageID: UUID,
        lineageID: UUID,
        normalizedPlayerTag: String?,
        appliedAt: Date,
        sourceTimestamp: Date?,
        parserVersion: String,
        canonicalFingerprint: String,
        rawJSON: String,
        observation: CanonicalSnapshotObservation,
        coverage: SnapshotObservationCoverage,
        isBaseline: Bool,
        baselineReason: SnapshotLineageReason?,
        timerSchema: SnapshotTimerSchema? = nil
    ) -> String {
        let material = SnapshotHistoryIntegrityMaterial(
            integrityVersion: integrityVersion,
            schemaVersion: schemaVersion,
            observationVersion: observationVersion,
            fingerprintVersion: fingerprintVersion,
            snapshotID: snapshotID,
            villageID: villageID,
            lineageID: lineageID,
            normalizedPlayerTag: normalizedPlayerTag,
            appliedAt: appliedAt,
            sourceTimestamp: sourceTimestamp,
            parserVersion: parserVersion,
            canonicalFingerprint: canonicalFingerprint,
            rawJSON: rawJSON,
            observation: observation,
            coverage: coverage,
            isBaseline: isBaseline,
            baselineReason: baselineReason,
            timerSchema: timerSchema
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(material)
        let digest = SHA256.hash(data: data)
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

    private static func canonicalSource(
        _ originalText: String,
        observationVersion: Int
    ) throws -> CanonicalSource {
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

        // Player tag and source timestamp are entry metadata, not observations.
        fields.removeValue(forKey: "tag")
        fields.removeValue(forKey: "timestamp")
        // Issue #208：v5+ 把 coverage 视为 snapshot metadata，从 observation
        // 中移除以免进入 canonicalFingerprint。v4 及更早必须保留，才能按
        // 已持久化 bytes 原样复现 fingerprint。
        if observationVersion >= SnapshotHistorySchema.observationWithoutCoverageMetadata {
            fields.removeValue(forKey: JSONSnapshotCoverageAdapter.contractField)
        }
        let unknown = fields.filter { key, _ in
            !SnapshotHistoryKnownSections.all.contains(key)
                && key != "boosts"
        }
        return CanonicalSource(fields: fields, unknownFields: unknown)
    }

    private static func makeObservation(
        source: CanonicalSource,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?,
        observationVersion: Int,
        timerSchema: SnapshotTimerSchema?
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
                    observationVersion: observationVersion,
                    timerSchema: timerSchema,
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
        observationVersion: Int,
        timerSchema: SnapshotTimerSchema?,
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
        // Issue #175：timer evidence 的收集规则按 observationVersion 分叉——
        // v4+ 由 source adapter 的版本化契约（字段集合）决定，无契约时
        // fail-closed（字段名不再自动权威）；v3 用全局 timerFields allowlist；
        // v2 及更早沿用宽松匹配（历史 entry 重建必须稳定）。
        let timerEvidence = object.filter { key, _ in
            if observationVersion >= SnapshotHistorySchema.observationWithTimerSchema {
                return timerSchema?.fields.keys.contains(key) ?? false
            }
            if observationVersion >= SnapshotHistorySchema.observationWithTimerAllowlist {
                return SnapshotHistoryKnownSections.timerFields.contains(key)
            }
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
            observationVersion: observationVersion,
            timerSchema: timerSchema,
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
            observationVersion: observationVersion,
            timerSchema: timerSchema,
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
        observationVersion: Int,
        timerSchema: SnapshotTimerSchema?,
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
                observationVersion: observationVersion,
                timerSchema: timerSchema,
                into: &items
            )
        }
    }

    private static func displayBinding(
        for identity: SnapshotItemIdentity,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?
    ) -> SnapshotDisplayBinding {
        // Once the separate craft universe is supplied, it is authoritative
        // for nested identities.  An unknown type/module must remain raw and
        // unbound; falling through to GameCatalog could mislabel it when the
        // two catalogs happen to reuse the same dataID.
        if craftTableCatalog != nil,
           identity.nestedKind == .type || identity.nestedKind == .module {
            return craftTableDisplayBinding(
                for: identity,
                catalog: catalog,
                craftTableCatalog: craftTableCatalog
            ) ?? SnapshotDisplayBinding()
        }

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

    private static func makeSectionCoverage(
        base: SnapshotHistoryBase,
        rawSection: String,
        presence: SnapshotSectionPresence,
        completeness: SnapshotCoverageState,
        proof: SnapshotCoverageProof,
        observedCount: Int
    ) -> SnapshotSectionCoverage {
        if SnapshotCoverageVerifier.validatesModuleIssuedProof(proof) {
            return SnapshotSectionCoverage.moduleIssued(
                base: base,
                rawSection: rawSection,
                presence: presence,
                completeness: completeness,
                proof: proof,
                observedCount: observedCount
            )
        }
        return SnapshotSectionCoverage(
            base: base,
            rawSection: rawSection,
            presence: presence,
            completeness: completeness,
            proof: proof,
            observedCount: observedCount
        )
    }

    private static func makeCoverage(
        source: CanonicalSource,
        originalText: String,
        catalog: GameCatalog?,
        craftTableCatalog: CraftTableCatalog?,
        sectionProofs: [String: SnapshotCoverageProof],
        sourceUniverse: SnapshotCoverageSourceUniverse?,
        schemaVersion: Int,
        timerSchema: SnapshotTimerSchema?
    ) -> SnapshotObservationCoverage {
        var fields: [SnapshotCoverageField] = []
        var sections: [SnapshotSectionCoverage] = []
        var diagnostics: [String] = []

        for section in SnapshotHistoryKnownSections.object.sorted() {
            let base = SnapshotHistoryBase(section: section)
            guard let value = source.fields[section] else {
                sections.append(makeSectionCoverage(
                    base: base,
                    rawSection: section,
                    presence: .missing,
                    completeness: .unavailable,
                    proof: proof(for: section, in: sectionProofs, fallback: "源 JSON 缺少 section。"),
                    observedCount: 0
                ))
                appendUnavailable(
                    base: base,
                    section: section,
                    fields: &fields
                )
                continue
            }

            guard case .array(let values) = value else {
                sections.append(makeSectionCoverage(
                    base: base,
                    rawSection: section,
                    presence: .invalid,
                    completeness: .partial,
                    proof: proof(for: section, in: sectionProofs, fallback: "section 不是数组。"),
                    observedCount: 0
                ))
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
            let sectionAnalysis = sectionCoverage(
                section: section,
                values: values,
                proof: sectionProofs[section]
            )
            let boundProof = SnapshotCoverageVerifier.attachPersistedBinding(
                to: sectionAnalysis.proof,
                rawJSON: originalText,
                section: section
            )
            sections.append(makeSectionCoverage(
                base: base,
                rawSection: section,
                presence: values.isEmpty ? .presentEmpty : .presentNonEmpty,
                completeness: sectionAnalysis.completeness,
                proof: boundProof,
                observedCount: values.count
            ))
            diagnostics.append(contentsOf: sectionAnalysis.diagnostics)
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
                } else if isTimerField(field) {
                    state = timerFieldState(
                        objects: objects,
                        invalidObjectCount: values.count - objects.count,
                        field: field,
                        spec: timerSchema?.fields[field]
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
                sections.append(makeSectionCoverage(
                    base: base,
                    rawSection: section,
                    presence: .missing,
                    completeness: .unavailable,
                    proof: proof(for: section, in: sectionProofs, fallback: "源 JSON 缺少 section。"),
                    observedCount: 0
                ))
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
                sections.append(makeSectionCoverage(
                    base: base,
                    rawSection: section,
                    presence: .invalid,
                    completeness: .partial,
                    proof: proof(for: section, in: sectionProofs, fallback: "section 不是数组。"),
                    observedCount: 0
                ))
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
            let sectionAnalysis = sectionCoverage(
                section: section,
                values: values,
                proof: sectionProofs[section]
            )
            let boundProof = SnapshotCoverageVerifier.attachPersistedBinding(
                to: sectionAnalysis.proof,
                rawJSON: originalText,
                section: section
            )
            sections.append(makeSectionCoverage(
                base: base,
                rawSection: section,
                presence: values.isEmpty ? .presentEmpty : .presentNonEmpty,
                completeness: sectionAnalysis.completeness,
                proof: boundProof,
                observedCount: values.count
            ))
            diagnostics.append(contentsOf: sectionAnalysis.diagnostics)
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

        return SnapshotObservationCoverage(
            schemaVersion: schemaVersion,
            fields: fields,
            sections: sections,
            diagnostics: diagnostics,
            sourceUniverse: sourceUniverse
        )
    }

    private struct SectionCoverageAnalysis {
        let completeness: SnapshotCoverageState
        let proof: SnapshotCoverageProof
        let diagnostics: [String]
    }

    private static func sectionCoverage(
        section: String,
        values: [CanonicalJSONValue],
        proof: SnapshotCoverageProof?
    ) -> SectionCoverageAnalysis {
        guard let proof else {
            return SectionCoverageAnalysis(
                completeness: .unavailable,
                proof: .unavailable(reason: "来源未提供 section 完整性证明。"),
                diagnostics: []
            )
        }

        guard proof.isVerified else {
            return SectionCoverageAnalysis(
                completeness: .unavailable,
                proof: proof,
                diagnostics: []
            )
        }

        if let expectedCount = SnapshotCoverageProof.expectedCount(of: proof),
           expectedCount != values.count {
            return SectionCoverageAnalysis(
                completeness: .partial,
                proof: proof,
                diagnostics: [section + ": observed count 与来源声明不一致。"]
            )
        }
        let hasInvalidElement = values.contains { value in
            if case .object(let object) = value {
                if SnapshotHistoryKnownSections.numeric.contains(section) {
                    return true
                }
                // An authoritative source claims the whole section is
                // enumerated; a root record without a usable `data` identity
                // means the enumeration is not well-formed enough to trust.
                guard integer(object["data"]) != nil else { return true }
                // Root completeness does not imply nested content is intact.
                // A malformed or truncated `types`/`modules` array must keep
                // the section from claiming complete coverage.
                for nestedField in ["types", "modules"] {
                    guard let nestedValue = object[nestedField] else { continue }
                    guard case .array(let children) = nestedValue else { return true }
                    if children.contains(where: { child in
                        guard case .object(let childObject) = child else { return true }
                        return integer(childObject["data"]) == nil
                    }) {
                        return true
                    }
                }
                return false
            }
            if SnapshotHistoryKnownSections.numeric.contains(section) {
                return integer(value) == nil
            }
            return true
        }
        guard !hasInvalidElement else {
            return SectionCoverageAnalysis(
                completeness: .partial,
                proof: proof,
                diagnostics: [section + ": section 含无法解析的元素。"]
            )
        }
        return SectionCoverageAnalysis(completeness: .complete, proof: proof, diagnostics: [])
    }

    private static func proof(
        for section: String,
        in proofs: [String: SnapshotCoverageProof],
        fallback: String
    ) -> SnapshotCoverageProof {
        proofs[section] ?? .unavailable(reason: fallback)
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

    private static func timerFieldState(
        objects: [[String: CanonicalJSONValue]],
        invalidObjectCount: Int,
        field: String,
        spec: SnapshotTimerFieldSpec?
    ) -> SnapshotCoverageState {
        guard !objects.isEmpty else {
            return invalidObjectCount == 0 ? .unavailable : .partial
        }

        let present = objects.filter { $0[field] != nil }
        guard !present.isEmpty else {
            // For a non-empty, well-formed section, omission of this optional
            // timer field is an observed inactive/absent state.  An empty
            // section remains unavailable because it contains no item-level
            // evidence at all.
            return invalidObjectCount == 0 ? .complete : .partial
        }

        guard invalidObjectCount == 0,
              present.count == objects.count,
              objects.allSatisfy({ object in
                  guard let value = object[field], let timer = integer(value) else {
                      return false
                  }
                  guard timer >= 0 else { return false }
                  if let minValue = spec?.minValue, timer < minValue { return false }
                  if let maxValue = spec?.maxValue, timer > maxValue { return false }
                  return true
              }) else {
            return .partial
        }
        return .complete
    }

    private static func isTimerField(_ field: String) -> Bool {
        SnapshotHistoryKnownSections.timerFields.contains(field)
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

private struct SnapshotHistoryIntegrityMaterial: Encodable {
    let integrityVersion: Int
    let schemaVersion: Int
    let observationVersion: Int
    let fingerprintVersion: Int
    let snapshotID: UUID
    let villageID: UUID
    let lineageID: UUID
    let normalizedPlayerTag: String?
    let appliedAt: Date
    let sourceTimestamp: Date?
    let parserVersion: String
    let canonicalFingerprint: String
    let rawJSON: String
    let observation: CanonicalSnapshotObservation
    let coverage: SnapshotObservationCoverage
    let isBaseline: Bool
    let baselineReason: SnapshotLineageReason?
    let timerSchema: SnapshotTimerSchema?

    init(
        integrityVersion: Int,
        schemaVersion: Int,
        observationVersion: Int,
        fingerprintVersion: Int,
        snapshotID: UUID,
        villageID: UUID,
        lineageID: UUID,
        normalizedPlayerTag: String?,
        appliedAt: Date,
        sourceTimestamp: Date?,
        parserVersion: String,
        canonicalFingerprint: String,
        rawJSON: String,
        observation: CanonicalSnapshotObservation,
        coverage: SnapshotObservationCoverage,
        isBaseline: Bool,
        baselineReason: SnapshotLineageReason?,
        timerSchema: SnapshotTimerSchema?
    ) {
        self.integrityVersion = integrityVersion
        self.schemaVersion = schemaVersion
        self.observationVersion = observationVersion
        self.fingerprintVersion = fingerprintVersion
        self.snapshotID = snapshotID
        self.villageID = villageID
        self.lineageID = lineageID
        self.normalizedPlayerTag = normalizedPlayerTag
        self.appliedAt = appliedAt
        self.sourceTimestamp = sourceTimestamp
        self.parserVersion = parserVersion
        self.canonicalFingerprint = canonicalFingerprint
        self.rawJSON = rawJSON
        self.observation = observation
        self.coverage = coverage
        self.isBaseline = isBaseline
        self.baselineReason = baselineReason
        self.timerSchema = timerSchema
    }
}
