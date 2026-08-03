import Foundation

public struct BuilderState: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public var currentTaskName: String
    public var remainingDays: Double

    public init(id: Int, currentTaskName: String = "空闲", remainingDays: Double = 0) {
        self.id = id
        self.currentTaskName = currentTaskName
        self.remainingDays = max(0, remainingDays)
    }

    public var title: String { "工人 " + String(id) }
    public var isAvailable: Bool { remainingDays <= 0.01 }

    public static let demo: [BuilderState] = [
        BuilderState(id: 1, currentTaskName: "城墙批次", remainingDays: 1.5),
        BuilderState(id: 2, currentTaskName: "女王", remainingDays: 3),
        BuilderState(id: 3, currentTaskName: "防空火箭", remainingDays: 0),
        BuilderState(id: 4, currentTaskName: "资源建筑", remainingDays: 2),
        BuilderState(id: 5, currentTaskName: "陷阱", remainingDays: 0.5),
        BuilderState(id: 6, currentTaskName: "大守护者", remainingDays: 4)
    ]
}

public struct ResourceStock: Codable, Hashable, Sendable {
    public var current: Int
    public var capacity: Int
    public var dailyIncome: Int

    public init(current: Int, capacity: Int, dailyIncome: Int) {
        self.current = max(0, current)
        self.capacity = max(1, capacity)
        self.dailyIncome = max(0, dailyIncome)
    }

    public var fillRatio: Double {
        min(1, max(0, Double(current) / Double(max(1, capacity))))
    }

    public var headroom: Int { max(0, capacity - current) }
}

public struct ResourceInventory: Codable, Hashable, Sendable {
    public var gold: ResourceStock
    public var elixir: ResourceStock
    public var darkElixir: ResourceStock

    public init(gold: ResourceStock, elixir: ResourceStock, darkElixir: ResourceStock) {
        self.gold = gold
        self.elixir = elixir
        self.darkElixir = darkElixir
    }

    public func stock(for resource: ResourceClass) -> ResourceStock? {
        switch resource {
        case .gold: gold
        case .elixir: elixir
        case .darkElixir: darkElixir
        case .mixed, .none: nil
        }
    }

    public func amount(for resource: ResourceClass) -> Int {
        stock(for: resource)?.current ?? 0
    }

    public func capacity(for resource: ResourceClass) -> Int {
        stock(for: resource)?.capacity ?? 0
    }

    public func dailyIncome(for resource: ResourceClass) -> Int {
        stock(for: resource)?.dailyIncome ?? 0
    }

    public static let demo = ResourceInventory(
        gold: ResourceStock(current: 9_000_000, capacity: 20_000_000, dailyIncome: 1_000_000),
        elixir: ResourceStock(current: 8_000_000, capacity: 20_000_000, dailyIncome: 1_200_000),
        darkElixir: ResourceStock(current: 300_000, capacity: 350_000, dailyIncome: 50_000)
    )
}

public struct HeroStatus: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var level: Int
    public var upgradeRemainingDays: Double
    public var warProtectedUntilDay: Double

    public init(
        id: UUID = UUID(),
        name: String,
        level: Int,
        upgradeRemainingDays: Double = 0,
        warProtectedUntilDay: Double = 0
    ) {
        self.id = id
        self.name = name
        self.level = max(1, level)
        self.upgradeRemainingDays = max(0, upgradeRemainingDays)
        self.warProtectedUntilDay = max(0, warProtectedUntilDay)
    }

    public var nextUpgradeAvailableDay: Double {
        max(upgradeRemainingDays, warProtectedUntilDay)
    }

    public static let demo: [HeroStatus] = [
        HeroStatus(name: "女王", level: 80, upgradeRemainingDays: 0, warProtectedUntilDay: 7),
        HeroStatus(name: "蛮王", level: 75, upgradeRemainingDays: 0, warProtectedUntilDay: 0),
        HeroStatus(name: "大守护者", level: 55, upgradeRemainingDays: 0, warProtectedUntilDay: 0),
        HeroStatus(name: "闰土", level: 30, upgradeRemainingDays: 0, warProtectedUntilDay: 0)
    ]
}
