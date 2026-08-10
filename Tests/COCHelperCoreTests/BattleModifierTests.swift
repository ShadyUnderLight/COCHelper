import Foundation
import XCTest
@testable import COCHelperCore

/// battleModifier 的格式化映射 + 编解码契约（Issue #72）。
/// - 映射表与 fuzz 均为确定性（fixed seed）测试，复用共享 `LCG`
///   （见 ClanAPIStateTests.swift，同 target 可见）。
/// - currentwar 分支（fixture/未知/null/round-trip）在 ClanWarDecodeTests 覆盖，
///   这里补充 fuzz 与 warlog 条目分支。
final class BattleModifierTests: XCTestCase {
    // MARK: - 稳定中文映射表

    /// 官方已知值域 → 稳定中文映射（表格驱动全分支）。
    /// 官方简中术语（Issue #99）：hardMode→锦标赛模式（官方已改名）、
    /// minusOne/Two/Three→传奇杯1/2/3（与 league_tier_catalog 的官方静态数据一致）。
    func testLocalizedTextKnownValues() {
        XCTAssertEqual(BattleModifierText.localizedText(for: "hardMode"), "锦标赛模式")
        XCTAssertEqual(BattleModifierText.localizedText(for: "minusOne"), "传奇杯1")
        XCTAssertEqual(BattleModifierText.localizedText(for: "minusTwo"), "传奇杯2")
        XCTAssertEqual(BattleModifierText.localizedText(for: "minusThree"), "传奇杯3")
    }

    /// nil、"none" 与空串/纯空白（均无规则信息）→ nil：UI 不渲染占位。
    func testLocalizedTextEmptyNoneAndNilAreHidden() {
        XCTAssertNil(BattleModifierText.localizedText(for: nil))
        XCTAssertNil(BattleModifierText.localizedText(for: "none"))
        XCTAssertNil(BattleModifierText.localizedText(for: ""), "空串携带零信息，归 nil 无损失")
        XCTAssertNil(BattleModifierText.localizedText(for: " "), "纯空白串归 nil，避免空「规则：」行")
        XCTAssertNil(BattleModifierText.localizedText(for: "\n\t "))
    }

    /// 未知非空值 → 原样返回（可审计 fallback，不做猜测映射）。
    func testLocalizedTextUnknownRawFallback() {
        XCTAssertEqual(BattleModifierText.localizedText(for: "futureX"), "futureX")
    }

    /// Property-based fuzz：localizedText 显示层不变式（确定性 fixed seed）。
    /// 断言四类契约：
    /// - 已知 key → 官方简中术语（防文案回退到旧术语）
    /// - 未知非空（无首尾空白）→ 恒等回退（可审计 fallback）
    /// - nil / "none" / 空白变体 → nil（UI 隐藏）
    /// - 输出卫生：非 nil 输出必为非空白串
    /// 注：带首尾空白的未知值回退为 trim 后原样（Issue #100 语义），
    /// 不属于本 fuzz 的恒等断言域，由 testLocalizedTextUnknownTrimmedFallback
    /// 与 testLocalizedTextPropertyRandomWhitespace 覆盖。
    func testLocalizedTextPropertiesFuzz() {
        let knownKeys = ["hardMode", "minusOne", "minusTwo", "minusThree"]
        let knownTerms = ["锦标赛模式", "传奇杯1", "传奇杯2", "传奇杯3"]
        let unknownPool = ["futureX", "tournament", "unknownRule", "MINUS_ONE", "hardmode"]
        let whitespacePool = ["", " ", "\t", "\n", " \n\t ", "\r\n"]
        var r = LCG(seed: 0x5EED_0B5E_0000_0000) // "seed"（与 #72 的 battle seed 区分）
        for _ in 0..<500 {
            switch Int(r.next() % 5) {
            case 0: // 已知 key → 官方术语
                let idx = Int(r.next() % UInt64(knownKeys.count))
                XCTAssertEqual(
                    BattleModifierText.localizedText(for: knownKeys[idx]), knownTerms[idx],
                    "已知 key \(knownKeys[idx]) 必须映射官方简中术语"
                )
                XCTAssertFalse(
                    knownTerms[idx].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "已知术语不得为空白"
                )
            case 1: // 未知非空 → 恒等回退
                let v = r.pick(unknownPool)
                XCTAssertEqual(BattleModifierText.localizedText(for: v), v, "未知非空必须恒等回退")
            case 2: // 随机可见 ASCII 串（排除全空白 / "none" / 已知 key / 首尾空白：
                    // 全空白归 nil 属隐藏规则；"none" 与已知 key 同理；带首尾空白的
                    // 未知串在 #100 语义下回退为 trim 后原样，不在恒等断言域）
                let len = 1 + Int(r.next() % 30)
                var s = ""
                for _ in 0..<len {
                    s.append(Character(UnicodeScalar(0x20 + Int(r.next() % 0x5F))!))
                }
                if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || s == "none" || knownKeys.contains(s)
                    || s != s.trimmingCharacters(in: .whitespacesAndNewlines) {
                    continue
                }
                XCTAssertEqual(BattleModifierText.localizedText(for: s), s, "未知串必须恒等回退")
            case 3: // nil / "none" → nil
                XCTAssertNil(BattleModifierText.localizedText(for: nil))
                XCTAssertNil(BattleModifierText.localizedText(for: "none"))
            default: // 空白变体 → nil（输出卫生的空白端）
                XCTAssertNil(BattleModifierText.localizedText(for: r.pick(whitespacePool)))
            }
        }
    }

    // MARK: - 空白规范化（Issue #100）

    /// 带首尾空白/换行的已知 key 必须与无空白输入得到同一显示
    /// （修复前 guard 用 trim、switch 用 raw 的不一致；" hardMode " 会走
    /// default 原样返回）。
    func testLocalizedTextTrimsWhitespaceAroundKnownValues() {
        XCTAssertEqual(BattleModifierText.localizedText(for: " hardMode "), "锦标赛模式")
        XCTAssertEqual(BattleModifierText.localizedText(for: "\nminusOne\t"), "传奇杯1")
        XCTAssertEqual(BattleModifierText.localizedText(for: " minusTwo\t"), "传奇杯2")
        XCTAssertEqual(BattleModifierText.localizedText(for: "\tminusThree\n"), "传奇杯3")
        XCTAssertNil(BattleModifierText.localizedText(for: " none "), "带空白的 none 必须与 none 同样隐藏")
    }

    /// 未知非空值带空白时：回退返回 trim 后的原样值（可审计、规范化一致），
    /// 不得因带空白而猜成已知模式，也不得把空白带回显示层。
    func testLocalizedTextUnknownTrimmedFallback() {
        XCTAssertEqual(BattleModifierText.localizedText(for: " futureX "), "futureX")
        XCTAssertEqual(BattleModifierText.localizedText(for: "\nunknownRule\t"), "unknownRule")
    }

    /// Property-based：对 4 个已知 key 与随机未知值施加随机空白前缀/后缀
    /// （空格/制表/换行/回车/不换行空格/空串组合），结果必须与无空白输入一致。
    /// 固定 seed 确定性复现，复用共享 LCG 的 pick() 便捷方法。
    func testLocalizedTextPropertyRandomWhitespace() {
        let whitespacePool = ["", " ", "\t", "\n", "\r", " \t", "\n\t ", "  \n  ", "\u{00A0}"]
        let knownCases: [(raw: String, expected: String)] = [
            ("hardMode", "困难模式"),
            ("minusOne", "传奇杯 I"),
            ("minusTwo", "传奇杯 II"),
            ("minusThree", "传奇杯 III"),
        ]
        var r = LCG(seed: 0xB47_71E_0000_0100) // "issue100" 变体 seed，与既有 seed 不重复
        for i in 0..<100 {
            let prefix = r.pick(whitespacePool)
            let suffix = r.pick(whitespacePool)
            for (raw, expected) in knownCases {
                XCTAssertEqual(
                    BattleModifierText.localizedText(for: prefix + raw + suffix),
                    expected,
                    "iteration \(i): known key \(raw) 带任意空白（prefix=\(prefix.debugDescription), suffix=\(suffix.debugDescription)）必须命中同一映射"
                )
            }
            let unknown = "v" + String(repeating: "x", count: 1 + Int(r.next() % 8))
            XCTAssertEqual(
                BattleModifierText.localizedText(for: prefix + unknown + suffix),
                unknown,
                "iteration \(i): 未知值 \(unknown) 必须回退 trim 后原样（prefix=\(prefix.debugDescription), suffix=\(suffix.debugDescription)），不得被空白影响"
            )
        }
    }

    // MARK: - currentwar fuzz（property-based）

    /// Property-based fuzz：battleModifier 随机形态（缺失/null/known/unknown/empty/长串）
    /// + 其他字段随机缺失 + 随机未知键。断言：
    /// - 解码值必须等于输入期望（防 decode 侧丢字段回归，如改回 always-nil）
    /// - decode→encode→decode round-trip 必须等值、battleModifier 不进 unrecognizedKeys
    func testBattleModifierFuzzRoundTrip() throws {
        let valuePool = ["hardMode", "minusOne", "minusTwo", "minusThree", "none", "futureX"]
        let unknownPool = ["newOfficialField", "futureField", "extra"]
        var r = LCG(seed: 0xB47_71E_0000_0000) // "battle" 的字母序 seed
        for i in 0..<200 {
            var json: [String: Any] = [:]
            var expected: String? = nil // 本次迭代 battleModifier 的期望解码值（缺失/null → nil）
            json["state"] = r.pick(["notInWar", "preparation", "inWar", "warEnded"])
            if !r.bool(20) { json["teamSize"] = 1 + Int(r.next() % 50) }
            if !r.bool(20) { json["attacksPerMember"] = 1 + Int(r.next() % 2) }
            if !r.bool(30) { json["preparationStartTime"] = "2026\(1 + Int(r.next() % 12))\(1 + Int(r.next() % 28))T080000.000Z" }
            if !r.bool(30) { json["startTime"] = "2026\(1 + Int(r.next() % 12))\(1 + Int(r.next() % 28))T080000.000Z" }
            if !r.bool(30) { json["endTime"] = "2026\(1 + Int(r.next() % 12))\(1 + Int(r.next() % 28))T100000.000Z" }
            if !r.bool(50) { json["warStartTime"] = "2026\(1 + Int(r.next() % 12))\(1 + Int(r.next() % 28))T100000.000Z" }
            // battleModifier 随机形态：50% 缺失、50% 出现（null / known / unknown / empty / 长串）
            if r.bool(50) {
                switch Int(r.next() % 5) {
                case 0: json["battleModifier"] = NSNull(); expected = nil // 显式 null → nil
                case 1: let v = r.pick(valuePool); json["battleModifier"] = v; expected = v
                case 2: json["battleModifier"] = "hardMode"; expected = "hardMode"
                case 3: json["battleModifier"] = ""; expected = ""
                default:
                    let v = String(repeating: "x", count: 1 + Int(r.next() % 30))
                    json["battleModifier"] = v; expected = v
                }
            }
            // 随机未知键：battleModifier 必须不在 unrecognizedKeys 内
            if r.bool(20) { json[r.pick(unknownPool)] = true }

            let data = try JSONSerialization.data(withJSONObject: json)
            let decoded = try JSONDecoder().decode(OfficialClanWarSnapshot.self, from: data)
            let roundTripped = try JSONDecoder().decode(
                OfficialClanWarSnapshot.self,
                from: try JSONEncoder().encode(decoded)
            )
            XCTAssertEqual(decoded, roundTripped, "iteration \(i): round-trip 必须等值")
            XCTAssertEqual(
                decoded.battleModifier, expected,
                "iteration \(i): 解码值必须等于输入期望（防 decode 侧丢字段回归）"
            )
            XCTAssertEqual(
                decoded.battleModifier, roundTripped.battleModifier,
                "iteration \(i): battleModifier 编解码后保持"
            )
            XCTAssertFalse(
                decoded.unrecognizedKeys.contains("battleModifier"),
                "iteration \(i): battleModifier 是 known key，不得进审计"
            )
        }
    }

    // MARK: - warlog 条目（official 同样返回该字段）

    /// warlog 条目（OfficialWarLogEntry）的 battleModifier：解码保存 + round-trip 保持
    /// （最小 `{"items":[...]}` 包装，与 ClanPaginationDecodeTests 一致）。
    func testWarLogEntryBattleModifierDecodeAndRoundTrip() throws {
        let json = #"{"items":[{"result":"win","battleModifier":"hardMode"},{"result":"lose"}]}"#
        let page = try JSONDecoder().decode(OfficialWarLogPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items[0].battleModifier, "hardMode")
        XCTAssertNil(page.items[1].battleModifier, "缺失 → nil")

        let roundTripped = try JSONDecoder().decode(
            OfficialWarLogPage.self,
            from: try JSONEncoder().encode(page)
        )
        XCTAssertEqual(roundTripped.items[0].battleModifier, "hardMode")
        XCTAssertEqual(roundTripped, page)

        // 编码护栏：nil battleModifier 的条目不输出该键（合成 Codable 契约）。
        // 注意：合成 Codable 的键输出顺序不是语言保证（swiftc 与 swift 解释器
        // 产物顺序都不同），断言必须不依赖键顺序 → 用 JSONSerialization 解析。
        let encoded = try JSONEncoder().encode(page)
        let jsonObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let items = try XCTUnwrap(jsonObject["items"] as? [[String: Any]])
        XCTAssertEqual(
            items[0]["battleModifier"] as? String, "hardMode",
            "有值条目应编码 battleModifier"
        )
        XCTAssertNil(items[1]["battleModifier"], "nil 条目不应编码 battleModifier")
    }
}

// MARK: - 共享 LCG 便捷方法（bool/pick：与既有 fixed-seed 测试同构，避免各文件重复实现）

extension LCG {
    mutating func bool(_ p: Int = 50) -> Bool { next() % 100 < UInt64(p) }
    mutating func pick(_ array: [String]) -> String {
        array[Int(next() % UInt64(array.count))]
    }
}
