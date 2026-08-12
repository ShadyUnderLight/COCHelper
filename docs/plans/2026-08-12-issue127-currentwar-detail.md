# Issue #127 CurrentWar 攻击详情/防守/北京时间 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐 currentwar 卡片剩余"看得懂、可审计"能力——攻击展开显示目标 tag 与时长、成员行显示最佳防守、战争时间显示北京时间、诊断区已完成部分不重做。

**Architecture:** 展示投影（Core）+ 视图（app target）分层。raw snapshot/缓存/parserVersion 一律不动。复用 #124 的 `WarLogTimeFormatter`（不重写 UTC 解析）；`ClanWarAttackLine` 加两个默认 nil 字段（warlog 共用调用点零改动）；`ClanWarMemberRow` 加 `bestDefense`（复用 `ClanWarAttackLine`，init 默认参数使既有测试零改动）；`ClanCombatSummary` 加 `durationText`（分:秒，可测）；`WarLogTimeFormatter` 提取 `utcDate(from:)` 共享解析并新增 `remainingText`。

**Tech Stack:** Swift 6.3.3 / SwiftUI / XCTest（单元 + SeededGenerator property，500 迭代，项目既有惯例）。

---

## 设计决策（3 候选投票，controller 定稿）

### 决策 1：攻击行类型方案
- A：扩展 `ClanWarAttackLine` 加 `defenderTag: String?`、`duration: Int?`（init 默认 nil）——warlog 调用点（`ClanCombatSummary.warMember`、`WarLogCardView.attackLineRow`）零改动
- B：新建 currentwar 专用 display line，`ClanWarMemberRow.lines` 改用它——类型重复 + 转换冗余 + 测试改动面大
- C：SwiftUI 直接读 raw model——违反 issue 明确建议
- **投票：A**（向后兼容扩展，破坏面最小；issue 的"兼容边界"担忧由默认参数解决）

### 决策 2：防守表现投影形态
- A：`ClanWarMemberRow` 加 `bestDefense: ClanWarAttackLine?`（复用类型，只消费 stars/destructionPercentage/duration）
- B：三个散字段——nil 组合爆炸，UI 三判
- C：新建 `ClanWarDefenseSummary` 专用类型——字段重复，收益小
- **投票：A**（bestOpponentAttack 字段与 attack line 完全对齐；`order`/`defenderTag` 对防守无意义恒 nil；init 加默认参数 `= nil` 使 `ClanWarDisplayProjectionFilterTests.makeRow` 等既有构造零改动）

### 决策 3：时间三态组装位置
- A：UI 层 switch phase + 复用 `WarLogTimeFormatter.displayText(raw:)` 三态
- B：Core 产出结构化时间行——违反 #125 契约"投影不产出中文文案"
- C：扩展 WarLogTimeFormatter 支持多字段——污染 #124 专用工具
- **投票：A**（issue 明示"如果 #124 已提供同一格式器，currentwar 复用；不要各自维护两套 UTC 解析规则"；倒计时用 Core 新增 `remainingText(endRaw:now:)` 保持可测）

### 决策 4：duration（分:秒）格式化位置
- A：UI 层私有函数——不可测，违反项目"格式化层放 Core"惯例
- B：投影产出 String——违反"投影输出结构化语义"契约
- C：`ClanCombatSummary.durationText(_:)` 纯函数（与 `displayDestructionPercent` 同文件同层）
- **投票：C**（nil/负值 → nil 未知；145 → "2:25"）

---

### Task 1: Core 投影扩展（攻击行透传 + bestDefense + durationText）

**Files:**
- Modify: `Sources/COCHelperCore/ClanCombatSummary.swift`
- Modify: `Sources/COCHelperCore/ClanWarDisplayProjection.swift`
- Test: `Tests/COCHelperCoreTests/ClanCombatSummaryTests.swift`（durationText 单元测试）
- Test: `Tests/COCHelperCoreTests/ClanWarDisplayProjectionTests.swift`（透传/bestDefense 单元测试）

- [ ] **Step 1: 写失败测试（durationText）**

在 `Tests/COCHelperCoreTests/ClanCombatSummaryTests.swift` 追加：

```swift
    // MARK: - durationText（Issue #127）

    func testDurationTextFormatsMinutesAndSeconds() {
        XCTAssertEqual(ClanCombatSummary.durationText(0), "0:00")
        XCTAssertEqual(ClanCombatSummary.durationText(59), "0:59")
        XCTAssertEqual(ClanCombatSummary.durationText(60), "1:00")
        XCTAssertEqual(ClanCombatSummary.durationText(65), "1:05")
        XCTAssertEqual(ClanCombatSummary.durationText(145), "2:25")
        XCTAssertEqual(ClanCombatSummary.durationText(3661), "61:01")
    }

    func testDurationTextNilAndNegativeIsUnknown() {
        XCTAssertNil(ClanCombatSummary.durationText(nil))
        XCTAssertNil(ClanCombatSummary.durationText(-1))
        XCTAssertNil(ClanCombatSummary.durationText(Int.min))
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ClanCombatSummaryTests/testDurationText`
Expected: 编译失败（durationText 不存在）

- [ ] **Step 3: 实现 durationText**

`Sources/COCHelperCore/ClanCombatSummary.swift` 在 `displayDestructionPercent` 后追加：

```swift
    /// 攻击时长展示文本（分:秒，如 145 → "2:25"）；nil 或负值 → nil（未知）。
    /// 不伪造时长；超长值（如 Int.max）分钟数直接大字面量，无算术风险。
    public static func durationText(_ duration: Int?) -> String? {
        guard let duration, duration >= 0 else { return nil }
        let minutes = duration / 60
        let seconds = duration % 60
        return "\(minutes):" + String(format: "%02d", seconds)
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter ClanCombatSummaryTests/testDurationText`
Expected: 2 tests PASS

- [ ] **Step 5: 扩展 ClanWarAttackLine（写失败测试先行）**

在 `Tests/COCHelperCoreTests/ClanWarDisplayProjectionTests.swift` 的 `ClanWarDisplayProjectionTests` 类追加：

```swift
    // MARK: - 攻击行透传（Issue #127）

    func testAttackLineProjectsTargetAndDuration() {
        let atk = ClanWarAttack(order: 1, attackerTag: "#ATK", defenderTag: "#DEF",
                                stars: 2, destructionPercentage: 80, duration: 145)
        let member = ClanWarMember(tag: "#M", name: "M", mapPosition: 1, townhallLevel: 10,
                                   attacks: [atk], opponentAttacks: nil, bestOpponentAttack: nil)
        let rows = ClanWarDisplayProjection.sortedRows([member], attacksPerMember: 2)
        let line = try! XCTUnwrap(rows.first?.lines?.first)
        XCTAssertEqual(line.order, 1)
        XCTAssertEqual(line.stars, 2)
        XCTAssertEqual(line.destructionPercentage, 80)
        XCTAssertEqual(line.defenderTag, "#DEF")
        XCTAssertEqual(line.duration, 145)
    }

    func testAttackLineMissingTargetAndDurationKeepOtherFields() {
        let atk = ClanWarAttack(order: 1, attackerTag: nil, defenderTag: nil,
                                stars: 3, destructionPercentage: 100, duration: nil)
        let member = ClanWarMember(tag: "#M", name: "M", mapPosition: 1, townhallLevel: nil,
                                   attacks: [atk], opponentAttacks: nil, bestOpponentAttack: nil)
        let line = try! XCTUnwrap(ClanWarDisplayProjection.sortedRows([member], attacksPerMember: 1).first?.lines?.first)
        XCTAssertNil(line.defenderTag)
        XCTAssertNil(line.duration)
        XCTAssertEqual(line.stars, 3)
        XCTAssertEqual(line.destructionPercentage, 100)
    }
```

- [ ] **Step 6: 运行确认失败**

Run: `swift test --filter ClanWarDisplayProjectionTests/testAttackLine`
Expected: 编译失败（ClanWarAttackLine 无 defenderTag/duration 属性）

- [ ] **Step 7: 实现扩展**

`Sources/COCHelperCore/ClanCombatSummary.swift` 的 `ClanWarAttackLine` 改为：

```swift
public struct ClanWarAttackLine: Hashable, Sendable {
    /// 攻击顺序（1 起）；nil = 缺失。
    public let order: Int?
    /// 星数；nil = 缺失。
    public let stars: Int?
    /// 摧毁百分比；nil = 缺失（不得用 0 顶替）。
    public let destructionPercentage: Double?
    /// 目标 tag（官方 defenderTag 透传）；nil = 缺失。warlog/currentwar 共用
    /// 类型：warlog 调用点不消费该字段（Issue #127 扩展，默认 nil 向后兼容）。
    public let defenderTag: String?
    /// 攻击时长（秒，官方透传）；nil = 缺失。展示格式见 `ClanCombatSummary.durationText`。
    public let duration: Int?

    public init(order: Int? = nil, stars: Int? = nil, destructionPercentage: Double? = nil,
                defenderTag: String? = nil, duration: Int? = nil) {
        self.order = order
        self.stars = stars
        self.destructionPercentage = destructionPercentage
        self.defenderTag = defenderTag
        self.duration = duration
    }
}
```

- [ ] **Step 8: 投影透传（sortedRows）**

`Sources/COCHelperCore/ClanWarDisplayProjection.swift` 的 `sortedRows(_:attacksPerMember:order:)` 中 lines 构造改为：

```swift
                lines: member.attacks.map { attacks in
                    attacks.map {
                        ClanWarAttackLine(order: $0.order, stars: $0.stars,
                                          destructionPercentage: $0.destructionPercentage,
                                          defenderTag: $0.defenderTag, duration: $0.duration)
                    }
                },
```

（同时给 `ClanWarMemberRow` 加 `bestDefense` 字段，见 Step 9——本步骤先只加透传）

- [ ] **Step 9: bestDefense 投影（写失败测试先行）**

在 `ClanWarDisplayProjectionTests` 追加：

```swift
    // MARK: - bestDefense（Issue #127）

    func testBestDefenseProjectedFromBestOpponentAttack() {
        let best = ClanWarAttack(order: nil, attackerTag: "#OPP", defenderTag: "#M",
                                 stars: 2, destructionPercentage: 75, duration: 120)
        let member = ClanWarMember(tag: "#M", name: "M", mapPosition: 1, townhallLevel: nil,
                                   attacks: [], opponentAttacks: 3, bestOpponentAttack: best)
        let row = try! XCTUnwrap(ClanWarDisplayProjection.sortedRows([member], attacksPerMember: 2).first)
        XCTAssertEqual(row.defenseAttacks, 3)
        let defense = try! XCTUnwrap(row.bestDefense)
        // 防守视角只消费 stars/destruction/duration；order/defenderTag 无意义恒 nil
        XCTAssertEqual(defense.stars, 2)
        XCTAssertEqual(defense.destructionPercentage, 75)
        XCTAssertEqual(defense.duration, 120)
        XCTAssertNil(defense.order)
        XCTAssertNil(defense.defenderTag)
    }

    func testBestDefenseNilWhenBestOpponentAttackMissing() {
        let member = ClanWarMember(tag: "#M", name: "M", mapPosition: 1, townhallLevel: nil,
                                   attacks: [], opponentAttacks: 0, bestOpponentAttack: nil)
        let row = try! XCTUnwrap(ClanWarDisplayProjection.sortedRows([member], attacksPerMember: 2).first)
        XCTAssertNil(row.bestDefense)
        XCTAssertEqual(row.defenseAttacks, 0)
    }
```

- [ ] **Step 10: 运行确认失败**

Run: `swift test --filter ClanWarDisplayProjectionTests/testBestDefense`
Expected: 编译失败（ClanWarMemberRow 无 bestDefense）

- [ ] **Step 11: 实现 bestDefense**

`ClanWarDisplayProjection.swift` 的 `ClanWarMemberRow`：

```swift
    /// 防守列数据：对方攻击本成员的次数（raw `ClanWarMember.opponentAttacks`
    /// 直接透传，官方即整数次数）；nil = 官方未返回防守数据。
    public let defenseAttacks: Int?
    /// 最佳防守（官方 `bestOpponentAttack` 投影；nil = 官方未返回）。
    /// 只消费 stars/destructionPercentage/duration（order/defenderTag 对防守
    /// 无意义，恒 nil——官方 bestOpponentAttack 的 defenderTag 是进攻方 tag，
    /// 防守视角不展示）。
    public let bestDefense: ClanWarAttackLine?

    public init(
        sourceIndex: Int, mapPosition: Int?, name: String?, tag: String?,
        townhallLevel: Int?, action: ClanWarMemberAction,
        stars: ClanWarMemberStars?, lines: [ClanWarAttackLine]?,
        defenseAttacks: Int?, bestDefense: ClanWarAttackLine? = nil
    ) {
        self.sourceIndex = sourceIndex
        self.mapPosition = mapPosition
        self.name = name
        self.tag = tag
        self.townhallLevel = townhallLevel
        self.action = action
        self.stars = stars
        self.lines = lines
        self.defenseAttacks = defenseAttacks
        self.bestDefense = bestDefense
    }
```

`sortedRows` 构造 `ClanWarMemberRow` 处加：

```swift
                defenseAttacks: member.opponentAttacks,
                bestDefense: member.bestOpponentAttack.map {
                    ClanWarAttackLine(stars: $0.stars,
                                      destructionPercentage: $0.destructionPercentage,
                                      duration: $0.duration)
                }
```

- [ ] **Step 12: 运行全量 Core 测试确认无回归**

Run: `swift test --filter ClanWarDisplayProjectionTests` 与 `swift test --filter ClanCombatSummaryTests`
Expected: 全 PASS（warlog 共用类型零破坏；FilterTests.makeRow 用命名参数 + 默认值零改动）

- [ ] **Step 13: Commit**

```bash
git add Sources/COCHelperCore/ClanCombatSummary.swift Sources/COCHelperCore/ClanWarDisplayProjection.swift Tests/COCHelperCoreTests/ClanCombatSummaryTests.swift Tests/COCHelperCoreTests/ClanWarDisplayProjectionTests.swift
git commit -m "feat(core): 攻击行透传目标/时长与最佳防守投影（Issue #127）"
```

---

### Task 2: Core property-based 测试

**Files:**
- Test: `Tests/COCHelperCoreTests/ClanWarDisplayProjectionTests.swift`（PropertyTests 类追加）

- [ ] **Step 1: 扩展随机生成器（randomAttack/randomMember 加新字段随机化）**

在 `ClanWarDisplayProjectionPropertyTests` 中修改 `randomAttack` 与 `randomMember`：

```swift
    private func randomAttack(_ g: inout SeededGenerator, order: Int) -> ClanWarAttack {
        ClanWarAttack(
            order: g.int(in: 0...3) == 0 ? nil : order,
            attackerTag: nil,
            defenderTag: g.int(in: 0...3) == 0 ? nil : "opponent-\(g.int(in: 0...99))",
            stars: g.int(in: 0...3) == 0 ? nil : g.int(in: -2...3),
            destructionPercentage: g.int(in: 0...3) == 0 ? nil : g.double(in: 0...150),
            duration: g.int(in: 0...3) == 0 ? nil : g.int(in: 0...600)
        )
    }
```

```swift
    private func randomMember(_ g: inout SeededGenerator, index: Int) -> ClanWarMember {
        let attackRoll = g.int(in: 0...3)
        let attacks: [ClanWarAttack]? = attackRoll == 0 ? nil : (attackRoll == 1 ? [] :
            (0..<g.int(in: 1...4)).map { randomAttack(&g, order: $0 + 1) })
        return ClanWarMember(
            tag: g.int(in: 0...3) == 0 ? nil : "member-\(index)",
            name: g.int(in: 0...3) == 0 ? nil : Self.namePool[g.int(in: 0...(Self.namePool.count - 1))],
            mapPosition: g.int(in: 0...3) == 0 ? nil : g.int(in: 1...40),
            townhallLevel: g.int(in: 0...3) == 0 ? nil : g.int(in: 1...17),
            attacks: attacks,
            opponentAttacks: g.int(in: 0...3) == 0 ? nil : g.int(in: 0...10),
            bestOpponentAttack: g.int(in: 0...3) == 0 ? nil :
                ClanWarAttack(order: nil, attackerTag: nil, defenderTag: nil,
                              stars: g.int(in: -1...3),
                              destructionPercentage: g.int(in: 0...3) == 0 ? nil : g.double(in: 0...150),
                              duration: g.int(in: 0...3) == 0 ? nil : g.int(in: 0...600))
        )
    }
```

**注意**：随机序列变化不影响既有 property 断言（幂等/守恒/不变量），既有测试不得改动。

- [ ] **Step 2: 写失败测试（三个新 property）**

**关键**：`sortedRows` 会按行动优先级重排成员，成员与行的对应必须用 `sourceIndex`（成员数组下标），不能依赖行序。

```swift
    // MARK: - Issue #127 properties

    /// 逐次攻击的 target/duration 与输入一一透传（保序、无聚合）。
    func testAttackLinesPreserveTargetAndDurationProperty() {
        var g = SeededGenerator(seed: 707)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
            for (index, member) in members.enumerated() {
                guard let attacks = member.attacks,
                      let row = rows.first(where: { $0.sourceIndex == index }),
                      let lines = row.lines
                else {
                    assertOrFail(member.attacks == nil,
                                 "attacks nil 时该成员无行或无 lines",
                                 context: "seed=707")
                    continue
                }
                assertOrFail(lines.count == attacks.count, "lines 数量必须等于 attacks 数量",
                             context: "seed=707 n=\(attacks.count)")
                for (atk, line) in zip(attacks, lines) {
                    assertOrFail(line.defenderTag == atk.defenderTag, "defenderTag 透传",
                                 context: "seed=707")
                    assertOrFail(line.duration == atk.duration, "duration 透传",
                                 context: "seed=707")
                    assertOrFail(line.stars == atk.stars, "stars 透传",
                                 context: "seed=707")
                    assertOrFail(line.destructionPercentage == atk.destructionPercentage,
                                 "destructionPercentage 透传（无聚合）", context: "seed=707")
                }
            }
        }
    }

    /// bestDefense 与 bestOpponentAttack 一一对应；bestOpponentAttack nil → bestDefense nil。
    func testBestDefenseConsistentProperty() {
        var g = SeededGenerator(seed: 808)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
            for (index, member) in members.enumerated() {
                guard let row = rows.first(where: { $0.sourceIndex == index }) else {
                    XCTFail("成员必有对应行")
                    continue
                }
                let best = member.bestOpponentAttack
                if let best {
                    let defense = row.bestDefense
                    assertOrFail(defense != nil, "bestOpponentAttack 存在时 bestDefense 必须非 nil",
                                 context: "seed=808")
                    assertOrFail(defense?.stars == best.stars, "bestDefense.stars 透传",
                                 context: "seed=808")
                    assertOrFail(defense?.destructionPercentage == best.destructionPercentage,
                                 "bestDefense.destructionPercentage 透传", context: "seed=808")
                    assertOrFail(defense?.duration == best.duration, "bestDefense.duration 透传",
                                 context: "seed=808")
                } else {
                    assertOrFail(row.bestDefense == nil, "bestOpponentAttack nil 时 bestDefense 必须 nil",
                                 context: "seed=808")
                }
            }
        }
    }

    /// durationText 可逆：非负输入解析回秒数一致；负值/nil → nil。
    func testDurationTextRoundTripProperty() {
        var g = SeededGenerator(seed: 909)
        for _ in 0..<Self.iterationCount {
            let raw = g.int(in: -100...10000)
            let text = ClanCombatSummary.durationText(raw)
            if raw < 0 {
                assertOrFail(text == nil, "负值必须 nil", context: "seed=909 raw=\(raw)")
            } else {
                assertOrFail(text != nil, "非负值必须非 nil", context: "seed=909 raw=\(raw)")
                if let text {
                    let parts = text.split(separator: ":")
                    assertOrFail(parts.count == 2, "格式必须 M:SS", context: "seed=909 text=\(text)")
                    let minutes = Int(parts[0]) ?? -1
                    let seconds = Int(parts[1]) ?? -1
                    assertOrFail(minutes * 60 + seconds == raw,
                                 "解析回秒数必须等于输入", context: "seed=909 raw=\(raw) text=\(text)")
                }
            }
        }
    }
```

```swift
    /// 逐次攻击的 target/duration 与输入一一透传（保序、无聚合）。
    func testAttackLinesPreserveTargetAndDurationProperty() {
        var g = SeededGenerator(seed: 707)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
            for member in members {
                guard let attacks = member.attacks,
                      let row = rows.first(where: { $0.sourceIndex == members.firstIndex(of: member) ?? -1 }),
                      let lines = row.lines
                else {
                    assertOrFail(member.attacks == nil,
                                 "attacks nil 时该成员无行或无 lines",
                                 context: "seed=707")
                    continue
                }
                assertOrFail(lines.count == attacks.count, "lines 数量必须等于 attacks 数量",
                             context: "seed=707 n=\(attacks.count)")
                for (atk, line) in zip(attacks, lines) {
                    assertOrFail(line.defenderTag == atk.defenderTag, "defenderTag 透传",
                                 context: "seed=707")
                    assertOrFail(line.duration == atk.duration, "duration 透传",
                                 context: "seed=707")
                    assertOrFail(line.stars == atk.stars, "stars 透传",
                                 context: "seed=707")
                    assertOrFail(line.destructionPercentage == atk.destructionPercentage,
                                 "destructionPercentage 透传（无聚合）", context: "seed=707")
                }
            }
        }
    }

    /// bestDefense 与 bestOpponentAttack 一一对应；bestOpponentAttack nil → bestDefense nil。
    func testBestDefenseConsistentProperty() {
        var g = SeededGenerator(seed: 808)
        for _ in 0..<Self.iterationCount {
            let members = randomMemberList(&g)
            let rows = ClanWarDisplayProjection.sortedRows(members, attacksPerMember: 2)
            for member in members {
                guard let row = rows.first(where: { $0.sourceIndex == members.firstIndex(of: member) ?? -1 }) else {
                    XCTFail("成员必有对应行")
                    continue
                }
                let best = member.bestOpponentAttack
                if let best {
                    let defense = row.bestDefense
                    assertOrFail(defense != nil, "bestOpponentAttack 存在时 bestDefense 必须非 nil",
                                 context: "seed=808")
                    assertOrFail(defense?.stars == best.stars, "bestDefense.stars 透传",
                                 context: "seed=808")
                    assertOrFail(defense?.destructionPercentage == best.destructionPercentage,
                                 "bestDefense.destructionPercentage 透传", context: "seed=808")
                    assertOrFail(defense?.duration == best.duration, "bestDefense.duration 透传",
                                 context: "seed=808")
                } else {
                    assertOrFail(row.bestDefense == nil, "bestOpponentAttack nil 时 bestDefense 必须 nil",
                                 context: "seed=808")
                }
            }
        }
    }

    /// durationText 可逆：非负输入解析回秒数一致；负值/nil → nil。
    func testDurationTextRoundTripProperty() {
        var g = SeededGenerator(seed: 909)
        for _ in 0..<Self.iterationCount {
            let raw = g.int(in: -100...10000)
            let text = ClanCombatSummary.durationText(raw)
            if raw < 0 {
                assertOrFail(text == nil, "负值必须 nil", context: "seed=909 raw=\(raw)")
            } else {
                assertOrFail(text != nil, "非负值必须非 nil", context: "seed=909 raw=\(raw)")
                if let text {
                    let parts = text.split(separator: ":")
                    assertOrFail(parts.count == 2, "格式必须 M:SS", context: "seed=909 text=\(text)")
                    let minutes = Int(parts[0]) ?? -1
                    let seconds = Int(parts[1]) ?? -1
                    assertOrFail(minutes * 60 + seconds == raw,
                                 "解析回秒数必须等于输入", context: "seed=909 raw=\(raw) text=\(text)")
                }
            }
        }
    }
```

- [ ] **Step 3: 运行确认全绿（生产代码已在 Task 1/3 落地，本 Task 只加测试）**

Run: `swift test --filter ClanWarDisplayProjectionPropertyTests`
Expected: 3 新 property + 既有 7 property 全 PASS（新测试对既有实现必须直接绿——透传与 bestDefense 已在 Task 1 实现；若红说明 Task 1 实现有缺陷，报告 BLOCKED）

- [ ] **Step 4: Commit**

```bash
git add Tests/COCHelperCoreTests/ClanWarDisplayProjectionTests.swift
git commit -m "test(core): 攻击透传/bestDefense/duration property 覆盖（Issue #127）"
```

---

### Task 3: Core 时间工具（utcDate 提取 + remainingText）

**Files:**
- Modify: `Sources/COCHelperCore/WarLogTimeFormatter.swift`
- Test: `Tests/COCHelperCoreTests/WarLogTimeFormatterTests.swift`

- [ ] **Step 1: 写失败测试**

`WarLogTimeFormatterTests` 追加：

```swift
    // MARK: - remainingText（Issue #127，currentwar inWar 倒计时）

    func testRemainingTextPositive() {
        // 20260809T110738.000Z = 北京时间 19:07:38
        let end = "20260809T110738.000Z"
        let now = utcDate(2026, 8, 9, 3, 7, 38)   // UTC 03:07:38 → 剩余 8 小时
        XCTAssertEqual(WarLogTimeFormatter.remainingText(endRaw: end, now: now), "剩余 8 小时")
    }

    func testRemainingTextMultipleDays() {
        let end = "20260809T110738.000Z"
        let now = utcDate(2026, 8, 6, 11, 7, 38)  // 剩余 3 天
        XCTAssertEqual(WarLogTimeFormatter.remainingText(endRaw: end, now: now), "剩余 3 天 0 小时")
    }

    func testRemainingTextExpiredOrUnparsableIsNil() {
        let end = "20260809T110738.000Z"
        XCTAssertNil(WarLogTimeFormatter.remainingText(endRaw: end,
                                                       now: utcDate(2026, 8, 9, 12, 0, 0)))
        XCTAssertNil(WarLogTimeFormatter.remainingText(endRaw: nil, now: Date()))
        XCTAssertNil(WarLogTimeFormatter.remainingText(endRaw: "not-a-date", now: Date()))
    }

    /// 测试辅助：UTC 固定日期（avoid DateComponents 时区漂移）。
    private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return Calendar(identifier: .gregorian).date(from: c)!
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter WarLogTimeFormatterTests/testRemainingText`
Expected: 编译失败（remainingText 不存在）

- [ ] **Step 3: 提取 utcDate 并实现 remainingText**

`WarLogTimeFormatter.swift`：
- 现有 `beijingTimeText(raw:)` 中从正则匹配到 `utcCalendar.date(from: components)` 的解析+校验逻辑提取为 `static func utcDate(from raw: String) -> Date?`（internal，保持原有范围校验：year >= 1992、daysInMonth、h/m/s 范围），`beijingTimeText` 改为：

```swift
    static func beijingTimeText(raw: String) -> String? {
        guard let utcDate = utcDate(from: raw) else { return nil }
        let bj = beijingCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: utcDate)
        guard let by = bj.year, let bm = bj.month, let bd = bj.day,
              let bh = bj.hour, let bmi = bj.minute, let bs = bj.second
        else { return nil }
        return "\(by)年\(bm)月\(bd)日 "
            + String(format: "%02d:%02d:%02d", bh, bmi, bs)
    }

    /// 官方 UTC 紧凑串 → Date（UTC）；解析/校验失败 nil。
    /// 与 `displayText` 共用同一解析规则（Issue #127 要求不得维护两套 UTC 解析）。
    static func utcDate(from raw: String) -> Date? {
        guard let match = raw.range(of: officialPattern, options: .regularExpression) else {
            return nil
        }
        let substr = String(raw[match])
        let parts = substr.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let datePart = parts[0], timePart = parts[1]
        func int(_ s: Substring, _ range: Range<Int>) -> Int? {
            let chars = Array(s)
            guard chars.count >= range.upperBound else { return nil }
            return Int(String(chars[range]))
        }
        guard let year = int(datePart, 0..<4),
              let month = int(datePart, 4..<6),
              let day = int(datePart, 6..<8),
              let hour = int(timePart, 0..<2),
              let minute = int(timePart, 2..<4),
              let second = int(timePart, 4..<6)
        else { return nil }
        guard year >= 1992,
              let maxDay = daysInMonth(year: year, month: month),
              (1...maxDay).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second)
        else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        return utcCalendar.date(from: components)
    }

    /// 剩余时间（Issue #127，currentwar inWar 用）：endTime 可解析且晚于 now
    /// → "剩余 X 天 X 小时"（不足 1 天只显示小时）；解析失败/已过期 → nil。
    public static func remainingText(endRaw: String?, now: Date) -> String? {
        guard let endRaw, let end = utcDate(from: endRaw) else { return nil }
        let seconds = Int(end.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        return days > 0 ? "剩余 \(days) 天 \(hours) 小时" : "剩余 \(hours) 小时"
    }
```

- [ ] **Step 4: 运行确认通过 + 既有 formatter 测试无回归**

Run: `swift test --filter WarLogTimeFormatterTests`
Expected: 既有 17 测试 + 新 3 测试全 PASS（重构提取 utcDate 后 beijing 输出逐字节不变）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelperCore/WarLogTimeFormatter.swift Tests/COCHelperCoreTests/WarLogTimeFormatterTests.swift
git commit -m "feat(core): 共享 UTC 解析提取与战争剩余时间（Issue #127）"
```

---

### Task 4: UI 成员区（攻击行目标/时长 + 最佳防守展示）

**Files:**
- Modify: `Sources/COCHelper/ClanWarMemberSection.swift`

- [ ] **Step 1: 扩展 attackLineText**

`ClanWarMemberSection.attackLineText` 改为（字段独立降级，缺失不隐藏其他字段）：

```swift
    /// 单次攻击明细文案：`1号进攻 · 目标 #XXX · ⭐2 · 摧毁率 90% · 耗时 2:25`。
    /// 各字段独立降级：order 缺失 → "?"；目标缺失 → "目标未知"（不补名称）；
    /// 星数缺失 → "⭐?"；摧毁率缺失 → "摧毁率未知"；时长缺失 → "耗时未知"。
    private static func attackLineText(_ line: ClanWarAttackLine) -> String {
        let order = line.order.map { "\($0)" } ?? "?"
        let target = line.defenderTag.map { "目标 \($0)" } ?? "目标未知"
        let stars = line.stars.map { "⭐\(min(max($0, 0), 3))" } ?? "⭐?"
        let destruction = ClanCombatSummary.displayDestructionPercent(line.destructionPercentage)
            .map { "摧毁率 \(ClanDisplayFormat.percent($0))%" } ?? "摧毁率未知"
        let duration = ClanCombatSummary.durationText(line.duration).map { "耗时 \($0)" } ?? "耗时未知"
        return "\(order)号进攻 · \(target) · \(stars) · \(destruction) · \(duration)"
    }
```

- [ ] **Step 2: 展开明细块加最佳防守行**

`detailBlock` 签名从 `(_ lines: [ClanWarAttackLine])` 改为 `(_ row: ClanWarMemberRow)`，内部渲染攻击明细 + 最佳防守：

```swift
    /// 展开的逐次攻击明细 + 最佳防守块（cocElevated 圆角背景）。
    /// 调用方保证 row 至少有一个可展开内容（lines 非空 或 bestDefense 非 nil）。
    private func detailBlock(_ row: ClanWarMemberRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let lines = row.lines, !lines.isEmpty {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(Self.attackLineText(line))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let best = row.bestDefense {
                Text(Self.bestDefenseText(best))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cocElevated, in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 6)
    }

    /// 最佳防守文案：`最佳防守 · ⭐2 · 摧毁率 75% · 耗时 2:00`。
    /// 字段缺失独立降级（与 attackLineText 同风格）；bestDefense 本身 nil 不显示。
    private static func bestDefenseText(_ best: ClanWarAttackLine) -> String {
        let stars = best.stars.map { "⭐\(min(max($0, 0), 3))" } ?? "⭐?"
        let destruction = ClanCombatSummary.displayDestructionPercent(best.destructionPercentage)
            .map { "摧毁率 \(ClanDisplayFormat.percent($0))%" } ?? "摧毁率未知"
        let duration = ClanCombatSummary.durationText(best.duration).map { "耗时 \($0)" } ?? "耗时未知"
        return "最佳防守 · \(stars) · \(destruction) · \(duration)"
    }
```

- [ ] **Step 3: 展开条件与 a11y 同步**

`memberList` 中展开条件改为（lines 非空 **或** bestDefense 非 nil）：

```swift
                ForEach(visibleRows, id: \.sourceIndex) { row in
                    memberRow(row)
                    if expandedIdentity == identity(of: row), Self.hasExpandableContent(row) {
                        detailBlock(row)
                    }
                }
```

`expandableHint` 改为：

```swift
    private func expandableHint(for row: ClanWarMemberRow) -> String {
        Self.hasExpandableContent(row) ? "双击展开攻击/防守明细" : ""
    }

    /// 行是否有可展开内容：攻击明细非空 或 最佳防守非 nil。
    private static func hasExpandableContent(_ row: ClanWarMemberRow) -> Bool {
        if let lines = row.lines, !lines.isEmpty { return true }
        return row.bestDefense != nil
    }
```

`memberCell` 中 chevron 条件同步改为 `Self.hasExpandableContent(row)`。

- [ ] **Step 4: 构建验证**

Run: `swift build`
Expected: 0 error 0 warning

Run: `swift test`
Expected: 全量 PASS（Core 无回归）

- [ ] **Step 5: Commit**

```bash
git add Sources/COCHelper/ClanWarMemberSection.swift
git commit -m "feat(ui): 攻击行目标/时长与最佳防守展示（Issue #127）"
```

---

### Task 5: UI 时间三态（metaLines）

**Files:**
- Modify: `Sources/COCHelper/ClanWarCardView.swift`

- [ ] **Step 1: metaLines 按 phase 三态组织时间行**

`ClanWarCardView.metaLines` 中时间部分替换为调用 `timeLines(_:phase:)`：

```swift
    /// 元信息行：战争规则（BattleModifierText 映射）+ 对战规模（quota 投影）
    /// + 时间行（按阶段三态，Issue #127：preparation 备战开始/开战时间；
    /// inWar 开始+结束+剩余；warEnded 只显示结束时间，不显示倒计时）。
    private func metaLines(_ snapshot: OfficialClanWarSnapshot, _ projection: ClanWarProjection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let rule = BattleModifierText.localizedText(for: snapshot.battleModifier) {
                Text("规则：\(rule)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let teamSize = projection.quota.teamSize {
                Text("对战规模：\(teamSize) 人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            timeLines(snapshot, phase: projection.phase)
        }
    }

    /// 时间行（按阶段）：缺失字段不渲染；解析失败保留原文并标注"格式未识别"。
    /// 全部复用 Core `WarLogTimeFormatter`（#124 同一解析规则，不维护第二套 UTC 解析）。
    @ViewBuilder
    private func timeLines(_ snapshot: OfficialClanWarSnapshot, phase: ClanWarPhase) -> some View {
        switch phase {
        case .preparation:
            timeLine(label: "备战开始", raw: snapshot.preparationStartTime)
            timeLine(label: "开战", raw: snapshot.startTime)
        case .inWar:
            timeLine(label: "开始", raw: snapshot.startTime ?? snapshot.warStartTime)
            timeLine(label: "结束", raw: snapshot.endTime)
            if let end = snapshot.endTime,
               let remaining = WarLogTimeFormatter.remainingText(endRaw: end, now: Date()) {
                Text("剩余：\(remaining)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        case .warEnded:
            timeLine(label: "结束", raw: snapshot.endTime)
        case .notInWar, .unknown:
            EmptyView()
        }
    }

    /// 单条时间行：三态（北京时间 / 官方原始未识别 / 缺失不渲染）。
    @ViewBuilder
    private func timeLine(label: String, raw: String?) -> some View {
        if let raw {
            switch WarLogTimeFormatter.displayText(raw: raw) {
            case .hidden:
                EmptyView()
            case .beijing(let text):
                Text("\(label)：\(text)（北京时间）")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            case .unparsable(let original):
                Text("\(label)：\(original)（官方原始时间/格式未识别）")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }
```

- [ ] **Step 2: 构建验证**

Run: `swift build`
Expected: 0 error 0 warning

- [ ] **Step 3: 全量测试**

Run: `swift test`
Expected: 全量 PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/COCHelper/ClanWarCardView.swift
git commit -m "feat(ui): 当前战争时间按阶段显示北京时间与剩余（Issue #127）"
```

---

### Task 6: 文档 + 全量验证

- [ ] **Step 1: plan 文档入库**

```bash
git add docs/plans/2026-08-12-issue127-currentwar-detail.md
git commit -m "docs(plans): Issue #127 攻击详情/防守/北京时间实施计划"
```

- [ ] **Step 2: 全量门禁**

```bash
swift test 2>&1 | tail -3
swift build -c release 2>&1 | tail -3
git diff --check
```

Expected: 全绿（基线 1169 + 新增）；release build 0 error；diff-check 无输出

- [ ] **Step 3: 自查清单**
- [ ] raw snapshot/缓存/parserVersion 零改动（git diff 核对仅列出的文件）
- [ ] warlog 行为零变化（`ClanCombatSummary.warMember` 构造未传新字段）
- [ ] `ClanWarAttackLine` 扩展向后兼容（默认 nil）
- [ ] 摧毁率仍逐次保留无聚合
- [ ] 时间只改 UI 投影，未动原始字符串写入/读取

---

## 验收映射（Issue #127 原文）

| Issue 要求 | 落地 Task |
|---|---|
| 攻击展开显示目标 tag/星/摧毁率/时长，缺失独立降级 | Task 1 + 4 |
| 摧毁率绝不跨攻击聚合 | 既有契约 + Task 2 property 锁透传 |
| 防守次数 + 最佳防守（星/摧毁/时长），nil 不转 0 | Task 1（defenseAttacks 既有）+ bestDefense 新 |
| 时间北京时间三态 + 倒计时；解析失败保留原文标注 | Task 3 + 5（复用 #124 formatter） |
| 不 bump parserVersion、不新增 API 请求 | 全程 |
| 诊断区不重做 | #126 已完成（本次零改动） |

## 非目标（红线）
- 不改 warlog 分页/条数（#124 已关）
- 不补成员/目标名称
- 不重命名/重写 WarLogTimeFormatter
- 不重做数据诊断区
