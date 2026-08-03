import Foundation

public enum PlanningHorizon: Int, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case days30 = 30
    case days90 = 90
    case days180 = 180

    public var id: Int { rawValue }
    public var days: Double { Double(rawValue) }
    public var title: String { String(rawValue) + " 天" }
}

public enum DailyCheckInFrequency: Int, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case once = 1
    case twice = 2
    case fourTimes = 4

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .once: "每天 1 次"
        case .twice: "每天 2 次"
        case .fourTimes: "每天 4 次"
        }
    }

    /// The smallest planning unit used by the heuristic scheduler.
    public var schedulingStep: Double { 1.0 / Double(rawValue) }
}

public enum WarMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case relaxed
    case warReady
    case league

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .relaxed: "休闲发展"
        case .warReady: "部落战优先"
        case .league: "联赛期间"
        }
    }

    public var description: String {
        switch self {
        case .relaxed: "允许少量英雄空档，追求长期效率"
        case .warReady: "尽量维持可出战阵容"
        case .league: "英雄默认保留，减少联赛期间的不可用窗口"
        }
    }
}

public enum TownHallReadiness: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case notReady
    case nearlyReady
    case ready

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .notReady: "还没准备好"
        case .nearlyReady: "接近准备好"
        case .ready: "已经准备好"
        }
    }
}

public enum UpgradeCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case townHall
    case building
    case defense
    case hero
    case wall
    case trap
    case resource
    case research

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .townHall: "大本营"
        case .building: "建筑"
        case .defense: "防御"
        case .hero: "英雄"
        case .wall: "城墙"
        case .trap: "陷阱"
        case .resource: "资源建筑"
        case .research: "科技"
        }
    }
}

public enum ResourceClass: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case gold
    case elixir
    case darkElixir
    case mixed
    case none

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .gold: "金币"
        case .elixir: "圣水"
        case .darkElixir: "黑油"
        case .mixed: "混合资源"
        case .none: "未指定"
        }
    }
}

public enum WarImpact: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case high
    case medium
    case low

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .high: "影响大"
        case .medium: "影响中"
        case .low: "影响小"
        }
    }
}

public enum BuilderTrack: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case automatic
    case core
    case hero
    case defense
    case flex
    case traps
    case longTermHero

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "自动分配"
        case .core: "核心建筑"
        case .hero: "短周期英雄"
        case .defense: "防御"
        case .flex: "城墙与资源"
        case .traps: "陷阱"
        case .longTermHero: "长期英雄"
        }
    }
}

public struct UpgradeTask: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var category: UpgradeCategory
    public var durationDays: Double
    public var resource: ResourceClass
    public var priority: Int
    public var warImpact: WarImpact
    public var track: BuilderTrack
    public var isRepeatable: Bool
    public var dataKey: String?
    public var estimatedCost: Int

    public init(
        id: UUID = UUID(),
        name: String,
        category: UpgradeCategory,
        durationDays: Double,
        resource: ResourceClass = .none,
        priority: Int = 50,
        warImpact: WarImpact = .medium,
        track: BuilderTrack = .automatic,
        isRepeatable: Bool = false,
        dataKey: String? = nil,
        estimatedCost: Int = 0
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.durationDays = max(0.25, durationDays)
        self.resource = resource
        self.priority = priority
        self.warImpact = warImpact
        self.track = track
        self.isRepeatable = isRepeatable
        self.dataKey = dataKey
        self.estimatedCost = max(0, estimatedCost)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case durationDays
        case resource
        case priority
        case warImpact
        case track
        case isRepeatable
        case dataKey
        case estimatedCost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名升级",
            category: try container.decodeIfPresent(UpgradeCategory.self, forKey: .category) ?? .building,
            durationDays: try container.decodeIfPresent(Double.self, forKey: .durationDays) ?? 1,
            resource: try container.decodeIfPresent(ResourceClass.self, forKey: .resource) ?? .none,
            priority: try container.decodeIfPresent(Int.self, forKey: .priority) ?? 50,
            warImpact: try container.decodeIfPresent(WarImpact.self, forKey: .warImpact) ?? .medium,
            track: try container.decodeIfPresent(BuilderTrack.self, forKey: .track) ?? .automatic,
            isRepeatable: try container.decodeIfPresent(Bool.self, forKey: .isRepeatable) ?? false,
            dataKey: try container.decodeIfPresent(String.self, forKey: .dataKey),
            estimatedCost: try container.decodeIfPresent(Int.self, forKey: .estimatedCost) ?? 0
        )
    }
}

public struct ResearchTask: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var durationDays: Double
    public var resource: ResourceClass
    public var priority: Int
    public var dataKey: String?
    public var estimatedCost: Int

    public init(
        id: UUID = UUID(),
        name: String,
        durationDays: Double,
        resource: ResourceClass = .elixir,
        priority: Int = 50,
        dataKey: String? = nil,
        estimatedCost: Int = 0
    ) {
        self.id = id
        self.name = name
        self.durationDays = max(0.25, durationDays)
        self.resource = resource
        self.priority = priority
        self.dataKey = dataKey
        self.estimatedCost = max(0, estimatedCost)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case durationDays
        case resource
        case priority
        case dataKey
        case estimatedCost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名科技",
            durationDays: try container.decodeIfPresent(Double.self, forKey: .durationDays) ?? 1,
            resource: try container.decodeIfPresent(ResourceClass.self, forKey: .resource) ?? .elixir,
            priority: try container.decodeIfPresent(Int.self, forKey: .priority) ?? 50,
            dataKey: try container.decodeIfPresent(String.self, forKey: .dataKey),
            estimatedCost: try container.decodeIfPresent(Int.self, forKey: .estimatedCost) ?? 0
        )
    }
}

public struct PlannerInput: Codable, Hashable, Sendable {
    public var townHallLevel: Int
    public var builderCount: Int
    public var researchRemainingDays: Double
    public var horizon: PlanningHorizon
    public var checkInFrequency: DailyCheckInFrequency
    public var warMode: WarMode
    public var reserveHeroesDuringLeague: Bool
    public var avoidResourceOverflow: Bool
    public var magicItemsAvailable: Bool
    public var nextTownHallReadiness: TownHallReadiness
    public var builderStates: [BuilderState]
    public var resourceInventory: ResourceInventory
    public var heroStatuses: [HeroStatus]
    public var gameDataCatalog: GameDataCatalog
    public var tasks: [UpgradeTask]
    public var researchTasks: [ResearchTask]

    public init(
        townHallLevel: Int,
        builderCount: Int,
        researchRemainingDays: Double,
        horizon: PlanningHorizon,
        checkInFrequency: DailyCheckInFrequency,
        warMode: WarMode,
        reserveHeroesDuringLeague: Bool,
        avoidResourceOverflow: Bool,
        magicItemsAvailable: Bool,
        nextTownHallReadiness: TownHallReadiness,
        builderStates: [BuilderState] = BuilderState.demo,
        resourceInventory: ResourceInventory = .demo,
        heroStatuses: [HeroStatus] = HeroStatus.demo,
        gameDataCatalog: GameDataCatalog = .demo,
        tasks: [UpgradeTask],
        researchTasks: [ResearchTask]
    ) {
        self.townHallLevel = max(1, townHallLevel)
        self.builderCount = min(6, max(1, builderCount))
        self.researchRemainingDays = max(0, researchRemainingDays)
        self.horizon = horizon
        self.checkInFrequency = checkInFrequency
        self.warMode = warMode
        self.reserveHeroesDuringLeague = reserveHeroesDuringLeague
        self.avoidResourceOverflow = avoidResourceOverflow
        self.magicItemsAvailable = magicItemsAvailable
        self.nextTownHallReadiness = nextTownHallReadiness
        let normalizedBuilders = builderStates.isEmpty ? BuilderState.demo : builderStates
        self.builderStates = (1...6).map { id in
            normalizedBuilders.first(where: { $0.id == id }) ?? BuilderState(id: id)
        }
        self.resourceInventory = resourceInventory
        self.heroStatuses = heroStatuses
        self.gameDataCatalog = gameDataCatalog
        self.tasks = tasks
        self.researchTasks = researchTasks
    }

    private enum CodingKeys: String, CodingKey {
        case townHallLevel
        case builderCount
        case researchRemainingDays
        case horizon
        case checkInFrequency
        case warMode
        case reserveHeroesDuringLeague
        case avoidResourceOverflow
        case magicItemsAvailable
        case nextTownHallReadiness
        case builderStates
        case resourceInventory
        case heroStatuses
        case gameDataCatalog
        case tasks
        case researchTasks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            townHallLevel: try container.decodeIfPresent(Int.self, forKey: .townHallLevel) ?? 1,
            builderCount: try container.decodeIfPresent(Int.self, forKey: .builderCount) ?? 1,
            researchRemainingDays: try container.decodeIfPresent(Double.self, forKey: .researchRemainingDays) ?? 0,
            horizon: try container.decodeIfPresent(PlanningHorizon.self, forKey: .horizon) ?? .days30,
            checkInFrequency: try container.decodeIfPresent(DailyCheckInFrequency.self, forKey: .checkInFrequency) ?? .once,
            warMode: try container.decodeIfPresent(WarMode.self, forKey: .warMode) ?? .relaxed,
            reserveHeroesDuringLeague: try container.decodeIfPresent(Bool.self, forKey: .reserveHeroesDuringLeague) ?? false,
            avoidResourceOverflow: try container.decodeIfPresent(Bool.self, forKey: .avoidResourceOverflow) ?? true,
            magicItemsAvailable: try container.decodeIfPresent(Bool.self, forKey: .magicItemsAvailable) ?? false,
            nextTownHallReadiness: try container.decodeIfPresent(TownHallReadiness.self, forKey: .nextTownHallReadiness) ?? .nearlyReady,
            builderStates: try container.decodeIfPresent([BuilderState].self, forKey: .builderStates) ?? BuilderState.demo,
            resourceInventory: try container.decodeIfPresent(ResourceInventory.self, forKey: .resourceInventory) ?? .demo,
            heroStatuses: try container.decodeIfPresent([HeroStatus].self, forKey: .heroStatuses) ?? HeroStatus.demo,
            gameDataCatalog: try container.decodeIfPresent(GameDataCatalog.self, forKey: .gameDataCatalog) ?? .demo,
            tasks: try container.decodeIfPresent([UpgradeTask].self, forKey: .tasks) ?? [],
            researchTasks: try container.decodeIfPresent([ResearchTask].self, forKey: .researchTasks) ?? []
        )
    }

    public static let demo = PlannerInput(
        townHallLevel: 15,
        builderCount: 6,
        researchRemainingDays: 1.5,
        horizon: .days90,
        checkInFrequency: .twice,
        warMode: .warReady,
        reserveHeroesDuringLeague: true,
        avoidResourceOverflow: true,
        magicItemsAvailable: true,
        nextTownHallReadiness: .nearlyReady,
        builderStates: BuilderState.demo,
        resourceInventory: .demo,
        heroStatuses: HeroStatus.demo,
        gameDataCatalog: .demo,
        tasks: [
            UpgradeTask(name: "大本营", category: .townHall, durationDays: 7, resource: .gold, priority: 100, warImpact: .high, track: .core, dataKey: "town-hall"),
            UpgradeTask(name: "实验室", category: .building, durationDays: 4, resource: .elixir, priority: 96, warImpact: .low, track: .core, dataKey: "laboratory"),
            UpgradeTask(name: "兵营", category: .building, durationDays: 4, resource: .elixir, priority: 88, warImpact: .medium, track: .core, dataKey: "barracks"),
            UpgradeTask(name: "女王", category: .hero, durationDays: 6, resource: .darkElixir, priority: 98, warImpact: .high, track: .hero, dataKey: "queen"),
            UpgradeTask(name: "女王", category: .hero, durationDays: 6, resource: .darkElixir, priority: 97, warImpact: .high, track: .hero, dataKey: "queen"),
            UpgradeTask(name: "女王", category: .hero, durationDays: 6, resource: .darkElixir, priority: 96, warImpact: .high, track: .hero, dataKey: "queen"),
            UpgradeTask(name: "防空火箭", category: .defense, durationDays: 5, resource: .gold, priority: 90, warImpact: .high, track: .defense, dataKey: "air-defense"),
            UpgradeTask(name: "资源建筑", category: .resource, durationDays: 3, resource: .elixir, priority: 62, warImpact: .low, track: .flex, dataKey: "resource-building"),
            UpgradeTask(name: "城墙", category: .wall, durationDays: 2.5, resource: .gold, priority: 54, warImpact: .low, track: .flex, isRepeatable: true, dataKey: "wall-batch"),
            UpgradeTask(name: "陷阱", category: .trap, durationDays: 1.5, resource: .gold, priority: 57, warImpact: .medium, track: .traps, isRepeatable: true, dataKey: "trap-batch"),
            UpgradeTask(name: "大守护者", category: .hero, durationDays: 7, resource: .darkElixir, priority: 86, warImpact: .high, track: .longTermHero, dataKey: "grand-warden")
        ],
        researchTasks: [
            ResearchTask(name: "核心兵种科技", durationDays: 5, resource: .elixir, priority: 95, dataKey: "core-research"),
            ResearchTask(name: "法术同步", durationDays: 4, resource: .elixir, priority: 82, dataKey: "spell-research"),
            ResearchTask(name: "备用兵种", durationDays: 6, resource: .elixir, priority: 65, dataKey: "backup-research")
        ]
    )
}

public struct PlannedTask: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceTaskID: UUID
    public let name: String
    public let category: UpgradeCategory
    public let resource: ResourceClass
    public let startDay: Double
    public let endDay: Double
    public let durationDays: Double
    public let cost: Int
    public let dataKey: String?
    public let note: String?
    public let isDeferred: Bool

    public init(
        id: UUID = UUID(),
        sourceTaskID: UUID,
        name: String,
        category: UpgradeCategory,
        resource: ResourceClass,
        startDay: Double,
        endDay: Double,
        durationDays: Double,
        cost: Int = 0,
        dataKey: String? = nil,
        note: String? = nil,
        isDeferred: Bool = false
    ) {
        self.id = id
        self.sourceTaskID = sourceTaskID
        self.name = name
        self.category = category
        self.resource = resource
        self.startDay = startDay
        self.endDay = endDay
        self.durationDays = durationDays
        self.cost = max(0, cost)
        self.dataKey = dataKey
        self.note = note
        self.isDeferred = isDeferred
    }
}

public struct BuilderPlan: Identifiable, Hashable, Sendable {
    public let id: Int
    public let builderIndex: Int
    public let title: String
    public let role: String
    public let tasks: [PlannedTask]

    public init(builderIndex: Int, title: String, role: String, tasks: [PlannedTask]) {
        self.id = builderIndex
        self.builderIndex = builderIndex
        self.title = title
        self.role = role
        self.tasks = tasks
    }
}

public enum InsightTone: String, Hashable, Sendable {
    case positive
    case warning
    case information
    case neutral
}

public struct PlannerInsight: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String
    public let tone: InsightTone

    public init(id: UUID = UUID(), title: String, message: String, tone: InsightTone) {
        self.id = id
        self.title = title
        self.message = message
        self.tone = tone
    }
}

public struct PlanMetrics: Hashable, Sendable {
    public let overallScore: Int
    public let warFriendlyScore: Int
    public let resourcePressure: Int
    public let syncScore: Int
    public let earlyTownHallRisk: Int
    public let activeBuilders: Int
    public let plannedTaskCount: Int
    public let resourceBlockedCount: Int
    public let dataCoveragePercent: Int

    public init(
        overallScore: Int,
        warFriendlyScore: Int,
        resourcePressure: Int,
        syncScore: Int,
        earlyTownHallRisk: Int,
        activeBuilders: Int,
        plannedTaskCount: Int,
        resourceBlockedCount: Int = 0,
        dataCoveragePercent: Int = 0
    ) {
        self.overallScore = overallScore
        self.warFriendlyScore = warFriendlyScore
        self.resourcePressure = resourcePressure
        self.syncScore = syncScore
        self.earlyTownHallRisk = earlyTownHallRisk
        self.activeBuilders = activeBuilders
        self.plannedTaskCount = plannedTaskCount
        self.resourceBlockedCount = resourceBlockedCount
        self.dataCoveragePercent = dataCoveragePercent
    }
}

public struct RoadmapPlan: Hashable, Sendable {
    public let horizonDays: Int
    public let builders: [BuilderPlan]
    public let research: [PlannedTask]
    public let metrics: PlanMetrics
    public let insights: [PlannerInsight]
    public let dataLayer: GameDataLayerStatus

    public init(
        horizonDays: Int,
        builders: [BuilderPlan],
        research: [PlannedTask],
        metrics: PlanMetrics,
        insights: [PlannerInsight],
        dataLayer: GameDataLayerStatus
    ) {
        self.horizonDays = horizonDays
        self.builders = builders
        self.research = research
        self.metrics = metrics
        self.insights = insights
        self.dataLayer = dataLayer
    }
}
