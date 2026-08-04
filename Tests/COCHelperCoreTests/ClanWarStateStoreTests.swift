import Foundation
import XCTest
@testable import COCHelperCore

/// ClanWarStateStore 直接单测：与 3a 的 ClanStateStore 同构（merging 语义、
/// 逐条容错解码、`{}` 条目不吞邻居、round-trip）。
final class ClanWarStateStoreTests: XCTestCase {
    private func makeState(tag: String, status: OfficialAPIRequestStatus = .success) -> ClanWarAPIState {
        ClanWarAPIState(status: status, clanTag: tag)
    }

    // MARK: - merging 语义

    func testMergeOnlyOverwritesRequestedTags() {
        let previous = [
            "#OLDCLAN": makeState(tag: "#OLDCLAN"),
            "#SHARED": makeState(tag: "#SHARED"),
        ]
        let refreshed = [
            "#NEWCLAN": makeState(tag: "#NEWCLAN"),
            "#SHARED": makeState(tag: "#SHARED", status: .failed),
        ]

        let merged = ClanWarStateStore(states: previous).merging(refreshed)

        XCTAssertNotNil(merged.states["#OLDCLAN"], "未请求的旧部落必须保留")
        XCTAssertEqual(merged.states["#SHARED"]?.status, .failed, "请求过的 tag 被覆盖")
        XCTAssertEqual(merged.states.count, 3)
    }

    func testMergeWithEmptyRefreshedKeepsEverything() {
        let previous = ["#A": makeState(tag: "#A")]
        XCTAssertEqual(ClanWarStateStore(states: previous).merging([:]).states.count, 1)
    }

    // MARK: - 逐条容错解码

    func testDecodeSkipsCorruptEntry() throws {
        // 第二条 state.status 类型错误（number 而非 string）；好条目需含
        // 合成 Codable 的全部必填字段。
        let json = """
        [
            { "#GOOD1": { "status": "success", "clanTag": "#GOOD1", "parserVersion": "clan-war-0.1", "unrecognizedKeys": [] } },
            { "#CORRUPT": { "status": 42, "clanTag": "#CORRUPT" } },
            { "#GOOD2": { "status": "failed", "clanTag": "#GOOD2", "parserVersion": "clan-war-0.1", "unrecognizedKeys": [], "lastErrorReason": "boom" } }
        ]
        """.data(using: .utf8)!

        let store = try JSONDecoder().decode(ClanWarStateStore.self, from: json)

        XCTAssertEqual(store.states.count, 2, "坏条目必须被跳过，不株连好条目")
        XCTAssertNotNil(store.states["#GOOD1"])
        XCTAssertNotNil(store.states["#GOOD2"])
        XCTAssertNil(store.states["#CORRUPT"])
        XCTAssertEqual(store.states["#GOOD2"]?.lastErrorReason, "boom")
    }

    /// 空字典条目 `{}` 是 decode 成功但 first == nil 的合法 JSON 形态：
    /// 必须丢弃自身且不得吞掉相邻好条目（3a 修复过的同款缺陷回归防护）。
    func testDecodeEmptyDictionaryEntryDoesNotSwallowNeighbor() throws {
        let json = """
        [
            { "#A": {"status": "success", "clanTag": "#A", "parserVersion": "clan-war-0.1", "unrecognizedKeys": []} },
            {},
            { "#C": {"status": "success", "clanTag": "#C", "parserVersion": "clan-war-0.1", "unrecognizedKeys": []} }
        ]
        """.data(using: .utf8)!

        let store = try JSONDecoder().decode(ClanWarStateStore.self, from: json)

        XCTAssertEqual(store.states.count, 2, "{} 条目被丢弃，且不得吞掉 #C")
        XCTAssertNotNil(store.states["#C"], "#C 不得被 {} 吞掉")
    }

    func testDecodeEmptyArrayYieldsEmptyStore() throws {
        let store = try JSONDecoder().decode(ClanWarStateStore.self, from: Data("[]".utf8))
        XCTAssertTrue(store.states.isEmpty)
    }

    // MARK: - Round-trip

    func testRoundTripPreservesAllStates() throws {
        let store = ClanWarStateStore(states: [
            "#A": makeState(tag: "#A"),
            "#B": makeState(tag: "#B", status: .failed),
        ])

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ClanWarStateStore.self, from: data)

        XCTAssertEqual(decoded, store)
        XCTAssertEqual(decoded.states["#B"]?.status, .failed)
    }
}
