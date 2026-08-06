import XCTest
@testable import COCHelperCore

final class OfficialTagValidatorTests: XCTestCase {
    // MARK: - isValid 基本用例

    func testIsValidAcceptsOfficialTag() {
        XCTAssertTrue(OfficialTagValidator.isValid("#ABC"))
        XCTAssertTrue(OfficialTagValidator.isValid("#2ABC"))
        XCTAssertTrue(OfficialTagValidator.isValid("#8QYG2V0C"))
        XCTAssertTrue(OfficialTagValidator.isValid("#0"))
        XCTAssertTrue(OfficialTagValidator.isValid("#Z9"))
    }

    func testIsValidRejectsMissingHash() {
        XCTAssertFalse(OfficialTagValidator.isValid("ABC"))
        XCTAssertFalse(OfficialTagValidator.isValid("2ABC"))
    }

    func testIsValidRejectsLowercase() {
        XCTAssertFalse(OfficialTagValidator.isValid("#abc"))
        XCTAssertFalse(OfficialTagValidator.isValid("#AbC"))
    }

    func testIsValidRejectsSpecialCharacters() {
        XCTAssertFalse(OfficialTagValidator.isValid("#A-B"))
        XCTAssertFalse(OfficialTagValidator.isValid("#A B"))
        XCTAssertFalse(OfficialTagValidator.isValid("#A_B"))
        XCTAssertFalse(OfficialTagValidator.isValid("#A.B"))
    }

    func testIsValidRejectsHashOnlyOrEmpty() {
        XCTAssertFalse(OfficialTagValidator.isValid("#"))
        XCTAssertFalse(OfficialTagValidator.isValid(""))
    }

    // MARK: - isValid 长度边界

    func testIsValidAcceptsMaxLengthTag() {
        let tag = "#" + String(repeating: "A", count: 20)
        XCTAssertEqual(tag.count, 21)
        XCTAssertTrue(OfficialTagValidator.isValid(tag))
    }

    func testIsValidRejectsTooLongTag() {
        let tag = "#" + String(repeating: "A", count: 21)
        XCTAssertEqual(tag.count, 22)
        XCTAssertFalse(OfficialTagValidator.isValid(tag))
    }

    // MARK: - normalized 基本用例（既有契约不变）

    func testNormalizedTrimsWhitespace() {
        XCTAssertEqual(OfficialTagValidator.normalized("  #ABC  "), "#ABC")
        XCTAssertEqual(OfficialTagValidator.normalized("\n#ABC\t"), "#ABC")
    }

    func testNormalizedKeepsValidTagUntouched() {
        XCTAssertEqual(OfficialTagValidator.normalized("#ABC"), "#ABC")
    }

    func testNormalizedReturnsNilForEmptyOrNil() {
        XCTAssertNil(OfficialTagValidator.normalized(nil))
        XCTAssertNil(OfficialTagValidator.normalized(""))
        XCTAssertNil(OfficialTagValidator.normalized("   "))
    }

    // MARK: - normalizedInput 基本用例

    func testNormalizedInputUppercasesAndAddsHash() {
        XCTAssertEqual(OfficialTagValidator.normalizedInput("abc123"), "#ABC123")
        XCTAssertEqual(OfficialTagValidator.normalizedInput("#AbC"), "#ABC")
        XCTAssertEqual(OfficialTagValidator.normalizedInput("abc"), "#ABC")
    }

    func testNormalizedInputTrimsWhitespace() {
        XCTAssertEqual(OfficialTagValidator.normalizedInput("  abc  "), "#ABC")
        XCTAssertEqual(OfficialTagValidator.normalizedInput("\n#AbC\t"), "#ABC")
    }

    func testNormalizedInputKeepsExistingHash() {
        XCTAssertEqual(OfficialTagValidator.normalizedInput("#ABC"), "#ABC")
    }

    func testNormalizedInputReturnsNilForEmptyOrNil() {
        XCTAssertNil(OfficialTagValidator.normalizedInput(nil))
        XCTAssertNil(OfficialTagValidator.normalizedInput(""))
        XCTAssertNil(OfficialTagValidator.normalizedInput("   "))
    }

    /// 非法字符不被过滤：标准化只负责 trim/大写/补 #，字符合法性由 isValid 判定。
    func testNormalizedInputKeepsIllegalCharsForValidation() {
        XCTAssertEqual(OfficialTagValidator.normalizedInput("abc-12"), "#ABC-12")
        XCTAssertFalse(OfficialTagValidator.isValid(OfficialTagValidator.normalizedInput("abc-12")!))
    }

    /// 大小写/前缀规范化后，isValid 接受原本小写或无 # 的输入。
    func testNormalizedInputProducesValidTagFromSloppyInput() {
        XCTAssertTrue(OfficialTagValidator.isValid(OfficialTagValidator.normalizedInput("abc123")!))
        XCTAssertTrue(OfficialTagValidator.isValid(OfficialTagValidator.normalizedInput("#abc")!))
    }

    // MARK: - 兼容性：旧类型名仍可用

    func testLegacyTypealiasStillWorks() {
        XCTAssertTrue(OfficialPlayerTagValidator.isValid("#ABC"))
        XCTAssertEqual(OfficialPlayerTagValidator.normalized("  #ABC  "), "#ABC")
    }

    // MARK: - property-based：随机生成 + 参照实现对比

    /// 参照实现（独立编写，避免与生产实现共享逻辑）：
    /// tag 合法 ⇔ 以 # 开头、其余 1...20 个 ASCII 大写字母或数字。
    private func referenceIsValid(_ tag: String) -> Bool {
        guard tag.hasPrefix("#") else { return false }
        let rest = tag.dropFirst()
        guard !rest.isEmpty, rest.count <= 20 else { return false }
        return rest.allSatisfy { $0.isASCII && (($0.isLetter && $0.isUppercase) || $0.isNumber) }
    }

    /// 参照实现：trim + 全大写 + 补齐 #。
    private func referenceNormalizedInput(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let uppercased = trimmed.uppercased()
        return uppercased.hasPrefix("#") ? uppercased : "#" + uppercased
    }

    func testPropertyIsValidMatchesReference() {
        var rng = SeededRandomGenerator(seed: 42)
        for _ in 0..<2_000 {
            let sample = rng.randomTag()
            XCTAssertEqual(
                OfficialTagValidator.isValid(sample),
                referenceIsValid(sample),
                "isValid 与参照实现不一致: \(sample)"
            )
        }
    }

    func testPropertyNormalizedIsIdempotentAndPreservesValidity() {
        var rng = SeededRandomGenerator(seed: 7)
        for _ in 0..<1_000 {
            let padded = rng.paddedTag()
            guard let normalized = OfficialTagValidator.normalized(padded) else {
                // 全空白或空 → 直接比较归一化结果
                continue
            }
            XCTAssertEqual(OfficialTagValidator.normalized(normalized), normalized, "normalized 不幂等: \(padded)")
            XCTAssertEqual(
                OfficialTagValidator.isValid(normalized),
                referenceIsValid(normalized),
                "normalized 后有效性不一致: \(padded) -> \(normalized)"
            )
        }
    }

    func testPropertyNormalizedOfWhitespaceOnlyIsNil() {
        var rng = SeededRandomGenerator(seed: 99)
        for _ in 0..<200 {
            let whitespace = rng.randomWhitespace()
            XCTAssertNil(OfficialTagValidator.normalized(whitespace))
        }
    }

    /// 核心不变量 I1：normalizedInput 幂等。
    func testPropertyNormalizedInputIsIdempotent() {
        var rng = SeededRandomGenerator(seed: 123)
        for _ in 0..<2_000 {
            let input = rng.paddedTag()
            guard let first = OfficialTagValidator.normalizedInput(input) else {
                XCTAssertNil(OfficialTagValidator.normalizedInput(input), "空输入必须稳定为 nil: \(input)")
                continue
            }
            XCTAssertEqual(
                OfficialTagValidator.normalizedInput(first),
                first,
                "normalizedInput 不幂等: \(input) -> \(first)"
            )
        }
    }

    /// 核心不变量 I2：normalizedInput 与参照实现逐字符一致。
    func testPropertyNormalizedInputMatchesReference() {
        var rng = SeededRandomGenerator(seed: 456)
        for _ in 0..<2_000 {
            let input = rng.randomTag()
            XCTAssertEqual(
                OfficialTagValidator.normalizedInput(input),
                referenceNormalizedInput(input),
                "normalizedInput 与参照实现不一致: \(input)"
            )
        }
    }

    /// 核心不变量 I3：标准化后若合法，isValid 必须为真（输入流程可直接信任标准化结果）。
    func testPropertyValidNormalizedInputAlwaysValid() {
        var rng = SeededRandomGenerator(seed: 789)
        for _ in 0..<2_000 {
            let input = rng.paddedTag()
            guard let normalized = OfficialTagValidator.normalizedInput(input) else { continue }
            let expected = referenceIsValid(normalized)
            XCTAssertEqual(
                OfficialTagValidator.isValid(normalized),
                expected,
                "标准化后有效性判定不一致: \(input) -> \(normalized)"
            )
        }
    }

    /// 长度边界：> 20 字符（不含 #）的合法字符集输入必须被拒绝。
    func testPropertyIsValidRejectsOverlongTags() {
        var rng = SeededRandomGenerator(seed: 321)
        for _ in 0..<500 {
            let overlong = rng.overlongValidCharsetTag()
            XCTAssertFalse(
                OfficialTagValidator.isValid(overlong),
                "超长 tag 必须拒绝: \(overlong) (count=\(overlong.count))"
            )
        }
    }
}

/// 确定性伪随机生成器（不引入第三方依赖的 property-based 辅助）。
struct SeededRandomGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    mutating func randomInt(in range: ClosedRange<Int>) -> Int {
        Int(next() % UInt64(range.upperBound - range.lowerBound + 1)) + range.lowerBound
    }

    /// 随机 tag：可能包含非法字符、小写、空白，长度 0-30（覆盖长度边界两侧）。
    mutating func randomTag() -> String {
        let length = randomInt(in: 0...30)
        let charset = Array("#ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz-_. ")
        return (0..<length).map { _ in String(charset[randomInt(in: 0...(charset.count - 1))]) }.joined()
    }

    /// 仅合法字符集（# + 大写 + 数字）、# 开头、长度 22-30（必超 20 上限，不含 # 为 21-29）。
    mutating func overlongValidCharsetTag() -> String {
        let length = randomInt(in: 22...30)
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return "#" + (0..<(length - 1)).map { _ in String(charset[randomInt(in: 0...(charset.count - 1))]) }.joined()
    }

    mutating func paddedTag() -> String {
        let whitespace = randomWhitespace()
        let core = randomTag()
        if Int.random(in: 0...1) == 0 {
            return core
        }
        return whitespace + core + whitespace
    }

    mutating func randomWhitespace() -> String {
        let chars = [" ", "\t", "\n"]
        let count = randomInt(in: 0...4)
        return (0..<count).map { _ in chars[randomInt(in: 0...2)] }.joined()
    }
}
