import Foundation

public enum CraftTableModuleStatus: String, Codable, Hashable, Sendable {
    case recorded
    case upgrading
    case maxed
    case unknown
}

/// One module rendered under a Defense in the read-only craft table.
public struct CraftTableModuleState: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let dataID: Int64
    public let name: String
    public let statTypes: [String]
    public let displayTitles: [String]
    public let currentLevel: Int?
    public let maxLevel: Int?
    public let status: CraftTableModuleStatus
    public let timerSeconds: Int64?
    public let remainingSeconds: Int64?
    public let missingReason: String?

    public init(
        id: String,
        dataID: Int64,
        name: String,
        statTypes: [String] = [],
        displayTitles: [String] = [],
        currentLevel: Int? = nil,
        maxLevel: Int? = nil,
        status: CraftTableModuleStatus = .unknown,
        timerSeconds: Int64? = nil,
        remainingSeconds: Int64? = nil,
        missingReason: String? = nil
    ) {
        self.id = id
        self.dataID = dataID
        self.name = name
        self.statTypes = statTypes
        self.displayTitles = displayTitles
        self.currentLevel = currentLevel
        self.maxLevel = maxLevel
        self.status = status
        self.timerSeconds = timerSeconds
        self.remainingSeconds = remainingSeconds
        self.missingReason = missingReason
    }

    public var attributeLabel: String? {
        let titles = displayTitles.filter { !$0.isEmpty }
        guard !titles.isEmpty else { return nil }
        return titles.joined(separator: "、")
    }

    public var nextLevel: Int? {
        guard status == .upgrading, let currentLevel else { return nil }
        return currentLevel + 1
    }

    public var isUpgrading: Bool { status == .upgrading }

    public var needsReimport: Bool {
        timerSeconds != nil && remainingSeconds == 0
    }
}

/// One Defense row with its ordered module rows.
public struct CraftTableDefenseState: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let dataID: Int64
    public let name: String
    public let currentLevel: Int?
    public let availability: CatalogAvailability
    public let modules: [CraftTableModuleState]

    public init(
        id: String,
        dataID: Int64,
        name: String,
        currentLevel: Int? = nil,
        availability: CatalogAvailability = .unconfigured,
        modules: [CraftTableModuleState]
    ) {
        self.id = id
        self.dataID = dataID
        self.name = name
        self.currentLevel = currentLevel
        self.availability = availability
        self.modules = modules
    }
}

/// Projects the nested account snapshot into the dedicated Defense/Module UI.
///
/// The snapshot remains authoritative for which Defenses/modules are observed.
/// The static catalog only supplies names, expected module IDs, attributes and
/// max levels; it never invents a new Defense outside the imported snapshot.
public enum CraftTableProjection {
    public static func project(
        village: VillageProfile,
        catalog: CraftTableCatalog?,
        base: TrackerBase,
        seasonalPhases: SeasonalPhaseTable = .empty,
        now: Date = Date()
    ) -> [CraftTableDefenseState] {
        guard base == .home,
              let snapshot = village.accountSnapshot,
              let craftTable = snapshot.objectSections["buildings"]?.first(where: {
                  $0.dataID == BuildingDisplayCategoryRules.craftTableDataID
              })
        else {
            return []
        }

        return craftTable.types.map { defense in
            let defenseSpec = catalog?.defense(dataID: defense.dataID)
            var modules = defense.modules.map { module in
                makeModule(
                    module,
                    parentID: defense.id,
                    snapshot: snapshot,
                    catalog: catalog,
                    now: now
                )
            }
            let observedIDs = Set(defense.modules.map(\.dataID))
            for moduleID in defenseSpec?.moduleIDs ?? [] where !observedIDs.contains(moduleID) {
                modules.append(makeMissingModule(
                    dataID: moduleID,
                    parentID: defense.id,
                    catalog: catalog
                ))
            }

            return CraftTableDefenseState(
                id: defense.id,
                dataID: defense.dataID,
                name: defenseSpec?.name ?? defense.nameLabel,
                currentLevel: defense.level,
                availability: seasonalPhases.availability(
                    forItemKey: "buildings:\(defense.dataID)",
                    lifecycle: defenseSpec?.lifecycle,  // Issue #98：目录声明；无声明 nil → 查表/未配置
                    at: now
                ),
                modules: modules
            )
        }
    }

    private static func makeModule(
        _ item: AccountItem,
        parentID: String,
        snapshot: AccountSnapshot,
        catalog: CraftTableCatalog?,
        now: Date
    ) -> CraftTableModuleState {
        let spec = catalog?.module(dataID: item.dataID)
        let remaining = VillageCatalogProjection.liveRemainingSeconds(
            for: item,
            snapshot: snapshot,
            at: now
        )
        let status: CraftTableModuleStatus
        if (remaining ?? 0) > 0 {
            status = .upgrading
        } else if let level = item.level, let maxLevel = spec?.maxLevel, level >= maxLevel {
            status = .maxed
        } else if spec != nil {
            status = .recorded
        } else {
            status = .unknown
        }
        let reason: String?
        if spec == nil {
            reason = "版本化精制台目录未收录该模组"
        } else {
            reason = nil
        }
        return CraftTableModuleState(
            id: item.id,
            dataID: item.dataID,
            name: spec?.name ?? item.nameLabel,
            statTypes: spec?.statTypes ?? [],
            displayTitles: spec?.displayTitles ?? [],
            currentLevel: item.level,
            maxLevel: spec?.maxLevel,
            status: status,
            timerSeconds: item.timerSeconds,
            remainingSeconds: remaining,
            missingReason: reason
        )
    }

    private static func makeMissingModule(
        dataID: Int64,
        parentID: String,
        catalog: CraftTableCatalog?
    ) -> CraftTableModuleState {
        let spec = catalog?.module(dataID: dataID)
        return CraftTableModuleState(
            id: parentID + ":module:" + String(dataID),
            dataID: dataID,
            name: spec?.name ?? ("未记录模组 #" + String(dataID)),
            statTypes: spec?.statTypes ?? [],
            displayTitles: spec?.displayTitles ?? [],
            currentLevel: nil,
            maxLevel: spec?.maxLevel,
            status: .unknown,
            missingReason: "快照未包含该模组"
        )
    }
}
