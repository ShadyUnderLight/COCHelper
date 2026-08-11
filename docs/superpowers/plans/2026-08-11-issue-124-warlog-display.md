# Issue #124 战争日志展示层实现计划（首屏 10 条 + 查看更多 + 北京时间）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 战争日志卡片默认只显示最近 10 条、每次"查看更多"+10（本地缓存优先、游标耗尽才请求网络）、官方 UTC endTime 稳定转换为北京时间展示，且不改变任何数据模型/缓存/parser version 语义。

**Architecture:** 展示层纯函数投影（COCHelperCore：`WarLogDisplayProjection` 可见条数/按钮状态、`WarLogTimeFormatter` 时间格式化）+ SwiftUI 视图薄集成（`WarLogCardView` 持有 `@State visibleCount` 预算）。所有可测逻辑进 Core，UI 只做渲染与生命周期重置。不做网络 limit 改动（UI prefix 已是最终上限保护，见 SDD 决策 D4）。

**Tech Stack:** Swift 6.0 / SwiftPM / XCTest（手写 property-based 风格测试，零第三方依赖）/ SwiftUI (macOS 14+)。

---

## SDD：设计分析（3 候选投票）

### D1. 时间解析实现方式（3 候选投票 → 选 A）

| 候选 | 方案 | 优点 | 缺点 |
|---|---|---|---|
| **A（选中）** | 正则校验 `^\d{8}T\d{6}(\.\d{1,3})?Z$` + 手动提取组件 + `Calendar`(UTC→Asia/Shanghai) | 无 locale/format 脆弱性；毫秒长度 0/1/2/3 位天然兼容；确定性最强，property 测试友好；无 DateFormatter 的 "SSS 解析 2 位毫秒" 陷阱 | 需手写 15 行解析 |
| B | `DateFormatter`(en_US_POSIX, UTC) 双格式解析 | 代码少 | "yyyyMMdd'T'HHmmss.SSS'Z'" 非严格解析不可靠（yyyy 部分匹配、SSS 长度敏感），跨 locale 脆弱 |
| C | `ISO8601DateFormatter` | 标准 | 官方格式无连字符/冒号，非 RFC3339，解析必然失败；不可行 |

### D2. 按钮状态建模（3 候选投票 → 选 A）

| 候选 | 方案 | 评价 |
|---|---|---|
| **A（选中）** | `enum MoreState { none, localHidden, serverMore }`，投影层纯函数判定 | 单值类型杜绝非法组合（如"本地有隐藏且无更多"）；可测；UI 只 switch |
| B | 两个 Bool `hasLocalHidden`/`hasServerMore` | 存在 4 种组合含无意义态；判定逻辑泄漏到 View |
| C | View 内 `if visibleCount < items.count` 直接写 | 两个分页概念混在 SwiftUI 条件里（issue 明确反对） |

优先级：`visibleCount < totalEntries → .localHidden`（本地优先，点击不发请求）；否则 `hasServerMore → .serverMore`；否则 `.none`。

### D3. visibleCount 生命周期（3 候选投票 → 选 A）

| 候选 | 方案 | 评价 |
|---|---|---|
| **A（选中）** | `@State` + `.onChange(of: clanTag)` 重置 + 刷新按钮 action 显式重置 | 显式、可控、可读；刷新重置满足验收"刷新首屏后回到 10" |
| B | `.id(clanTag)` 重建 | 隐式重置但重建整个卡片（含成员折叠状态），刷新按钮无法单独重置 |
| C | 存入 AppModel | 把 UI 状态写进 Model，跨部落泄漏风险；与 issue"不写 UserDefaults/不污染其他部落"精神相悖 |

### D4. 网络 limit:10（决策：不做）

issue"建议实现顺序 #3"为可选建议，非验收标准。理由：① UI `prefix(visibleCount)` 已是最终上限保护（issue 原文承认）；② 改动会修改 AppModel 两处 fetch 闭包 + 现有 `testRefreshWarLogFirstPage` 的 `"(no-query)"` 断言（契约变更，扩大回归面）；③ PR 聚焦展示层（issue 标题 [UI]）。记录在计划，如需后续统一页大小另开任务。

### D5. 官方顺序依赖（前置确认点）

官方 warlog 文档需登录认证，本地无法确认"最近在前"。**遵循 issue 目标 1 的显式指示**：按官方返回顺序 prefix 展示、不排序，并在投影层代码注释标明依赖。真实 API 顺序检查列入最终验收清单（如发现非最新在前，需另立投影层排序任务，不在本 PR 静默猜测）。

### 类型契约（定稿）

```swift
// COCHelperCore
public enum WarLogDisplayProjection {
    public static let defaultVisibleCount: Int = 10
    public static let increment: Int = 10

    public enum MoreState: Equatable, Sendable {
        case none          // 无更多：隐藏按钮
        case localHidden   // 本地缓存还有未展示条目：点击纯本地展开，不发请求
        case serverMore    // 本地已展示完且有 after 游标：点击发请求
    }

    /// 最终上限保护：prefix 截取，负值钳制为 0（Array.prefix 负长度会 fatal）。
    public static func visibleEntries<T>(_ entries: [T], visibleCount: Int) -> [T]

    /// 按钮状态纯函数：localHidden 优先于 serverMore。
    public static func moreState(totalEntries: Int, visibleCount: Int, hasServerMore: Bool) -> MoreState
}

public enum WarLogTimeDisplay: Equatable, Sendable {
    case hidden                          // endTime 缺失：不渲染时间行
    case beijing(String)                 // "2026年8月9日 19:07:38"
    case unparsable(String)              // 非法格式：保留原始值，UI 标"官方原始时间"
}

public enum WarLogTimeFormatter {
    /// 官方串（如 "20260809T110738.000Z"）→ 展示三态；nil → .hidden。
    public static func displayText(raw: String?) -> WarLogTimeDisplay
}
```

实现约束：`TimeZone(identifier: "Asia/Shanghai")`（nil 时 fallback 固定 GMT+8）；**绝不使用 `TimeZone.current`**；解析时 Z 视为 UTC；`Calendar(identifier: .gregorian)`。

---

## 任务分解与文件结构

| Task | 文件 | 内容 |
|---|---|---|
| 1 | `Sources/COCHelperCore/WarLogDisplayProjection.swift`（新建）<br>`Tests/COCHelperCoreTests/WarLogDisplayProjectionTests.swift`（新建） | 可见条数投影 + 按钮状态（TDD） |
| 2 | `Sources/COCHelperCore/WarLogTimeFormatter.swift`（新建）<br>`Tests/COCHelperCoreTests/WarLogTimeFormatterTests.swift`（新建） | UTC→北京时间格式化 + 降级（TDD + property-based） |
| 3 | `Sources/COCHelper/WarLogCardView.swift`（修改） | visibleCount @State + 按钮分派 + 时间行替换 + 生命周期重置 |
| 4 | — | 全量验证：swift test / release build / git diff --check |

每任务独立 commit。不做：CapitalRaidCardView、ClanWarCardView、endTime 模型、parser version、PaginationMerge、UserDefaults。

---

### Task 1: WarLogDisplayProjection（Core 投影层）

**Files:**
- Create: `Sources/COCHelperCore/WarLogDisplayProjection.swift`
- Test: `Tests/COCHelperCoreTests/WarLogDisplayProjectionTests.swift`

- [ ] **Step 1: 写失败测试**（`WarLogDisplayProjectionTests.swift`）

```swift
import XCTest
@testable import COCHelperCore

final class WarLogDisplayProjectionTests: XCTestCase {
    // MARK: - 常量

    func testConstants() {
        XCTAssertEqual(WarLogDisplayProjection.defaultVisibleCount, 10)
        XCTAssertEqual(WarLogDisplayProjection.increment, 10)
    }

    // MARK: - visibleEntries：prefix 语义 + 顺序保持 + 负值钳制

    func testVisibleEntriesPrefixAndOrderPreserved() {
        let items = Array(0..<30)
        for visibleCount in 0...40 {
            let visible = WarLogDisplayProjection.visibleEntries(items, visibleCount: visibleCount)
            XCTAssertEqual(visible, Array(0..<min(max(0, visibleCount), 30)),
                           "visibleCount=\(visibleCount) 应为前 min(vc,30) 条且保持顺序")
        }
    }

    func testVisibleEntriesClampsNegativeToEmpty() {
        XCTAssertEqual(WarLogDisplayProjection.visibleEntries([1, 2, 3], visibleCount: -5), [])
        XCTAssertEqual(WarLogDisplayProjection.visibleEntries([1, 2, 3], visibleCount: 0), [])
    }

    func testVisibleEntriesEmptyInput() {
        XCTAssertEqual(WarLogDisplayProjection.visibleEntries([String](), visibleCount: 10), [])
    }

    func testVisibleEntriesLessThanDefaultShowsAll() {
        let items = [1, 2]
        XCTAssertEqual(WarLogDisplayProjection.visibleEntries(items, visibleCount: 10), [1, 2])
    }

    // MARK: - moreState：全组合枚举 + 优先级

    func testMoreStateAllCombinations() {
        for total in 0...5 {
            for visible in 0...8 {
                for server in [false, true] {
                    let state = WarLogDisplayProjection.moreState(
                        totalEntries: total, visibleCount: visible, hasServerMore: server)
                    let expected: WarLogDisplayProjection.MoreState =
                        visible < total ? .localHidden
                        : (server ? .serverMore : .none)
                    XCTAssertEqual(state, expected,
                                   "total=\(total) visible=\(visible) server=\(server)")
                }
            }
        }
    }

    func testMoreStateLocalHiddenTakesPriorityOverServerMore() {
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 15, visibleCount: 10, hasServerMore: true),
            .localHidden)
    }

    func testMoreStateBoundaryExactlyAtTotal() {
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 10, visibleCount: 10, hasServerMore: false),
            .none)
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 10, visibleCount: 10, hasServerMore: true),
            .serverMore)
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 10, visibleCount: 9, hasServerMore: true),
            .localHidden)
    }

    func testMoreStateExhaustedLocallyButServerHasMore() {
        XCTAssertEqual(
            WarLogDisplayProjection.moreState(totalEntries: 10, visibleCount: 10, hasServerMore: true),
            .serverMore)
    }
}
```

- [ ] **Step 2: 运行确认 RED**

Run: `swift test --filter WarLogDisplayProjectionTests`
Expected: FAIL（`WarLogDisplayProjection` 不存在 → compile error）

- [ ] **Step 3: 最小实现**（`WarLogDisplayProjection.swift`）

```swift
import Foundation

/// 战争日志卡片展示投影（Issue #124）：集中定义可见条数、按钮状态，
/// 避免把"本地隐藏条目"与"服务端游标"两个分页概念混在 SwiftUI 条件里。
///
/// 顺序语义：保持官方 warlog 返回顺序，只做 prefix 截取，不排序。
/// （官方接口当前按最近在前返回；如确认官方不保证该顺序，须在此层
/// 另行定义可验证的排序规则，不得静默猜测。）
public enum WarLogDisplayProjection {
    /// 首屏默认可见条数。
    public static let defaultVisibleCount: Int = 10
    /// "查看更多"每次增加的条数。
    public static let increment: Int = 10

    /// "查看更多"按钮状态。
    public enum MoreState: Equatable, Sendable {
        /// 无更多：隐藏按钮（本地已展示完且无服务端游标）。
        case none
        /// 本地缓存还有未展示条目：点击纯本地展开（不发请求）。
        case localHidden
        /// 本地已展示完且服务端还有游标：点击请求下一页。
        case serverMore
    }

    /// 展示投影：`prefix(visibleCount)` 最终上限保护。
    /// 负数钳制为 0（`Array.prefix` 负长度触发 fatal error）。
    public static func visibleEntries<T>(_ entries: [T], visibleCount: Int) -> [T] {
        Array(entries.prefix(max(0, visibleCount)))
    }

    /// 按钮状态判定：本地隐藏优先于服务端更多（本地未展示完时不发请求）。
    public static func moreState(
        totalEntries: Int, visibleCount: Int, hasServerMore: Bool
    ) -> MoreState {
        if visibleCount < totalEntries { return .localHidden }
        if hasServerMore { return .serverMore }
        return .none
    }
}
```

- [ ] **Step 4: 运行确认 GREEN**

Run: `swift test --filter WarLogDisplayProjectionTests`
Expected: PASS（9 tests）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/WarLogDisplayProjection.swift Tests/COCHelperCoreTests/WarLogDisplayProjectionTests.swift
git commit -m "feat(core): war log display projection (Issue #124) — visible count & more-state"
```

---

### Task 2: WarLogTimeFormatter（Core 时间格式化）

**Files:**
- Create: `Sources/COCHelperCore/WarLogTimeFormatter.swift`
- Test: `Tests/COCHelperCoreTests/WarLogTimeFormatterTests.swift`

- [ ] **Step 1: 写失败测试**（含 property-based 抽样 + 时区独立性）

```swift
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
            .beijing("2026年8月10日 0:00:00"))
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260809T155959.000Z"),
            .beijing("2026年8月9日 23:59:59"))
    }

    func testCrossMonthBoundary() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20260731T160000.000Z"),
            .beijing("2026年8月1日 0:00:00"))
    }

    func testCrossYearBoundary() {
        XCTAssertEqual(
            WarLogTimeFormatter.displayText(raw: "20251231T160000.000Z"),
            .beijing("2026年1月1日 0:00:00"))
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
```

- [ ] **Step 2: 运行确认 RED**

Run: `swift test --filter WarLogTimeFormatterTests`
Expected: FAIL（类型不存在 → compile error）

- [ ] **Step 3: 最小实现**（`WarLogTimeFormatter.swift`）

```swift
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
/// 实现选择：正则校验 + 手动组件解析（D1 候选 A），无 DateFormatter locale 脆弱性。
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
    private static let officialPattern = #"^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(\.\d{1,3})?Z$"#

    public static func displayText(raw: String?) -> WarLogTimeDisplay {
        guard let raw, !raw.isEmpty else { return .hidden }
        guard let text = beijingTimeText(raw: raw) else { return .unparsable(raw) }
        return .beijing(text)
    }

    /// 转换成功返回"yyyy年M月d日 HH:mm:ss"（北京时间）；失败返回 nil。
    public static func beijingTimeText(raw: String) -> String? {
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
```

注意：`int(_:Range)` 的写法 —— `timePart` 含毫秒和 Z（如 `110738.000Z`），`chars[0..<6]` 只取前 6 位，OK。`datePart` 是 8 位数字，OK。

- [ ] **Step 4: 运行确认 GREEN**

Run: `swift test --filter WarLogTimeFormatterTests`
Expected: PASS（13 tests）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/WarLogTimeFormatter.swift Tests/COCHelperCoreTests/WarLogTimeFormatterTests.swift
git commit -m "feat(core): war log endTime → Beijing time formatter (Issue #124)"
```

---

### Task 3: WarLogCardView UI 集成

**Files:**
- Modify: `Sources/COCHelper/WarLogCardView.swift`

UI 无测试基座（无 ViewInspector 依赖），此任务以编译 + 行为评审 + 人工验收清单为验证手段（项目惯例）。

- [ ] **Step 1: 修改点 1 — 添加 @State 与生命周期重置**

在 `struct WarLogCardView: View` 内添加：

```swift
    /// 已授权展示的条数预算（Issue #124）：首屏 10，点"查看更多"+10。
    /// 预算语义：点击 serverMore 时预算先 +10 再发起请求，请求返回后
    /// prefix(预算) 自动展示新条目；失败时预算空位无影响（仍显示旧数据）。
    @State private var visibleCount = WarLogDisplayProjection.defaultVisibleCount
```

在 `body` 的 `Panel` 上挂生命周期重置（clanTag 变化 → 重置；两个入口共用一个卡片结构）：

```swift
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                header
                statusContent
            }
        }
        .onChange(of: clanTag) {
            visibleCount = WarLogDisplayProjection.defaultVisibleCount
        }
```

- [ ] **Step 2: 修改点 2 — 列表 prefix 渲染**

`warLogList` 中：

```swift
            } else {
                ForEach(
                    Array(WarLogDisplayProjection.visibleEntries(page.items, visibleCount: visibleCount).enumerated()),
                    id: \.offset
                ) { _, entry in
                    warLogRow(entry)
                    if entry.endTime != page.items.last?.endTime {
                        Divider().padding(.leading, 40)
                    }
                }
            }
```

（Divider 判定保持对全列表 last 比较，行为与现状一致。）

- [ ] **Step 3: 修改点 3 — 按钮区状态分派**

替换 `statusContent` 中：

```swift
                if hasMore {
                        loadMoreButton("加载更多部落对战", tag: clanTag)
                }
```

为：

```swift
                switch WarLogDisplayProjection.moreState(
                    totalEntries: page.items.count,
                    visibleCount: visibleCount,
                    hasServerMore: hasMore
                ) {
                case .localHidden:
                    loadMoreButton("查看更多（再显示 \(WarLogDisplayProjection.increment) 条）", tag: clanTag) {
                        visibleCount += WarLogDisplayProjection.increment
                    }
                case .serverMore:
                    loadMoreButton("查看更多", tag: clanTag) {
                        visibleCount += WarLogDisplayProjection.increment
                        model.loadMoreWarLog(tag: clanTag)
                    }
                case .none:
                    EmptyView()
                }
```

同时把 `loadMoreButton` 改造为闭包注入 action（当前硬编码调 `model.loadMoreWarLog`）：

```swift
    private func loadMoreButton(_ title: String, tag: String, action: @escaping () -> Void) -> some View {
        HStack {
            Button(action: action) {
                if model.isRefreshingWarLog(clanTag: clanTag) {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: "ellipsis.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshingWarLogData || model.isRefreshingWarLog(clanTag: clanTag))
            Spacer()
        }
    }
```

- [ ] **Step 4: 修改点 4 — 刷新时重置 visibleCount**

`refreshButton` 的 Button action 中（两处 `model.refreshWarLog` 调用前）重置：

```swift
            Button {
                visibleCount = WarLogDisplayProjection.defaultVisibleCount
                if force {
                    model.refreshWarLog(tag: tag, force: true)
                } else {
                    model.refreshWarLog(tag: tag)
                }
            } label: {
```

- [ ] **Step 5: 修改点 5 — 时间行替换**

`warLogSummary` 中替换：

```swift
                if let endTime = entry.endTime {
                    Text("结束：\(endTime)（官方时间）")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
```

为：

```swift
                switch WarLogTimeFormatter.displayText(raw: entry.endTime) {
                case .hidden:
                    EmptyView()
                case .beijing(let text):
                    Text("结束：\(text)（北京时间）")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                case .unparsable(let raw):
                    Text("结束：\(raw)（官方原始时间）")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
```

- [ ] **Step 6: 编译验证**

Run: `swift build`
Expected: BUILD SUCCESSFUL（无警告）

- [ ] **Step 7: Commit**

```bash
git add Sources/COCHelper/WarLogCardView.swift
git commit -m "feat(ui): war log card shows 10 by default, +10 per load, Beijing time (Issue #124)"
```

---

### Task 4: 全量验证与验收清单

- [ ] **Step 1: 全量测试**

Run: `swift test`
Expected: 全部通过（原有 1029 + 新增 22 = 1051 左右）

- [ ] **Step 2: Release 构建**

Run: `swift build -c release`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: diff 检查**

Run: `git diff --check`
Expected: 无输出

- [ ] **Step 4: 人工窗口验收清单**（记录于 PR body，需真机/本地窗口执行）

- [ ] 有 10+ 条记录时首屏只显示 10 条
- [ ] 少于 10 条时不补空行、不显示"查看更多"
- [ ] 点"查看更多"每次最多 +10；本地有缓存时（看 Network/日志）不发请求
- [ ] 缓存耗尽且有 after 时点按钮才发请求
- [ ] 末页后按钮消失
- [ ] 切换村庄/刷新后回到 10 条，部落间不共享展开状态
- [ ] 时间显示"2026年8月9日 19:07:38（北京时间）"
- [ ] **官方顺序检查：** 首屏 10 条确为最近 10 场（如官方非最近在前，需另立排序任务）
- [ ] 失败/不公开状态不被遮蔽，成员明细展开行为不变

- [ ] **Step 5: 无未提交改动**

Run: `git status`
Expected: working tree clean

---

## Reflexion（实现后自查清单）

- [ ] 类型契约与计划一致（WarLogDisplayProjection / WarLogTimeDisplay / WarLogTimeFormatter）
- [ ] 每个 Core 函数先有失败测试（TDD 已执行）
- [ ] 未修改：endTime 模型、parser version、PaginationMerge、ClanWarCardView、CapitalRaidCardView
- [ ] 未引入 TimeZone.current；未写 UserDefaults；未加第三方依赖
- [ ] 按钮状态：localHidden 不发请求（代码评审重点）
- [ ] visibleCount 负数防护（prefix 钳制）
- [ ] 现有测试断言未被改动（未做 limit:10 → `"(no-query)"` 断言保持）
- [ ] `swift test` / `swift build -c release` / `git diff --check` 全绿

## 非目标（不做）

- CapitalRaidCardView / ClanWarCardView 的时间展示与"查看更多"（issue 明确非目标）
- 网络 limit:10（D4 决策：推迟）
- 无限滚动、用户自定义条数、UserDefaults 持久化展开状态
- endTime 存储语义、缓存结构、parser version、last-good、失败降级、公开性判断、成员明细
