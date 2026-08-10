import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

/// 联赛/段位展示格式化（Issue #71 Task 3）：playerLeagueTierLabel 新逻辑 +
/// 现有 league 标签迁移到 LeagueTierCatalog 后的回归保护。
/// 注意：catalog 数据为官方最新简中术语（铜杯联赛3 等），
/// 旧手写字典的「青铜联赛 III / 传奇联赛 / 泰坦联赛 I」等映射已按官方
/// 静态数据修正（44000013=石头联赛2、85000006=银杯联赛1、105000028=飞龙联赛28）。
final class ClanDisplayFormatTests: XCTestCase {
    // MARK: - playerLeagueTierLabel（排位段位，2026 新增）

    func testPlayerLeagueTierLabelKnownIDs() {
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueTierLabel(PlayerLeague(id: 105000036, name: "Legend League", iconUrls: nil)),
            "传奇杯1"
        )
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueTierLabel(PlayerLeague(id: 105000034, name: "Legend League", iconUrls: nil)),
            "传奇杯3"
        )
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueTierLabel(PlayerLeague(id: 105000028, name: "Dragon League 28", iconUrls: nil)),
            "飞龙联赛28"
        )
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueTierLabel(PlayerLeague(id: 105000001, name: "Skeleton League 1", iconUrls: nil)),
            "骷髅兵联赛1"
        )
    }

    func testPlayerLeagueTierLabelNil() {
        XCTAssertNil(ClanDisplayFormat.playerLeagueTierLabel(nil))
        XCTAssertNil(
            ClanDisplayFormat.playerLeagueTierLabel(
                PlayerLeague(id: nil, name: nil, iconUrls: nil)
            )
        )
    }

    func testPlayerLeagueTierLabelUnknownIDPreservesOfficialName() {
        // 未知 ID 必须保留官方原始 name（可审计），不伪造中文（Issue #71）。
        // 注意：29000023 是"未知段位"样例（目录外）。若官方目录后续收录
        // 该 ID，本测试须同步改为断言中文名。
        let tier = PlayerLeague(id: 29000023, name: "Legend League III", iconUrls: nil)
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueTierLabel(tier),
            "待本地化（ID: 29000023, Legend League III）"
        )
        // name 缺失时仍显示 ID
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueTierLabel(PlayerLeague(id: 29000023, name: nil, iconUrls: nil)),
            "待本地化（ID: 29000023）"
        )
    }

    // MARK: - 迁移回归保护（catalog 数据与官方静态数据一致）

    func testPlayerLeagueLabelRegression() {
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 29000000, name: "Unranked", iconUrls: nil)),
            "未定级"
        )
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 29000001, name: "Bronze League III", iconUrls: nil)),
            "铜杯联赛3"
        )
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 29000010, name: "Crystal League III", iconUrls: nil)),
            "水晶杯联赛3"
        )
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 29000022, name: "Legend League", iconUrls: nil)),
            "传奇杯联赛"
        )
        XCTAssertNil(ClanDisplayFormat.playerLeagueLabel(nil))
    }

    func testBuilderBaseLeagueLabelRegression() {
        XCTAssertEqual(
            ClanDisplayFormat.builderBaseLeagueLabel(PlayerLeague(id: 44000000, name: "Wood League V", iconUrls: nil)),
            "木头联赛5"
        )
        XCTAssertEqual(
            ClanDisplayFormat.builderBaseLeagueLabel(PlayerLeague(id: 44000013, name: "Stone League II", iconUrls: nil)),
            "石头联赛2"
        )
        XCTAssertEqual(
            ClanDisplayFormat.builderBaseLeagueLabel(PlayerLeague(id: 44000041, name: "Diamond League", iconUrls: nil)),
            "钻石联赛"
        )
        XCTAssertNil(ClanDisplayFormat.builderBaseLeagueLabel(nil))
    }

    func testCapitalLeagueLabelRegression() {
        XCTAssertEqual(
            ClanDisplayFormat.capitalLeagueLabel(ClanLeague(id: 85000000, name: "Unranked")),
            "未排名"
        )
        XCTAssertEqual(
            ClanDisplayFormat.capitalLeagueLabel(ClanLeague(id: 85000006, name: "Silver League I")),
            "银杯联赛1"
        )
        XCTAssertEqual(
            ClanDisplayFormat.capitalLeagueLabel(ClanLeague(id: 85000022, name: "Legend League")),
            "传奇杯联赛"
        )
        XCTAssertNil(ClanDisplayFormat.capitalLeagueLabel(nil))
    }

    func testRequiredLeagueTierLabelRegression() {
        XCTAssertEqual(
            ClanDisplayFormat.requiredLeagueTierLabel(ClanLeagueTier(id: 105000028, name: "Dragon League 28")),
            "飞龙联赛28"
        )
        XCTAssertEqual(
            ClanDisplayFormat.requiredLeagueTierLabel(ClanLeagueTier(id: 105000034, name: "Legend League")),
            "传奇杯3"
        )
        XCTAssertNil(ClanDisplayFormat.requiredLeagueTierLabel(nil))
    }

    // MARK: - clanLevelLabel（Issue #95：部落等级语义，禁止显示为"X级大本营"）

    /// Issue #95 复现值：clanLevel=20 曾渲染为"20级大本营"。
    /// 修复后必须显示部落等级语义。0 是真实值（不视为缺失，同
    /// upgradeCostLabel 的 "0 不视为缺失" 原则）。
    func testClanLevelLabelFormats() {
        XCTAssertEqual(ClanDisplayFormat.clanLevelLabel(20), "部落等级 20")
        XCTAssertEqual(ClanDisplayFormat.clanLevelLabel(17), "部落等级 17")
        XCTAssertEqual(ClanDisplayFormat.clanLevelLabel(0), "部落等级 0")
    }

    /// 缺失（nil）→ nil：UI 不渲染虚假等级占位（验收标准第 3 条）。
    func testClanLevelLabelNil() {
        XCTAssertNil(ClanDisplayFormat.clanLevelLabel(nil))
    }

    /// Property-based：任意非 nil Int（含异常负值/极值），文案恒为
    /// 「部落等级 \(n)」，永不包含"大本营"字样（固定 seed SplitMix64，
    /// 可复现）。负值原样格式化：API 脏数据不钳制，保留可审计信号。
    func testClanLevelLabelPropertyNeverTownHall() {
        var rng = SplitMix64Generator(seed: 0x95_95)
        let extremeValues: [Int] = [Int.min, -1, 0, 1, Int.max]
        for level in extremeValues {
            XCTAssertEqual(ClanDisplayFormat.clanLevelLabel(level), "部落等级 \(level)")
        }
        for _ in 0..<500 {
            let level = Int.random(in: -5...100, using: &rng)
            let label = ClanDisplayFormat.clanLevelLabel(level)
            XCTAssertEqual(label, "部落等级 \(level)")
            XCTAssertFalse(label?.contains("大本营") ?? false)
        }
    }

    // MARK: - 未知 ID 降级文案（保留官方 name，可审计）

    func testUnknownIDFallbackText() {
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 99999999, name: "Mystery League", iconUrls: nil)),
            "未本地化联赛（ID: 99999999, Mystery League）"
        )
        XCTAssertEqual(
            ClanDisplayFormat.builderBaseLeagueLabel(PlayerLeague(id: 99999999, name: "Mystery League", iconUrls: nil)),
            "未本地化联赛（ID: 99999999, Mystery League）"
        )
        XCTAssertEqual(
            ClanDisplayFormat.capitalLeagueLabel(ClanLeague(id: 99999999, name: "Mystery League")),
            "未本地化联赛（ID: 99999999, Mystery League）"
        )
        XCTAssertEqual(
            ClanDisplayFormat.requiredLeagueTierLabel(ClanLeagueTier(id: 99999999, name: "Mystery League")),
            "未本地化联赛（ID: 99999999, Mystery League）"
        )
        // name 缺失时只显示 ID
        XCTAssertEqual(
            ClanDisplayFormat.playerLeagueLabel(PlayerLeague(id: 99999999, name: nil, iconUrls: nil)),
            "未本地化联赛（ID: 99999999）"
        )
    }

    // MARK: - typeLabel（Issue #101：open → 任何人都可加入）

    /// 已知三值穷举（P1）+ 未知值。官方 raw value 精确匹配。
    /// open 文案为 Issue #101 唯一改动点：任何人可加入。
    func testTypeLabelKnownValues() {
        XCTAssertEqual(ClanDisplayFormat.typeLabel("open"), "任何人都可加入")
        XCTAssertEqual(ClanDisplayFormat.typeLabel("inviteOnly"), "只有被批准才能加入")
        XCTAssertEqual(ClanDisplayFormat.typeLabel("closed"), "不可加入")
        XCTAssertEqual(ClanDisplayFormat.typeLabel("unknown_raw_value"), "未知")
        // P3：返回值永不等于输入 raw value（不泄漏英文）
        XCTAssertNotEqual(ClanDisplayFormat.typeLabel("open"), "open")
        XCTAssertNotEqual(ClanDisplayFormat.typeLabel("inviteOnly"), "inviteOnly")
        XCTAssertNotEqual(ClanDisplayFormat.typeLabel("closed"), "closed")
    }

    /// 类 raw 值（大小写变体、首尾空白、分隔符变体、空串）不得命中
    /// 精确匹配 → 全部「未知」（不做修剪/归一化，官方 raw 三值恒等匹配）。
    func testTypeLabelExactMatchNoNormalization() {
        let nearMisses = ["Open", "OPEN", " OPEN ", "open\n", "invite_only", "InviteOnly", "closed\n", "CLOSED", ""]
        for raw in nearMisses {
            XCTAssertEqual(ClanDisplayFormat.typeLabel(raw), "未知", "raw: \(raw.debugDescription)")
            XCTAssertNotEqual(ClanDisplayFormat.typeLabel(raw), raw)
        }
    }

    /// Property-based（固定 seed SplitMix64，可复现，同 clanLevelLabel 风格）：
    /// 任意 ASCII 字符串（大小写/数字/符号/空白/空串，长度 0-12）输出恒为
    /// 「未知」（P2）且不等于输入（P3，字母表纯 ASCII 不会生成 CJK「未知」）；
    /// 已知三值 + 生成值全部输出均属于四态集合（P4，联合输出域封闭）。
    func testTypeLabelPropertyUnknownForArbitraryASCIIStrings() {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.\n\t")
        let known = Set(["open", "inviteOnly", "closed"])
        let fourStates = Set(["任何人都可加入", "只有被批准才能加入", "不可加入", "未知"])
        // P4 联合输出域：已知三值也须属于四态集合（独立于 P1 穷举的契约断言）
        for raw in known {
            XCTAssertTrue(fourStates.contains(ClanDisplayFormat.typeLabel(raw)), "输出不在四态集合: \(raw)")
        }
        var rng = SplitMix64Generator(seed: 0x01_01)
        var asserted = 0
        for _ in 0..<600 {
            let count = Int.random(in: 0...12, using: &rng)
            let raw = String((0..<count).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
            if known.contains(raw) { continue } // 已知三值由穷举断言覆盖（P1），避免重复
            let label = ClanDisplayFormat.typeLabel(raw)
            XCTAssertEqual(label, "未知") // P2
            XCTAssertNotEqual(label, raw) // P3：不泄漏英文 raw
            XCTAssertTrue(fourStates.contains(label), "输出不在四态集合: \(label.debugDescription)") // P4
            asserted += 1
        }
        XCTAssertGreaterThanOrEqual(asserted, 500)
    }
}
