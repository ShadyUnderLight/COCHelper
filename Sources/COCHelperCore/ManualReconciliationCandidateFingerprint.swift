import CryptoKit
import Foundation

/// Issue #272：reconciliation candidate fingerprint，与 TypeScript `encodeReconciliationCandidateJson` 对齐。
public enum ManualReconciliationCandidateFingerprint {
    public static func compute(
        duplicate: Bool,
        lineageComparable: Bool,
        timeConfidence: ManualReconciliationTimeConfidence,
        newReference: ManualBaselineReference,
        newNormalizedPlayerTag: String?,
        sourceTimestampMs: Int64?,
        items: [ManualReconciliationItem]
    ) -> String {
        guard let json = encodingMaterialJson(
            duplicate: duplicate,
            lineageComparable: lineageComparable,
            timeConfidence: timeConfidence,
            newReference: newReference,
            newNormalizedPlayerTag: newNormalizedPlayerTag,
            sourceTimestampMs: sourceTimestampMs,
            items: items
        ) else {
            return "sha256:"
        }
        let digest = SHA256.hash(data: Data(json.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func encodingMaterialJson(
        duplicate: Bool,
        lineageComparable: Bool,
        timeConfidence: ManualReconciliationTimeConfidence,
        newReference: ManualBaselineReference,
        newNormalizedPlayerTag: String?,
        sourceTimestampMs: Int64?,
        items: [ManualReconciliationItem]
    ) -> String? {
        let material = FingerprintJSON.object([
            "duplicate": .bool(duplicate),
            "lineageComparable": .bool(lineageComparable),
            "timeConfidence": .string(timeConfidence.rawValue),
            "newReference": encodeReference(duplicate: duplicate, reference: newReference),
            "newNormalizedPlayerTag": encodeOptionalString(newNormalizedPlayerTag),
            "sourceTimestampMs": encodeOptionalInt64(sourceTimestampMs),
            "items": .array(
                items.map(encodeItem).sorted {
                    guard case .object(let left) = $0,
                          case .string(let leftStableId) = left["stableId"],
                          case .object(let right) = $1,
                          case .string(let rightStableId) = right["stableId"] else {
                        return false
                    }
                    return leftStableId < rightStableId
                }
            ),
        ])
        return String(data: material.jsonData, encoding: .utf8)
    }

    private enum FingerprintJSON {
        case null
        case bool(Bool)
        case number(String)
        case string(String)
        case array([FingerprintJSON])
        case object([String: FingerprintJSON])

        var jsonData: Data {
            switch self {
            case .null:
                return Data("null".utf8)
            case .bool(let value):
                return Data((value ? "true" : "false").utf8)
            case .number(let value):
                return Data(value.utf8)
            case .string(let value):
                return jsonStringData(value)
            case .array(let values):
                return join(values.map(\.jsonData), open: 0x5B, close: 0x5D)
            case .object(let values):
                var pieces: [Data] = []
                for key in values.keys.sorted() {
                    var piece = jsonStringData(key)
                    piece.append(58)
                    piece.append(values[key]!.jsonData)
                    pieces.append(piece)
                }
                return join(pieces, open: 0x7B, close: 0x7D)
            }
        }
    }

    private static func encodeItem(_ item: ManualReconciliationItem) -> FingerprintJSON {
        .object([
            "stableId": .string(item.itemKey.stableID),
            "classification": .string(item.classification.rawValue),
            "confirmedRecordIDs": .array(
                item.confirmedRecordIDs.map(\.uuidString).sorted().map(FingerprintJSON.string)
            ),
            "relatedRecordIDs": .array(
                item.relatedRecordIDs.map(\.uuidString).sorted().map(FingerprintJSON.string)
            ),
            "observedTimer": .bool(item.observedTimer),
            "coverageComplete": .bool(item.coverageComplete),
            "observedDistributionComplete": .bool(item.observedDistributionComplete),
            "observedSectionTrustGatesOpen": .bool(item.observedSectionTrustGatesOpen),
            "observedTimerCoverageComplete": .bool(item.observedTimerCoverageComplete),
            "previousDistribution": encodeDistribution(item.previousDistribution),
            "observedDistribution": encodeDistribution(item.observedDistribution),
        ])
    }

    private static func encodeReference(
        duplicate: Bool,
        reference: ManualBaselineReference
    ) -> FingerprintJSON {
        if duplicate {
            return .object([
                "fingerprint": encodeOptionalString(reference.fingerprint),
                "revision": .string(reference.revision),
            ])
        }
        return .object([
            "fingerprint": encodeOptionalString(reference.fingerprint),
        ])
    }

    private static func encodeDistribution(_ distribution: ManualLevelDistribution?) -> FingerprintJSON {
        guard let distribution else { return .null }
        return .array(distribution.levels.map { entry in
            .object([
                "level": .number(String(entry.level)),
                "quantity": .string(String(entry.quantity)),
            ])
        })
    }

    private static func encodeOptionalString(_ value: String?) -> FingerprintJSON {
        guard let value else { return .null }
        return .string(value)
    }

    private static func encodeOptionalInt64(_ value: Int64?) -> FingerprintJSON {
        guard let value else { return .null }
        return .number(String(value))
    }

    private static func join(_ pieces: [Data], open: UInt8, close: UInt8) -> Data {
        var data = Data([open])
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                data.append(44)
            }
            data.append(piece)
        }
        data.append(close)
        return data
    }

    private static func jsonStringData(_ value: String) -> Data {
        var result = Data([0x22])
        for byte in value.utf8 {
            switch byte {
            case 0x22:
                result.append(contentsOf: [0x5C, 0x22])
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
            case 0 ..< 0x20:
                result.append(0x5C)
                result.append(contentsOf: String(format: "u%04X", byte).utf8)
            default:
                result.append(byte)
            }
        }
        result.append(0x22)
        return result
    }
}

extension ManualReconciliationPreview {
    public var candidateFingerprint: String {
        ManualReconciliationCandidateFingerprint.compute(
            duplicate: duplicate,
            lineageComparable: lineageComparable,
            timeConfidence: timeConfidence,
            newReference: newReference,
            newNormalizedPlayerTag: newNormalizedPlayerTag,
            sourceTimestampMs: sourceTimestamp.map {
                Int64($0.timeIntervalSince1970 * 1_000)
            },
            items: items
        )
    }
}
