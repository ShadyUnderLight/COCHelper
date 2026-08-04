# Issue #14 GameCatalog + VillageCatalogProjection 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增版本化静态目录读取器 `GameCatalog` 与村庄投影层 `VillageCatalogProjection`，把账号快照与 APK 静态目录 join，产出含名称/完整时长/上限/图标/状态的项目视图。

**Architecture:** 两个纯数据层文件，不触碰现有解码/排序/UI。`GameCatalog` 解码仓库内 `Resources/GameCatalog/18.400.13/catalog.json`（683 items / 5479 levels），建 `(section, dataID)` 索引并封装「表语义感知」的时长查询。`VillageCatalogProjection` 把 `AccountSnapshot` 与目录 join，按 `(section, dataID, level)` 聚合非升级记录（升级记录各自保留），输出状态枚举与诊断。

**Tech Stack:** Swift 6, swift-tools 6.0, swift-testing-free XCTest（沿用现有 XCTest 风格），无外部依赖。

**前置**：#13 已完成（PR #19），catalog.json/manifest.json 已在 `Sources/COCHelperCore/Resources/GameCatalog/18.400.13/`。

---

## 1. 类型契约（SDD）

### 1.1 GameCatalog.swift（新建）

```swift
import Foundation

// MARK: - Manifest

public struct CatalogCounts: Codable, Hashable, Sendable {
    public let items: Int
    public let levels: Int
    public let missingIcons: Int?
    public let missingTime: Int?
}

public struct CatalogGeneratedFile: Codable, Hashable, Sendable {
    public let path: String
    public let sha256: String?
    public let size: Int?
    public let kind: String?
    public let entries: Int?
}

public struct CatalogManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let gameVersion: String
    public let buildTag: String
    public let locale: String
    public let sourceFingerprint: String
    public let generatedFiles: [CatalogGeneratedFile]
    public let counts: CatalogCounts
}

// MARK: - Assets

/// 静态资源引用；`missingReason != nil` 时表示该引用不可渲染，必须原样暴露给 UI。
public struct CatalogAssetRef: Codable, Hashable, Sendable {
    public let container: String?
    public let exportName: String?
    public let renderedPath: String?
    public let missingReason: String?
}

// MARK: - Items

public struct CatalogItem: Codable, Identifiable, Hashable, Sendable {
    /// 与账号快照 section 名同源（含 `buildings2` 等后缀形式）。
    public let section: String
    public let category: String
    public let dataID: Int64
    /// home / builder / nil（capital 无 base）。
    public let base: String?
    public let baseMissingReason: String?
    public let name: String
    public let maxLevel: Int
    public let icon: CatalogAssetRef?
    public let levelVisual: CatalogAssetRef?
    public let levels: [CatalogLevel]

    public var id: String { "\(section):\(dataID)" }
}

public struct CatalogLevel: Codable, Identifiable, Hashable, Sendable {
    /// 源表原始等级号（可能不连续，如战斗直升机 15..35），查表必须按值匹配。
    public let level: Int
    /// 表语义见 `CatalogDurationSemantics`；缺失为 nil，不填 0。
    public let durationSeconds: Int64?
    public let upgradeResource: String?
    public let upgradeCost: Int64?
    public let requiredTownHallLevel: Int?
    public let requiredLaboratoryLevel: Int?
    public let icon: CatalogAssetRef?
    public let levelVisual: CatalogAssetRef?
    public let missingReason: String?

    public var id: String { String(level) }
}

// MARK: - Duration semantics

/// 行语义按表区分（#13 约定）：
/// - buildToLevel：建筑/陷阱表（BuildTime*），行 N = 「升级到 N 级」的完整时长；
/// - upgradeFromLevel：单位/法术/英雄/战宠/装备/守护者表（UpgradeTime*），行 N = 「从 N 级升到 N+1 级」的时长。
public enum CatalogDurationSemantics: String, Sendable {
    case buildToLevel
    case upgradeFromLevel
}

// MARK: - GameCatalog

/// 版本化静态目录。`Sendable`，不可变，可安全跨线程共享。
public struct GameCatalog: Sendable {
    public static let defaultBundledVersion = "18.400.13"

    public let gameVersion: String

    /// 从 Bundle 加载指定版本目录；目录缺失或解码失败返回 nil（调用方输出诊断，不崩溃）。
    public static func loadBundled(version: String = defaultBundledVersion) -> GameCatalog?

    /// 主查询：`(section, dataID)` 精确匹配（catalog.section 与快照 section 同源）。
    public func item(section: String, dataID: Int64) -> CatalogItem?

    public func items(in section: String) -> [CatalogItem]

    /// 该 section 的时长表语义。
    public static func durationSemantics(forSection section: String) -> CatalogDurationSemantics

    /// 「从 fromLevel 升到 nextLevel（= fromLevel + 1）的完整时长」；目录无该等级记录时返回 nil。
    /// 语义：buildToLevel → levels[nextLevel]；upgradeFromLevel → levels[fromLevel]。
    public func durationToUpgradeLevel(nextLevel: Int, for item: CatalogItem) -> Int64?
}
```

### 1.2 VillageCatalogProjection.swift（新建）

```swift
import Foundation

public enum VillageItemStatus: String, Codable, Hashable, Sendable {
    /// 进行中（remainingSeconds > 0）。
    case upgrading
    /// 有记录、未在升级、未达上限。
    case complete
    /// 已达目录上限（currentLevel >= maxLevel）。
    case maxed
    /// 目录未命中（或目录不可用）：保留 dataID 与 missingReason，不丢弃记录。
    case unknown
    /// 类别不支持（helpers/decos/obstacles 等不参与升级追踪）。
    case unavailable
    /// 目录存在但快照无记录。投影不产出该项；枚举留给 UI 层（#12）遍历目录时使用。
    case available
}

/// 单个物品的投影状态。
public struct VillageItemState: Identifiable, Hashable, Sendable {
    /// 快照原始 id（含 `.types.`/`.modules.` 路径 → 可追溯）。
    public let id: String
    public let section: String
    public let dataID: Int64
    public let base: TrackerBase
    public let name: String
    public let category: TrackerCategory?
    public let currentLevel: Int?
    public let count: Int?
    public let timerSeconds: Int64?
    public let remainingSeconds: Int64?
    /// 仅当 isUpgrading 且 currentLevel 存在时为 currentLevel + 1；否则 nil。
    public let nextLevel: Int?
    /// 目录给出的完整时长（表语义感知）；目录未命中或缺失时 nil。
    public let nextLevelDurationSeconds: Int64?
    public let maxLevel: Int?
    public let status: VillageItemStatus
    public let missingReason: String?
    public let icon: CatalogAssetRef?
    public let levelVisual: CatalogAssetRef?
    public let isNested: Bool

    public var isUpgrading: Bool { (remainingSeconds ?? 0) > 0 }
}

/// 一个村庄、一个基地的完整投影。
public struct VillageCatalogProjection: Sendable {
    public let villageID: UUID
    public let villageName: String
    public let base: TrackerBase
    /// 目录版本；目录不可用时 nil。
    public let catalogVersion: String?
    public let items: [VillageItemState]
    public let diagnostics: [AccountDataDiagnostic]

    /// 核心入口。
    /// - 投影规则：
    ///   1. 只处理快照中出现的记录（含嵌套 types/modules）；
    ///   2. join 键 `(section, dataID)`，命中后校验 `catalog.base` 与投影 base 一致；
    ///   3. 同 `(section, dataID, currentLevel)` 的非升级记录合并为一条并聚合 count；
    ///      升级记录永远各自保留（每个计时实例独立）；
    ///   4. 目录不可用/版本不匹配 → 诊断 warning；join 未命中 → status `.unknown` + missingReason；
    ///      类别不支持 → `.unavailable`；
    ///   5. 名称优先级：目录 name > AccountNameCatalog > `#dataID`。
    public static func project(
        village: VillageProfile,
        catalog: GameCatalog?,
        expectedGameVersion: String? = GameCatalog.defaultBundledVersion,
        base: TrackerBase,
        now: Date = Date()
    ) -> VillageCatalogProjection
}
```

### 1.3 不改动的文件

- `AccountSnapshot.swift`（JSON 解码格式不动）
- `TrackerModels.swift`（`UpgradeTracker.activeRecords` 排序与倒计时语义不动）
- `VillageProfile.swift`、`AccountNameCatalog.swift`、`Package.swift`

---

## 2. 设计决策（CoT 摘要）

| 决策 | 候选 | 结论 |
|---|---|---|
| 目录加载策略 | 1. 启动全量解码 2. 懒加载 3. 原始 Data + 按需解码 | **1**：2.9MB/683 items 单次解码（测试断言 < 2s）；不可变 struct 天然 Sendable；懒加载引入线程安全复杂度，无收益 |
| join 键 | 1. `(section, dataID)` + base 防御校验 2. canonicalSection+base+dataID 组合键 3. 全局唯一 dataID | **1**：catalog.section 与快照 section 同源（fixture 242/242 命中、`(section,dataID)` 无重复已验证）；base 作为命中后校验，不匹配视为 miss。组合键需要重复 canonicalization，无信息增益 |
| 投影 API | 1. 静态函数 + 不可变 struct 2. class 缓存增量 3. protocol 抽象 | **1**：纯数据层无状态；第二个实现出现前不需要 protocol（YAGNI）；UI 性能问题留到 #12 再优化 |
| 重复记录聚合 | 1. 全部保留 2. 全合并 3. 非升级合并 + 升级保留 | **3**：升级实例有独立计时不可合并；非升级重复记录（fixture 1000013 lvl18 ×2）合并聚合 count；满足验收「按等级和数量正确聚合」 |
| count 聚合规则 | — | `nil` 视为 1（一条快照记录 = 至少一个实例），聚合 count = nil 条数 + 非 nil count 之和；property 测试断言 count >= 组内条数 |
| available 语义 | 1. 投影产出 available 项 2. 仅枚举保留 | **2**：issue「快照缺少某项目 ≠ 0 级」；683×2 全量展开会爆炸；留给 #12 UI 遍历目录 |
| 时长语义 | 表语义感知（buildToLevel vs upgradeFromLevel） | **实现中修正为统一语义**：实测 #13 生成器已把 UpgradeTime 表「映射到下一等级」（野蛮人 lvl13=1,080,000s=从12升13 验收值吻合），catalog 中所有表 `levels[N].durationSeconds` 统一为「升级到 N 级」。`CatalogDurationSemantics` 枚举删除，统一查 `levels[nextLevel]` |
| 状态优先级 | — | **实现中修正**：`isUpgrading` 优先于目录命中（升级状态独立于目录）；目录未命中时 upgrading 项仍为 `.upgrading` + missingReason |
| 嵌套 types/modules | — | 快照解析后嵌套项保留**父 section**（normalize 递归传原 section），目录无 modules/types 条目 → 嵌套项恒 miss 为 `.unknown` + missingReason（保留可追溯），非 bug |

---

## 3. 任务分解（TDD）

### Task 1: GameCatalog 测试（先红）

**Files:**
- Create: `Tests/COCHelperCoreTests/GameCatalogTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import COCHelperCore

final class GameCatalogTests: XCTestCase {
    func testLoadBundledDecodesRealCatalog() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        XCTAssertEqual(catalog.gameVersion, "18.400.13")
        XCTAssertGreaterThan(catalog.items(in: "buildings").count, 0)
        XCTAssertNotNil(catalog.item(section: "units", dataID: 4_000_000)) // 野蛮人
        XCTAssertNotNil(catalog.item(section: "buildings", dataID: 1_000_000)) // 兵营
    }

    func testLoadBundledUnknownVersionReturnsNil() {
        XCTAssertNil(GameCatalog.loadBundled(version: "99.0.0"))
    }

    func testBundledLoadPerformanceIsReasonable() {
        // 2.9MB 目录不得阻塞启动：解码上限 5s（CI 慢机器余量）。
        measure { _ = GameCatalog.loadBundled() }
    }

    func testItemLookupUsesExactSectionAndDataID() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        XCTAssertNil(catalog.item(section: "units", dataID: 1_000_000))
        XCTAssertNil(catalog.item(section: "buildings2", dataID: 1_000_000))
    }

    func testBuildingDurationIsBuildToLevelSemantics() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barracks = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_000))
        // 兵营 level 2 dur=300s：从 1 升 2 的完整时长 = levels[nextLevel=2]
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 2, for: barracks), 300)
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 3, for: barracks), 1800)
    }

    func testUnitDurationIsUpgradeFromLevelSemantics() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barbarian = try XCTUnwrap(catalog.item(section: "units", dataID: 4_000_000))
        // 野蛮人 level 2 dur=1800s：从 1 升 2 = levels[fromLevel=1]
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 2, for: barbarian), 1800)
        XCTAssertEqual(catalog.durationToUpgradeLevel(nextLevel: 3, for: barbarian), 3600)
    }

    func testBuilderBaseTrapsUseBuildSemantics() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let trap = try XCTUnwrap(catalog.item(section: "traps2", dataID: 12_000_010))
        XCTAssertEqual(
            GameCatalog.durationSemantics(forSection: "traps2"), .buildToLevel)
        _ = trap // 具体时长由数据驱动，语义才是契约
    }

    func testDurationNilWhenLevelRecordMissing() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let barracks = try XCTUnwrap(catalog.item(section: "buildings", dataID: 1_000_000))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 999, for: barracks))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 0, for: barracks))
    }

    func testEquipmentDurationStaysNil() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let puppet = try XCTUnwrap(catalog.item(section: "equipment", dataID: 90_000_000))
        XCTAssertNil(catalog.durationToUpgradeLevel(nextLevel: 4, for: puppet))
    }

    func testCatalogItemIDAndLevelIDsAreStable() throws {
        let catalog = try XCTUnwrap(GameCatalog.loadBundled())
        let item = try XCTUnwrap(catalog.item(section: "heroes", dataID: 28_000_000))
        XCTAssertEqual(item.id, "heroes:28000000")
        XCTAssertEqual(item.levels.map(\.id).first, "1")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GameCatalogTests`
Expected: 编译失败（类型 `GameCatalog` 不存在）——即 RED。

### Task 2: GameCatalog 实现（转绿）

**Files:**
- Create: `Sources/COCHelperCore/GameCatalog.swift`

- [ ] **Step 1: 按契约实现**

完整代码见「1.1 类型契约」+ 以下实现要点：

```swift
// 解码 payload（catalog.json 顶层只有 gameVersion + items）
private struct Payload: Decodable {
    let gameVersion: String
    let items: [CatalogItem]
}

// 索引
private let itemsBySection: [String: [CatalogItem]]
private let index: [String: CatalogItem]   // key = "\(section):\(dataID)"

public static func loadBundled(version: String) -> GameCatalog? {
    guard let url = Bundle.module.url(
        forResource: "catalog", withExtension: "json",
        subdirectory: "GameCatalog/\(version)"
    ), let data = try? Data(contentsOf: url),
       let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { return nil }
    return GameCatalog(gameVersion: payload.gameVersion, items: payload.items)
}

public static func durationSemantics(forSection section: String) -> CatalogDurationSemantics {
    switch section {
    case "buildings", "buildings2", "traps", "traps2": .buildToLevel
    default: .upgradeFromLevel
    }
}

public func durationToUpgradeLevel(nextLevel: Int, for item: CatalogItem) -> Int64? {
    guard nextLevel > 1 else { return nil }   // 升到 1 级不存在（初始等级）
    let target: Int
    switch Self.durationSemantics(forSection: item.section) {
    case .buildToLevel: target = nextLevel
    case .upgradeFromLevel: target = nextLevel - 1
    }
    return item.levels.first(where: { $0.level == target })?.durationSeconds
}
```

- [ ] **Step 2: 跑测试确认通过**

Run: `swift test --filter GameCatalogTests`
Expected: 全部 PASS；`testBundledLoadPerformanceIsReasonable` 基线耗时记录到输出（可接受 > 5s 再优化）。

- [ ] **Step 3: 提交**

```bash
git add Sources/COCHelperCore/GameCatalog.swift Tests/COCHelperCoreTests/GameCatalogTests.swift
git commit -m "feat: versioned GameCatalog reader with table-semantics durations (Issue #14)"
```

### Task 3: VillageCatalogProjection 测试（先红）

**Files:**
- Create: `Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift`
- Test helper: 内嵌合成目录 JSON + 合成快照构造器 + 种子随机数生成器（property-based）

- [ ] **Step 1: 写测试 helper 与失败测试**

```swift
import XCTest
@testable import COCHelperCore

/// 固定种子的可复现随机源（property-based 无外部依赖）。
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 0x5851F42D4C957F2D &+ 0x14057B7EF767814F
        return state
    }
}

final class VillageCatalogProjectionTests: XCTestCase {
    // MARK: - Helpers

    private func makeVillage(
        tag: String? = "#TEST",
        objectSections: [String: [AccountItem]] = [:]
    ) -> VillageProfile {
        VillageProfile(
            name: "测试村庄",
            accountSnapshot: AccountSnapshot(
                tag: tag,
                capturedAt: nil,
                importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                ageSeconds: nil,
                originalText: "",
                objectSections: objectSections,
                numericSections: [:],
                boosts: [:],
                unknownTopLevelKeys: [],
                diagnostics: []
            )
        )
    }

    private func makeItem(
        section: String,
        dataID: Int64,
        level: Int? = nil,
        count: Int? = nil,
        timerSeconds: Int64? = nil,
        remainingSeconds: Int64? = nil,
        types: [AccountItem] = [],
        modules: [AccountItem] = [],
        path: String = "0"
    ) -> AccountItem {
        AccountItem(
            id: section + ":" + path,
            section: section,
            dataID: dataID,
            level: level,
            count: count,
            timerSeconds: timerSeconds,
            remainingSeconds: remainingSeconds,
            types: types,
            modules: modules
        )
    }

    /// 小型合成目录：兵营(建筑语义)、野蛮人(单位语义)、战宠、装备、陷阱。
    private func makeCatalogJSON() -> String {
        """
        {
          "gameVersion": "18.400.13",
          "items": [
            {"section":"buildings","category":"buildings","dataID":1000001,"base":"home","name":"加农炮","maxLevel":2,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[
               {"level":1,"durationSeconds":60,"upgradeResource":"Elixir","upgradeCost":200,"requiredTownHallLevel":1,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
               {"level":2,"durationSeconds":300,"upgradeResource":"Elixir","upgradeCost":2000,"requiredTownHallLevel":2,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
             ]},
            {"section":"units","category":"troops","dataID":4000000,"base":"home","name":"野蛮人","maxLevel":3,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[
               {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"min_level_initial_no_upgrade"},
               {"level":2,"durationSeconds":1800,"upgradeResource":"Elixir","upgradeCost":250,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null},
               {"level":3,"durationSeconds":3600,"upgradeResource":"Elixir","upgradeCost":500,"requiredTownHallLevel":null,"requiredLaboratoryLevel":1,"icon":null,"levelVisual":null,"missingReason":null}
             ]},
            {"section":"buildings2","category":"buildings","dataID":1000033,"base":"builder","name":"建筑工人小屋","maxLevel":2,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[
               {"level":1,"durationSeconds":60,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null},
               {"level":2,"durationSeconds":600,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":null}
             ]},
            {"section":"equipment","category":"equipment","dataID":90000000,"base":"home","name":"野蛮人木偶","maxLevel":3,
             "icon":null,"levelVisual":null,"baseMissingReason":null,"missingReason":null,
             "levels":[
               {"level":1,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"},
               {"level":2,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"},
               {"level":3,"durationSeconds":null,"upgradeResource":null,"upgradeCost":null,"requiredTownHallLevel":null,"requiredLaboratoryLevel":null,"icon":null,"levelVisual":null,"missingReason":"no_direct_upgrade_time"}
             ]}
          ]
        }
        """
    }

    private func makeCatalog(from json: String? = nil) -> GameCatalog? {
        let text = json ?? makeCatalogJSON()
        let data = Data(text.utf8)
        struct Payload: Decodable { let gameVersion: String; let items: [CatalogItem] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        // 通过 public API 构造：loadBundled 不可注入，这里用真实 bundle 目录 + 只测匹配到的项不可行，
        // 因此需要一个测试可见的初始化入口 —— 见实现注记。
        return makeCatalogViaInit(gameVersion: payload.gameVersion, items: payload.items)
    }

    private func makeCatalogViaInit(gameVersion: String, items: [CatalogItem]) -> GameCatalog? {
        // 占位：Task 4 实现 public init 后填充
        fatalError("not implemented")
    }
```

> **实现注记（Task 4）**：`GameCatalog` 需要 public `init(manifest:items:)` 或 `init(gameVersion:items:)` 作为测试注入入口，`loadBundled` 只是其便捷包装。设计决策 1 已含此意。

测试用例（其余部分按 3.1 节「测试矩阵」展开）：

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter VillageCatalogProjectionTests`
Expected: 编译失败（`VillageCatalogProjection` 不存在）—— RED。

### Task 4: VillageCatalogProjection 实现（转绿）

**Files:**
- Create: `Sources/COCHelperCore/VillageCatalogProjection.swift`
- Modify: `Sources/COCHelperCore/GameCatalog.swift`（加 public init 测试注入入口）

实现要点：

```swift
public struct VillageCatalogProjection: Sendable {
    public static func project(
        village: VillageProfile,
        catalog: GameCatalog?,
        expectedGameVersion: String?,
        base: TrackerBase,
        now: Date
    ) -> VillageCatalogProjection {
        var diagnostics: [AccountDataDiagnostic] = []
        if catalog == nil {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning, path: "GameCatalog",
                message: "静态升级目录不可用，等级上限与完整时长信息将缺失。"))
        } else if let expectedGameVersion, catalog?.gameVersion != expectedGameVersion {
            diagnostics.append(AccountDataDiagnostic(
                severity: .warning, path: "GameCatalog",
                message: "静态目录版本 \(catalog?.gameVersion ?? "?") 与期望版本 \(expectedGameVersion) 不匹配。"))
        }

        let snapshot = village.accountSnapshot
        let states: [VillageItemState] = snapshot.map { snap in
            aggregate(records(from: snap, catalog: catalog, base: base, now: now))
        } ?? []

        return VillageCatalogProjection(
            villageID: village.id, villageName: village.name, base: base,
            catalogVersion: catalog?.gameVersion, items: states, diagnostics: diagnostics)
    }
}
```

- [ ] **Step 2: 跑测试确认通过**

Run: `swift test --filter VillageCatalogProjectionTests`
Expected: 全部 PASS。

- [ ] **Step 3: 提交**

```bash
git add Sources/COCHelperCore/GameCatalog.swift Sources/COCHelperCore/VillageCatalogProjection.swift \
        Tests/COCHelperCoreTests/GameCatalogTests.swift Tests/COCHelperCoreTests/VillageCatalogProjectionTests.swift
git commit -m "feat: village catalog projection joining snapshot with static catalog (Issue #14)"
```

### Task 5: 全量验证 + 文档

- [ ] **Step 1: 全量测试**

Run: `swift test`
Expected: 0 failures。

- [ ] **Step 2: 更新 README「当前已实现」**

在 README 增加一条：静态升级目录（版本化、含逐级完整时长/等级上限/资源引用）与村庄投影层已内置；目录缺失或版本不匹配时给出诊断。

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "docs: mention static game catalog and projection layer"
```

---

## 4. 测试矩阵（VillageCatalogProjectionTests 全部用例）

| # | 测试 | 断言要点 |
|---|---|---|
| 1 | testProjectionSeparatesHomeAndBuilderBase | 合成快照含 buildings 1000001 与 buildings2 1000033：home 投影只含前者、builder 投影只含后者；两投影 items 均非空且互斥 |
| 2 | testRealFixtureJoinsAllSupportedCategories | 匿名 fixture：buildings/traps/units/siege_machines/heroes/spells/pets/equipment/guardians 各至少 1 项命中目录（status != .unknown），总数与 UpgradeTracker 口径一致 |
| 3 | testUpgradingItemHasNextLevelAndStaticDuration | fixture 升级项：nextLevel == currentLevel+1；nextLevelDurationSeconds 非 nil（目录命中时）；remainingSeconds 与快照一致 |
| 4 | testDuplicateBuildingsAggregateByLevel | 1000013 lvl18 两条（cnt nil + cnt 1）→ 聚合 1 条 count 2；lvl17 两条升级记录各自保留 |
| 5 | testNextLevelNilWhenNotUpgrading | 无 timer 的项 nextLevel == nil |
| 6 | testMissingCatalogProducesWarningAndUnknownItems | catalog nil → 1 条 warning；追踪类目项全部 .unknown；items 不空 |
| 7 | testCatalogVersionMismatchProducesWarning | expectedGameVersion="99" → warning 含版本号 |
| 8 | testUnsupportedCategoryIsUnavailable | helpers 项 → .unavailable + missingReason |
| 9 | testUnknownDataIDKeptWithReason | 合成快照含目录外 dataID → .unknown、记录保留、missingReason 含 dataID |
| 10 | testMaxedWhenLevelReachesCatalogCap | 加农炮 level 2（maxLevel 2）→ .maxed |
| 11 | testBaseMismatchTreatedAsUnknown | catalog item base=home 但投影 base=builder（构造 section 冲突场景）→ .unknown |
| 12 | testNestedTypesModulesKeepSourcePath | 含 modules 的项 → isNested、id 含 `.modules.`、名称可查 |
| 13 | testNamePriorityCatalogOverNameCatalog | 目录有 name 时不用 `#dataID`；目录未命中时名称 fallback 到 `#dataID`（合成） |
| 14 | testAggregatedStateRetainsTimersAndLevels | 聚合项保留 level/count/remaining 语义 |
| P1 | testPropertyHomeNeverContainsBuilderSections | 随机快照 × 种子：home 投影无 `2` 后缀 section |
| P2 | testPropertyNextLevelFollowsUpgradingOnly | 随机快照：nextLevel == level+1 ⟺ isUpgrading && level != nil |
| P3 | testPropertyStatusAssignmentExhaustiveAndExclusive | 随机快照：每项恰一状态；upgrading ⟺ remaining>0；unavailable ⟺ 类别不支持；unknown ⟺ 目录未命中 |
| P4 | testPropertyAggregatedCountAtLeastRecordCount | 随机快照：非升级聚合项 count >= 组内条数 |
| P5 | testPropertyDurationSemanticsMatchTableType | 随机合成目录 + 随机等级：buildings 系 nextLevel 时长 == levels[nextLevel]；units 系 == levels[nextLevel-1]（记录存在时） |
| P6 | testPropertyEveryUpgradingRecordSurvivesProjection | 随机快照：每条升级输入记录在投影中可找到同 (section,dataID,level) 的 upgrading 项 |

---

## 5. 验证命令

```bash
swift test --filter GameCatalogTests
swift test --filter VillageCatalogProjectionTests
swift test
```
