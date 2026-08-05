import Foundation
import XCTest
@testable import COCHelperCore

/// 确定性伪随机（fixed seed）：字段随机缺失 + 随机未知键，验证成员模型
/// 解码容忍契约与 round-trip 稳定性（Issue #20 强化护栏）。
final class ClanMemberDecodeFuzzTests: XCTestCase {
    private struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func bool(_ p: Int = 50) -> Bool { next() % 100 < UInt64(p) }
    }

    /// 生成一个成员 JSON 字典：字段随机缺失 + 未知键（官方 ClanWarMember 形态：
    /// attacks 为攻击数组、townhallLevel 小写）。
    private static func memberDict(_ r: inout Rand, seed: Int, unknownKeyPool: [String]) -> [String: Any] {
        var d: [String: Any] = [:]
        if !r.bool(20) { d["tag"] = "#FUZZ\(seed)" }
        if !r.bool(20) { d["name"] = "fuzz-\(seed)" }
        if !r.bool(20) { d["townhallLevel"] = 1 + Int(r.next() % 20) }
        if !r.bool(20) { d["mapPosition"] = 1 + Int(r.next() % 50) }
        if !r.bool(20) { d["opponentAttacks"] = Int(r.next() % 3) }
        if !r.bool(25) {
            var attacks: [[String: Any]] = []
            for _ in 0..<Int(r.next() % 3) {
                var a: [String: Any] = [:]
                if !r.bool(25) { a["order"] = Int(r.next() % 3) + 1 }
                if !r.bool(25) { a["attackerTag"] = "#A\(seed)" }
                if !r.bool(25) { a["defenderTag"] = "#D\(seed)" }
                if !r.bool(25) { a["stars"] = Int(r.next() % 4) }
                if !r.bool(25) { a["destructionPercentage"] = Double(r.next() % 101) }
                if !r.bool(25) { a["duration"] = Int(r.next() % 300) }
                attacks.append(a)
            }
            d["attacks"] = attacks
        }
        if !r.bool(30) {
            var b: [String: Any] = [:]
            if !r.bool(25) { b["order"] = 1 }
            if !r.bool(25) { b["attackerTag"] = "#O\(seed)" }
            if !r.bool(25) { b["defenderTag"] = "#M\(seed)" }
            if !r.bool(25) { b["stars"] = Int(r.next() % 4) }
            if !r.bool(25) { b["destructionPercentage"] = Double(r.next() % 101) }
            if !r.bool(25) { b["duration"] = Int(r.next() % 300) }
            d["bestOpponentAttack"] = b
        }
        if r.bool(15) { d[unknownKeyPool.randomElement()!] = "future" }
        return d
    }

    func testClanWarMemberFuzzRoundTrip() throws {
        let pool = ["newField", "extra", "order", "futureKey"]
        var r = Rand(state: 0x2026_0820_0000_0000)
        for i in 0..<200 {
            var members: [[String: Any]] = []
            for j in 0..<Int(r.next() % 6) {
                members.append(Self.memberDict(&r, seed: i * 10 + j, unknownKeyPool: pool))
            }
            let json: [String: Any] = ["state": "inWar", "clan": ["name": "c", "members": members]]
            let data = try JSONSerialization.data(withJSONObject: json)
            let decoded = try JSONDecoder().decode(OfficialClanWarSnapshot.self, from: data)
            let roundTripped = try JSONDecoder().decode(
                OfficialClanWarSnapshot.self,
                from: try JSONEncoder().encode(decoded)
            )
            XCTAssertEqual(decoded, roundTripped, "iteration \(i): round-trip 必须等值")
            XCTAssertEqual(decoded.clan?.members?.count, members.count, "iteration \(i): 成员数保持")
            XCTAssertEqual(decoded.unrecognizedKeys, [], "iteration \(i): 嵌套未知键不进顶层审计")
        }
    }

    func testCapitalRaidSeasonFuzzRoundTrip() throws {
        var r = Rand(state: 0xCA11_7A11_0000_0000)
        for i in 0..<200 {
            var members: [[String: Any]] = []
            for _ in 0..<Int(r.next() % 5) {
                var m: [String: Any] = [:]
                if !r.bool(15) { m["tag"] = "#R\(i)" }
                if !r.bool(15) { m["name"] = "m\(i)" }
                if !r.bool(15) { m["capitalResourcesLooted"] = Int(r.next() % 50_000) }
                if !r.bool(15) { m["attacks"] = Int(r.next() % 20) }
                members.append(m)
            }
            var logs: [[String: Any]] = []
            for _ in 0..<Int(r.next() % 4) {
                var clanInfo: [String: Any] = [:]
                if !r.bool(25) { clanInfo["tag"] = "#C\(i)" }
                if !r.bool(25) { clanInfo["name"] = "c\(i)" }
                if !r.bool(25) { clanInfo["level"] = Int(r.next() % 15) }
                if r.bool(20) { clanInfo["badgeUrls"] = ["small": "https://x/\(i).png"] }
                var districts: [[String: Any]] = []
                for _ in 0..<Int(r.next() % 4) {
                    var dd: [String: Any] = [:]
                    if !r.bool(25) { dd["id"] = Int(r.next() % 100) }
                    if !r.bool(25) { dd["name"] = "d\(i)" }
                    if !r.bool(25) { dd["districtHallLevel"] = Int(r.next() % 7) }
                    if !r.bool(25) { dd["stars"] = Int(r.next() % 4) }
                    if !r.bool(25) { dd["destructionPercent"] = Double(r.next() % 101) }
                    if !r.bool(25) { dd["attackCount"] = Int(r.next() % 10) }
                    if !r.bool(25) { dd["totalLooted"] = Int(r.next() % 50_000) }
                    districts.append(dd)
                }
                var e: [String: Any] = ["districts": districts]
                // 交替生成 attackLog（defender）与 defenseLog（attacker）形态：
                // 用同一个 logs 数组混两种条目，解码端两模型分开断言太复杂——
                // 直接对 OfficialCapitalRaidPage 顶层解码验证 round-trip 即可，
                // 字段名正确性由 R1 的 fixture 测试覆盖。
                if !r.bool(20) { e["defender"] = clanInfo }
                if !r.bool(20) { e["attacker"] = clanInfo }
                if !r.bool(25) { e["attackCount"] = Int(r.next() % 10) }
                if !r.bool(25) { e["districtCount"] = Int(r.next() % 6) }
                if !r.bool(25) { e["districtsDestroyed"] = Int(r.next() % 6) }
                if r.bool(10) { e["futureField"] = true }
                logs.append(e)
            }
            let json: [String: Any] = [
                "items": [["state": "ended", "members": members, "attackLog": logs]],
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            let decoded = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: data)
            let roundTripped = try JSONDecoder().decode(
                OfficialCapitalRaidPage.self,
                from: try JSONEncoder().encode(decoded)
            )
            XCTAssertEqual(decoded, roundTripped, "iteration \(i): round-trip 必须等值")
            XCTAssertEqual(decoded.items[0].members?.count, members.count)
            XCTAssertEqual(decoded.items[0].attackLog?.count, logs.count)
        }
    }
}
