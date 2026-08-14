import Foundation

/// Version numbers for the standalone snapshot-history contract.
///
/// These versions are deliberately independent from the current account import
/// format.  Storage and migrations can therefore reject a future history
/// record without changing the legacy `AccountSnapshot` Codable contract.
public enum SnapshotHistorySchema {
    public static let envelope = 1
    public static let entry = 1
    public static let observation = 2
    public static let fingerprint = 1
    public static let integrity = 1
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
    public let catalogFingerprint: String?

    public init(
        displayName: String? = nil,
        category: String? = nil,
        displayCategory: String? = nil,
        catalogVersion: String? = nil,
        catalogFingerprint: String? = nil
    ) {
        self.displayName = displayName
        self.category = category
        self.displayCategory = displayCategory
        self.catalogVersion = catalogVersion
        self.catalogFingerprint = catalogFingerprint
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
/// `rawTopLevelFields` retains known and unknown source sections after only
/// removing volatile `tag` and `timestamp` metadata.  This gives future
/// consumers an auditable escape hatch without silently dropping new fields.
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

/// Evidence that permits absence to be interpreted as a real observation.
/// The current account JSON adapter has no such source-level proof and uses
/// `unavailable`; future adapters may provide an explicit authoritative
/// protocol and version.
public enum SnapshotCoverageProof: Codable, Hashable, Sendable {
    case authoritative(source: String, version: String, expectedCount: Int?)
    case unavailable(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case source
        case version
        case expectedCount
        case reason
    }

    private enum Kind: String, Codable {
        case authoritative
        case unavailable
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .authoritative(let source, let version, let expectedCount):
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
            self = .authoritative(
                source: try container.decode(String.self, forKey: .source),
                version: try container.decode(String.self, forKey: .version),
                expectedCount: try container.decodeIfPresent(Int.self, forKey: .expectedCount)
            )
        case .unavailable:
            self = .unavailable(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    public var isAuthoritative: Bool {
        guard case .authoritative(let source, let version, let expectedCount) = self else {
            return false
        }
        guard Self.isNonBlankSource(source), Self.isParsableProtocolVersion(version) else {
            return false
        }
        return expectedCount == nil || expectedCount! >= 0
    }

    /// source 必须含非空白字符——纯空白来源没有可审计的标识价值。
    private static func isNonBlankSource(_ source: String) -> Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 协议版本必须是 1–3 段 ASCII 数字("1"、"1.2"、"1.2.3")。
    /// 空白段、4+ 段、非 ASCII 数字(如全角"１")、字母混入("v1"、
    /// "1.2-beta")均按不可信处理——Issue #173 fail-closed:
    /// source version 不可信 → unavailable。
    private static func isParsableProtocolVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return false }
        return components.allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber)
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
    }

    public var id: String {
        [base.rawValue, rawSection].map { String($0.utf8.count) + ":" + $0 }.joined(separator: "|")
    }

    public var isComplete: Bool {
        completeness == .complete && proof.isAuthoritative
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

    public init(
        schemaVersion: Int = SnapshotHistorySchema.observation,
        fields: [SnapshotCoverageField],
        sections: [SnapshotSectionCoverage] = [],
        diagnostics: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.fields = fields.sorted { $0.id < $1.id }
        self.sections = sections.sorted { $0.id < $1.id }
        self.diagnostics = diagnostics.sorted()
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
        schemaVersion < SnapshotHistorySchema.observation || sections.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case fields
        case sections
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? SnapshotHistorySchema.observation,
            fields: try container.decode([SnapshotCoverageField].self, forKey: .fields),
            sections: try container.decodeIfPresent([SnapshotSectionCoverage].self, forKey: .sections)
                ?? [],
            diagnostics: try container.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
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
        if schemaVersion >= SnapshotHistorySchema.observation {
            try container.encode(sections, forKey: .sections)
        }
        try container.encode(diagnostics, forKey: .diagnostics)
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
    public let fingerprintVersion: Int
    public let integrityVersion: Int
    public let snapshotID: UUID
    public let villageID: UUID
    public let lineageID: UUID
    public let normalizedPlayerTag: String?
    /// User-confirmed local commit time; never used as source evidence.
    public let appliedAt: Date
    /// Timestamp copied from the source payload, if present.
    public let sourceTimestamp: Date?
    public let parserVersion: String
    public let canonicalFingerprint: String
    public let rawJSON: String
    public let observation: CanonicalSnapshotObservation
    public let coverage: SnapshotObservationCoverage
    public let isBaseline: Bool
    public let baselineReason: SnapshotLineageReason?
    public let integrityFingerprint: String

    public init(
        schemaVersion: Int = SnapshotHistorySchema.entry,
        observationVersion: Int = SnapshotHistorySchema.observation,
        fingerprintVersion: Int = SnapshotHistorySchema.fingerprint,
        integrityVersion: Int = SnapshotHistorySchema.integrity,
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
        integrityFingerprint: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.observationVersion = observationVersion
        self.fingerprintVersion = fingerprintVersion
        self.integrityVersion = integrityVersion
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
        self.integrityFingerprint = integrityFingerprint ?? SnapshotHistoryCanonicalizer.integrityFingerprint(
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
            baselineReason: baselineReason
        )
    }

    public var id: UUID { snapshotID }
}

public enum SnapshotHistoryCanonicalizationError: Error, LocalizedError, Equatable, Sendable {
    case emptySource
    case topLevelMustBeObject
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .emptySource:
            "快照原文为空，无法建立历史观察。"
        case .topLevelMustBeObject:
            "快照原文顶层必须是对象。"
        case .invalidJSON(let message):
            "快照原文不是有效 JSON：" + message
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
            return .array(normalized.sorted {
                $0.canonicalData.lexicographicallyPrecedes($1.canonicalData)
            })
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

    private static func jsonStringData(_ value: String) -> Data {
        // Encoding a one-element array avoids relying on fragment support on
        // older Foundation implementations; remove only the outer brackets.
        guard let data = try? JSONSerialization.data(withJSONObject: [value]) else {
            return Data("\"\"".utf8)
        }
        return Data(data.dropFirst().dropLast())
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
