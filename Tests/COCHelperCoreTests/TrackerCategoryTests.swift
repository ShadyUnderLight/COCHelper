import XCTest
@testable import COCHelperCore

final class TrackerCategoryTests: XCTestCase {
    // MARK: - 官方术语（Issue #75 工作流 A）

    /// TH18 新防御系统官方简体中文为"守卫"（官方 18 本更新说明），
    /// 分类标题不得使用旧译"守护者"。
    func testGuardiansTitleUsesOfficialTerminology() {
        XCTAssertEqual(TrackerCategory.guardians.title, "守卫")
    }

    // MARK: - 契约锁定（缓存兼容）

    /// 快照 section 名与 rawValue 是旧缓存持久化格式，禁止为改标题而误动。
    func testGuardiansRawValueAndSectionContract() {
        XCTAssertEqual(TrackerCategory.guardians.rawValue, "guardians")
        XCTAssertEqual(TrackerCategory.from(section: "guardians"), .guardians)
    }

    // MARK: - Property-based（固定种子可复现）

    func testTitleInvariantsHoldForRandomSamples() {
        var rng = SeededRNG(seed: 0x75)
        var sampledTitles = Set<String>()
        for _ in 0..<2000 {
            let category = TrackerCategory.allCases[Int(rng.next() % UInt64(TrackerCategory.allCases.count))]
            let title = category.title
            // 不变量 (a)：所有 title 非空
            XCTAssertFalse(title.isEmpty, "\(category.rawValue) 的 title 不得为空")
            // 不变量 (b)：title 不泄漏 rawValue（现有 title 均为中文，rawValue 均为英文）
            XCTAssertNotEqual(title, category.rawValue, "\(category.rawValue) 的 title 不得直接回显 rawValue")
            sampledTitles.insert(title)
        }
        // 固定种子下采样覆盖全部分类（先验证再写，见 Issue #75 工作流 A 自查）
        XCTAssertEqual(sampledTitles.count, TrackerCategory.allCases.count)
    }

    // MARK: - 标题去重

    func testTitlesAreUnique() {
        XCTAssertEqual(
            Set(TrackerCategory.allCases.map(\.title)).count,
            TrackerCategory.allCases.count
        )
    }
}
