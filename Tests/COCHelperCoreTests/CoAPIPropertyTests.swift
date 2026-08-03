import Foundation
import XCTest
@testable import COCHelperCore

/// Deterministic LCG（m = 2^32, a = 1664525, c = 1013904223）。
/// 固定种子 ⇒ 属性测试可复现：同一种子重跑得到同一序列。
struct SeededGenerator {
    private var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> UInt32 {
        state = 1664525 &* state &+ 1013904223
        return state
    }
    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int(next() % UInt32(range.count)) + range.lowerBound
    }
    mutating func bool() -> Bool { next() & 1 == 1 }
    mutating func element(from chars: [Character]) -> Character {
        chars[Int(next() % UInt32(chars.count))]
    }
}

final class CoAPIPropertyTests: XCTestCase {

    /// 合法 COC tag 字符集（大写字母 + 数字 + `#`）。
    private let tagAlphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#")
    /// 非 `#` 字符子集，用于控制 tag 中 `#` 的精确数量。
    private let nonHashAlphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    // MARK: - Helpers

    /// 断言失败时先打印复现上下文，再报失败；成功时静默。
    private func assertOrFail(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !condition() {
            let contextText = context()
            print(contextText)
            XCTFail("\(message) | \(contextText)", file: file, line: line)
        }
    }

    private func truncatedForLog(_ string: String, limit: Int = 200) -> String {
        string.count > limit ? String(string.prefix(limit)) + "…" : string
    }

    /// 生成长度 1-12、恰好含 0-2 个 `#` 的随机 tag。
    private func makeRandomTag(generator: inout SeededGenerator) -> String {
        let length = generator.int(in: 1...12)
        let hashCount = min(generator.int(in: 0...2), length)
        var available = Array(0..<length)
        var hashPositions: Set<Int> = []
        for _ in 0..<hashCount {
            hashPositions.insert(available.remove(at: generator.int(in: 0...(available.count - 1))))
        }
        var chars: [Character] = []
        chars.reserveCapacity(length)
        for position in 0..<length {
            chars.append(hashPositions.contains(position) ? "#" : generator.element(from: nonHashAlphabet))
        }
        return String(chars)
    }

    private func randomLetters(_ generator: inout SeededGenerator, maxLength: Int) -> String {
        let count = generator.int(in: 0...maxLength)
        var chars: [Character] = []
        chars.reserveCapacity(count)
        for _ in 0..<count {
            chars.append(generator.element(from: letters))
        }
        return String(chars)
    }

    /// 随机 JSON 值：字符串 / 整数 / 布尔 / 嵌套对象 / 数组 / null。
    private func randomUnknownValue(_ generator: inout SeededGenerator) -> String {
        switch generator.int(in: 0...5) {
        case 0:
            return "\"" + randomLetters(&generator, maxLength: 10) + "\""
        case 1:
            return "\(generator.int(in: -1_000_000...1_000_000))"
        case 2:
            return generator.bool() ? "true" : "false"
        case 3:
            return "{\"nested\": \(generator.int(in: 0...100))}"
        case 4:
            return "[\(generator.int(in: 0...10)), \(generator.int(in: 0...10)), \(generator.int(in: 0...10))]"
        default:
            return "null"
        }
    }

    /// 单个 item 的字段（id 必填，name/isCountry 各 50% 出现），id 供断言核对。
    private struct GeneratedItem {
        let id: Int
        var fields: [String]
    }

    // MARK: - URL 编码属性（200 轮，种子 42）

    func testURLEncodingProperty_randomTags() {
        var generator = SeededGenerator(seed: 42)
        let config = CoAPIConfig()
        for iteration in 0..<200 {
            let tag = makeRandomTag(generator: &generator)
            let url = CoAPIURLBuilder.endpoint(config: config, path: "/players/" + tag)
            let context = "seed=42 iteration=\(iteration) tag=\(tag)"

            // 1. `#` 不能被当作 fragment 分隔符
            assertOrFail(url.fragment == nil, "URL 不应解析出 fragment", context: context)
            // 2. 编码视图（不解码）中不得出现裸 `#`
            let encodedPath = url.path(percentEncoded: true)
            assertOrFail(!encodedPath.contains("#"), "percentEncoded path 不应含裸 #（实际: \(encodedPath)）", context: context)
            // 3. tag 含 `#` 时，路径中必须出现 %23
            if tag.contains("#") {
                assertOrFail(encodedPath.contains("%23"), "percentEncoded path 应含 %23（实际: \(encodedPath)）", context: context)
            }
            // 4. 无损不变量：解码回 tag 后应以 /v1/players/<tag> 结尾
            let decoded = encodedPath.removingPercentEncoding ?? "<removingPercentEncoding 返回 nil>"
            assertOrFail(
                decoded.hasSuffix("/v1/players/" + tag),
                "round-trip 应无损还原 tag（encoded=\(encodedPath), decoded=\(decoded)）",
                context: context
            )
            // 5. host 保持默认
            assertOrFail(url.host == "api.clashofclans.com", "host 应保持默认（实际: \(url.host ?? "nil")）", context: context)
        }
    }

    // MARK: - 宽松解码属性：未知字段不应破坏解码（200 轮，种子 7）

    func testDecodingProperty_randomUnknownFields() {
        let decoder = JSONDecoder()
        var generator = SeededGenerator(seed: 7)
        for iteration in 0..<200 {
            let itemCount = generator.int(in: 0...3)
            var items: [GeneratedItem] = []
            var topLevelFields: [String] = []

            // 必填字段：id（随机正整数）；name/isCountry 各 50% 概率出现
            for _ in 0..<itemCount {
                var fields: [String] = []
                let id = generator.int(in: 1...100_000)
                fields.append("\"id\": \(id)")
                if generator.bool() {
                    fields.append("\"name\": \"" + randomLetters(&generator, maxLength: 12) + "\"")
                }
                if generator.bool() {
                    fields.append("\"isCountry\": \(generator.bool())")
                }
                items.append(GeneratedItem(id: id, fields: fields))
            }

            // 注入 3-8 个未知键，随机放在顶层或某个 item 内层
            let unknownCount = generator.int(in: 3...8)
            for unknownIndex in 0..<unknownCount {
                let entry = "\"unexpected_\(unknownIndex)\": " + randomUnknownValue(&generator)
                if itemCount > 0 && generator.bool() {
                    let target = generator.int(in: 0...(itemCount - 1))
                    items[target].fields.append(entry)
                } else {
                    topLevelFields.append(entry)
                }
            }

            let itemsJSON = items.map { "{" + $0.fields.joined(separator: ", ") + "}" }.joined(separator: ", ")
            var jsonFields = ["\"items\": [" + itemsJSON + "]"]
            jsonFields.append(contentsOf: topLevelFields)
            let json = "{" + jsonFields.joined(separator: ", ") + "}"
            let context = "seed=7 iteration=\(iteration) json=\(truncatedForLog(json))"

            do {
                let decoded = try decoder.decode(LocationsResponse.self, from: Data(json.utf8))
                assertOrFail(
                    decoded.items.count == itemCount,
                    "items.count 应为 \(itemCount)（实际 \(decoded.items.count)）",
                    context: context
                )
                assertOrFail(
                    zip(decoded.items, items).allSatisfy { $0.id == $1.id },
                    "每个 item 的 id 应等于生成值",
                    context: context
                )
            } catch {
                print(context)
                XCTFail("含未知字段的 JSON 应解码成功，但抛错: \(error) | \(context)")
            }
        }
    }

    // MARK: - 严格解码属性：id 缺失或类型错误必须抛错（100 轮，种子 99）

    func testDecodingProperty_malformedIDsThrow() {
        let decoder = JSONDecoder()
        var generator = SeededGenerator(seed: 99)
        for iteration in 0..<100 {
            let itemCount = generator.int(in: 1...3)
            var itemJSONs: [String] = []
            for index in 0..<itemCount {
                if index == 0 {
                    // 第一个 item 必然带缺陷：id 缺失，或 id 类型错误（"id": "abc"）
                    let missingID = generator.bool()
                    var fields: [String] = []
                    if missingID {
                        if generator.bool() { fields.append("\"name\": \"nope\"") }
                        if generator.bool() { fields.append("\"isCountry\": true") }
                    } else {
                        fields.append("\"id\": \"abc\"")
                        if generator.bool() { fields.append("\"name\": \"nope\"") }
                    }
                    itemJSONs.append("{" + fields.joined(separator: ", ") + "}")
                } else {
                    // 其余 item 格式正确
                    var fields = ["\"id\": \(generator.int(in: 1...100_000))"]
                    if generator.bool() { fields.append("\"name\": \"ok\"") }
                    itemJSONs.append("{" + fields.joined(separator: ", ") + "}")
                }
            }
            let json = "{\"items\": [" + itemJSONs.joined(separator: ", ") + "]}"
            let context = "seed=99 iteration=\(iteration) json=\(truncatedForLog(json))"

            do {
                _ = try decoder.decode(LocationsResponse.self, from: Data(json.utf8))
                print(context)
                XCTFail("id 缺失或类型错误的 JSON 应解码失败（malformed 路径）| \(context)")
            } catch {
                // 预期行为：必须抛错
            }
        }
    }
}
