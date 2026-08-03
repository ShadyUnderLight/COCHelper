import Foundation

public enum GameDataSource: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case demo
    case userVerified
    case officialSnapshot
    case officialPending

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .demo: "演示数据"
        case .userVerified: "用户核对"
        case .officialSnapshot: "官方快照"
        case .officialPending: "等待官方数据"
        }
    }
}

public struct GameDataEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var displayName: String
    public var category: UpgradeCategory
    public var townHallLevel: Int
    public var defaultDurationDays: Double
    public var resource: ResourceClass
    public var cost: Int
    public var warImpact: WarImpact

    public init(
        id: String,
        displayName: String,
        category: UpgradeCategory,
        townHallLevel: Int,
        defaultDurationDays: Double,
        resource: ResourceClass,
        cost: Int,
        warImpact: WarImpact
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.townHallLevel = max(1, townHallLevel)
        self.defaultDurationDays = max(0.25, defaultDurationDays)
        self.resource = resource
        self.cost = max(0, cost)
        self.warImpact = warImpact
    }
}

public struct GameDataLayerStatus: Hashable, Sendable {
    public let schemaVersion: Int
    public let gameVersion: String
    public let catalogVersion: String
    public let source: GameDataSource
    public let entryCount: Int
    public let isStructurallyValid: Bool

    public var versionLabel: String {
        catalogVersion + " · schema " + String(schemaVersion)
    }

    public init(
        schemaVersion: Int,
        gameVersion: String,
        catalogVersion: String,
        source: GameDataSource,
        entryCount: Int,
        isStructurallyValid: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.gameVersion = gameVersion
        self.catalogVersion = catalogVersion
        self.source = source
        self.entryCount = entryCount
        self.isStructurallyValid = isStructurallyValid
    }
}

public struct GameDataCatalog: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var gameVersion: String
    public var catalogVersion: String
    public var source: GameDataSource
    public var entries: [GameDataEntry]

    public init(
        schemaVersion: Int,
        gameVersion: String,
        catalogVersion: String,
        source: GameDataSource,
        entries: [GameDataEntry]
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.gameVersion = gameVersion
        self.catalogVersion = catalogVersion
        self.source = source
        self.entries = entries
    }

    public func entry(for id: String?) -> GameDataEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    public var status: GameDataLayerStatus {
        let ids = entries.map(\.id)
        let isValid = !catalogVersion.isEmpty
            && !gameVersion.isEmpty
            && ids.count == Set(ids).count
            && entries.allSatisfy { !$0.id.isEmpty && $0.defaultDurationDays > 0 && $0.cost >= 0 }
        return GameDataLayerStatus(
            schemaVersion: schemaVersion,
            gameVersion: gameVersion,
            catalogVersion: catalogVersion,
            source: source,
            entryCount: entries.count,
            isStructurallyValid: isValid
        )
    }

    public static let demo = GameDataCatalog(
        schemaVersion: 1,
        gameVersion: "未绑定官方版本",
        catalogVersion: "demo-0.1",
        source: .demo,
        entries: [
            GameDataEntry(id: "town-hall", displayName: "大本营", category: .townHall, townHallLevel: 15, defaultDurationDays: 7, resource: .gold, cost: 6_000_000, warImpact: .high),
            GameDataEntry(id: "laboratory", displayName: "实验室", category: .building, townHallLevel: 15, defaultDurationDays: 4, resource: .elixir, cost: 2_000_000, warImpact: .low),
            GameDataEntry(id: "barracks", displayName: "兵营", category: .building, townHallLevel: 15, defaultDurationDays: 4, resource: .elixir, cost: 2_000_000, warImpact: .medium),
            GameDataEntry(id: "queen", displayName: "女王", category: .hero, townHallLevel: 15, defaultDurationDays: 6, resource: .darkElixir, cost: 120_000, warImpact: .high),
            GameDataEntry(id: "air-defense", displayName: "防空火箭", category: .defense, townHallLevel: 15, defaultDurationDays: 5, resource: .gold, cost: 4_000_000, warImpact: .high),
            GameDataEntry(id: "resource-building", displayName: "资源建筑", category: .resource, townHallLevel: 15, defaultDurationDays: 3, resource: .elixir, cost: 1_500_000, warImpact: .low),
            GameDataEntry(id: "wall-batch", displayName: "城墙", category: .wall, townHallLevel: 15, defaultDurationDays: 2.5, resource: .gold, cost: 1_000_000, warImpact: .low),
            GameDataEntry(id: "trap-batch", displayName: "陷阱", category: .trap, townHallLevel: 15, defaultDurationDays: 1.5, resource: .gold, cost: 800_000, warImpact: .medium),
            GameDataEntry(id: "grand-warden", displayName: "大守护者", category: .hero, townHallLevel: 15, defaultDurationDays: 7, resource: .darkElixir, cost: 150_000, warImpact: .high),
            GameDataEntry(id: "core-research", displayName: "核心兵种科技", category: .research, townHallLevel: 15, defaultDurationDays: 5, resource: .elixir, cost: 2_000_000, warImpact: .high),
            GameDataEntry(id: "spell-research", displayName: "法术同步", category: .research, townHallLevel: 15, defaultDurationDays: 4, resource: .elixir, cost: 1_500_000, warImpact: .medium),
            GameDataEntry(id: "backup-research", displayName: "备用兵种", category: .research, townHallLevel: 15, defaultDurationDays: 6, resource: .elixir, cost: 1_800_000, warImpact: .low)
        ]
    )
}
