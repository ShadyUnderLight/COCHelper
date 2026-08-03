import Foundation

/// One independently planned Clash of Clans account.
///
/// The planner input is intentionally stored alongside the imported snapshot:
/// the JSON export does not contain every value required by the heuristic
/// planner, so each village keeps its own explicit overrides instead of
/// borrowing the state of another village.
public struct VillageProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var input: PlannerInput
    public var accountSnapshot: AccountSnapshot?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        input: PlannerInput = .empty,
        accountSnapshot: AccountSnapshot? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "未命名村庄" : trimmedName
        self.input = input
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
