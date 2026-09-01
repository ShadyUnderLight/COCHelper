import Foundation
import COCHelperCore

enum ManualDomainOracle {
    struct StartGateRequest: Decodable {
        let itemSection: String
        let requestedQueueKind: String?
        let builderCapacity: Int?
    }

    struct OccupancyRecord: Decodable {
        let rawSection: String
        let queueKind: String?
    }

    struct OccupancyRequest: Decodable {
        let targetQueueKind: String
        let builderCapacity: Int
        let records: [OccupancyRecord]
    }

    enum Envelope: Decodable {
        case startGate(StartGateRequest)
        case occupancy(OccupancyRequest)

        private enum CodingKeys: String, CodingKey {
            case kind
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "startGate":
                self = .startGate(try StartGateRequest(from: decoder))
            case "occupancy":
                self = .occupancy(try OccupancyRequest(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "unsupported manual domain kind"
                )
            }
        }
    }

    static func evaluate(source: String) throws -> String {
        let data = Data(source.utf8)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        switch envelope {
        case .startGate(let request):
            return try encodeOutcome(evaluateStartGate(request))
        case .occupancy(let request):
            return try encodeOutcome(evaluateOccupancy(request))
        }
    }

    private static func evaluateStartGate(_ request: StartGateRequest) throws -> [String: String?] {
        let villageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let baseline = ManualBaselineReference(
            revision: "rev",
            fingerprint: "fp",
            lineageID: "lineage-1"
        )
        let itemKey = TrackerItemKey.root(base: .home, rawSection: request.itemSection, dataID: 1_000_002)
        let core = try ManualUpgradeCore(itemStates: [
            ManualItemState(
                itemKey: itemKey,
                baselineReference: baseline,
                manualCompletedDistribution: ManualLevelDistribution(levelQuantities: [:]),
                status: .manualCompleted
            ),
        ])
        var configs: [LocalQueueCapacityConfig] = []
        if let builderCapacity = request.builderCapacity {
            configs.append(try LocalQueueCapacityConfig(
                villageID: villageID,
                queueKind: .builder,
                capacity: builderCapacity,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ))
        }
        let requestedQueueKind = request.requestedQueueKind.map(LocalQueueKind.init(rawValue:))
        let error = ManualQueueCapacityGate.validateStartAgainstQueueCapacity(
            itemKey: itemKey,
            durationState: .timed(seconds: 60),
            core: core,
            queueCapacityConfigs: configs,
            queueAssignments: [],
            currentBaseline: baseline,
            storeAvailable: true,
            requestedQueueKind: requestedQueueKind,
            now: Date(timeIntervalSince1970: 1_000)
        )
        return ["errorKind": errorKind(error)]
    }

    private static func evaluateOccupancy(_ request: OccupancyRequest) throws -> [String: Int] {
        let villageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let baseline = ManualBaselineReference(
            revision: "rev",
            fingerprint: "fp",
            lineageID: "lineage-1"
        )
        let queueKind: LocalQueueKind = request.targetQueueKind == "builder" ? .builder : .laboratory
        let config = try LocalQueueCapacityConfig(
            villageID: villageID,
            queueKind: queueKind,
            capacity: request.builderCapacity,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let records = try request.records.map { entry in
            try activeRecord(rawSection: entry.rawSection, queueKind: entry.queueKind, baseline: baseline)
        }
        let occupancy = LocalQueueOccupancyResolver.occupancy(
            queueKind: queueKind,
            activeRecords: records,
            capacityConfig: config,
            at: Date(timeIntervalSince1970: 1_000)
        )
        return [
            "activeManualCount": occupancy.activeManualCount,
            "full": occupancy.isFull ? 1 : 0,
        ]
    }

    private static func activeRecord(
        rawSection: String,
        queueKind: String?,
        baseline: ManualBaselineReference
    ) throws -> ManualUpgradeRecord {
        let itemKey = TrackerItemKey.root(base: .home, rawSection: rawSection, dataID: 1_000_002)
        return try ManualUpgradeRecord(
            recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            itemKey: itemKey,
            fromLevel: 1,
            targetLevel: 2,
            quantity: 1,
            startedAt: Date(timeIntervalSince1970: 1_000),
            expectedEndAt: Date(timeIntervalSince1970: 3_600),
            durationSeconds: 2_600,
            durationKind: .timed,
            frozenCosts: nil,
            catalogProvenance: ManualCatalogProvenance(gameVersion: "18.400.13"),
            baselineReference: baseline,
            queueKind: queueKind,
            status: .active
        )
    }

    private static func errorKind(_ error: ManualQueueCapacityGateError?) -> String? {
        switch error {
        case nil:
            return nil
        case .invalidQueueKind:
            return "invalidQueueKind"
        case .occupancyNotAvailable(let status):
            return status == .unavailable ? "occupancyNotAvailable" : "occupancyNotAvailable"
        case .queueCapacityFull:
            return "queueCapacityFull"
        }
    }

    private static func encodeOutcome(_ value: [String: Any?]) throws -> String {
        var normalized: [String: Any] = [:]
        for key in value.keys.sorted() {
            let entry = value[key]!
            normalized[key] = entry ?? NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: normalized)
        let canonical = try CanonicalJSONValue.fromJSONData(data).canonicalized.canonicalData
        return hex(canonical)
    }

    private static func encodeOutcome(_ value: [String: Int]) throws -> String {
        var normalized: [String: Any] = [:]
        for key in value.keys.sorted() {
            normalized[key] = value[key]!
        }
        let data = try JSONSerialization.data(withJSONObject: normalized)
        let canonical = try CanonicalJSONValue.fromJSONData(data).canonicalized.canonicalData
        return hex(canonical)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
