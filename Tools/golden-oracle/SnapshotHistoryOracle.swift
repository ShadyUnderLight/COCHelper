import Foundation
import COCHelperCore

enum SnapshotHistoryOracle {
    struct CanonicalizeRequest: Decodable {
        let snapshotText: String
        let villageID: String
        let lineageID: String
        let snapshotID: String
        let appliedAtRefSeconds: Double
        let importedAtRefSeconds: Double
    }

    struct DiffRequest: Decodable {
        let fromEntryJSON: String
        let toEntryJSON: String
    }

    enum Envelope: Decodable {
        case canonicalize(CanonicalizeRequest)
        case diff(DiffRequest)

        private enum CodingKeys: String, CodingKey {
            case kind
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "canonicalize":
                self = .canonicalize(try CanonicalizeRequest(from: decoder))
            case "diff":
                self = .diff(try DiffRequest(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "unsupported snapshot history kind"
                )
            }
        }
    }

    static func evaluate(source: String) throws -> String {
        let data = Data(source.utf8)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        switch envelope {
        case .canonicalize(let request):
            return try encodeOutcome(evaluateCanonicalize(request))
        case .diff(let request):
            return try encodeOutcome(evaluateDiff(request))
        }
    }

    private static func evaluateCanonicalize(_ request: CanonicalizeRequest) throws -> [String: String] {
        let importedAt = Date(timeIntervalSinceReferenceDate: request.importedAtRefSeconds)
        let snapshot = try AccountSnapshotImporter.parse(request.snapshotText, now: importedAt)
        let entry = try SnapshotHistoryCanonicalizer.canonicalize(
            snapshot: snapshot,
            villageID: UUID(uuidString: request.villageID)!,
            lineageID: UUID(uuidString: request.lineageID)!,
            appliedAt: Date(timeIntervalSinceReferenceDate: request.appliedAtRefSeconds),
            snapshotID: UUID(uuidString: request.snapshotID)!
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let wire = try encoder.encode(entry)
        return [
            "canonicalFingerprint": entry.canonicalFingerprint,
            "integrityFingerprint": entry.integrityFingerprint,
            "encodedJSONHex": hex(wire),
        ]
    }

    private static func evaluateDiff(_ request: DiffRequest) throws -> [String: String] {
        let decoder = JSONDecoder()
        let from = try decoder.decode(SnapshotHistoryEntry.self, from: Data(request.fromEntryJSON.utf8))
        let to = try decoder.decode(SnapshotHistoryEntry.self, from: Data(request.toEntryJSON.utf8))
        let diff = SnapshotDiffEngine.compare(from: from, to: to)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let wire = try encoder.encode(diff)
        return [
            "comparisonState": diff.comparisonState.rawValue,
            "changeCount": String(diff.changes.count),
            "encodedJSONHex": hex(wire),
        ]
    }

    private static func encodeOutcome(_ value: [String: String]) throws -> String {
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
