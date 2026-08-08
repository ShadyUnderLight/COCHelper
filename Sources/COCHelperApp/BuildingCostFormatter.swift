import Foundation

/// 千分位费用格式化（Issue #71 移层：从 COCHelper executable 移至
/// COCHelperApp，与 `ClanDisplayFormat` 同层聚合；跨模块调用需 public）。
///
/// 注意 `String(format: "%,d", …)` 在 macOS 不产生分组（comma flag 未实现，
/// 会原样输出 "%d" 而非分组数字），故用 NumberFormatter(.decimal) 走当前
/// locale 分组符（与 `AccountDurationFormatter` 同为纯函数式格式化器）。
public enum BuildingCostFormatter {
    public static func label(_ cost: Int64) -> String {
        numberFormatter.string(from: NSNumber(value: cost)) ?? String(cost)
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
