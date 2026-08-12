import Foundation

/// 部落对战攻击明细/最佳防守文案（Issue #127，从 UI 迁入 Core 可测）。
///
/// 契约（与 `ClanCombatSummary.durationText` / `displayDestructionPercent` 同源）：
/// - 各字段独立降级：order 缺失 → "?"；目标缺失 → "目标未知"（不补名称）；
///   星数缺失 → "⭐?"；摧毁率缺失 → "摧毁率未知"；时长缺失 → "耗时未知"。
/// - 星数 clamp [0,3]（官方契约 0...3，schema 外输入不崩溃）。
/// - 摧毁率经 `displayDestructionPercent`（NaN/Inf → 未知），格式化走
///   `ClanCombatSummary.percentText`（单一来源）。
/// - 时长经 `ClanCombatSummary.durationText`（分:秒）。
public enum ClanWarDetailText {
    /// 单次攻击明细：`1号进攻 · 目标 #XXX · ⭐2 · 摧毁率 90% · 耗时 2:25`。
    public static func attackLine(_ line: ClanWarAttackLine) -> String {
        let order = line.order.map { "\($0)" } ?? "?"
        let target = line.defenderTag.map { "目标 \($0)" } ?? "目标未知"
        let stars = line.stars.map { "⭐\(min(max($0, 0), 3))" } ?? "⭐?"
        let destruction = ClanCombatSummary.displayDestructionPercent(line.destructionPercentage)
            .map { "摧毁率 \(ClanCombatSummary.percentText($0))%" } ?? "摧毁率未知"
        let duration = ClanCombatSummary.durationText(line.duration).map { "耗时 \($0)" } ?? "耗时未知"
        return "\(order)号进攻 · \(target) · \(stars) · \(destruction) · \(duration)"
    }

    /// 最佳防守：`最佳防守 · ⭐2 · 摧毁率 75% · 耗时 2:00`。
    public static func bestDefense(_ best: ClanWarAttackLine) -> String {
        let stars = best.stars.map { "⭐\(min(max($0, 0), 3))" } ?? "⭐?"
        let destruction = ClanCombatSummary.displayDestructionPercent(best.destructionPercentage)
            .map { "摧毁率 \(ClanCombatSummary.percentText($0))%" } ?? "摧毁率未知"
        let duration = ClanCombatSummary.durationText(best.duration).map { "耗时 \($0)" } ?? "耗时未知"
        return "最佳防守 · \(stars) · \(destruction) · \(duration)"
    }
}
