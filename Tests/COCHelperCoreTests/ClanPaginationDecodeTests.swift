import Foundation
import XCTest
@testable import COCHelperCore

/// 读取 warlog / capital 分页 fixture。
func fullWarLogPageData() -> Data {
    let url = Bundle.module.url(forResource: "official_war_log_page", withExtension: "json")!
    return try! Data(contentsOf: url)
}

func fullCapitalRaidPageData() -> Data {
    let url = Bundle.module.url(forResource: "official_capital_raid_page", withExtension: "json")!
    return try! Data(contentsOf: url)
}

final class ClanPaginationDecodeTests: XCTestCase {
    // MARK: - warlog 页

    func testDecodeWarLogPage() throws {
        let page = try JSONDecoder().decode(
            OfficialPaginatedPage<OfficialWarLogEntry>.self,
            from: fullWarLogPageData()
        )

        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].result, "win")
        XCTAssertEqual(page.items[0].endTime, "20260730T100000.000Z")
        XCTAssertEqual(page.items[0].teamSize, 30)
        XCTAssertEqual(page.items[0].clan?.stars, 95)
        XCTAssertEqual(page.items[0].clan?.destructionPercentage, 100.0)
        XCTAssertEqual(page.items[0].opponent?.name, "anonymized-opponent")
        XCTAssertEqual(page.items[1].result, "lose")
        XCTAssertEqual(page.before, "CURSORBEFORE1")
        XCTAssertEqual(page.after, "CURSORAFTER1")
    }

    /// 末页无游标：before/after 为 nil。
    func testDecodeWarLogLastPageWithoutCursors() throws {
        let page = try JSONDecoder().decode(
            OfficialPaginatedPage<OfficialWarLogEntry>.self,
            from: Data(#"{"items":[]}"#.utf8)
        )
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.before)
        XCTAssertNil(page.after)
    }

    /// 空对象容忍：items 缺省为 []（传输层损坏容错）。
    func testDecodeEmptyPageObject() throws {
        let page = try JSONDecoder().decode(
            OfficialPaginatedPage<OfficialWarLogEntry>.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.after)
    }

    // MARK: - capital raid 页

    func testDecodeCapitalRaidPage() throws {
        let page = try JSONDecoder().decode(
            OfficialPaginatedPage<OfficialCapitalRaidSeason>.self,
            from: fullCapitalRaidPageData()
        )

        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].state, "ended")
        XCTAssertEqual(page.items[0].startTime, "20260701T080000.000Z")
        XCTAssertEqual(page.items[0].totalLooted, 123456)
        XCTAssertEqual(page.items[0].offensiveReward, 5000)
        XCTAssertEqual(page.items[0].defensiveReward, 2500)
        XCTAssertEqual(page.items[0].clan?.attackCount, 60)
        XCTAssertEqual(page.items[0].clan?.destroyedDistricts, 120)
        XCTAssertEqual(page.before, "RAIDCURSORBEFORE1")
        XCTAssertEqual(page.after, "RAIDCURSORAFTER1")
    }

    /// attackLog/defenseLog（成员攻击明细）deferred：嵌套容忍，不解码失败。
    func testDecodeToleratesAttackLogArrays() throws {
        let page = try JSONDecoder().decode(
            OfficialPaginatedPage<OfficialCapitalRaidSeason>.self,
            from: fullCapitalRaidPageData()
        )
        XCTAssertEqual(page.items[0].totalLooted, 123456, "attackLog 存在时摘要仍正确")
    }

    // MARK: - Round-trip

    func testRoundTripWarLogPage() throws {
        let original = try JSONDecoder().decode(
            OfficialPaginatedPage<OfficialWarLogEntry>.self,
            from: fullWarLogPageData()
        )
        let decoded = try JSONDecoder().decode(
            OfficialPaginatedPage<OfficialWarLogEntry>.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripCapitalRaidPage() throws {
        let original = try JSONDecoder().decode(
            OfficialPaginatedPage<OfficialCapitalRaidSeason>.self,
            from: fullCapitalRaidPageData()
        )
        let decoded = try JSONDecoder().decode(
            OfficialPaginatedPage<OfficialCapitalRaidSeason>.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }
}
