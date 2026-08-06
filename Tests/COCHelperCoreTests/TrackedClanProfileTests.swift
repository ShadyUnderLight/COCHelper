import Foundation
import XCTest
@testable import COCHelperCore

final class TrackedClanProfileTests: XCTestCase {
    // MARK: - ClanTagNormalizer

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(ClanTagNormalizer.normalize("  #2QJQ8J88  "), "#2QJQ8J88")
    }

    func testNormalizeUppercases() {
        XCTAssertEqual(ClanTagNormalizer.normalize("#2qjq8j88"), "#2QJQ8J88")
    }

    func testNormalizeRejectsMissingHash() {
        XCTAssertNil(ClanTagNormalizer.normalize("2QJQ8J88"))
    }

    func testNormalizeRejectsBareHash() {
        XCTAssertNil(ClanTagNormalizer.normalize("#"))
    }

    func testNormalizeRejectsEmptyAndNil() {
        XCTAssertNil(ClanTagNormalizer.normalize(""))
        XCTAssertNil(ClanTagNormalizer.normalize("   "))
        XCTAssertNil(ClanTagNormalizer.normalize(nil))
    }

    func testNormalizeRejectsIllegalCharacters() {
        XCTAssertNil(ClanTagNormalizer.normalize("#abc-def"))
        XCTAssertNil(ClanTagNormalizer.normalize("#abc def"))
        XCTAssertNil(ClanTagNormalizer.normalize("#abc_123"))
        XCTAssertNil(ClanTagNormalizer.normalize("中文"))
    }

    func testNormalizeMixedCase() {
        XCTAssertEqual(ClanTagNormalizer.normalize("#AbC1"), "#ABC1")
    }

    // MARK: - property-based（种子化可复现）

    func testNormalizePropertyIsIdempotentForAllValidTags() {
        let seed = UInt64(42)
        let validChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var rng = SplitMix64Generator(seed: seed)
        for _ in 0..<200 {
            let len = Int.random(in: 1...12, using: &rng)
            let body = (0..<len).map { _ in validChars.randomElement(using: &rng)! }.map(String.init).joined()
            let tag = "#" + body
            XCTAssertEqual(ClanTagNormalizer.normalize(tag), tag, "规范化的合法 tag 应幂等")
        }
    }

    func testNormalizePropertyFuzzInputsNeverCrashAndAreDeterministic() {
        let seed = UInt64(7)
        let alphabet = Array(" #abCD01-_[]{}中文\n\t!@#")
        var rng = SplitMix64Generator(seed: seed)
        for _ in 0..<500 {
            let len = Int.random(in: 0...20, using: &rng)
            let raw = (0..<len).map { _ in alphabet.randomElement(using: &rng)! }.map(String.init).joined()
            let a = ClanTagNormalizer.normalize(raw)
            let b = ClanTagNormalizer.normalize(raw)
            XCTAssertEqual(a, b, "normalize 必须确定性")
            if let tag = a {
                XCTAssertTrue(tag.hasPrefix("#"), "normalize 成功结果必须保留 # 前缀")
                XCTAssertEqual(ClanTagNormalizer.normalize(tag), tag, "成功结果再次 normalize 必须幂等")
            }
        }
    }

    // MARK: - Codable round-trip

    func testProfileCodableRoundTrip() throws {
        let profile = TrackedClanProfile(clanTag: "#2QJQ8J88", displayName: "我的部落", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(TrackedClanProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testProfileCodableWithoutDisplayName() throws {
        let profile = TrackedClanProfile(clanTag: "#ABC123", displayName: nil, createdAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(TrackedClanProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testProfileIDIsClanTag() {
        let p = TrackedClanProfile(clanTag: "#TAG1", displayName: nil, createdAt: Date())
        XCTAssertEqual(p.id, "#TAG1")
    }
}

/// 可复现的种子化随机源（splitmix64，property-based 测试用）。
///
/// 独立于 `CoAPIPropertyTests` 中的同名 `SeededGenerator`（UInt32 LCG，
/// 不实现 `RandomNumberGenerator` 协议），故命名区分避免重声明冲突。
struct SplitMix64Generator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        self.state = seed
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
