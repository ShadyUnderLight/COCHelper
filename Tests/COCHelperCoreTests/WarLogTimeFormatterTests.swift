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
                   "20260809T110738.000z", "abc", "20261309T110738.000Z", "20260809T246000.000Z",
                   "20260230T110738.000Z", "20230229T110738.000Z",
                   "20260809T111160.000Z", "20260809T110760.000Z"]
        for raw in bad {
            XCTAssertEqual(WarLogTimeFormatter.displayText(raw: raw), .unparsable(raw),
                           "raw=\(raw) 应降级为 unparsable 并保留原始值")
        }
    }

    /// 闰年 2 月 29 日是合法日期（2024 为闰年），必须成功转换。
    func testLeapDayValid() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20240229T110738.000Z"),
            .beijing("2024年2月29日 19:07:38"))
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

    // MARK: - 年份边界与世纪闰年（评审补测）

    /// year < 1992 拒绝（ICU 历史历法数据），1992 边界接受。
    func testYear1992Boundary() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "19911231T235959.000Z"),
            .unparsable("19911231T235959.000Z"))
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "19920101T000000.000Z"),
            .beijing("1992年1月1日 08:00:00"))
    }

    /// 世纪闰年：2000 可被 400 整除是闰年，2100 不是。
    func testCenturyLeapYears() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20000229T000000.000Z"),
            .beijing("2000年2月29日 08:00:00"))
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "21000229T000000.000Z"),
            .unparsable("21000229T000000.000Z"))
    }

    /// 极端年份 9999：ICU 正确处理 +8h 进位（输出 5 位年，理论不可达，锁定行为防回归）。
    func testYear9999Extreme() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "99991231T235959Z"),
            .beijing("10000年1月1日 07:59:59"))
    }

    /// 尾部空白与 4 位毫秒必须拒绝（正则严格锚定）。
    func testTrailingWhitespaceAndFourDigitMillisecondsRejected() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260809T110738.000Z "),
            .unparsable("20260809T110738.000Z "))
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260809T110738.0000Z"),
            .unparsable("20260809T110738.0000Z"))
    }

    // MARK: - remainingText（Issue #127，currentwar inWar 倒计时）

    func testRemainingTextPositive() {
        // 20260809T110738.000Z = 北京时间 19:07:38
        let end = "20260809T110738.000Z"
        let now = utcDate(2026, 8, 9, 3, 7, 38)   // UTC 03:07:38 → 剩余 8 小时
        XCTAssertEqual(WarLogTimeFormatter.remainingText(endRaw: end, now: now), "剩余 8 小时")
    }

    func testRemainingTextMultipleDays() {
        let end = "20260809T110738.000Z"
        let now = utcDate(2026, 8, 6, 11, 7, 38)  // 剩余 3 天
        XCTAssertEqual(WarLogTimeFormatter.remainingText(endRaw: end, now: now), "剩余 3 天 0 小时")
    }

    func testRemainingTextExpiredOrUnparsableIsNil() {
        let end = "20260809T110738.000Z"
        XCTAssertNil(WarLogTimeFormatter.remainingText(endRaw: end,
                                                       now: utcDate(2026, 8, 9, 12, 0, 0)))
        XCTAssertNil(WarLogTimeFormatter.remainingText(endRaw: nil, now: Date()))
        XCTAssertNil(WarLogTimeFormatter.remainingText(endRaw: "not-a-date", now: Date()))
    }

    func testRemainingTextBoundaries() {
        let end = "20260809T110738.000Z"
        // end 恰好等于 now：不算剩余 → nil
        XCTAssertNil(WarLogTimeFormatter.remainingText(endRaw: end,
                                                       now: utcDate(2026, 8, 9, 11, 7, 38)))
        // 不足 1 小时显示分钟粒度（Issue #127 F2 契约变更：不再伪造"剩余 0 小时"）
        XCTAssertEqual(WarLogTimeFormatter.remainingText(endRaw: end,
                                                         now: utcDate(2026, 8, 9, 10, 37, 38)),
                       "剩余 30 分钟")
        // 极端跨度（正则允许的最大区间）不溢出不崩溃
        XCTAssertNotNil(WarLogTimeFormatter.remainingText(
            endRaw: "99991231T235959Z", now: utcDate(1992, 1, 1, 0, 0, 0)))
    }

    /// 分钟粒度（Issue #127 F2）：不足 1 小时显示分钟；不足 1 分钟显示"剩余不足 1 分钟"。
    func testRemainingTextMinuteGranularity() {
        let end = "20260809T110738.000Z"
        // 剩 30 分钟
        XCTAssertEqual(WarLogTimeFormatter.remainingText(endRaw: end,
                                                         now: utcDate(2026, 8, 9, 10, 37, 38)),
                       "剩余 30 分钟")
        // 剩 59 秒（floor 到不足 1 分钟）
        XCTAssertEqual(WarLogTimeFormatter.remainingText(endRaw: end,
                                                         now: utcDate(2026, 8, 9, 11, 6, 39)),
                       "剩余不足 1 分钟")
        // 剩 1 分钟整
        XCTAssertEqual(WarLogTimeFormatter.remainingText(endRaw: end,
                                                         now: utcDate(2026, 8, 9, 11, 6, 38)),
                       "剩余 1 分钟")
        // 小数秒：剩 59m30s → floor 到 59 分钟（锁定 floor 语义，防 ceil 逃逸）
        let nowHalf = utcDate(2026, 8, 9, 10, 7, 38).addingTimeInterval(0.5)  // 10:07:38.5 → 距 end 3599.5s
        XCTAssertEqual(WarLogTimeFormatter.remainingText(endRaw: end, now: nowHalf),
                       "剩余 59 分钟")
    }

    /// 测试辅助：UTC 固定日期（避免 DateComponents 时区漂移）。
    /// 必须显式钉住 UTC：Calendar(identifier:) 默认跟随本机时区（实测 Asia/Shanghai），
    /// 否则组件会被按本地时区解释，断言值只在 UTC 下成立。
    private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: c)!
    }
}
