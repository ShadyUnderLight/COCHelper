import Foundation
import XCTest
@testable import COCHelperCore

final class TrackedClanStoreTests: XCTestCase {
    private func profile(_ tag: String, name: String? = nil) -> TrackedClanProfile {
        TrackedClanProfile(clanTag: tag, displayName: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testEmptyStoreRoundTrip() throws {
        let store = TrackedClanStore()
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(TrackedClanStore.self, from: data)
        XCTAssertTrue(decoded.profiles.isEmpty)
    }

    func testStorePreservesOrder() throws {
        let store = TrackedClanStore(profiles: [profile("#BBB"), profile("#AAA"), profile("#CCC")])
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(TrackedClanStore.self, from: data)
        XCTAssertEqual(decoded.profiles.map(\.clanTag), ["#BBB", "#AAA", "#CCC"])
    }

    func testSingleCorruptEntryDoesNotLoseOthers() throws {
        let good1 = profile("#AAA")
        let good2 = profile("#CCC")
        let good1Data = try JSONEncoder().encode(good1)
        let good2Data = try JSONEncoder().encode(good2)
        // 注意：损坏数据必须语法合法（如 clanTag 为 Int 而非 String 的类型错误）。
        // 语法不完整（如 object 未闭合）属于整体损坏，JSONDecoder 无法流式恢复，走抛错路径。
        let corrupt = Data("{\"clanTag\": 123}".utf8) // clanTag 类型错误 → 单条解码失败
        var payload = Data()
        payload.append(contentsOf: [UInt8(0x5B)]) // [
        payload.append(good1Data)
        payload.append(contentsOf: [UInt8(0x2C)]) // ,
        payload.append(corrupt)
        payload.append(contentsOf: [UInt8(0x2C)]) // ,
        payload.append(good2Data)
        payload.append(contentsOf: [UInt8(0x5D)]) // ]
        let decoded = try JSONDecoder().decode(TrackedClanStore.self, from: payload)
        XCTAssertEqual(decoded.profiles.map(\.clanTag), ["#AAA", "#CCC"], "损坏单条必须被跳过，其余保留")
    }

    func testTotallyCorruptDataThrows() {
        let bad = Data("not json at all".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TrackedClanStore.self, from: bad))
    }

    func testUpsertReplacesExistingTag() {
        var store = TrackedClanStore(profiles: [profile("#AAA", name: "旧名")])
        store.upsert(profile("#AAA", name: "新名"))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].displayName, "新名")
        XCTAssertEqual(store.profiles[0].clanTag, "#AAA")
    }

    func testUpsertReplacesInPlacePreservingOrder() {
        var store = TrackedClanStore(profiles: [profile("#AAA"), profile("#BBB"), profile("#CCC")])
        store.upsert(profile("#BBB", name: "改名"))
        XCTAssertEqual(store.profiles.map(\.clanTag), ["#AAA", "#BBB", "#CCC"], "替换必须保持原位置")
        XCTAssertEqual(store.profiles[1].displayName, "改名")
    }

    func testUpsertAppendsNewTag() {
        var store = TrackedClanStore(profiles: [profile("#AAA")])
        store.upsert(profile("#BBB"))
        XCTAssertEqual(store.profiles.map(\.clanTag), ["#AAA", "#BBB"])
    }

    func testRemoveByTag() {
        var store = TrackedClanStore(profiles: [profile("#AAA"), profile("#BBB")])
        store.remove(tag: "#AAA")
        XCTAssertEqual(store.profiles.map(\.clanTag), ["#BBB"])
        store.remove(tag: "#NOT_EXIST")
        XCTAssertEqual(store.profiles.map(\.clanTag), ["#BBB"])
    }
}
