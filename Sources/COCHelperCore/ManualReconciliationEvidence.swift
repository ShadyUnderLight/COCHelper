import Foundation

public enum ManualReconciliationRelatedChangeCoverageState: String, Codable, Hashable, Sendable {
    case complete
    case partial
    case unavailable
}

public struct ManualReconciliationRelatedChangeEvidence: Codable, Hashable, Sendable {
    public let coverageState: ManualReconciliationRelatedChangeCoverageState

    public init(coverageState: ManualReconciliationRelatedChangeCoverageState) {
        self.coverageState = coverageState
    }
}

/// Wire shape: `[level, quantity]` where quantity is a decimal string.
public struct ManualReconciliationDistributionWireLevel: Codable, Hashable, Sendable {
    public let level: Int
    public let quantity: String

    public init(level: Int, quantity: String) {
        self.level = level
        self.quantity = quantity
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        level = try container.decode(Int.self)
        quantity = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(level)
        try container.encode(quantity)
    }
}

public struct ManualReconciliationObservationEvidence: Codable, Hashable, Sendable {
    public let distribution: [ManualReconciliationDistributionWireLevel]?
    public let displayName: String
    public let hasTimer: Bool
    public let coverageComplete: Bool
    public let distributionComplete: Bool
    public let sectionTrustGatesOpen: Bool
    public let timerCoverageComplete: Bool

    public init(
        distribution: [ManualReconciliationDistributionWireLevel]? = nil,
        displayName: String,
        hasTimer: Bool = false,
        coverageComplete: Bool = false,
        distributionComplete: Bool = false,
        sectionTrustGatesOpen: Bool = false,
        timerCoverageComplete: Bool = false
    ) {
        self.distribution = distribution
        self.displayName = displayName
        self.hasTimer = hasTimer
        self.coverageComplete = coverageComplete
        self.distributionComplete = distributionComplete
        self.sectionTrustGatesOpen = sectionTrustGatesOpen
        self.timerCoverageComplete = timerCoverageComplete
    }
}

public struct ManualReconciliationEvidence: Codable, Hashable, Sendable {
    public let villageID: UUID
    public let newBaselineReference: ManualBaselineReference
    public let newNormalizedPlayerTag: String?
    public let sourceTimestampMs: Int64?
    public let duplicate: Bool
    public let lineageComparable: Bool
    public let observations: [String: ManualReconciliationObservationEvidence]
    public let itemKeys: [String: TrackerItemKey]
    public let previousObservations: [String: ManualReconciliationObservationEvidence]?
    public let relatedChangesByStableID: [String: [ManualReconciliationRelatedChangeEvidence]]?
    public let previousSnapshotID: UUID?
    public let previousLineageID: UUID?
    public let previousSourceTimestampMs: Int64?

    public init(
        villageID: UUID,
        newBaselineReference: ManualBaselineReference,
        newNormalizedPlayerTag: String? = nil,
        sourceTimestampMs: Int64? = nil,
        duplicate: Bool,
        lineageComparable: Bool,
        observations: [String: ManualReconciliationObservationEvidence],
        itemKeys: [String: TrackerItemKey],
        previousObservations: [String: ManualReconciliationObservationEvidence]? = nil,
        relatedChangesByStableID: [String: [ManualReconciliationRelatedChangeEvidence]]? = nil,
        previousSnapshotID: UUID? = nil,
        previousLineageID: UUID? = nil,
        previousSourceTimestampMs: Int64? = nil
    ) {
        self.villageID = villageID
        self.newBaselineReference = newBaselineReference
        self.newNormalizedPlayerTag = newNormalizedPlayerTag
        self.sourceTimestampMs = sourceTimestampMs
        self.duplicate = duplicate
        self.lineageComparable = lineageComparable
        self.observations = observations
        self.itemKeys = itemKeys
        self.previousObservations = previousObservations
        self.relatedChangesByStableID = relatedChangesByStableID
        self.previousSnapshotID = previousSnapshotID
        self.previousLineageID = previousLineageID
        self.previousSourceTimestampMs = previousSourceTimestampMs
    }

    private enum CodingKeys: String, CodingKey {
        case villageID
        case newBaselineReference
        case newNormalizedPlayerTag
        case sourceTimestampMs
        case duplicate
        case lineageComparable
        case observations
        case itemKeys
        case previousObservations
        case relatedChangesByStableID
        case previousSnapshotID
        case previousLineageID
        case previousSourceTimestampMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        villageID = try container.decode(UUID.self, forKey: .villageID)
        newBaselineReference = try container.decode(
            ManualBaselineReference.self, forKey: .newBaselineReference)
        newNormalizedPlayerTag = try container.decodeIfPresent(
            String.self, forKey: .newNormalizedPlayerTag)
        sourceTimestampMs = Self.decodeOptionalTimestampMs(
            from: container, forKey: .sourceTimestampMs)
        duplicate = try container.decode(Bool.self, forKey: .duplicate)
        lineageComparable = try container.decode(Bool.self, forKey: .lineageComparable)
        observations = try container.decode(
            [String: ManualReconciliationObservationEvidence].self, forKey: .observations)
        itemKeys = try container.decode([String: TrackerItemKey].self, forKey: .itemKeys)
        previousObservations = try container.decodeIfPresent(
            [String: ManualReconciliationObservationEvidence].self, forKey: .previousObservations)
        relatedChangesByStableID = try container.decodeIfPresent(
            [String: [ManualReconciliationRelatedChangeEvidence]].self,
            forKey: .relatedChangesByStableID)
        previousSnapshotID = try container.decodeIfPresent(UUID.self, forKey: .previousSnapshotID)
        previousLineageID = try container.decodeIfPresent(UUID.self, forKey: .previousLineageID)
        previousSourceTimestampMs = Self.decodeOptionalTimestampMs(
            from: container, forKey: .previousSourceTimestampMs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(villageID, forKey: .villageID)
        try container.encode(newBaselineReference, forKey: .newBaselineReference)
        try container.encodeIfPresent(newNormalizedPlayerTag, forKey: .newNormalizedPlayerTag)
        try container.encodeIfPresent(sourceTimestampMs, forKey: .sourceTimestampMs)
        try container.encode(duplicate, forKey: .duplicate)
        try container.encode(lineageComparable, forKey: .lineageComparable)
        try container.encode(observations, forKey: .observations)
        try container.encode(itemKeys, forKey: .itemKeys)
        try container.encodeIfPresent(previousObservations, forKey: .previousObservations)
        try container.encodeIfPresent(relatedChangesByStableID, forKey: .relatedChangesByStableID)
        try container.encodeIfPresent(previousSnapshotID, forKey: .previousSnapshotID)
        try container.encodeIfPresent(previousLineageID, forKey: .previousLineageID)
        try container.encodeIfPresent(previousSourceTimestampMs, forKey: .previousSourceTimestampMs)
    }

    private static func decodeOptionalTimestampMs(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int64? {
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}
