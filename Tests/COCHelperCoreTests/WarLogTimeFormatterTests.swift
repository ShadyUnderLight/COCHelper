import XCTest
@testable import COCHelperCore

final class WarLogTimeFormatterTests: XCTestCase {
    // MARK: - 已知样例（issue 提供）

    func testOfficialExampleConvertsToBeijing() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260809T110738.000Z"),
            .beijing("2026年8月9日 19:07:38"))
    }

    // MARK: - 跨日/跨月/跨年边界

    func testCrossDayBoundary() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260809T160000.000Z"),
            .beijing("2026年8月10日 00:00:00"))
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260809T155959.000Z"),
            .beijing("2026年8月9日 23:59:59"))
    }

    func testCrossMonthBoundary() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260731T160000.000Z"),
            .beijing("2026年8月1日 00:00:00"))
    }

    func testCrossYearBoundary() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20251231T160000.000Z"),
            .beijing("2026年1月1日 00:00:00"))
    }

    // MARK: - 毫秒变体

    func testNoMillisecondsVariant() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260809T110738Z"),
            .beijing("2026年8月9日 19:07:38"))
    }

    func testOneAndTwoDigitMillisecondsVariants() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260809T110738.5Z"),
            .beijing("2026年8月9日 19:07:38"))
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260809T110738.50Z"),
            .beijing("2026年8月9日 19:07:38"))
    }

    // MARK: - 缺失 / 非法降级

    func testNilEndTimeIsHidden() {
        XCTAssertEqual(WarLogTimeFormatter.displayText(raw: nil), .hidden)
    }

    func testUnparsableRawValuesDegrade() {
        let bad = ["", "20260809", "2026-08-09T11:07:38.000Z",
                   "20260809T110738", "20260809T110738.000", "20260809T110738.000+00:00",
                   "20260809T110738.000z", "abc", "20261309T110738.000Z", "20260809T246000.000Z"]
        for raw in bad {
            XCTAssertEqual(WarLogTimeFormatter.displayText(raw: raw), .unparsable(raw),
                           "raw=\(raw) 应降级为 unparsable 并保留原始值")
        }
    }

    // MARK: - 时区独立性（issue 验收：非北京时区环境输出一致）

    func testOutputIndependentOfCurrentTimeZone() {
        let raw = "20260809T110738.000Z"
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        for zoneID in ["America/Los_Angeles", "Asia/Tokyo", "UTC", "Pacific/Kiritimati"] {
            NSTimeZone.default = TimeZone(identifier: zoneID)!
            XCTAssertEqual(
                WarLogTimeFormatter.displayText(raw: raw), .beijing("2026年8月9日 19:07:38"),
                "本机时区 \(zoneID) 下输出必须相同")
        }
    }

    // MARK: - Property-based：确定性抽样 × 独立整数参考实现

    /// 独立参考实现：公历 civil-from-days 算法（Howard Hinnant），
    /// 纯整数运算 UTC+8，与生产实现（Foundation Calendar）完全独立。
    private func referenceBeijing(
        year y: Int, month m: Int, day d: Int, hour h: Int, minute mi: Int, second s: Int
    ) -> String {
        func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
            let y2 = m <= 2 ? y - 1 : y
            let era = (y2 >= 0 ? y2 : y2 - 399) / 400
            let yoe = y2 - era * 400
            let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146097 + doe - 719468
        }
        func civilFromDays(_ z: Int) -> (Int, Int, Int) {
            let z2 = z + 719468
            let era = (z2 >= 0 ? z2 : z2 - 146096) / 146097
            let doe = z2 - era * 146097
            let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
            let y = yoe + era * 400
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            let d = doy - (153 * mp + 2) / 5 + 1
            let m = mp + (mp < 10 ? 3 : -9)
            return (m <= 2 ? y + 1 : y, m, d)
        }
        let utcMinutes = daysFromCivil(y, m, d) * 1440 + h * 60 + mi
        let beijingMinutes = utcMinutes + 480
        let (by, bm, bd) = civilFromDays(beijingMinutes / 1440)
        let bh = (beijingMinutes % 1440) / 60
        let bmi = beijingMinutes % 60
        return "\(by)年\(bm)月\(bd)日 \(String(format: "%02d", bh)):\(String(format: "%02d", bmi)):\(String(format: "%02d", s))"
    }

    func testPropertySampledUTCHoursAcrossDays() {
        // 确定性笛卡尔积抽样：24 小时 × 3 分钟 × 3 秒 = 216 条
        for hour in 0...23 {
            for minute in [0, 30, 59] {
                for second in [0, 7, 59] {
                    let raw = String(format: "20260809T%02d%02d%02d.000Z", hour, minute, second)
                    let expected = referenceBeijing(year: 2026, month: 8, day: 9,
                                                    hour: hour, minute: minute, second: second)
                    XCTAssertEqual(
                        WarLogTimeFormatter.displayText(raw: raw), .beijing(expected),
                        "raw=\(raw)")
                }
            }
        }
    }

    func testPropertyMillisecondsDoNotAffectOutput() {
        for ms in ["0", "00", "000", "999"] {
            let raw = "20260809T110738.\(ms)Z"
            XCTAssertEqual(
                WarLogTimeFormatter.displayText(raw: raw), .beijing("2026年8月9日 19:07:38"),
                "毫秒 \(ms) 不应影响秒级输出")
        }
    }

    // MARK: - 输出格式

    func testOutputFormatShape() {
        guard case .beijing(let text) = WarLogTimeFormatter.displayText(raw: "20260809T110738.000Z") else {
            return XCTFail("应输出 beijing")
        }
        XCTAssertNotNil(text.range(of: #"^\d{4}年\d{1,2}月\d{1,2}日 \d{2}:\d{2}:\d{2}$"#, options: .regularExpression),
                         "输出格式不符: \(text)")
    }
}
