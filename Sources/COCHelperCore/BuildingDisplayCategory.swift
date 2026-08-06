import Foundation

public enum TrackerDisplayCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case defense
    case military
    case craftTable

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .defense: "防御建筑"
        case .military: "军事设施"
        case .craftTable: "精制台"
        }
    }

    public var systemImage: String {
        switch self {
        case .defense: "shield.lefthalf.filled"
        case .military: "figure.arms.open"
        case .craftTable: "hammer.fill"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .defense: 0
        case .military: 1
        case .craftTable: 2
        }
    }
}

/// Issue #37：主世界建筑展示分类的集中式规则表（稳定 dataID，不依赖本地化名称）。
/// 规则：section == "buildings" 且 base == .home 才细分；精制台按根父归属；
/// 其余（资源/大本营/活动/未知）返回 nil → UI 走原「建筑与防御」兜底，项目不丢失。
public enum BuildingDisplayCategoryRules {
    public static let craftTableDataID: Int64 = 1000097

    /// 已确认的主世界普通防御建筑（issue #37 定义 + 2026-08-06 三 agent 投票）。
    static let defenseDataIDs: Set<Int64> = [
        1000008, 1000009, 1000010, 1000011, 1000012, 1000013,
        1000019, 1000021, 1000027, 1000028, 1000031, 1000032,
        1000067, 1000072, 1000077, 1000079, 1000084, 1000085,
        1000086, 1000089, 1000102,
    ]

    /// 已确认的军事/作战支持设施（issue #37 定义 + 2026-08-06 三 agent 投票）。
    static let militaryDataIDs: Set<Int64> = [
        1000000, 1000006, 1000007, 1000014, 1000020, 1000026,
        1000029, 1000059, 1000068, 1000070, 1000071,
    ]

    /// 平铺 id 的根父段：`"buildings:6.types.0.modules.2"` → `"buildings:6"`；
    /// 无嵌套段时返回原 id。
    public static func rootID(of id: String) -> String {
        id.split(separator: ".").first.map(String.init) ?? id
    }

    /// 展示分类判定。嵌套项必须传 `rootParentDataID`（其自身 dataID 是 types/modules 段，
    /// 不在任何白名单内）；平铺项传 nil。`rootParentDataID` 非 nil 时按根父自身归类
    /// （嵌套项继承根父展示分类，避免父子跨组分裂），平铺项仍按自身 `dataID` 白名单判定。
    public static func displayCategory(
        section: String,
        dataID: Int64,
        base: TrackerBase,
        rootParentDataID: Int64?
    ) -> TrackerDisplayCategory? {
        guard section == "buildings", base == .home else { return nil }
        if let rootParentDataID {
            // 嵌套项：继承根父展示分类（根父自身归类；精制台 1000097 → .craftTable，
            // 防御/军事白名单父建筑的后代跟随父项，避免跨组父子分裂）。
            return displayCategory(section: section, dataID: rootParentDataID, base: base, rootParentDataID: nil)
        }
        if dataID == craftTableDataID { return .craftTable }
        if defenseDataIDs.contains(dataID) { return .defense }
        if militaryDataIDs.contains(dataID) { return .military }
        return nil
    }
}
