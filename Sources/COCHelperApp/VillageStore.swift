import Foundation
import COCHelperCore

/// The legacy villages key stores a JSON array.  Versioned envelopes are
/// recognized on read so an older binary cannot mistake a future format for
/// an empty store and overwrite it.
public enum VillageStoreSchema {
    public static let current = 1
}

public enum VillageStoreStatus: String, Equatable, Sendable {
    case missing
    case available
    case empty
    case readOnly
    case corrupt
    case unsupported
    case writeFailed

    public var isRecoveryRequired: Bool {
        switch self {
        case .readOnly, .corrupt, .unsupported, .writeFailed:
            return true
        case .missing, .available, .empty:
            return false
        }
    }
}

public enum VillageStoreError: Error, LocalizedError, Equatable, Sendable {
    case corrupt(String)
    case unsupportedSchema(Int)
    case invalid(String)
    case writeFailed(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let message):
            return "村庄存储损坏：" + message
        case .unsupportedSchema(let version):
            return "村庄存储版本不受支持：" + String(version)
        case .invalid(let message):
            return "村庄存储内容无效：" + message
        case .writeFailed(let message):
            return "村庄存储写入失败：" + message
        case .unavailable(let message):
            return "村庄存储不可用：" + message
        }
    }
}

public enum VillageStoreLoadResult: Sendable {
    case missing
    case loaded([VillageProfile])
    case corrupt(rawData: Data, message: String)
    case unsupportedSchema(rawData: Data, schemaVersion: Int)

    public var rawData: Data? {
        switch self {
        case .missing, .loaded:
            return nil
        case .corrupt(let rawData, _), .unsupportedSchema(let rawData, _):
            return rawData
        }
    }
}

/// Codec and validation contract shared by AppModel and its transaction
/// coordinators.  The existing array format remains the current on-disk
/// format; a future version is only recognized when it advertises a larger
/// `schemaVersion` envelope.
public enum VillageStoreCodec {
    public static func load(_ data: Data?) -> VillageStoreLoadResult {
        guard let data else { return .missing }

        do {
            let villages = try JSONDecoder().decode([VillageProfile].self, from: data)
            guard Set(villages.map(\.id)).count == villages.count else {
                return .corrupt(
                    rawData: data,
                    message: "村庄列表包含重复的村庄 ID。"
                )
            }
            return .loaded(villages)
        } catch {
            if let schemaVersion = advertisedSchemaVersion(in: data),
               schemaVersion > VillageStoreSchema.current {
                return .unsupportedSchema(rawData: data, schemaVersion: schemaVersion)
            }
            return .corrupt(rawData: data, message: error.localizedDescription)
        }
    }

    public static func encode(_ villages: [VillageProfile]) throws -> Data {
        do {
            return try JSONEncoder().encode(villages)
        } catch {
            throw VillageStoreError.writeFailed("编码村庄列表失败：" + error.localizedDescription)
        }
    }

    public static func validate(_ data: Data?, label: String) throws {
        switch load(data) {
        case .missing, .loaded:
            return
        case .corrupt(_, let message):
            throw VillageStoreError.corrupt("\(label) 无法解码：\(message)")
        case .unsupportedSchema(_, let schemaVersion):
            throw VillageStoreError.unsupportedSchema(schemaVersion)
        }
    }

    private static func advertisedSchemaVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let number = dictionary["schemaVersion"] as? NSNumber else {
            return nil
        }
        return number.intValue
    }
}
