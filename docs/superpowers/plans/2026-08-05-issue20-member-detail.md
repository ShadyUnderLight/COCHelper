# 成员级明细（Issue #20）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Issue #7 三个端点（currentwar / warlog / capitalraidseasons）已接入的摘要层之上，补充成员级明细解码与展开式 UI 展示。

**Architecture:** 模型层全 optional + 合成 Codable（跟随项目嵌套模型约定：顶层审计、嵌套容忍），一次修改 `ClanWarParticipant` 同时覆盖 currentwar 与 warlog；capital 侧新增 4 个模型。UI 用 `DisclosureGroup`（默认折叠）+ 行数上限。parserVersion 随解析范围递增。不新增任何网络请求（无 N+1）。

**Tech Stack:** Swift 6.0 / SwiftPM / SwiftUI（macOS 14）/ XCTest

---

## 设计决策（3 候选投票）

| 决策点 | 候选 | 结果 |
|---|---|---|
| A. 成员嵌套模型解码策略 | A1 声明式 synthesized Codable 全 optional（推荐）；A2 自定义 init(from:)+knownKeys 审计；A3 UI 层二次解析原始 JSON | **A1**：与项目嵌套模型约定一致（ClanCapital/ClanLabel/ClanWarParticipant 均 synthesized），零样板、向后兼容、未知子字段容忍；A2 嵌套审计无消费者；A3 破坏审计/持久化契约 |
| B. parserVersion 策略 | B1 解析范围变化即 bump（推荐）；B2 不 bump；B3 归并单一版本 | **B1**：历史有先例（warlog 0.1→0.2），审计标记保持真实；B3 破坏端点独立版本语义 |
| C. UI 展开模式与行数上限 | C1 DisclosureGroup 默认折叠 + 每表上限 30 行（推荐）；C2 自定义 chevron+@State；C3 不设限 | **C1**：系统标准组件（macOS 14+），零自定义；30 行覆盖常见 30v30 战争全量，50v50 截断提示 |

## 类型契约

```swift
// Sources/COCHelperCore/ClanWarModels.swift
public struct ClanWarMember: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    public let townHallLevel: Int?      // 战争结束时可能缺失
    public let mapPosition: Int?        // 1 起
    public let attacks: Int?            // 可能 0 次攻击
    public let stars: Int?
    public let destructionPercentage: Double?  // Double 容忍浮点/整数
    // opponentAttacks（逐次攻击明细）deferred：嵌套容忍
}

// ClanWarParticipant 增加：
public let members: [ClanWarMember]?

// Sources/COCHelperCore/ClanPaginationModels.swift
public struct CapitalRaidSeasonMember: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    public let capitalResourcesLooted: Int?
    public let attacks: Int?
}
public struct CapitalRaidDefender: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    public let destructionPercent: Double?
}
public struct CapitalRaidAttackLogEntry: Codable, Hashable, Sendable {
    public let defender: CapitalRaidDefender?
    public let attackCount: Int?
    public let districtCount: Int?
    public let districtsDestroyed: Int?
    public let looted: Int?
}
public struct CapitalRaidDefenseLogEntry: Codable, Hashable, Sendable {
    public let defender: CapitalRaidDefender?
    public let attackCount: Int?
    public let districtCount: Int?
    public let districtsDestroyed: Int?
}
// OfficialCapitalRaidSeason 增加：
public let members: [CapitalRaidSeasonMember]?
public let attackLog: [CapitalRaidAttackLogEntry]?
public let defenseLog: [CapitalRaidDefenseLogEntry]?
```

**parserVersion 变更**（`Sources/COCHelperCore/OfficialEndpointState.swift`）：
- `OfficialClanWarSnapshot`: `"clan-war-0.1"` → `"clan-war-0.2"`
- `OfficialWarLogPage`: `"clan-war-log-0.2"` → `"clan-war-log-0.3"`
- `OfficialCapitalRaidPage`: `"clan-capital-0.2"` → `"clan-capital-0.3"`

---

## Task 1: 模型层 — ClanWarMember（currentwar + warlog 共用）

**Files:**
- Modify: `Sources/COCHelperCore/ClanWarModels.swift`
- Test: `Tests/COCHelperCoreTests/ClanWarDecodeTests.swift`
- Test: `Tests/COCHelperCoreTests/ClanPaginationDecodeTests.swift`
- Modify (fixture): `Tests/COCHelperCoreTests/Fixtures/official_war_log_page.json`

- [ ] **Step 1: 写失败测试（RED）** — `ClanWarDecodeTests.swift` 新增：

```swift
// MARK: - 成员级攻击表（Issue #20）

/// 成员级攻击表解码：full fixture 每方 1 名成员（tag/名称/大本/位置/攻击/星/摧毁%）。
func testDecodeClanWarMembers() throws {
    let war = try decode(fullClanWarFixtureData())

    let clanMembers = try XCTUnwrap(war.clan?.members, "clan.members 应被解析")
    XCTAssertEqual(clanMembers.count, 1)
    let member = try XCTUnwrap(clanMembers.first)
    XCTAssertEqual(member.tag, "#PLAYERANONYMIZED")
    XCTAssertEqual(member.name, "anonymized-member")
    XCTAssertEqual(member.townHallLevel, 13)
    XCTAssertEqual(member.mapPosition, 1)
    XCTAssertEqual(member.attacks, 2)
    XCTAssertEqual(member.stars, 6)
    XCTAssertEqual(member.destructionPercentage, 100)

    let opponentMembers = try XCTUnwrap(war.opponent?.members)
    XCTAssertEqual(opponentMembers.count, 1)
    XCTAssertEqual(opponentMembers.first?.townHallLevel, 12)
}

/// 无 members 键（warEnded 等）容忍：成员为 nil，不影响摘要。
func testDecodeWithoutMembersTolerated() throws {
    let war = try decode(fixture("official_clan_war_ended"))
    XCTAssertNil(war.clan?.members)
    XCTAssertEqual(war.clan?.stars, 95)
}

/// 成员字段部分缺失（仅 tag+name）不破坏解码。
func testDecodeMemberWithPartialFields() throws {
    let war = try decode(Data(#"{"clan":{"members":[{"tag":"#A","name":"x"}]}}"#.utf8))
    XCTAssertEqual(war.clan?.members?.first?.tag, "#A")
    XCTAssertNil(war.clan?.members?.first?.townHallLevel)
    XCTAssertTrue(war.unrecognizedKeys.isEmpty, "clan 是已知键，嵌套内容不进顶层审计")
}
```

`ClanPaginationDecodeTests.swift` 新增（warlog 成员走同一模型）：

```swift
// MARK: - warlog 成员明细（Issue #20，与 currentwar 共用 ClanWarMember）

func testDecodeWarLogEntryMembers() throws {
    let page = try JSONDecoder().decode(OfficialWarLogPage.self, from: fullWarLogPageData())
    let members = try XCTUnwrap(page.items[0].clan?.members)
    XCTAssertEqual(members.count, 1)
    XCTAssertEqual(members.first?.name, "anonymized-member")
    XCTAssertEqual(members.first?.townHallLevel, 14)
    XCTAssertEqual(members.first?.mapPosition, 1)
    XCTAssertEqual(members.first?.attacks, 2)
    XCTAssertEqual(members.first?.stars, 6)
    XCTAssertEqual(members.first?.destructionPercentage, 100)
    // 第二场战争无 members 键 → nil 容忍
    XCTAssertNil(page.items[1].clan?.members)
}
```

- [ ] **Step 2: 扩充 warlog fixture** — `official_war_log_page.json` 第一场战争 `clan.members` 由 `[]` 改为：

```json
"members": [
  {
    "tag": "#PLAYERANONYMIZED",
    "name": "anonymized-member",
    "townHallLevel": 14,
    "mapPosition": 1,
    "attacks": 2,
    "stars": 6,
    "destructionPercentage": 100
  }
]
```

（`opponent.members` 保持 `[]`，第二场战争不带 members 键——两种形态都覆盖。）

- [ ] **Step 3: 运行确认 RED** — `swift test --filter ClanWarDecodeTests` 与 `--filter ClanPaginationDecodeTests`，预期：`war.clan?.members` 为 nil，断言失败（编译可通过——`members` 属性此时不存在会编译失败，这正是 RED 的编译期形态；若先加属性后跑测试，测试会因 nil 而 fail）。

> 注意：合成 Codable 未声明属性时 `members` 被忽略。为了让测试以**运行期**方式红，先只加 `public let members: [ClanWarMember]?` 声明（属性存在但 fixture 解码后为 nil），断言失败为运行期 RED。随后 Step 5 补模型定义。

- [ ] **Step 4: 实现（GREEN）** — `ClanWarModels.swift`：

```swift
/// currentwar / warlog 成员级攻击表条目（官方 ClanWarMember）。
///
/// 全 optional + 合成 Codable：官方新增字段或个别字段缺失（如 warEnded
/// 后部分成员无攻击记录、大本等级缺失）不破坏解码；未知子字段
/// （如 opponentAttacks 逐次攻击明细）容忍忽略，不做属性声明（deferred）。
public struct ClanWarMember: Codable, Hashable, Sendable {
    public let tag: String?
    public let name: String?
    /// 大本等级（战争结束/未开战时可能缺失）。
    public let townHallLevel: Int?
    /// 地图位置（1 起）。
    public let mapPosition: Int?
    /// 已使用攻击次数（成员可能 0 次攻击）。
    public let attacks: Int?
    public let stars: Int?
    /// 摧毁百分比（官方可能返回浮点或整数，用 Double 容忍两者）。
    public let destructionPercentage: Double?

    public init(
        tag: String?, name: String?, townHallLevel: Int?, mapPosition: Int?,
        attacks: Int?, stars: Int?, destructionPercentage: Double?
    ) {
        self.tag = tag
        self.name = name
        self.townHallLevel = townHallLevel
        self.mapPosition = mapPosition
        self.attacks = attacks
        self.stars = stars
        self.destructionPercentage = destructionPercentage
    }
}
```

`ClanWarParticipant` 增加属性与 init 参数（更新注释，移除 "members 不声明属性" 的 deferred 说明）：

```swift
    /// 成员级攻击表（currentwar 双方 / warlog 每场战争；缺失容忍）。
    public let members: [ClanWarMember]?
```

- [ ] **Step 5: 运行确认 GREEN** — `swift test`（全量），预期 353+ 测试全绿。

- [ ] **Step 6: Commit**

```bash
git add Sources/COCHelperCore/ClanWarModels.swift Tests/COCHelperCoreTests/ClanWarDecodeTests.swift Tests/COCHelperCoreTests/ClanPaginationDecodeTests.swift Tests/COCHelperCoreTests/Fixtures/official_war_log_page.json
git commit -m "feat: 战争成员级攻击表解码模型 ClanWarMember (Issue #20)"
```

## Task 2: 模型层 — CapitalRaid 成员/攻防日志

**Files:**
- Modify: `Sources/COCHelperCore/ClanPaginationModels.swift`
- Test: `Tests/COCHelperCoreTests/ClanPaginationDecodeTests.swift`
- Modify (fixture): `Tests/COCHelperCoreTests/Fixtures/official_capital_raid_page.json`

- [ ] **Step 1: 写失败测试（RED）** — `ClanPaginationDecodeTests.swift` 新增：

```swift
// MARK: - 资本赛季成员/攻防日志（Issue #20）

func testDecodeCapitalRaidMembers() throws {
    let page = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fullCapitalRaidPageData())
    let members = try XCTUnwrap(page.items[0].members)
    XCTAssertEqual(members.count, 1)
    XCTAssertEqual(members.first?.tag, "#PLAYERANONYMIZED")
    XCTAssertEqual(members.first?.name, "anonymized-member")
    XCTAssertEqual(members.first?.capitalResourcesLooted, 25000)
    XCTAssertEqual(members.first?.attacks, 6)
    // 第二赛季无 members 键 → nil
    XCTAssertNil(page.items[1].members)
}

func testDecodeCapitalRaidAttackLog() throws {
    let page = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fullCapitalRaidPageData())
    let log = try XCTUnwrap(page.items[0].attackLog)
    XCTAssertEqual(log.count, 1)
    let entry = try XCTUnwrap(log.first)
    XCTAssertEqual(entry.defender?.name, "anonymized-district")
    XCTAssertEqual(entry.defender?.destructionPercent, 100)
    XCTAssertEqual(entry.attackCount, 4)
    XCTAssertEqual(entry.districtCount, 5)
    XCTAssertEqual(entry.districtsDestroyed, 1)
    XCTAssertEqual(entry.looted, 20000)
    XCTAssertNil(page.items[1].attackLog)
}

func testDecodeCapitalRaidDefenseLog() throws {
    let page = try JSONDecoder().decode(OfficialCapitalRaidPage.self, from: fullCapitalRaidPageData())
    let log = try XCTUnwrap(page.items[0].defenseLog)
    XCTAssertEqual(log.count, 1)
    let entry = try XCTUnwrap(log.first)
    XCTAssertEqual(entry.defender?.name, "anonymized-home-district")
    XCTAssertEqual(entry.attackCount, 3)
    XCTAssertEqual(entry.districtCount, 5)
    XCTAssertEqual(entry.districtsDestroyed, 0)
    XCTAssertNil(entry.looted, "defenseLog 无 looted 字段")
}

/// 成员/日志字段部分缺失（如 defender 只有 name）不破坏解码。
func testDecodeCapitalRaidLogWithPartialFields() throws {
    let season = try JSONDecoder().decode(
        OfficialCapitalRaidPage.self,
        from: Data(#"{"items":[{"state":"ended","attackLog":[{"defender":{"name":"x"},"attackCount":1}]}]}"#.utf8)
    )
    XCTAssertEqual(season.items[0].attackLog?.first?.defender?.name, "x")
    XCTAssertNil(season.items[0].attackLog?.first?.defender?.destructionPercent)
}
```

- [ ] **Step 2: 扩充 capital fixture** — `official_capital_raid_page.json` 第一赛季：

```json
"members": [
  {
    "tag": "#PLAYERANONYMIZED",
    "name": "anonymized-member",
    "capitalResourcesLooted": 25000,
    "attacks": 6
  }
],
"attackLog": [
  {
    "defender": { "tag": "#DISTRICTANONYMIZED", "name": "anonymized-district", "destructionPercent": 100 },
    "attackCount": 4,
    "districtCount": 5,
    "districtsDestroyed": 1,
    "looted": 20000
  }
],
"defenseLog": [
  {
    "defender": { "tag": "#HOMEDISTRICTANONYMIZED", "name": "anonymized-home-district", "destructionPercent": 40 },
    "attackCount": 3,
    "districtCount": 5,
    "districtsDestroyed": 0
  }
]
```

（第二赛季不带这三个键——两种形态都覆盖。）

- [ ] **Step 3: 运行确认 RED** — `swift test --filter ClanPaginationDecodeTests`，预期 `items[0].members` 为 nil 断言失败。

- [ ] **Step 4: 实现（GREEN）** — `ClanPaginationModels.swift` 在 `OfficialCapitalRaidSeason` 上方新增 4 个模型（代码见上文类型契约），并给 `OfficialCapitalRaidSeason` 增加三个属性 + init 参数（移除 "deferred" 注释）。

- [ ] **Step 5: 运行确认 GREEN** — `swift test --filter ClanPaginationDecodeTests` 全绿，再跑全量 `swift test`。

- [ ] **Step 6: Commit**

```bash
git add Sources/COCHelperCore/ClanPaginationModels.swift Tests/COCHelperCoreTests/ClanPaginationDecodeTests.swift Tests/COCHelperCoreTests/Fixtures/official_capital_raid_page.json
git commit -m "feat: 资本赛季成员贡献与攻防日志解码模型 (Issue #20)"
```

## Task 3: parserVersion bump

**Files:**
- Modify: `Sources/COCHelperCore/OfficialEndpointState.swift`
- Test: `Tests/COCHelperCoreTests/GenericEndpointStateTests.swift`

- [ ] **Step 1: 改测试（RED）** — `GenericEndpointStateTests.swift` `testDefaultParserVersionRestoredPerEndpoint`（L88-100）：

```swift
        let war = ClanWarAPIState(status: .never, clanTag: "#A")
        XCTAssertEqual(war.parserVersion, "clan-war-0.2")

        let warLog = ClanWarLogAPIState(status: .never, clanTag: "#A")
        XCTAssertEqual(warLog.parserVersion, "clan-war-log-0.3")

        let capital = ClanCapitalAPIState(status: .never, clanTag: "#A")
        XCTAssertEqual(capital.parserVersion, "clan-capital-0.3")
```

- [ ] **Step 2: 运行确认 RED** — `swift test --filter GenericEndpointStateTests`，预期 3 个断言失败。

- [ ] **Step 3: 实现（GREEN）** — `OfficialEndpointState.swift` L104/L102/L105 附近：

```swift
extension OfficialClanWarSnapshot: EndpointParserVersioning {
    public static var currentParserVersion: String { "clan-war-0.2" }
}
// 分页包装类型：
public static var currentParserVersion: String { "clan-war-log-0.3" }
public static var currentParserVersion: String { "clan-capital-0.3" }
```

（实际位置：`ClanPaginationModels.swift` L102 与 L125；`OfficialEndpointState.swift` L104。）

- [ ] **Step 4: 运行确认 GREEN** — `swift test` 全量。

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/OfficialEndpointState.swift Sources/COCHelperCore/ClanPaginationModels.swift Tests/COCHelperCoreTests/GenericEndpointStateTests.swift
git commit -m "chore: 成员级解析范围变化递增 parserVersion (Issue #20)"
```

## Task 4: Property-based 解码 fuzz（强化护栏）

**Files:**
- Create: `Tests/COCHelperCoreTests/ClanMemberDecodeFuzzTests.swift`

说明：非新行为开发，属验证强化——以确定性伪随机生成器遍历字段缺失/未知键组合，验证合成解码的容忍契约与 round-trip 稳定性。

- [ ] **Step 1: 写 fuzz 测试**

```swift
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

    /// 生成一个成员 JSON 字典：每个字段以 p% 概率缺失，另加随机未知键。
    private static func memberDict(_ r: inout Rand, seed: Int, unknownKeyPool: [String]) -> [String: Any] {
        var d: [String: Any] = [:]
        if !r.bool(20) { d["tag"] = "#FUZZ\(seed)" }
        if !r.bool(20) { d["name"] = "fuzz-\(seed)" }
        if !r.bool(20) { d["townHallLevel"] = 1 + Int(r.next() % 20) }
        if !r.bool(20) { d["mapPosition"] = 1 + Int(r.next() % 50) }
        if !r.bool(20) { d["attacks"] = Int(r.next() % 3) }
        if !r.bool(20) { d["stars"] = Int(r.next() % 7) }
        if !r.bool(20) { d["destructionPercentage"] = Double(r.next() % 101) }
        if r.bool(15) { d[unknownKeyPool.randomElement()!] = "future" }
        return d
    }

    func testClanWarMemberFuzzRoundTrip() throws {
        let pool = ["opponentAttacks", "newField", "extra", "order"]
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
                var defender: [String: Any] = [:]
                if !r.bool(20) { defender["tag"] = "#D\(i)" }
                if !r.bool(20) { defender["name"] = "d\(i)" }
                if !r.bool(20) { defender["destructionPercent"] = Double(r.next() % 101) }
                var e: [String: Any] = ["defender": defender]
                if !r.bool(20) { e["attackCount"] = Int(r.next() % 10) }
                if !r.bool(20) { e["districtCount"] = Int(r.next() % 6) }
                if !r.bool(20) { e["districtsDestroyed"] = Int(r.next() % 6) }
                if !r.bool(20) { e["looted"] = Int(r.next() % 50_000) }
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
```

- [ ] **Step 2: 运行确认通过** — `swift test --filter ClanMemberDecodeFuzzTests`，预期 200×2 迭代全绿。若红：定位具体迭代与字段组合，按 bug 修复（修模型而非改测试）。

- [ ] **Step 3: Commit**

```bash
git add Tests/COCHelperCoreTests/ClanMemberDecodeFuzzTests.swift
git commit -m "test: 成员模型解码 property-based fuzz 护栏 (Issue #20)"
```

## Task 5: UI — ClanWarCardView 成员攻击表

**Files:**
- Modify: `Sources/COCHelper/ClanWarCardView.swift`

说明：UI 层无测试基建（Tests 只含 COCHelperCore），按项目现状以编译 + 手动验证为准。每表上限 30 行。

- [ ] **Step 1: 实现** — `scoreRow` 中两个 `participantRow` 之后（`if let clan = snapshot.clan` 块内）追加展开组：

```swift
            if let clan = snapshot.clan {
                participantRow(...)
                memberDisclosure(title: "成员攻击表（\(clan.members?.count ?? 0) 人）", members: clan.members ?? [])
            }
            if let opponent = snapshot.opponent {
                participantRow(...)
                memberDisclosure(title: "对方成员攻击表（\(opponent.members?.count ?? 0) 人）", members: opponent.members ?? [])
            }
```

新增私有方法：

```swift
    /// 成员攻击表展开组（默认折叠；上限 30 行，超出提示）。
    @ViewBuilder
    private func memberDisclosure(title: String, members: [ClanWarMember]) -> some View {
        if !members.isEmpty {
            DisclosureGroup(title) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(members.prefix(30), id: \.self) { member in
                        memberRow(member)
                    }
                    if members.count > 30 {
                        Text("还有 \(members.count - 30) 名成员…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .font(.caption)
        }
    }

    private func memberRow(_ member: ClanWarMember) -> some View {
        HStack(spacing: 8) {
            if let position = member.mapPosition {
                Text("\(position)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
            }
            Text(member.name ?? "未知成员")
                .font(.caption)
                .lineLimit(1)
            if let th = member.townHallLevel {
                Text("TH\(th)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text([member.attacks.map { "\($0)攻" },
                  member.stars.map { "⭐\($0)" },
                  member.destructionPercentage.map { "\(Self.percent($0))%" }]
                .compactMap { $0 }
                .joined(separator: " · "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private static func percent(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value)) : String(format: "%.1f", value)
    }
```

- [ ] **Step 2: 编译验证** — `swift build`，预期无错误无警告。

- [ ] **Step 3: Commit**

```bash
git add Sources/COCHelper/ClanWarCardView.swift
git commit -m "feat: 当前战争卡片成员攻击表展开明细 (Issue #20)"
```

## Task 6: UI — WarLogCardView 成员明细

**Files:**
- Modify: `Sources/COCHelper/WarLogCardView.swift`

- [ ] **Step 1: 实现** — `warLogRow` 外层包 DisclosureGroup（仅当 `entry.clan?.members` 非空时展示展开箭头）：

```swift
    @ViewBuilder
    private func warLogRow(_ entry: OfficialWarLogEntry) -> some View {
        if let members = entry.clan?.members, !members.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(members.prefix(30), id: \.self) { member in
                        memberRow(member)
                    }
                    if members.count > 30 {
                        Text("还有 \(members.count - 30) 名成员…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                warLogSummary(entry)
            }
            .font(.caption)
        } else {
            warLogSummary(entry)
        }
    }
```

将原 `warLogRow` 的 HStack 内容提取为 `warLogSummary(_ entry:)`（代码不变，仅改名）。

新增 `memberRow`（与 Task 5 相同的行渲染；因 struct 作用域隔离，两个文件各自声明，不抽公共组件——UI 组件抽取超出本期最小范围）：

```swift
    private func memberRow(_ member: ClanWarMember) -> some View {
        HStack(spacing: 8) {
            if let position = member.mapPosition {
                Text("\(position)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
            }
            Text(member.name ?? "未知成员")
                .font(.caption)
                .lineLimit(1)
            if let th = member.townHallLevel {
                Text("TH\(th)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text([member.attacks.map { "\($0)攻" },
                  member.stars.map { "⭐\($0)" },
                  member.destructionPercentage.map { "\(Self.percent($0))%" }]
                .compactMap { $0 }
                .joined(separator: " · "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private static func percent(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value)) : String(format: "%.1f", value)
    }
```

- [ ] **Step 2: 编译验证** — `swift build`，预期无错误无警告。

- [ ] **Step 3: Commit**

```bash
git add Sources/COCHelper/WarLogCardView.swift
git commit -m "feat: 战争日志条目成员明细展开 (Issue #20)"
```

## Task 7: UI — CapitalRaidCardView 成员贡献与攻防日志

**Files:**
- Modify: `Sources/COCHelper/CapitalRaidCardView.swift`

- [ ] **Step 1: 实现** — `seasonRow` 外包 DisclosureGroup（仅当 members/attackLog/defenseLog 任一非空）：

```swift
    @ViewBuilder
    private func seasonRow(_ season: OfficialCapitalRaidSeason) -> some View {
        let hasDetail = !(season.members ?? []).isEmpty
            || !(season.attackLog ?? []).isEmpty
            || !(season.defenseLog ?? []).isEmpty
        if hasDetail {
            DisclosureGroup {
                seasonDetail(season)
                    .padding(.vertical, 4)
            } label: {
                seasonSummary(season)
            }
            .font(.caption)
        } else {
            seasonSummary(season)
        }
    }
```

将原 `seasonRow` 的 HStack 提取为 `seasonSummary(_:)`，新增：

```swift
    @ViewBuilder
    private func seasonDetail(_ season: OfficialCapitalRaidSeason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let members = season.members, !members.isEmpty {
                Text("成员贡献（\(members.count) 人）")
                    .font(.caption.weight(.semibold))
                ForEach(members.prefix(30), id: \.self) { member in
                    HStack {
                        Text(member.name ?? "未知成员").font(.caption).lineLimit(1)
                        Spacer()
                        Text([member.attacks.map { "\($0) 攻" },
                              member.capitalResourcesLooted.map { Self.formatted($0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if members.count > 30 {
                    Text("还有 \(members.count - 30) 名成员…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let log = season.attackLog, !log.isEmpty {
                Text("进攻日志（\(log.count) 条）").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(log.prefix(30), id: \.self) { entry in
                    raidLogRow(entry)
                }
                if log.count > 30 {
                    Text("还有 \(log.count - 30) 条…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let log = season.defenseLog, !log.isEmpty {
                Text("防守日志（\(log.count) 条）").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(log.prefix(30), id: \.self) { entry in
                    HStack {
                        Text("vs " + (entry.defender?.name ?? "未知区域")).font(.caption).lineLimit(1)
                        Spacer()
                        Text([entry.defender?.destructionPercent.map { "摧毁 \(Self.percent($0))%" },
                              entry.attackCount.map { "\($0) 攻" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if log.count > 30 {
                    Text("还有 \(log.count - 30) 条…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func raidLogRow(_ entry: CapitalRaidAttackLogEntry) -> some View {
        HStack {
            Text("vs " + (entry.defender?.name ?? "未知区域")).font(.caption).lineLimit(1)
            Spacer()
            Text([entry.defender?.destructionPercent.map { "摧毁 \(Self.percent($0))%" },
                  entry.attackCount.map { "\($0) 攻" },
                  entry.districtsDestroyed.map { "\($0) 区域" },
                  entry.looted.map { Self.formatted($0) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }

    private static func percent(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value)) : String(format: "%.1f", value)
    }
```

- [ ] **Step 2: 编译验证** — `swift build`，预期无错误无警告。

- [ ] **Step 3: Commit**

```bash
git add Sources/COCHelper/CapitalRaidCardView.swift
git commit -m "feat: 资本赛季成员贡献与攻防日志展开明细 (Issue #20)"
```

## Task 8: 全量验证与自查（Reflexion）

- [ ] **Step 1: 全量验证**

```bash
swift test
swift build -c release
git diff --check
```

预期：全部通过；release 构建成功；无空白错误。

- [ ] **Step 2: 自查清单**
- [ ] 三个端点的成员数据均在现有响应内解析，无任何新增网络请求（grep `fetchPlayer` / `client.fetch` 无新调用）
- [ ] 老持久化数据兼容：`ClanWarStateStoreTests` / `ClanStateStoreTests` 中旧 parserVersion fixture 未改动且通过（历史数据仍可加载）
- [ ] 顶层审计不回归：`testDecodeFullInWarFixture` 的 `unrecognizedKeys == ["newOfficialField"]` 仍通过（members 不进入顶层审计）
- [ ] `git log --oneline` 提交粒度：8 个 Task 对应 10 个提交（Task 1 含 AppModelTests 配套修复的独立提交、Task 2 含评审 minor 修复的独立提交、Task 8 含 README/注释同步与计划文档的 docs 提交）
- [ ] `git status` 干净，仅剩计划文档（计划文档随 PR 提交）

- [ ] **Step 3: Commit（计划文档）**

```bash
git add docs/superpowers/plans/2026-08-05-issue20-member-detail.md
git commit -m "docs: Issue #20 成员级明细实施计划"
```

## 边界（不要做）

- 不解析 `opponentAttacks`（逐次攻击明细，deferred）
- 不逐成员调 player endpoint（N+1 禁止）
- 不做 CWL、不做 `clan.memberList`（另开 issue）
- 不改分页/刷新/存储语义
- 不抽公共 UI 组件（两个文件各自声明 `memberRow`/`percent`，超出本期最小范围）
- 不动工作区无关文件（README、smoke-api、configure_coc_api.sh）

---

## 追加：评审 P1 修复（2026-08-05，外部评审否决后）

评审发现 3 个 P1（经 5 个独立来源验证属实：官方文档镜像 MasiaAntoine/clash-of-clan-api-doc-official、clashperk/clashofclans.js、huyurt/coc-api-consumer、mathsman5133/coc.py、clashperk types）：

| P1 | 事实 | 修复 |
|---|---|---|
| P1-1 ClanWarMember | 官方字段名 `townhallLevel`（小写 h，与 player 端点不同）；`attacks` 是 ClanWarAttack **数组**（非整数——原 Int 解码遇真实响应 typeMismatch 整页失败）；成员无 stars/destructionPercentage 顶层字段；`opponentAttacks` 整数（被攻击次数）；`bestOpponentAttack` 对象 | 9e26123：新增 ClanWarAttack，重写 ClanWarMember；fixture/测试同步官方形态；UI 从 attacks 数组聚合（count/Σ星/Σ摧毁） |
| P1-2 capital 日志 | `defenseLog` 条目字段名是 `attacker`（原读 defender → 全 nil）；`attackLog`/`defenseLog` 的摧毁率/掠夺在嵌套 `districts[]`（`destructionPercent`/`totalLooted`），无顶层 looted；部落方为 ClanInfo{tag,name,level,badgeUrls} | 9e26123 + 41e9873：新增 CapitalRaidClanInfo/CapitalRaidDistrict，重写两个日志条目模型与 UI |
| P1-3 loadMore 跨版本 | 替换语义丢历史页 + 绕过游标停滞保护（响应 after==请求游标时不清空 → 重复请求） | 4aee514：跨版本改为**重建**——无游标请求第一页替换，停滞保护天然保留；同版本路径不变 |

验证：365/365 全绿、release 构建、diff-check 干净。fuzz 生成器同步官方形态（2c628e1）。
