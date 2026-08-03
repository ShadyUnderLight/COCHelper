import Foundation

/// Chinese names extracted from the game's localized logic tables.
///
/// The catalog is bundled with the app so importing an export never needs a
/// network request. `#dataID` remains available through `AccountItem.rawIDLabel`
/// when a future game version introduces an ID that is not in this catalog.
public struct AccountNameCatalog: Sendable {
    public static let bundled = loadBundled()

    private let names: [String: String]

    public init(names: [String: String]) {
        self.names = names
    }

    public var count: Int { names.count }

    public func name(for section: String, dataID: Int64) -> String? {
        if let exact = names[key(section, dataID)] {
            return exact
        }

        if (102_000_000..<103_000_000).contains(dataID),
           let moduleName = names[key("modules", dataID)] {
            return moduleName
        }
        if (103_000_000..<104_000_000).contains(dataID),
           let typeName = names[key("types", dataID)] {
            return typeName
        }
        return nil
    }

    public func name(forNumericSection section: String, dataID: Int64) -> String? {
        names[key(section, dataID)]
    }

    private func key(_ section: String, _ dataID: Int64) -> String {
        section + ":" + String(dataID)
    }

    private static func loadBundled() -> AccountNameCatalog {
        guard let url = Bundle.module.url(forResource: "account_name_catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return AccountNameCatalog(names: [:])
        }
        return AccountNameCatalog(names: payload.entries)
    }

    private struct Payload: Decodable {
        let entries: [String: String]
    }
}
