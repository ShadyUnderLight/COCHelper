import Foundation

/// 战争日志条目时间展示三态（Issue #124）。
public enum WarLogTimeDisplay: Equatable, Sendable {
    /// endTime 缺失：不渲染时间行。
    case hidden
    /// 成功转换为北京时间："2026年8月9日 19:07:38"。
    case beijing(String)
    /// 格式无法识别：保留原始值（UI 标明"官方原始时间"），不得伪造日期。
    case unparsable(String)
}

/// 官方 UTC 紧凑时间 → 北京时间展示（Issue #124）。
///
/// 官方形态：`yyyyMMdd'T'HHmmss[.SSS]'Z'`（如 `20260809T110738.000Z`），
/// Z 视为 UTC；输出固定 Asia/Shanghai（北京），**绝不使用 TimeZone.current**。
/// 实现选择：正则校验 + 手动组件解析（设计评审 D1 候选 A），无 DateFormatter locale 脆弱性。
public enum WarLogTimeFormatter {
    /// 固定北京时区：优先 Asia/Shanghai 标识；ICU 缺失时兜底固定 UTC+8
    /// （中国无夏令时，语义等价）。
    private static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")
        ?? TimeZone(secondsFromGMT: 8 * 3600)!

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private static let beijingCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = beijingTimeZone
        return c
    }()

    /// 官方串正则：8 位日期 + T + 6 位时间 + 可选 1-3 位毫秒 + 大写 Z。
    /// `\z` 严格锚定串尾（`$` 在 anchorsMatchLines 模式下会匹配行尾，不保险）。
    private static let officialPattern = #"^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(\.\d{1,3})?Z\z"#

    public static func displayText(raw: String?) -> WarLogTimeDisplay {
        guard let raw else { return .hidden }
        guard let text = beijingTimeText(raw: raw) else { return .unparsable(raw) }
        return .beijing(text)
    }

    /// 当月天数（含闰年 2 月）；month 越界返回 nil。
    private static func daysInMonth(year: Int, month: Int) -> Int? {
        let table = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month) else { return nil }
        if month == 2, (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 { return 29 }
        return table[month - 1]
    }

    /// 转换成功返回"yyyy年M月d日 HH:mm:ss"（北京时间）；失败返回 nil。
    static func beijingTimeText(raw: String) -> String? {
        guard let match = raw.range(of: officialPattern, options: .regularExpression) else {
            return nil
        }
        let substr = String(raw[match])
        let parts = substr.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let datePart = parts[0], timePart = parts[1]

        func int(_ s: Substring, _ range: Range<Int>) -> Int? {
            let chars = Array(s)
            guard chars.count >= range.upperBound else { return nil }
            return Int(String(chars[range]))
        }

        guard let year = int(datePart, 0..<4),
              let month = int(datePart, 4..<6),
              let day = int(datePart, 6..<8),
              let hour = int(timePart, 0..<2),
              let minute = int(timePart, 2..<4),
              let second = int(timePart, 4..<6)
        else { return nil }

        // 显式范围校验：Foundation Calendar 对越界组件是"溢出归一化"而非拒绝
        // （实测 month 13 → 次年 1 月、hour 24 → 次日），必须先拒绝，
        // 否则会输出被 Calendar 归一化后的伪日期，违反"不得伪造日期"约束。
        // 年份下限 1992：ICU 对更早年份走历史历法数据（BCE 纪元改写、1582 前
        // Julian 历 10 天断层、1901 前 LMT 偏移 +8:05:43），输出组件与输入
        // 不再对应，同样属于伪造日期；CoC 数据最早 2016 年，1992 以下直接拒绝。
        guard year >= 1992,
              let maxDay = daysInMonth(year: year, month: month),
              (1...maxDay).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second)
        else { return nil }

        // 毫秒只参与解析、不参与展示（秒级精度足够），缺失按 0。
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second

        guard let utcDate = utcCalendar.date(from: components) else { return nil }
        let bj = beijingCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: utcDate)
        guard let by = bj.year, let bm = bj.month, let bd = bj.day,
              let bh = bj.hour, let bmi = bj.minute, let bs = bj.second
        else { return nil }

        return "\(by)年\(bm)月\(bd)日 "
            + String(format: "%02d:%02d:%02d", bh, bmi, bs)
    }
}
