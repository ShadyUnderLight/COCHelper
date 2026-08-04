import Foundation

public enum TrackerBase: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case home
    case builder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "主村"
        case .builder: "建筑工人基地"
        }
    }

    public var subtitle: String {
        switch self {
        case .home: "Home Village"
        case .builder: "Builder Base"
        }
    }
}

public enum TrackerCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case buildings
    case traps
    case troops
    case spells
    case siegeMachines
    case heroes
    case equipment
    case pets
    case guardians

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .buildings: "建筑与防御"
        case .traps: "陷阱"
        case .troops: "兵种"
        case .spells: "法术"
        case .siegeMachines: "攻城器械"
        case .heroes: "英雄"
        case .equipment: "装备"
        case .pets: "战宠"
        case .guardians: "守护者"
        }
    }

    public var systemImage: String {
        switch self {
        case .buildings: "building.2.fill"
        case .traps: "exclamationmark.triangle.fill"
        case .troops: "figure.2.arms.open"
        case .spells: "wand.and.stars"
        case .siegeMachines: "car.fill"
        case .heroes: "person.crop.circle.badge.star"
        case .equipment: "shield.lefthalf.filled"
        case .pets: "pawprint.fill"
        case .guardians: "person.2.fill"
        }
    }

    fileprivate var sortOrder: Int {
        switch self {
        case .buildings: 0
        case .traps: 1
        case .troops: 2
        case .spells: 3
        case .siegeMachines: 4
        case .heroes: 5
        case .equipment: 6
        case .pets: 7
        case .guardians: 8
        }
    }

    /// 快照 section 名 → 追踪类别；未知类别返回 nil。
    public static func from(section: String) -> TrackerCategory? {
        switch section.hasSuffix("2") ? String(section.dropLast()) : section {
        case "buildings": .buildings
        case "traps": .traps
        case "units": .troops
        case "spells": .spells
        case "siege_machines": .siegeMachines
        case "heroes": .heroes
        case "equipment": .equipment
        case "pets": .pets
        case "guardians": .guardians
        default: nil
        }
    }
}

public struct UpgradeLevelRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let dataID: Int64
    public let name: String
    public let category: TrackerCategory
    public let base: TrackerBase
    public let sourceSection: String
    public let currentLevel: Int?
    public let count: Int?
    public let timerSeconds: Int64?
    public let remainingSeconds: Int64?
    public let isNested: Bool

    public init(
        id: String,
        dataID: Int64,
        name: String,
        category: TrackerCategory,
        base: TrackerBase,
        sourceSection: String,
        currentLevel: Int?,
        count: Int?,
        timerSeconds: Int64?,
        remainingSeconds: Int64?,
        isNested: Bool
    ) {
        self.id = id
        self.dataID = dataID
        self.name = name
        self.category = category
        self.base = base
        self.sourceSection = sourceSection
        self.currentLevel = currentLevel
        self.count = count
        self.timerSeconds = timerSeconds
        self.remainingSeconds = remainingSeconds
        self.isNested = isNested
    }

    public var hasTimer: Bool { timerSeconds != nil }

    public var isUpgrading: Bool {
        (remainingSeconds ?? 0) > 0
    }

    /// The copied account payload does not expose a separate target level.
    /// For an active timer, the next level is therefore an explicit UI
    /// inference from the recorded current level.
    public var inferredTargetLevel: Int? {
        guard isUpgrading, let currentLevel else { return nil }
        return currentLevel + 1
    }

    public var levelLabel: String {
        guard let currentLevel else { return "等级未记录" }
        if let inferredTargetLevel {
            return String(currentLevel) + " → " + String(inferredTargetLevel)
        }
        return "等级 " + String(currentLevel)
    }

    public var statusLabel: String {
        if isUpgrading { return "正在升级" }
        if hasTimer { return "计时已结束" }
        return "已记录"
    }

    public var countLabel: String? {
        guard let count, count > 1 else { return nil }
        return "×" + String(count)
    }

    public var dataIDLabel: String {
        "#" + String(dataID)
    }

    public var progress: Double? {
        guard let timerSeconds, timerSeconds > 0, let remainingSeconds else { return nil }
        return min(1, max(0, 1 - Double(remainingSeconds) / Double(timerSeconds)))
    }
}

public struct VillageUpgradeRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let villageID: UUID
    public let villageName: String
    public let villageTag: String?
    public let upgrade: UpgradeLevelRecord

    public init(village: VillageProfile, upgrade: UpgradeLevelRecord) {
        self.id = village.id.uuidString + ":" + upgrade.id
        self.villageID = village.id
        self.villageName = village.name
        self.villageTag = village.tag
        self.upgrade = upgrade
    }

    public var base: TrackerBase { upgrade.base }
    public var remainingSeconds: Int64? { upgrade.remainingSeconds }
    public func completionDate(from now: Date) -> Date? {
        guard let remainingSeconds, remainingSeconds > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(remainingSeconds))
    }
}

public enum UpgradeTracker {
    private static let supportedSections: Set<String> = [
        "buildings", "traps", "units", "spells", "siege_machines", "heroes",
        "equipment", "pets", "guardians"
    ]

    public static func records(
        from snapshot: AccountSnapshot,
        base: TrackerBase,
        at now: Date = Date()
    ) -> [UpgradeLevelRecord] {
        snapshot.allObjectItems.compactMap { item in
            let canonicalSection = item.section.hasSuffix("2")
                ? String(item.section.dropLast())
                : item.section
            guard supportedSections.contains(canonicalSection),
                  TrackerCategory.from(section: item.section) != nil,
                  isItemInBase(item, base: base),
                  item.level != nil || item.count != nil || item.timerSeconds != nil
            else { return nil }

            let remainingSeconds = liveRemainingSeconds(
                for: item,
                snapshot: snapshot,
                at: now
            )
            return UpgradeLevelRecord(
                id: item.id,
                dataID: item.dataID,
                name: item.nameLabel,
                category: TrackerCategory.from(section: item.section)!,
                base: base,
                sourceSection: canonicalSection,
                currentLevel: item.level,
                count: item.count,
                timerSeconds: item.timerSeconds,
                remainingSeconds: remainingSeconds,
                isNested: item.id.contains(".types.") || item.id.contains(".modules.")
            )
        }
        .sorted { lhs, rhs in
            if lhs.category.sortOrder != rhs.category.sortOrder {
                return lhs.category.sortOrder < rhs.category.sortOrder
            }
            let leftName = lhs.name.localizedStandardCompare(rhs.name)
            if leftName != .orderedSame { return leftName == .orderedAscending }
            if lhs.currentLevel != rhs.currentLevel { return (lhs.currentLevel ?? -1) < (rhs.currentLevel ?? -1) }
            return lhs.id < rhs.id
        }
    }

    public static func activeRecords(
        from snapshot: AccountSnapshot,
        base: TrackerBase,
        at now: Date = Date()
    ) -> [UpgradeLevelRecord] {
        records(from: snapshot, base: base, at: now)
            .filter(\.isUpgrading)
            .sorted { lhs, rhs in
                let left = lhs.remainingSeconds ?? .max
                let right = rhs.remainingSeconds ?? .max
                if left != right { return left < right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public static func activeRecords(
        from villages: [VillageProfile],
        at now: Date = Date()
    ) -> [VillageUpgradeRecord] {
        villages.flatMap { village in
            guard let snapshot = village.accountSnapshot else { return [VillageUpgradeRecord]() }
            return TrackerBase.allCases.flatMap { base in
                activeRecords(from: snapshot, base: base, at: now).map {
                    VillageUpgradeRecord(village: village, upgrade: $0)
                }
            }
        }
        .sorted { lhs, rhs in
            let leftRemaining = lhs.remainingSeconds ?? .max
            let rightRemaining = rhs.remainingSeconds ?? .max
            if leftRemaining != rightRemaining { return leftRemaining < rightRemaining }
            let villageOrder = lhs.villageName.localizedStandardCompare(rhs.villageName)
            if villageOrder != .orderedSame { return villageOrder == .orderedAscending }
            if lhs.base != rhs.base { return lhs.base.rawValue < rhs.base.rawValue }
            return lhs.id < rhs.id
        }
    }

    private static func isItemInBase(_ item: AccountItem, base: TrackerBase) -> Bool {
        let isBuilderBase = item.section.hasSuffix("2")
        switch base {
        case .home: return !isBuilderBase
        case .builder: return isBuilderBase
        }
    }

    private static func liveRemainingSeconds(
        for item: AccountItem,
        snapshot: AccountSnapshot,
        at now: Date
    ) -> Int64? {
        guard let remaining = item.remainingSeconds else { return nil }
        let elapsed = max(0, Int64(now.timeIntervalSince(snapshot.importedAt).rounded(.down)))
        return max(0, remaining - elapsed)
    }
}
