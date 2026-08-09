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

/// Issue #37 + #75 工作流 C：主世界建筑展示分类。数据源 = catalog 的
/// `displayCategory` 字段（**唯一事实源**，Python 侧 validate 闭枚举保证
/// "defense"/"military"/"craftTable"/null；Swift 侧白名单已随数据化删除）。
/// 规则：section == "buildings" 且 base == .home 才细分（按根父 dataID 查
/// catalog）；catalog 为 nil、目录 item 缺失或字段缺失 → nil → UI 走原
/// 「建筑与防御」兜底，项目不丢失（安全回退）。
public enum BuildingDisplayCategoryRules {
    /// 精制台 dataID。**快照查询锚点**（CraftTableProjection 定位精制台槽位），
    /// 非分类白名单——分类由 catalog displayCategory 驱动（#65 落地后评估
    /// 数据化）；validate.py 已强制 catalog 中 1000097.displayCategory ==
    /// "craftTable"（双源一致性，此处常量与目录数据互证）。
    public static let craftTableDataID: Int64 = 1000097

    /// 平铺 id 的根父段：`"buildings:6.types.0.modules.2"` → `"buildings:6"`；
    /// 无嵌套段时返回原 id。
    public static func rootID(of id: String) -> String {
        id.split(separator: ".").first.map(String.init) ?? id
    }

    /// 展示分类判定。嵌套项必须传 `rootParentDataID`（其自身 dataID 是
    /// types/modules 段，不在目录内）；平铺项传 nil。
    /// `rootParentDataID` 非 nil 时按根父自身 dataID 查 catalog 归类
    /// （嵌套项继承根父展示分类，避免父子跨组分裂），平铺项按自身 dataID 查。
    /// catalog 为 nil 或查不到 item/字段缺失 → nil（安全回退，UI 走兜底组）；
    /// 未知 raw 值（契约外字符串）→ nil（防御性兜底，catalog 数据已由
    /// validate 闭枚举保证，此处仅纵深防御）。
    public static func displayCategory(
        section: String,
        dataID: Int64,
        base: TrackerBase,
        rootParentDataID: Int64?,
        catalog: GameCatalog?
    ) -> TrackerDisplayCategory? {
        guard section == "buildings", base == .home else { return nil }
        // 嵌套继承：按根父 dataID 查 catalog（根父自身归类；平铺项即自身 dataID）。
        let effectiveDataID = rootParentDataID ?? dataID
        guard let raw = catalog?.item(section: "buildings", dataID: effectiveDataID)?.displayCategory else {
            return nil
        }
        return TrackerDisplayCategory(rawValue: raw)
    }
}
