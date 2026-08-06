import XCTest
@testable import COCHelperCore

final class OfficialPlayerTagValidatorTests: XCTestCase {
    // MARK: - isValid 基本用例

    func testIsValidAcceptsOfficialTag() {
        XCTAssertTrue(OfficialPlayerTagValidator.isValid("#ABC"))
        XCTAssertTrue(OfficialPlayerTagValidator.isValid("#2ABC"))
        XCTAssertTrue(OfficialPlayerTagValidator.isValid("#8QYG2V0C"))
        XCTAssertTrue(OfficialPlayerTagValidator.isValid("#0"))
        XCTAssertTrue(OfficialPlayerTagValidator.isValid("#Z9"))
    }

    func testIsValidRejectsMissingHash() {
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("ABC"))
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("2ABC"))
    }

    func testIsValidRejectsLowercase() {
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("#abc"))
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("#AbC"))
    }

    func testIsValidRejectsSpecialCharacters() {
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("#A-B"))
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("#A B"))
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("#A_B"))
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("#A.B"))
    }

    func testIsValidRejectsHashOnlyOrEmpty() {
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("#"))
        XCTAssertFalse(OfficialPlayerTagValidator.isValid(""))
    }

    // MARK: - 长度上限（权威规则：官方 tag 8-12 位，body ≤ 14 防御上限）

    func testIsValidAcceptsMaxLengthBody() {
        // body 恰好 14 位（含 # 共 15 字符）：上限内合法
        XCTAssertTrue(OfficialPlayerTagValidator.isValid("#" + String(repeating: "A", count: 14)))
        XCTAssertTrue(OfficialPlayerTagValidator.isValid("#" + String(repeating: "9", count: 14)))
    }

    func testIsValidRejectsOverlongBody() {
        // body 超过 14 位：防御上限拒绝（与手动添加路径 ClanTagNormalizer 规则一致）
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("#" + String(repeating: "A", count: 15)))
        XCTAssertFalse(OfficialPlayerTagValidator.isValid("#" + String(repeating: "9", count: 15)))
    }

    // MARK: - normalized 基本用例

    func testNormalizedTrimsWhitespace() {
        XCTAssertEqual(OfficialPlayerTagValidator.normalized("  #ABC  "), "#ABC")
        XCTAssertEqual(OfficialPlayerTagValidator.normalized("\n#ABC\t"), "#ABC")
    }

    func testNormalizedKeepsValidTagUntouched() {
        XCTAssertEqual(OfficialPlayerTagValidator.normalized("#ABC"), "#ABC")
    }

    func testNormalizedReturnsNilForEmptyOrNil() {
        XCTAssertNil(OfficialPlayerTagValidator.normalized(nil))
        XCTAssertNil(OfficialPlayerTagValidator.normalized(""))
        XCTAssertNil(OfficialPlayerTagValidator.normalized("   "))
    }

    // MARK: - property-based：随机生成 + 参照实现对比

    /// 参照实现：tag 合法 ⇔ 以 # 开头、其余全为大写字母或数字、且 body ≤ 14 位。
    private func referenceIsValid(_ tag: String) -> Bool {
        guard tag.hasPrefix("#") else { return false }
        let rest = tag.dropFirst()
        guard !rest.isEmpty, rest.count <= 14 else { return false }
        return rest.allSatisfy { $0.isASCII && (($0.isLetter && $0.isUppercase) || $0.isNumber) }
    }

    func testPropertyIsValidMatchesReference() {
        var rng = SeededRandomGenerator(seed: 42)
        for _ in 0..<2_000 {
            let sample = rng.randomTag()
            XCTAssertEqual(
                OfficialPlayerTagValidator.isValid(sample),
                referenceIsValid(sample),
                "isValid 与参照实现不一致: \(sample)"
            )
        }
    }

    func testPropertyNormalizedIsIdempotentAndPreservesValidity() {
        var rng = SeededRandomGenerator(seed: 7)
        for _ in 0..<1_000 {
            let padded = rng.paddedTag()
            guard let normalized = OfficialPlayerTagValidator.normalized(padded) else {
                // 全空白或空 → 直接比较归一化结果
                continue
            }
            XCTAssertEqual(OfficialPlayerTagValidator.normalized(normalized), normalized, "normalized 不幂等: \(padded)")
            XCTAssertEqual(
                OfficialPlayerTagValidator.isValid(normalized),
                referenceIsValid(normalized),
                "normalized 后有效性不一致: \(padded) -> \(normalized)"
            )
        }
    }

    func testPropertyNormalizedOfWhitespaceOnlyIsNil() {
        var rng = SeededRandomGenerator(seed: 99)
        for _ in 0..<200 {
            let whitespace = rng.randomWhitespace()
            XCTAssertNil(OfficialPlayerTagValidator.normalized(whitespace))
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

    /// 随机 tag：可能包含非法字符、小写、空白，长度 0-20（覆盖超长边界，钉住长度上限规则）。
    mutating func randomTag() -> String {
        let length = randomInt(in: 0...20)
        let charset = Array("#ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz-_. ")
        return (0..<length).map { _ in String(charset[randomInt(in: 0...(charset.count - 1))]) }.joined()
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
