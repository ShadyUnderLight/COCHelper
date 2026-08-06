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

    /// 非 ASCII 输入不被 `uppercased()` 折叠（ß→SS、ı→I、ſ→S 是折叠陷阱）：
    /// 原样保留 + 补 #，由 isValid 拒绝，错误提示契约成立。
    func testNormalizedInputPreservesNonASCIIForValidation() {
        XCTAssertEqual(OfficialTagValidator.normalizedInput("ß"), "#ß")
        XCTAssertFalse(OfficialTagValidator.isValid("#ß"))
        XCTAssertEqual(OfficialTagValidator.normalizedInput("ı"), "#ı")
        XCTAssertFalse(OfficialTagValidator.isValid("#ı"))
        XCTAssertEqual(OfficialTagValidator.normalizedInput("ſ"), "#ſ")
        XCTAssertFalse(OfficialTagValidator.isValid("#ſ"))
        XCTAssertEqual(OfficialTagValidator.normalizedInput("éabc"), "#éabc")
        XCTAssertFalse(OfficialTagValidator.isValid("#éabc"))
        // U+0130 带点大写 I / i+combining dot / I+combining dot：门控保留，isValid 拒绝。
        XCTAssertEqual(OfficialTagValidator.normalizedInput("İ"), "#İ")
        XCTAssertFalse(OfficialTagValidator.isValid("#İ"))
        XCTAssertEqual(OfficialTagValidator.normalizedInput("i\u{307}"), "#i\u{307}")
        XCTAssertFalse(OfficialTagValidator.isValid("#i\u{307}"))
        XCTAssertEqual(OfficialTagValidator.normalizedInput("I\u{307}"), "#I\u{307}")
        XCTAssertFalse(OfficialTagValidator.isValid("#I\u{307}"))
    }

    /// 10 个 ß 若被折叠为 SS 恰好 20 字符、能骗过长度上限——门控后必须被拒。
    func testNormalizedInputRejectsUnicodeExpansionExploit() {
        let input = String(repeating: "ß", count: 10)
        XCTAssertEqual(OfficialTagValidator.normalizedInput(input), "#" + input)
        XCTAssertFalse(OfficialTagValidator.isValid("#" + input))
    }

    /// 双 # 前缀：只补一个 #，多余 # 视为非法（isValid 拒绝，不静默折叠）。
    func testNormalizedInputKeepsDoubleHash() {
        XCTAssertEqual(OfficialTagValidator.normalizedInput("##ABC"), "##ABC")
        XCTAssertFalse(OfficialTagValidator.isValid("##ABC"))
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

    /// 参照实现（**独立技术路线**，避免与生产实现共享逻辑产生自证盲区）：
    /// - `referenceIsValid` 用正则锚定完整匹配（生产用字符扫描 + 长度判断）；
    /// - `referenceNormalizedInput` 用 scalar 数值判断 ASCII + 首字符判断前缀
    ///   （生产用 `isASCII` 属性 + `hasPrefix`）。
    /// 两条路线互相证伪：任何一条写错（如字符集、长度、ASCII 门控）都会暴露。
    private func referenceIsValid(_ tag: String) -> Bool {
        // ^#[A-Z0-9]{1,20}$：完整匹配才合法。
        guard tag.range(of: "^#[A-Z0-9]{1,20}$", options: .regularExpression) != nil else {
            return false
        }
        return true
    }

    private func referenceNormalizedInput(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 非 ASCII（scalar 值 ≥ 128）不参与大写化，原样保留。
        let isPureASCII = trimmed.unicodeScalars.allSatisfy { $0.value < 128 }
        let core = isPureASCII ? trimmed.uppercased() : trimmed
        return core.first == "#" ? core : "#" + core
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

    /// 随机 tag：可能包含非法字符、小写、空白、非 ASCII（ß/ı/ſ/é），
    /// 长度 0-30（覆盖长度边界两侧与 Unicode 折叠路径）。
    mutating func randomTag() -> String {
        let length = randomInt(in: 0...30)
        let charset = Array("#ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz-_. ßıſé")
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
        if randomInt(in: 0...1) == 0 {
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
