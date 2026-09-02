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

    struct Outcome: Encodable {
        struct Item: Encodable {
            let stableId: String
            let classification: String
        }

        let candidateFingerprint: String
        let duplicate: Bool
        let lineageComparable: Bool
        let timeConfidence: String
        let items: [Item]
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
            candidateFingerprint: preview.candidateFingerprint,
            duplicate: preview.duplicate,
            lineageComparable: preview.lineageComparable,
            timeConfidence: preview.timeConfidence.rawValue,
            items: preview.items.map {
                Outcome.Item(stableId: $0.itemKey.stableID, classification: $0.classification.rawValue)
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

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
