import Foundation

/// Version numbers for the standalone snapshot-history contract.
///
/// These versions are deliberately independent from the current account import
/// format.  Storage and migrations can therefore reject a future history
/// record without changing the legacy `AccountSnapshot` Codable contract.
public enum SnapshotHistorySchema {
    /// v2（Issue #304）：移除 fingerprint/integrity 摘要字段的新 wire 形状。
    /// 旧文件按旧 schema 标记不可用，不迁移、不 fallback。
    public static let envelope = 2
    /// v2（Issue #304）：移除 canonicalFingerprint/integrityFingerprint/version 字段。
    public static let entry = 2
    /// v2 首次引入 section coverage 证据（Issue #164/#173）。
    /// 该版本及以上的 entry 必须携带 section 完整性证明。
    public static let observationWithSectionEvidence = 2
    /// v3 引入 timer evidence allowlist（Issue #175）：canonicalizer 只把
    /// `timerFields` 内的字段收集进 rawTimerEvidence；v2 及更早的 entry
    /// 重建时沿用宽松匹配，保证旧历史 fingerprint 稳定。
    public static let observationWithTimerAllowlist = 3
    /// v4 引入 source timer schema 契约：收集由 adapter 声明的字段集合、
    /// 单位、remaining/absolute 语义与取值范围决定，无契约时 fail-closed。
    public static let observationWithTimerSchema = 4
    /// v5：顶层 `coverage` 从 observation 中移除，作为 snapshot metadata
    /// （Issue #208）。v4 及更早的 entry 重建时必须保留 coverage，才能复现
    /// 已持久化的 observation 身份。
    public static let observationWithoutCoverageMetadata = 5
    /// v6：coverage 冻结 module-issued source universe 契约（Issue #236）。
    /// v5 及更早 entry 无 source universe，UI trust 保持保守 fail-closed。
    public static let observationWithSourceUniverse = 6
    public static let observation = 6
}

/// Issue #175 source timer schema 契约：由 source adapter 版本化声明。
public struct SnapshotTimerSchema: Codable, Hashable, Sendable {
    public let version: String
    public let fields: [String: SnapshotTimerFieldSpec]

    public init(version: String, fields: [String: SnapshotTimerFieldSpec]) {
        self.version = version
        self.fields = fields
    }
}

public struct SnapshotTimerFieldSpec: Codable, Hashable, Sendable {
    public let unit: SnapshotTimerUnit
    public let semantics: SnapshotTimerSemantics
    public let minValue: Int64?
    public let maxValue: Int64?

    public init(
        unit: SnapshotTimerUnit,
        semantics: SnapshotTimerSemantics,
        minValue: Int64? = nil,
        maxValue: Int64? = nil
    ) {
        self.unit = unit
        self.semantics = semantics
        self.minValue = minValue
        self.maxValue = maxValue
    }
}

public enum SnapshotTimerUnit: String, Codable, Hashable, Sendable {
    case seconds
    case milliseconds
}

public enum SnapshotTimerSemantics: String, Codable, Hashable, Sendable {
    /// 剩余时长：随真实时间自然减少，比较时按 elapsed 规范化。
    case remaining
    /// 绝对结束时间戳：不随流逝减少，值不变是自然状态。
    case absolute
}

public enum SnapshotHistoryBase: String, Codable, Hashable, Sendable {
    case home
    case builder
    case unknown

    public init(section: String) {
        if SnapshotHistoryKnownSections.builder.contains(section) {
            self = .builder
        } else if SnapshotHistoryKnownSections.home.contains(section) {
            self = .home
        } else {
            self = .unknown
        }
    }
}

public enum SnapshotNestedKind: String, Codable, Hashable, Sendable {
    case root
    case type
    case module
    case unknown
}

/// A parent segment in a nested identity.  It intentionally contains no
/// array index: duplicate records remain duplicate observations rather than
/// becoming unstable identities when the source array is reordered.
public struct SnapshotNestedPathComponent: Codable, Hashable, Sendable {
    public let kind: SnapshotNestedKind
    public let dataID: Int64

    public init(kind: SnapshotNestedKind, dataID: Int64) {
        self.kind = kind
        self.dataID = dataID
    }
}

/// Stable identity for one observed record.
public struct SnapshotItemIdentity: Codable, Hashable, Sendable, Identifiable {
    public let base: SnapshotHistoryBase
    public let rawSection: String
    public let dataID: Int64
    public let nestedKind: SnapshotNestedKind
    public let nestedRootIdentity: String?
    public let nestedRootDataID: Int64?
    public let nestedParentPath: [SnapshotNestedPathComponent]

    public init(
        base: SnapshotHistoryBase,
        rawSection: String,
        dataID: Int64,
        nestedKind: SnapshotNestedKind = .root,
        nestedRootIdentity: String? = nil,
        nestedRootDataID: Int64? = nil,
        nestedParentPath: [SnapshotNestedPathComponent] = []
    ) {
        self.base = base
        self.rawSection = rawSection
        self.dataID = dataID
        self.nestedKind = nestedKind
        self.nestedRootIdentity = nestedRootIdentity
        self.nestedRootDataID = nestedRootDataID
        self.nestedParentPath = nestedParentPath
    }

    public var id: String { key }

    /// A length-prefixed key prevents collisions from delimiters in future
    /// raw section names while remaining readable in diagnostics and tests.
    public var key: String {
        let components = [
            base.rawValue,
            rawSection,
            String(dataID),
            nestedKind.rawValue,
            nestedRootIdentity ?? "",
            nestedParentPath.map { $0.kind.rawValue + ":" + String($0.dataID) }.joined(separator: ",")
        ]
        return components.map { String($0.utf8.count) + ":" + $0 }.joined(separator: "|")
    }

    public var rootDataID: Int64 { nestedRootDataID ?? dataID }
}

/// Display information captured at history-entry creation time.  A later
/// catalog update must not rewrite this value or be consulted to render old
/// history.
public struct SnapshotDisplayBinding: Codable, Hashable, Sendable {
    public let displayName: String?
    public let category: String?
    public let displayCategory: String?
    public let catalogVersion: String?

    public init(
        displayName: String? = nil,
        category: String? = nil,
        displayCategory: String? = nil,
        catalogVersion: String? = nil
    ) {
        self.displayName = displayName
        self.category = category
        self.displayCategory = displayCategory
        self.catalogVersion = catalogVersion
    }
}

/// One flattened observation.  `rawTimerEvidence` is the source value, not a
/// live countdown calculated from import time.
public struct SnapshotObservationItem: Codable, Hashable, Sendable, Identifiable {
    public let identity: SnapshotItemIdentity
    public let level: Int?
    public let count: Int?
    public let rawTimerEvidence: [String: CanonicalJSONValue]
    public let helperRecurrent: Bool?
    public let gearUp: Int?
    public let weapon: Int?
    public let unknownFields: [String: CanonicalJSONValue]
    public let display: SnapshotDisplayBinding

    public init(
        identity: SnapshotItemIdentity,
        level: Int? = nil,
        count: Int? = nil,
        rawTimerEvidence: [String: CanonicalJSONValue] = [:],
        helperRecurrent: Bool? = nil,
        gearUp: Int? = nil,
        weapon: Int? = nil,
        unknownFields: [String: CanonicalJSONValue] = [:],
        display: SnapshotDisplayBinding = SnapshotDisplayBinding()
    ) {
        self.identity = identity
        self.level = level
        self.count = count
        self.rawTimerEvidence = rawTimerEvidence
        self.helperRecurrent = helperRecurrent
        self.gearUp = gearUp
        self.weapon = weapon
        self.unknownFields = unknownFields
        self.display = display
    }

    public var id: String { identity.key }
}

/// Canonical, order-independent representation of the source observation.
/// `rawTopLevelFields` retains known and unknown source sections after removing
/// volatile entry metadata. `tag` / `timestamp` are always stripped; `coverage`
/// is stripped from observation v5+ (Issue #208) and kept in v4- so persisted
/// fingerprints can be rebuilt. Coverage is audited via `rawJSON` and frozen
/// section proofs. Remaining unknown fields stay here so future consumers
/// can inspect them.
public struct CanonicalSnapshotObservation: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let rawTopLevelFields: [String: CanonicalJSONValue]
    public let unknownTopLevelFields: [String: CanonicalJSONValue]
    public let items: [SnapshotObservationItem]

    public init(
        schemaVersion: Int = SnapshotHistorySchema.observation,
        rawTopLevelFields: [String: CanonicalJSONValue],
        unknownTopLevelFields: [String: CanonicalJSONValue] = [:],
        items: [SnapshotObservationItem]
    ) {
        self.schemaVersion = schemaVersion
        self.rawTopLevelFields = rawTopLevelFields
        self.unknownTopLevelFields = unknownTopLevelFields
        self.items = items
    }
}

public enum SnapshotCoverageState: String, Codable, Hashable, Sendable {
    case complete
    case partial
    case unavailable
}

/// Whether a source section was present in the original JSON.  Presence is
/// intentionally separate from completeness: a parseable array is not proof
/// that the source enumerated the entire section.
public enum SnapshotSectionPresence: String, Codable, Hashable, Sendable {
    case missing
    case presentEmpty
    case presentNonEmpty
    case invalid
}

/// Section coverage trust contract (Issue #205).
///
/// - `declared`: pasted JSON or exporter self-assertion; auditable but not
///   verified. Must not open destructive diff or manual reconciliation gates.
/// - `verified`: auditable adapter metadata. Runtime trust requires a module-issued
///   witness from `SnapshotCoverageVerifier`; wire decode alone is fail-closed.
/// - `legacyAuthoritative`: frozen history wire `kind: authoritative` before
///   the trust model. Runtime trust equals `declared`; encode preserves legacy
///   wire shape so integrity fingerprints stay stable.
/// - `unavailable`: no usable declaration.
public enum SnapshotCoverageProof: Codable, Hashable, Sendable {
    case declared(source: String, version: String, expectedCount: Int?)
    case verified(VerifiedCoverageEvidence)
    case legacyAuthoritative(source: String, version: String, expectedCount: Int?)
    case unavailable(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case source
        case version
        case expectedCount
        case reason
        case adapterID
        case protocolVersion
        case verificationReason
        case verificationRuleVersion
    }

    private enum Kind: String, Codable {
        case authoritative
        case declared
        case verified
        case unavailable
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .declared(let source, let version, let expectedCount):
            try container.encode(Kind.declared, forKey: .kind)
            try container.encode(source, forKey: .source)
            try container.encode(version, forKey: .version)
            try container.encodeIfPresent(expectedCount, forKey: .expectedCount)
        case .verified(let evidence):
            try container.encode(Kind.verified, forKey: .kind)
            try container.encode(evidence.source, forKey: .source)
            try container.encode(evidence.adapterID, forKey: .adapterID)
            try container.encode(evidence.protocolVersion, forKey: .protocolVersion)
            try container.encodeIfPresent(evidence.expectedCount, forKey: .expectedCount)
            try container.encodeIfPresent(evidence.verificationReason, forKey: .verificationReason)
            try container.encodeIfPresent(evidence.verificationRuleVersion, forKey: .verificationRuleVersion)
        case .legacyAuthoritative(let source, let version, let expectedCount):
            // Preserve pre-#205 wire bytes for immutable history integrity.
            try container.encode(Kind.authoritative, forKey: .kind)
            try container.encode(source, forKey: .source)
            try container.encode(version, forKey: .version)
            try container.encodeIfPresent(expectedCount, forKey: .expectedCount)
        case .unavailable(let reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .authoritative:
            self = .legacyAuthoritative(
                source: try container.decode(String.self, forKey: .source),
                version: try container.decode(String.self, forKey: .version),
                expectedCount: try container.decodeIfPresent(Int.self, forKey: .expectedCount)
            )
        case .declared:
            self = .declared(
                source: try container.decode(String.self, forKey: .source),
                version: try container.decode(String.self, forKey: .version),
                expectedCount: try container.decodeIfPresent(Int.self, forKey: .expectedCount)
            )
        case .verified:
            self = .verified(
                VerifiedCoverageEvidence(
                    decodedWire: try container.decode(String.self, forKey: .source),
                    adapterID: try container.decode(String.self, forKey: .adapterID),
                    protocolVersion: try container.decode(String.self, forKey: .protocolVersion),
                    expectedCount: try container.decodeIfPresent(Int.self, forKey: .expectedCount),
                    verificationReason: try container.decodeIfPresent(String.self, forKey: .verificationReason),
                    verificationRuleVersion: try container.decodeIfPresent(
                        String.self,
                        forKey: .verificationRuleVersion
                    )
                )
            )
        case .unavailable:
            self = .unavailable(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    /// Whether this proof may open destructive absence/quantity inference gates.
    public var isVerified: Bool {
        SnapshotCoverageVerifier.validatesModuleIssuedProof(self)
    }

    /// Persisted verified wire metadata (not sufficient alone for trust gates).
    public var hasVerifiedWireMetadata: Bool {
        SnapshotCoverageVerifier.isWellFormedVerifiedWireProof(self)
    }

    /// Whether a declaration is syntactically well-formed (not the same as verified).
    public var isWellFormedDeclaration: Bool {
        switch self {
        case .declared(let source, let version, let expectedCount),
             .legacyAuthoritative(let source, let version, let expectedCount):
            guard Self.isNonBlankSource(source), Self.isParsableProtocolVersion(version) else {
                return false
            }
            return expectedCount == nil || expectedCount! >= 0
        case .verified, .unavailable:
            return false
        }
    }

    /// source 必须含非空白字符——纯空白来源没有可审计的标识价值。
    private static func isNonBlankSource(_ source: String) -> Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 协议版本必须是 1–3 段 ASCII 数字("1"、"1.2"、"1.2.3")。
    private static func isParsableProtocolVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return false }
        return components.allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber)
        }
    }

    static func expectedCount(of proof: SnapshotCoverageProof) -> Int? {
        switch proof {
        case .declared(_, _, let expectedCount),
             .legacyAuthoritative(_, _, let expectedCount):
            return expectedCount
        case .verified(let evidence):
            return evidence.expectedCount
        case .unavailable:
            return nil
        }
    }
}

/// Frozen completeness evidence for one raw source section.
public struct SnapshotSectionCoverage: Codable, Hashable, Sendable, Identifiable {
    public let base: SnapshotHistoryBase
    public let rawSection: String
    public let presence: SnapshotSectionPresence
    public let completeness: SnapshotCoverageState
    public let proof: SnapshotCoverageProof
    public let observedCount: Int
    /// Runtime trust; not serialized and excluded from duplicate / integrity identity.
    package var runtimeTrust: SectionCoverageRuntimeTrust

    public init(
        base: SnapshotHistoryBase,
        rawSection: String,
        presence: SnapshotSectionPresence,
        completeness: SnapshotCoverageState,
        proof: SnapshotCoverageProof,
        observedCount: Int
    ) {
        self.base = base
        self.rawSection = rawSection
        self.presence = presence
        self.completeness = completeness
        self.proof = proof
        self.observedCount = max(0, observedCount)
        self.runtimeTrust = proof.hasVerifiedWireMetadata ? .pending : .notApplicable
    }

    /// Module-issued verified proof with live runtime witness (Issue #234).
    static func moduleIssued(
        base: SnapshotHistoryBase,
        rawSection: String,
        presence: SnapshotSectionPresence,
        completeness: SnapshotCoverageState,
        proof: SnapshotCoverageProof,
        observedCount: Int
    ) -> SnapshotSectionCoverage {
        guard SnapshotCoverageVerifier.validatesModuleIssuedProof(proof) else {
            preconditionFailure("moduleIssued factory requires module-issued verified proof")
        }
        return SnapshotSectionCoverage(
            base: base,
            rawSection: rawSection,
            presence: presence,
            completeness: completeness,
            proof: proof,
            observedCount: observedCount,
            runtimeTrust: .trusted
        )
    }

    /// Load-time revalidation or internal hydration (Issue #234).
    init(
        base: SnapshotHistoryBase,
        rawSection: String,
        presence: SnapshotSectionPresence,
        completeness: SnapshotCoverageState,
        proof: SnapshotCoverageProof,
        observedCount: Int,
        runtimeTrust: SectionCoverageRuntimeTrust
    ) {
        self.base = base
        self.rawSection = rawSection
        self.presence = presence
        self.completeness = completeness
        self.proof = proof
        self.observedCount = max(0, observedCount)
        self.runtimeTrust = runtimeTrust
    }

    public var id: String {
        [base.rawValue, rawSection].map { String($0.utf8.count) + ":" + $0 }.joined(separator: "|")
    }

    public var opensTrustGates: Bool {
        proof.hasVerifiedWireMetadata && runtimeTrust.opensTrustGates
    }

    public var isComplete: Bool {
        completeness == .complete && opensTrustGates
    }

    /// Issue #224: persisted wire metadata vs runtime trust.
    public var verifiedPersistedTrust: VerifiedCoveragePersistedTrust? {
        guard proof.hasVerifiedWireMetadata else { return nil }
        switch runtimeTrust {
        case .trusted:
            return .runtimeTrusted
        case .pending:
            return .pendingRevalidation
        case .rejected:
            return .insufficientPersistedEvidence
        case .notApplicable:
            return .insufficientPersistedEvidence
        }
    }

    public static func == (lhs: SnapshotSectionCoverage, rhs: SnapshotSectionCoverage) -> Bool {
        lhs.base == rhs.base
            && lhs.rawSection == rhs.rawSection
            && lhs.presence == rhs.presence
            && lhs.completeness == rhs.completeness
            && lhs.proof == rhs.proof
            && lhs.observedCount == rhs.observedCount
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(base)
        hasher.combine(rawSection)
        hasher.combine(presence)
        hasher.combine(completeness)
        hasher.combine(proof)
        hasher.combine(observedCount)
    }

    private enum CodingKeys: String, CodingKey {
        case base
        case rawSection
        case presence
        case completeness
        case proof
        case observedCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let proof = try container.decode(SnapshotCoverageProof.self, forKey: .proof)
        self.init(
            base: try container.decode(SnapshotHistoryBase.self, forKey: .base),
            rawSection: try container.decode(String.self, forKey: .rawSection),
            presence: try container.decode(SnapshotSectionPresence.self, forKey: .presence),
            completeness: try container.decode(SnapshotCoverageState.self, forKey: .completeness),
            proof: proof,
            observedCount: try container.decode(Int.self, forKey: .observedCount)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(base, forKey: .base)
        try container.encode(rawSection, forKey: .rawSection)
        try container.encode(presence, forKey: .presence)
        try container.encode(completeness, forKey: .completeness)
        try container.encode(proof, forKey: .proof)
        try container.encode(observedCount, forKey: .observedCount)
    }
}

public struct SnapshotCoverageField: Codable, Hashable, Sendable, Identifiable {
    public let base: SnapshotHistoryBase
    public let rawSection: String
    public let field: String
    public let state: SnapshotCoverageState

    public init(
        base: SnapshotHistoryBase,
        rawSection: String,
        field: String,
        state: SnapshotCoverageState
    ) {
        self.base = base
        self.rawSection = rawSection
        self.field = field
        self.state = state
    }

    public var id: String {
        [base.rawValue, rawSection, field].map { String($0.utf8.count) + ":" + $0 }.joined(separator: "|")
    }
}

public struct SnapshotObservationCoverage: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let fields: [SnapshotCoverageField]
    public let sections: [SnapshotSectionCoverage]
    public let diagnostics: [String]
    /// Module-issued source universe contract (Issue #236). Absent for v1–v5 history.
    public let sourceUniverse: SnapshotCoverageSourceUniverse?
    /// Runtime trust for `sourceUniverse`; not serialized or part of duplicate identity.
    package var sourceUniverseRuntimeTrust: SourceUniverseRuntimeTrust

    public init(
        schemaVersion: Int = SnapshotHistorySchema.observation,
        fields: [SnapshotCoverageField],
        sections: [SnapshotSectionCoverage] = [],
        diagnostics: [String] = [],
        sourceUniverse: SnapshotCoverageSourceUniverse? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.fields = fields.sorted { $0.id < $1.id }
        self.sections = sections.sorted { $0.id < $1.id }
        self.diagnostics = diagnostics.sorted()
        self.sourceUniverse = sourceUniverse
        self.sourceUniverseRuntimeTrust = Self.initialUniverseTrust(for: sourceUniverse)
    }

    /// Load-time hydration and internal tests only.
    package init(
        schemaVersion: Int,
        fields: [SnapshotCoverageField],
        sections: [SnapshotSectionCoverage],
        diagnostics: [String],
        sourceUniverse: SnapshotCoverageSourceUniverse?,
        sourceUniverseRuntimeTrust: SourceUniverseRuntimeTrust
    ) {
        self.schemaVersion = schemaVersion
        self.fields = fields.sorted { $0.id < $1.id }
        self.sections = sections.sorted { $0.id < $1.id }
        self.diagnostics = diagnostics.sorted()
        self.sourceUniverse = sourceUniverse
        self.sourceUniverseRuntimeTrust = sourceUniverseRuntimeTrust
    }

    package static func initialUniverseTrust(
        for universe: SnapshotCoverageSourceUniverse?
    ) -> SourceUniverseRuntimeTrust {
        guard let universe else { return .notApplicable }
        return universe.runtimeWitness == .moduleIssued ? .trusted : .pending
    }

    public static func == (lhs: SnapshotObservationCoverage, rhs: SnapshotObservationCoverage) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.fields == rhs.fields
            && lhs.sections == rhs.sections
            && lhs.diagnostics == rhs.diagnostics
            && lhs.sourceUniverse == rhs.sourceUniverse
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(schemaVersion)
        hasher.combine(fields)
        hasher.combine(sections)
        hasher.combine(diagnostics)
        hasher.combine(sourceUniverse)
    }

    public func state(
        base: SnapshotHistoryBase,
        rawSection: String,
        field: String
    ) -> SnapshotCoverageState? {
        fields.first {
            $0.base == base && $0.rawSection == rawSection && $0.field == field
        }?.state
    }

    public func section(
        base: SnapshotHistoryBase,
        rawSection: String
    ) -> SnapshotSectionCoverage? {
        sections.first { $0.base == base && $0.rawSection == rawSection }
    }

    /// Records written before the section evidence contract are readable but
    /// cannot prove that an observed array was complete.
    public var hasLegacySectionCoverage: Bool {
        schemaVersion < SnapshotHistorySchema.observationWithSectionEvidence || sections.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case fields
        case sections
        case diagnostics
        case sourceUniverse
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? SnapshotHistorySchema.observation
        let sourceUniverse: SnapshotCoverageSourceUniverse?
        if schemaVersion >= SnapshotHistorySchema.observationWithSourceUniverse {
            sourceUniverse = try container.decodeIfPresent(
                SnapshotCoverageSourceUniverse.self,
                forKey: .sourceUniverse
            )
        } else {
            sourceUniverse = nil
        }
        self.init(
            schemaVersion: schemaVersion,
            fields: try container.decode([SnapshotCoverageField].self, forKey: .fields),
            sections: try container.decodeIfPresent([SnapshotSectionCoverage].self, forKey: .sections)
                ?? [],
            diagnostics: try container.decodeIfPresent([String].self, forKey: .diagnostics) ?? [],
            sourceUniverse: sourceUniverse
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(fields, forKey: .fields)
        // Legacy v1 records were written without section evidence.  Omitting
        // the key keeps their serialized bytes and integrity digest identical
        // to the original format; the Diff engine treats them as legacy and
        // never backfills them from the current catalog.
        if schemaVersion >= SnapshotHistorySchema.observationWithSectionEvidence {
            try container.encode(sections, forKey: .sections)
        }
        try container.encode(diagnostics, forKey: .diagnostics)
        if schemaVersion >= SnapshotHistorySchema.observationWithSourceUniverse,
           let sourceUniverse {
            try container.encode(sourceUniverse, forKey: .sourceUniverse)
        }
    }
}

/// Duplicate / Diff 用的 coverage 身份：只含可序列化、immutable 的 provenance。
///
/// `VerifiedCoverageEvidence.runtimeWitness` 是进程内瞬态状态，encode 后丢失；
/// 不得进入 duplicate identity，否则 save/reload 会把同一份历史拆成新 snapshot。
public struct SnapshotHistoryCoverageDuplicateKey: Hashable, Sendable {
    public let schemaVersion: Int
    public let fields: [SnapshotCoverageField]
    public let sections: [SnapshotHistorySectionDuplicateKey]
    public let diagnostics: [String]
    public let sourceUniverse: SnapshotCoverageSourceUniverse?

    public init(_ coverage: SnapshotObservationCoverage) {
        self.schemaVersion = coverage.schemaVersion
        self.fields = coverage.fields
        self.sections = coverage.sections.map(SnapshotHistorySectionDuplicateKey.init)
        self.diagnostics = coverage.diagnostics
        self.sourceUniverse = coverage.sourceUniverse
    }
}

public struct SnapshotHistorySectionDuplicateKey: Hashable, Sendable {
    public let base: SnapshotHistoryBase
    public let rawSection: String
    public let presence: SnapshotSectionPresence
    public let completeness: SnapshotCoverageState
    public let proof: SnapshotHistoryProofDuplicateKey
    public let observedCount: Int

    public init(_ section: SnapshotSectionCoverage) {
        self.base = section.base
        self.rawSection = section.rawSection
        self.presence = section.presence
        self.completeness = section.completeness
        self.proof = SnapshotHistoryProofDuplicateKey(section.proof)
        self.observedCount = section.observedCount
    }
}

public enum SnapshotHistoryProofDuplicateKey: Hashable, Sendable {
    case declared(source: String, version: String, expectedCount: Int?)
    case verified(
        source: String,
        adapterID: String,
        protocolVersion: String,
        expectedCount: Int?,
        verificationReason: String?,
        verificationRuleVersion: String?
    )
    case legacyAuthoritative(source: String, version: String, expectedCount: Int?)
    case unavailable(reason: String)

    public init(_ proof: SnapshotCoverageProof) {
        switch proof {
        case .declared(let source, let version, let expectedCount):
            self = .declared(source: source, version: version, expectedCount: expectedCount)
        case .verified(let evidence):
            self = .verified(
                source: evidence.source,
                adapterID: evidence.adapterID,
                protocolVersion: evidence.protocolVersion,
                expectedCount: evidence.expectedCount,
                verificationReason: evidence.verificationReason,
                verificationRuleVersion: evidence.verificationRuleVersion
            )
        case .legacyAuthoritative(let source, let version, let expectedCount):
            self = .legacyAuthoritative(source: source, version: version, expectedCount: expectedCount)
        case .unavailable(let reason):
            self = .unavailable(reason: reason)
        }
    }
}

public enum SnapshotLineageOutcome: String, Codable, Hashable, Sendable {
    case initial
    case continued
    case newLineage
    case unknown
}

public enum SnapshotLineageReason: String, Codable, Hashable, Sendable {
    case initial
    case sameVillageAndTag
    case tagChanged
    case missingTag
    case invalidTag
    case villageChanged
    case previousConflict
}

/// Minimal context supplied by a future storage layer.  This type deliberately
/// does not read UserDefaults or mutate any history itself.
public struct SnapshotLineageContext: Codable, Hashable, Sendable {
    public let villageID: UUID
    public let lineageID: UUID
    public let normalizedPlayerTag: String?
    public let hasConflict: Bool

    public init(
        villageID: UUID,
        lineageID: UUID,
        normalizedPlayerTag: String?,
        hasConflict: Bool = false
    ) {
        self.villageID = villageID
        self.lineageID = lineageID
        self.normalizedPlayerTag = normalizedPlayerTag
        self.hasConflict = hasConflict
    }
}

public struct SnapshotLineageResolution: Codable, Hashable, Sendable {
    public let lineageID: UUID
    public let outcome: SnapshotLineageOutcome
    public let reason: SnapshotLineageReason
    public let isBaseline: Bool
    public let comparisonAllowed: Bool

    public init(
        lineageID: UUID,
        outcome: SnapshotLineageOutcome,
        reason: SnapshotLineageReason,
        isBaseline: Bool,
        comparisonAllowed: Bool
    ) {
        self.lineageID = lineageID
        self.outcome = outcome
        self.reason = reason
        self.isBaseline = isBaseline
        self.comparisonAllowed = comparisonAllowed
    }
}

public enum SnapshotLineageResolver {
    private enum TagStatus {
        case missing
        case invalid
        case valid(String)
    }

    public static func resolve(
        villageID: UUID,
        normalizedPlayerTag rawTag: String?,
        previous: SnapshotLineageContext?
    ) -> SnapshotLineageResolution {
        let tagStatus = status(of: rawTag)

        guard case .valid = tagStatus else {
            return SnapshotLineageResolution(
                lineageID: UUID(),
                outcome: .unknown,
                reason: reason(for: tagStatus),
                isBaseline: true,
                comparisonAllowed: false
            )
        }

        guard let previous else {
            return SnapshotLineageResolution(
                lineageID: UUID(),
                outcome: .initial,
                reason: .initial,
                isBaseline: true,
                comparisonAllowed: false
            )
        }

        let previousTagStatus = status(of: previous.normalizedPlayerTag)

        guard previous.villageID == villageID else {
            return SnapshotLineageResolution(
                lineageID: UUID(),
                outcome: .unknown,
                reason: .villageChanged,
                isBaseline: true,
                comparisonAllowed: false
            )
        }

        guard !previous.hasConflict else {
            return SnapshotLineageResolution(
                lineageID: UUID(),
                outcome: .unknown,
                reason: .previousConflict,
                isBaseline: true,
                comparisonAllowed: false
            )
        }

        guard case .valid(let tag) = tagStatus,
              case .valid(let previousTag) = previousTagStatus else {
            // An unconfirmed identity is intentionally never joined to a prior
            // record.  A later storage layer can keep the record, but must
            // suppress a diff until a confirmed lineage is available again.
            return SnapshotLineageResolution(
                lineageID: UUID(),
                outcome: .unknown,
                reason: reason(for: previousTagStatus),
                isBaseline: true,
                comparisonAllowed: false
            )
        }

        if tag == previousTag {
            return SnapshotLineageResolution(
                lineageID: previous.lineageID,
                outcome: .continued,
                reason: .sameVillageAndTag,
                isBaseline: false,
                comparisonAllowed: true
            )
        }

        return SnapshotLineageResolution(
            lineageID: UUID(),
            outcome: .newLineage,
            reason: .tagChanged,
            isBaseline: true,
            comparisonAllowed: false
        )
    }

    private static func status(of rawTag: String?) -> TagStatus {
        guard let normalized = OfficialPlayerTagValidator.normalized(rawTag) else {
            return .missing
        }
        guard OfficialPlayerTagValidator.isValid(normalized) else {
            return .invalid
        }
        return .valid(normalized)
    }

    private static func reason(for status: TagStatus) -> SnapshotLineageReason {
        switch status {
        case .missing: .missingTag
        case .invalid: .invalidTag
        case .valid: .sameVillageAndTag
        }
    }
}

public struct SnapshotHistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let observationVersion: Int
    public let snapshotID: UUID
    public let villageID: UUID
    public let lineageID: UUID
    public let normalizedPlayerTag: String?
    /// User-confirmed local commit time; never used as source evidence.
    public let appliedAt: Date
    /// Timestamp copied from the source payload, if present.
    public let sourceTimestamp: Date?
    public let parserVersion: String
    public let rawJSON: String
    public let observation: CanonicalSnapshotObservation
    public let coverage: SnapshotObservationCoverage
    public let isBaseline: Bool
    public let baselineReason: SnapshotLineageReason?
    /// Issue #175：v4+ entry 冻结的 source timer schema 契约（provenance）。
    /// 旧版本 entry 解码时缺省为 nil。
    public let timerSchema: SnapshotTimerSchema?

    public init(
        schemaVersion: Int = SnapshotHistorySchema.entry,
        observationVersion: Int = SnapshotHistorySchema.observation,
        snapshotID: UUID,
        villageID: UUID,
        lineageID: UUID,
        normalizedPlayerTag: String?,
        appliedAt: Date,
        sourceTimestamp: Date?,
        parserVersion: String,
        rawJSON: String,
        observation: CanonicalSnapshotObservation,
        coverage: SnapshotObservationCoverage,
        isBaseline: Bool,
        baselineReason: SnapshotLineageReason?,
        timerSchema: SnapshotTimerSchema? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.observationVersion = observationVersion
        self.snapshotID = snapshotID
        self.villageID = villageID
        self.lineageID = lineageID
        self.normalizedPlayerTag = normalizedPlayerTag
        self.appliedAt = appliedAt
        self.sourceTimestamp = sourceTimestamp
        self.parserVersion = parserVersion
        self.rawJSON = rawJSON
        self.observation = observation
        self.coverage = coverage
        self.isBaseline = isBaseline
        self.baselineReason = baselineReason
        self.timerSchema = timerSchema
    }

    public var id: UUID { snapshotID }
}

extension SnapshotHistoryEntry {
    /// Issue #224 / #273: restore runtime trust for persisted verified coverage after decode.
    public func hydratingVerifiedCoverage(
        policy: SnapshotCoverageRevalidationPolicy = .production
    ) -> SnapshotHistoryEntry {
        SnapshotCoverageTrustHydration.hydrate(entry: self, policy: policy)
    }
}

public enum SnapshotHistoryCanonicalizationError: Error, LocalizedError, Equatable, Sendable {
    case emptySource
    case topLevelMustBeObject
    case invalidJSON(String)
    case sourceUniverseRequiresObservationV6

    public var errorDescription: String? {
        switch self {
        case .emptySource:
            "快照原文为空，无法建立历史观察。"
        case .topLevelMustBeObject:
            "快照原文顶层必须是对象。"
        case .invalidJSON(let message):
            "快照原文不是有效 JSON：" + message
        case .sourceUniverseRequiresObservationV6:
            "source universe 需要 observation v6 或更高版本。"
        }
    }
}

/// A JSON value with a deterministic, order-independent byte representation.
/// The Codable representation is tagged so number tokens remain distinguishable
/// from strings when this auditable value is persisted.
public enum CanonicalJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([CanonicalJSONValue])
    case object([String: CanonicalJSONValue])

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case items
        case fields
    }

    private enum Kind: String, Codable {
        case null
        case bool
        case number
        case string
        case array
        case object
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .null:
            self = .null
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .number:
            self = .number(try container.decode(String.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .array:
            self = .array(try container.decode([CanonicalJSONValue].self, forKey: .items))
        case .object:
            self = .object(try container.decode([String: CanonicalJSONValue].self, forKey: .fields))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .array(let values):
            try container.encode(Kind.array, forKey: .kind)
            try container.encode(values, forKey: .items)
        case .object(let values):
            try container.encode(Kind.object, forKey: .kind)
            try container.encode(values, forKey: .fields)
        }
    }

    public static func fromJSONData(_ data: Data) throws -> CanonicalJSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try fromJSONObject(object)
    }

    public static func fromJSONObject(_ object: Any) throws -> CanonicalJSONValue {
        if object is NSNull {
            return .null
        }
        if let value = object as? String {
            return .string(value)
        }
        if let number = object as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "c" || type == "B" {
                return .bool(number.boolValue)
            }
            return .number(number.stringValue)
        }
        if let values = object as? [Any] {
            return .array(try values.map(fromJSONObject))
        }
        if let values = object as? [String: Any] {
            var result: [String: CanonicalJSONValue] = [:]
            for key in values.keys.sorted() {
                result[key] = try fromJSONObject(values[key]!)
            }
            return .object(result)
        }
        throw NSError(
            domain: "COCHelper.CanonicalJSONValue",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "发现不支持的 JSON 值类型。"]
        )
    }

    /// Canonical JSON bytes: object keys are sorted and array elements are
    /// sorted by their own canonical bytes.  Duplicate array elements remain.
    public var canonicalized: CanonicalJSONValue {
        switch self {
        case .null, .bool, .number, .string:
            return self
        case .array(let values):
            let normalized = values.map(\.canonicalized)
            return .array(Self.sortedByCanonicalData(normalized))
        case .object(let values):
            return .object(values.mapValues(\.canonicalized))
        }
    }

    public var canonicalData: Data {
        switch self {
        case .null:
            return Data("null".utf8)
        case .bool(let value):
            return Data((value ? "true" : "false").utf8)
        case .number(let value):
            return Data(value.utf8)
        case .string(let value):
            return Self.jsonStringData(value)
        case .array(let values):
            let encoded = values.map(\.canonicalData).sorted { $0.lexicographicallyPrecedes($1) }
            return Self.joined(encoded, open: "[", close: "]")
        case .object(let values):
            var pieces: [Data] = []
            for key in values.keys.sorted() {
                var piece = Self.jsonStringData(key)
                piece.append(58)
                piece.append(values[key]!.canonicalData)
                pieces.append(piece)
            }
            return Self.joined(pieces, open: "{", close: "}")
        }
    }

    /// Sort by a precomputed canonical-data key so comparators never
    /// re-serialize the same value on each comparison.
    static func sortedByCanonicalData(_ values: [CanonicalJSONValue]) -> [CanonicalJSONValue] {
        sortedByCanonicalData(values, representing: { $0 })
    }

    static func sortedByCanonicalData<T>(
        _ items: [T],
        representing: (T) -> CanonicalJSONValue
    ) -> [T] {
        items
            .map { item -> (Data, T) in (representing(item).canonicalData, item) }
            .sorted { $0.0.lexicographicallyPrecedes($1.0) }
            .map(\.1)
    }

    /// Deterministic JSON string encoding matching `JSONSerialization`
    /// compact output, without allocating an `_NSJSONWriter` per string.
    private static func jsonStringData(_ value: String) -> Data {
        var result = Data()
        result.reserveCapacity(value.utf8.count + 2)
        result.append(0x22)
        for byte in value.utf8 {
            switch byte {
            case 0x22:
                result.append(contentsOf: [0x5C, 0x22])
            case 0x2F:
                // Apple JSONSerialization 会转义 solidus（\/）；必须逐字节一致，
                // 否则已有历史的 fingerprint 会对不上。
                result.append(contentsOf: [0x5C, 0x2F])
            case 0x5C:
                result.append(contentsOf: [0x5C, 0x5C])
            case 0x08:
                result.append(contentsOf: [0x5C, 0x62])
            case 0x09:
                result.append(contentsOf: [0x5C, 0x74])
            case 0x0A:
                result.append(contentsOf: [0x5C, 0x6E])
            case 0x0C:
                result.append(contentsOf: [0x5C, 0x66])
            case 0x0D:
                result.append(contentsOf: [0x5C, 0x72])
            case 0x00...0x1F:
                result.append(contentsOf: [0x5C, 0x75, 0x30, 0x30])
                result.append(hexNibble(byte >> 4))
                result.append(hexNibble(byte & 0x0F))
            default:
                result.append(byte)
            }
        }
        result.append(0x22)
        return result
    }

    private static func hexNibble(_ value: UInt8) -> UInt8 {
        value < 10 ? (0x30 as UInt8) + value : (0x61 as UInt8) + (value - 10)
    }

    private static func joined(_ values: [Data], open: String, close: String) -> Data {
        var result = Data(open.utf8)
        for (index, value) in values.enumerated() {
            if index > 0 { result.append(44) }
            result.append(value)
        }
        result.append(Data(close.utf8))
        return result
    }
}

enum SnapshotHistoryKnownSections {
    static let object: Set<String> = [
        "helpers", "guardians", "buildings", "traps", "decos", "obstacles", "units",
        "siege_machines", "heroes", "spells", "pets", "equipment", "buildings2", "traps2",
        "decos2", "obstacles2", "units2", "heroes2"
    ]

    static let numeric: Set<String> = [
        "house_parts", "skins", "sceneries", "skins2", "sceneries2"
    ]

    static let builder: Set<String> = object.union(numeric).filter { $0.hasSuffix("2") }
    static let home: Set<String> = object.union(numeric).filter { !$0.hasSuffix("2") }
    static let all: Set<String> = object.union(numeric)
    static let topLevelMetadata: Set<String> = ["tag", "timestamp", "boosts"]
    /// Issue #175 source contract：唯一允许进入 timer 业务 reducer 的字段。
    /// 名字相似但不在契约内的未知字段（如 timer_state、cooldown_remaining）
    /// 只保留在 unknownFields / raw JSON，不得驱动升级/完成判定。
    static let timerFields: Set<String> = [
        "timer", "helper_timer", "helper_cooldown"
    ]
    static let itemFields: Set<String> = [
        "data", "lvl", "cnt", "timer", "helper_timer", "helper_cooldown",
        "helper_recurrent", "gear_up", "weapon", "types", "modules"
    ]
}
