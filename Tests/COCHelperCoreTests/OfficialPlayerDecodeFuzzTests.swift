import Foundation
import XCTest
@testable import COCHelperCore

/// 确定性伪随机（fixed seed）：随机字段缺失 + leagueTier 随机有/无
/// （有则带随机 id/name/iconUrls）+ 随机未知键，验证玩家快照解码容忍
/// 契约与 leagueTier round-trip 恒等（Issue #71）。
final class OfficialPlayerDecodeFuzzTests: XCTestCase {
    private struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func bool(_ p: Int = 50) -> Bool { next() % 100 < UInt64(p) }
    }

    /// 联赛/段位对象（league / builderBaseLeague / leagueTier 共用形状）。
    private static func leagueDict(_ r: inout Rand, seed: Int) -> [String: Any] {
        var d: [String: Any] = [:]
        if !r.bool(25) { d["id"] = 29_000_000 + Int(r.next() % 100) }
        if !r.bool(25) { d["name"] = "league-\(seed)" }
        if !r.bool(25) {
            d["iconUrls"] = [
                "small": "https://example.com/s\(seed).png",
                "medium": "https://example.com/m\(seed).png",
            ]
        }
        return d
    }

    /// 生成一个玩家 JSON 字典：字段随机缺失 + leagueTier 随机有/无 + 随机未知键。
    private static func playerDict(_ r: inout Rand, seed: Int, unknownKeyPool: [String]) -> [String: Any] {
        var d: [String: Any] = [:]
        if !r.bool(20) { d["tag"] = "#FUZZ\(seed)" }
        if !r.bool(20) { d["name"] = "fuzz-\(seed)" }
        if !r.bool(20) { d["trophies"] = Int(r.next() % 7000) }
        if !r.bool(30) { d["league"] = leagueDict(&r, seed: seed) }
        if !r.bool(30) { d["builderBaseLeague"] = leagueDict(&r, seed: seed) }
        if !r.bool(30) { d["leagueTier"] = leagueDict(&r, seed: seed) }
        if r.bool(15) { d[unknownKeyPool[Int(r.next() % UInt64(unknownKeyPool.count))]] = "future" }
        return d
    }

    func testPlayerSnapshotFuzzRoundTripWithLeagueTier() throws {
        let pool = ["newField", "extra", "futureKey", "leagueTierExtra"]
        var r = Rand(state: 0x7151_0026_0000_0000)
        for i in 0..<200 {
            let json = Self.playerDict(&r, seed: i, unknownKeyPool: pool)
            let data = try JSONSerialization.data(withJSONObject: json)
            let decoded = try JSONDecoder().decode(OfficialPlayerSnapshot.self, from: data)
            let roundTripped = try JSONDecoder().decode(
                OfficialPlayerSnapshot.self,
                from: try JSONEncoder().encode(decoded)
            )
            XCTAssertEqual(decoded, roundTripped, "iteration \(i): round-trip 必须等值")
            XCTAssertEqual(
                decoded.leagueTier, roundTripped.leagueTier,
                "iteration \(i): leagueTier 保真"
            )
            // leagueTier 是已知键：无论存在与否都不进 unrecognizedKeys
            XCTAssertFalse(
                decoded.unrecognizedKeys.contains("leagueTier"),
                "iteration \(i): leagueTier 不得被收集进未知键"
            )
        }
    }
}
