import Foundation
import COCHelperCore

enum ManualReconciliationOracle {
    struct WireRequest: Decodable {
        let evidence: ManualReconciliationEvidence
        let currentState: WireVillageState
        let appliedAtMs: Int64
    }

    struct WireVillageState: Decodable {
        let villageID: UUID
        let core: WireCore
        let stateUpdatedAtMs: Int64
    }

    struct WireCore: Decodable {
        let itemStates: [WireItemState]
        let records: [WireRecord]
    }

    struct WireItemState: Decodable {
        let itemKey: TrackerItemKey
        let baselineReference: ManualBaselineReference
        let importedObservation: WireImportedObservation?
        let manualCompletedDistribution: [[String]]
        let status: ManualItemStatus
    }

    struct WireImportedObservation: Decodable {
        let reference: ManualBaselineReference
        let levelDistribution: [[String]]?
        let sourceTimestampMs: Int64?
        let observedTimer: Bool
        let observedTimerCoverageComplete: Bool
    }

    struct WireRecord: Decodable {
        let recordID: UUID
        let itemKey: TrackerItemKey
        let fromLevel: Int
        let targetLevel: Int
        let quantity: String
        let startedAtMs: Int64
        let expectedEndAtMs: Int64
        let durationSeconds: String
        let durationKind: ManualUpgradeDurationKind
        let frozenCosts: [CatalogUpgradeCost]?
        let catalogProvenance: ManualCatalogProvenance
        let baselineReference: ManualBaselineReference
        let queueKind: String?
        let status: ManualUpgradeRecordStatus
    }

    // Issue #304：outcome 直接携带去除随机 ID 的语义字段
    //（替代 candidateFingerprint），与 testkit parity-case 形状一致。
    // 全部 key 显式编码（含 null），与 TypeScript JSON.stringify 对齐。
    struct Outcome: Encodable {
        struct DistributionLevel: Encodable {
            let level: Int
            let quantity: String
        }

        struct Item: Encodable {
            let stableId: String
            let classification: String
            let previousDistribution: [DistributionLevel]?
            let observedDistribution: [DistributionLevel]?
            let relatedRecordIDs: [String]
            let confirmedRecordIDs: [String]
            let observedTimer: Bool
            let coverageComplete: Bool
            let observedDistributionComplete: Bool
            let observedSectionTrustGatesOpen: Bool
            let observedTimerCoverageComplete: Bool

            private enum CodingKeys: String, CodingKey {
                case stableId
                case classification
                case previousDistribution
                case observedDistribution
                case relatedRecordIDs
                case confirmedRecordIDs
                case observedTimer
                case coverageComplete
                case observedDistributionComplete
                case observedSectionTrustGatesOpen
                case observedTimerCoverageComplete
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(stableId, forKey: .stableId)
                try container.encode(classification, forKey: .classification)
                try container.encode(previousDistribution, forKey: .previousDistribution)
                try container.encode(observedDistribution, forKey: .observedDistribution)
                try container.encode(relatedRecordIDs, forKey: .relatedRecordIDs)
                try container.encode(confirmedRecordIDs, forKey: .confirmedRecordIDs)
                try container.encode(observedTimer, forKey: .observedTimer)
                try container.encode(coverageComplete, forKey: .coverageComplete)
                try container.encode(
                    observedDistributionComplete,
                    forKey: .observedDistributionComplete
                )
                try container.encode(
                    observedSectionTrustGatesOpen,
                    forKey: .observedSectionTrustGatesOpen
                )
                try container.encode(
                    observedTimerCoverageComplete,
                    forKey: .observedTimerCoverageComplete
                )
            }
        }

        struct NewReference: Encodable {
            let revision: String
            let lineageID: String?

            private enum CodingKeys: String, CodingKey {
                case revision
                case lineageID
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(revision, forKey: .revision)
                try container.encode(lineageID, forKey: .lineageID)
            }
        }

        let duplicate: Bool
        let lineageComparable: Bool
        let timeConfidence: String
        let newReference: NewReference
        let newNormalizedPlayerTag: String?
        let sourceTimestampMs: Int64?
        let items: [Item]

        private enum CodingKeys: String, CodingKey {
            case duplicate
            case lineageComparable
            case timeConfidence
            case newReference
            case newNormalizedPlayerTag
            case sourceTimestampMs
            case items
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(duplicate, forKey: .duplicate)
            try container.encode(lineageComparable, forKey: .lineageComparable)
            try container.encode(timeConfidence, forKey: .timeConfidence)
            try container.encode(newReference, forKey: .newReference)
            try container.encode(newNormalizedPlayerTag, forKey: .newNormalizedPlayerTag)
            try container.encode(sourceTimestampMs, forKey: .sourceTimestampMs)
            try container.encode(items, forKey: .items)
        }
    }

    static func evaluate(source: String) throws -> String {
        let data = Data(source.utf8)
        let request = try JSONDecoder().decode(WireRequest.self, from: data)
        let currentState = try buildVillageState(from: request.currentState)
        let preview = try ManualTrackerReconciliationService.previewFromEvidence(
            request.evidence,
            currentState: currentState,
            appliedAt: Date(timeIntervalSince1970: TimeInterval(request.appliedAtMs) / 1000)
        )
        let outcome = Outcome(
            duplicate: preview.duplicate,
            lineageComparable: preview.lineageComparable,
            timeConfidence: preview.timeConfidence.rawValue,
            newReference: Outcome.NewReference(
                revision: preview.newReference.revision,
                lineageID: preview.newReference.lineageID
            ),
            newNormalizedPlayerTag: preview.newNormalizedPlayerTag,
            sourceTimestampMs: preview.sourceTimestamp.map {
                Int64($0.timeIntervalSince1970 * 1_000)
            },
            items: preview.items.map {
                Outcome.Item(
                    stableId: $0.itemKey.stableID,
                    classification: $0.classification.rawValue,
                    previousDistribution: distributionLevels($0.previousDistribution),
                    observedDistribution: distributionLevels($0.observedDistribution),
                    relatedRecordIDs: $0.relatedRecordIDs.map(\.uuidString).sorted(),
                    confirmedRecordIDs: $0.confirmedRecordIDs.map(\.uuidString).sorted(),
                    observedTimer: $0.observedTimer,
                    coverageComplete: $0.coverageComplete,
                    observedDistributionComplete: $0.observedDistributionComplete,
                    observedSectionTrustGatesOpen: $0.observedSectionTrustGatesOpen,
                    observedTimerCoverageComplete: $0.observedTimerCoverageComplete
                )
            }.sorted { $0.stableId < $1.stableId }
        )
        let encoded = try JSONEncoder().encode(outcome)
        let canonical = try CanonicalJSONValue.fromJSONData(encoded).canonicalized.canonicalData
        return hex(canonical)
    }

    private static func buildVillageState(from wire: WireVillageState) throws -> ManualTrackerVillageState {
        let itemStates = try wire.core.itemStates.map { entry in
            let imported: ManualImportedObservation?
            if let observation = entry.importedObservation {
                imported = try ManualImportedObservation(
                    reference: observation.reference,
                    levelDistribution: try distribution(from: observation.levelDistribution),
                    sourceTimestamp: observation.sourceTimestampMs.map {
                        Date(timeIntervalSince1970: TimeInterval($0) / 1000)
                    },
                    observedTimer: observation.observedTimer,
                    observedTimerCoverageComplete: observation.observedTimerCoverageComplete
                )
            } else {
                imported = nil
            }
            return try ManualItemState(
                itemKey: entry.itemKey,
                baselineReference: entry.baselineReference,
                importedObservation: imported,
                manualCompletedDistribution: try ManualLevelDistribution(
                    levelQuantities: distributionMap(from: entry.manualCompletedDistribution)
                ),
                status: entry.status
            )
        }
        let records = try wire.core.records.map { record in
            try ManualUpgradeRecord(
                recordID: record.recordID,
                itemKey: record.itemKey,
                fromLevel: record.fromLevel,
                targetLevel: record.targetLevel,
                quantity: Int64(record.quantity)!,
                startedAt: Date(timeIntervalSince1970: TimeInterval(record.startedAtMs) / 1000),
                expectedEndAt: Date(timeIntervalSince1970: TimeInterval(record.expectedEndAtMs) / 1000),
                durationSeconds: Int64(record.durationSeconds)!,
                durationKind: record.durationKind,
                frozenCosts: record.frozenCosts,
                catalogProvenance: record.catalogProvenance,
                baselineReference: record.baselineReference,
                queueKind: record.queueKind,
                status: record.status
            )
        }
        return try ManualTrackerVillageState(
            villageID: wire.villageID,
            core: ManualUpgradeCore(itemStates: itemStates, records: records),
            stateUpdatedAt: Date(timeIntervalSince1970: TimeInterval(wire.stateUpdatedAtMs) / 1000)
        )
    }

    private static func distribution(from wire: [[String]]?) throws -> ManualLevelDistribution? {
        guard let wire else { return nil }
        return try ManualLevelDistribution(levelQuantities: distributionMap(from: wire))
    }

    private static func distributionMap(from wire: [[String]]) throws -> [Int: Int64] {
        var result: [Int: Int64] = [:]
        for entry in wire {
            guard entry.count == 2,
                  let level = Int(entry[0]),
                  let quantity = Int64(entry[1]) else {
                throw ManualReconciliationError.invalidObservation("distribution wire 形状无效")
            }
            result[level] = quantity
        }
        return result
    }

    private static func distributionLevels(
        _ distribution: ManualLevelDistribution?
    ) -> [Outcome.DistributionLevel]? {
        guard let distribution else { return nil }
        return distribution.levels.map {
            Outcome.DistributionLevel(level: $0.level, quantity: String($0.quantity))
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
