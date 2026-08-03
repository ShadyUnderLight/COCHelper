import Foundation

/// One independently tracked Clash of Clans account.
///
/// The imported snapshot is the source of truth for this local tracker. The
/// old planner input field was intentionally removed; old persisted village
/// JSON remains decodable because unknown fields are ignored by Codable.
public struct VillageProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var accountSnapshot: AccountSnapshot?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        accountSnapshot: AccountSnapshot? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "未命名村庄" : trimmedName
        self.accountSnapshot = accountSnapshot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var tag: String? {
        accountSnapshot?.tag
    }

    public var identityLabel: String {
        tag ?? "尚未导入 JSON"
    }

    public var hasImportedData: Bool {
        accountSnapshot != nil
    }
}
