import Foundation

/// Issue #212：村庄详情扁平 render row 元数据（轻量 ID，不含 View body）。
///
/// 稳定 ID = 投影/快照 ID（禁止 offset / UUID——跨筛选/分页不变）。
/// 渲染时通过 `groupID` / `instanceID` / `itemID` 回查当前 tick 的
/// `BuildingGroup` / `BuildingInstance` / `VillageItemState`。
public enum VillageDetailFlatRow: Identifiable, Hashable, Sendable {
    /// 非精制台 section 头部：标题 + 完成度（Panel）。
    case sectionHeader(groupID: String, stats: VillageCategoryCompletion?)
    /// 精制台整组：标题 + 完成度 + 表格保留单 Panel 外观。
    case craftTable(groupID: String, stats: VillageCategoryCompletion?)
    /// 组头卡：`BuildingGroupSummaryView` 汇总 + Start/Cancel/Adjust 动作行。
    case groupHeader(groupID: String)
    /// 单实例块：实例行 + 该记录自己的升级阶梯（leadingDivider = 组内非首个）。
    case instance(groupID: String, instanceID: String, leadingDivider: Bool)
    /// 旧列表行（issue #24 父子缩进平铺；leadingDivider = 非 section 内首行）。
    case legacy(itemID: String, groupID: String, indented: Bool, leadingDivider: Bool)

    public var id: String {
        switch self {
        case .sectionHeader(let groupID, _):
            return "section:\(groupID)"
        case .craftTable(let groupID, _):
            return "craft:\(groupID)"
        case .groupHeader(let groupID):
            return "groupHeader:\(groupID)"
        case .instance(let groupID, let instanceID, _):
            return "instance:\(groupID):\(instanceID)"
        case .legacy(let itemID, _, _, _):
            return "legacy:\(itemID)"
        }
    }
}
