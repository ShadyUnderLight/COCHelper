# Issue #41 手动部落跟踪 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 支持用户凭部落 Tag 手动添加/持久化/切换/刷新部落的 4 类官方数据，与村庄入口共享同一按 Tag 状态层。

**Architecture:** Core 层新增 `TrackedClanProfile` + `ClanTagNormalizer` + `TrackedClanStore`（逐条容错持久化，仿 `OfficialStateStore`）；AppModel 新增 trackedClans 管理与 6 个按 tag 刷新 API（村庄版转发）；4 张部落卡片改为"可选 villageID + 可选注入 clanTag"双入口（方案 A，村庄调用点零改动）；ContentView 侧边栏新增"部落"Section。

**Tech Stack:** Swift 6.0 / SwiftUI / macOS 14 / XCTest（手写 property-based 测试，无第三方依赖）

---

## 类型契约（SDD 输出，全任务共用）

```swift
// Core: Sources/COCHelperCore/TrackedClanProfile.swift
public struct TrackedClanProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String { clanTag }
    public let clanTag: String          // 规范化 tag，主键
    public var displayName: String?     // 用户备注，可空
    public var createdAt: Date
}

// Core: Sources/COCHelperCore/TrackedClanProfile.swift 内
public enum ClanTagNormalizer {
    /// 规范化：trim + uppercase + isValid 校验；非法返回 nil
    /// （缺 #、只有 #、空、含非法字符 → nil；不自动补 #，issue 要求拒绝缺 # 输入）
    public static func normalize(_ raw: String?) -> String?
}

// Core: Sources/COCHelperCore/TrackedClanStore.swift
public struct TrackedClanStore: Codable, Hashable, Sendable {
    public private(set) var profiles: [TrackedClanProfile]  // 保序数组
    public init(profiles: [TrackedClanProfile] = [])
    // Codable：unkeyedContainer + JSONSkipper 逐条容错（仿 OfficialStateStore）
    // 编码保持数组顺序；upsert 按 clanTag 去重（已存在则替换）
}

// AppModel 新增（Sources/COCHelperApp/AppModel.swift）
@Published public private(set) var trackedClans: [TrackedClanProfile]
private static let trackedClansStorageKey = "coc-helper.tracked-clans.v1"

public enum TrackedClanAddError: Equatable { case invalidTag, duplicate }

public func addTrackedClan(rawTag: String?, displayName: String?) -> Result<TrackedClanProfile, TrackedClanAddError>
public func removeTrackedClan(tag: String)
public func isCurrentVillageClan(_ tag: String) -> Bool   // 当前选中村庄归属标识
public func trackedClanRefreshStatus(_ tag: String) -> TrackedClanRefreshStatus?  // 可选，UI 用

// 按 tag 刷新 API（6 个，村庄版转发）
public func refreshClan(tag: String)
public func refreshClanWar(tag: String)
public func refreshWarLog(tag: String, force: Bool = false)
public func loadMoreWarLog(tag: String)
public func refreshCapitalRaid(tag: String)
public func loadMoreCapitalRaid(tag: String)

// 卡片双入口（方案 A，以 ClanCardView 为例）
struct ClanCardView: View {
    @EnvironmentObject private var model: AppModel
    let villageID: UUID?
    let injectedClanTag: String?
    init(villageID: UUID? = nil, clanTag: String? = nil)
    private var isManualEntry: Bool { injectedClanTag != nil }
    private var resolvedClanTag: String? { injectedClanTag ?? villageID.flatMap { model.officialClanTag(for: $0) } }
}
// 手动部落入口：ClanCardView(clanTag: tag)（villageID 默认 nil）
// 村庄入口：ClanCardView(villageID: villageID)（现有调用零改动）
```

---

### Task 1: Core — TrackedClanProfile + ClanTagNormalizer（TDD）

**Files:**
- Create: `Sources/COCHelperCore/TrackedClanProfile.swift`
- Test: `Tests/COCHelperCoreTests/TrackedClanProfileTests.swift`

- [ ] **Step 1: 写失败测试** `TrackedClanProfileTests.swift`：

```swift
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

    func testNormalizeRejectsLowercaseAfterPrefixPreservedSemantics() {
        // 小写必须被转大写后接受；混合非法字符拒绝
        XCTAssertEqual(ClanTagNormalizer.normalize("#AbC1"), "#ABC1")
    }

    // MARK: - property-based（种子化可复现）

    func testNormalizePropertyIsIdempotentForAllValidTags() {
        let seed = UInt64(42)
        let validChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var rng = SeededGenerator(seed: seed)
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
        var rng = SeededGenerator(seed: seed)
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
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("displayName") == false) // displayName 为 nil 时应省略或存 null，此处只验证 round-trip
        let decoded = try JSONDecoder().decode(TrackedClanProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testProfileIDIsClanTag() {
        let p = TrackedClanProfile(clanTag: "#TAG1", displayName: nil, createdAt: Date())
        XCTAssertEqual(p.id, "#TAG1")
    }
}

/// 可复现的种子化随机源（property-based 测试用）。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        // SplitMix64：仅测试用，确定性要求即可
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter TrackedClanProfileTests`
Expected: FAIL（`cannot find 'ClanTagNormalizer' in scope` 等编译错误）

- [ ] **Step 3: 实现** `Sources/COCHelperCore/TrackedClanProfile.swift`：

```swift
import Foundation

/// 用户手动跟踪的部落档案（Issue #41）。
///
/// 与村庄档案（`VillageProfile`）、玩家快照（`AccountSnapshot`）完全独立；
/// API 数据不写入本档案——部落数据仍在按 Tag 共享的 `clanStates` 等状态层。
/// `clanTag` 是规范化后的唯一主键（`Identifiable.id`），重复添加由
/// `TrackedClanStore` 负责去重。
public struct TrackedClanProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String { clanTag }
    /// 规范化部落 Tag（trim + 大写 + `#` 前缀校验），稳定身份。
    public let clanTag: String
    /// 用户自定义显示名称/备注，可为 nil。
    public var displayName: String?
    /// 创建时间（本地）。
    public var createdAt: Date

    public init(clanTag: String, displayName: String?, createdAt: Date) {
        self.clanTag = clanTag
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

/// 官方部落 Tag 的规范化与校验（Issue #41）。
///
/// 字符集与玩家 Tag 相同（`#` + 大写 `A-Z` + `0-9`），但语义独立：
/// - 输入先 trim 首尾空白；
/// - 转大写（官方 Tag 不区分大小写，规范化避免同一部落两个 key）；
/// - 缺少 `#` 前缀、只有 `#`、空值或含非法字符一律拒绝（不自动补 `#`）；
/// - 成功结果保证 `OfficialPlayerTagValidator.isValid` 为 true。
public enum ClanTagNormalizer {
    /// 规范化部落 Tag；非法输入返回 nil。
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let uppercased = trimmed.uppercased()
        guard OfficialPlayerTagValidator.isValid(uppercased) else { return nil }
        return uppercased
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter TrackedClanProfileTests`
Expected: PASS（全部）

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperCore/TrackedClanProfile.swift Tests/COCHelperCoreTests/TrackedClanProfileTests.swift
git commit -m "feat: TrackedClanProfile 与 ClanTagNormalizer（Issue #41 手动部落档案模型）"
```

---

### Task 2: Core — TrackedClanStore 持久化容器（TDD）

**Files:**
- Create: `Sources/COCHelperCore/TrackedClanStore.swift`
- Test: `Tests/COCHelperCoreTests/TrackedClanStoreTests.swift`

- [ ] **Step 1: 写失败测试** `TrackedClanStoreTests.swift`：

```swift
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
        // 模拟：第一条合法、第二条损坏、第三条合法
        let good1 = profile("#AAA")
        let good2 = profile("#CCC")
        let good1Data = try JSONEncoder().encode(good1)
        let good2Data = try JSONEncoder().encode(good2)
        let corrupt = Data("{\"clanTag\": 123, ".utf8) // 类型错误 → 单条解码失败
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

    func testUpsertAppendsNewTag() {
        var store = TrackedClanStore(profiles: [profile("#AAA")])
        store.upsert(profile("#BBB"))
        XCTAssertEqual(store.profiles.map(\.clanTag), ["#AAA", "#BBB"])
    }

    func testRemoveByTag() {
        var store = TrackedClanStore(profiles: [profile("#AAA"), profile("#BBB")])
        store.remove(tag: "#AAA")
        XCTAssertEqual(store.profiles.map(\.clanTag), ["#BBB"])
        store.remove(tag: "#NOT_EXIST") // 幂等
        XCTAssertEqual(store.profiles.map(\.clanTag), ["#BBB"])
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter TrackedClanStoreTests`
Expected: FAIL（编译错误：类型不存在）

- [ ] **Step 3: 实现** `Sources/COCHelperCore/TrackedClanStore.swift`：

```swift
import Foundation

/// 手动跟踪部落档案的持久化容器（Issue #41）。
///
/// 存储格式：`TrackedClanProfile` 数组，**保持添加顺序**（UI 列表按序显示）。
/// 容错契约（仿 `OfficialStateStore`）：
/// - 解码逐条容错：一条损坏只丢弃该条，不株连整库；
/// - 坏条目用 `JSONSkipper` 强制推进解码游标；
/// - 整体损坏时抛错（调用方按空库处理）。
/// `clanTag` 是唯一键：`upsert` 已存在则替换、不存在则追加；`remove` 幂等。
public struct TrackedClanStore: Codable, Hashable, Sendable {
    public private(set) var profiles: [TrackedClanProfile]

    public init(profiles: [TrackedClanProfile] = []) {
        self.profiles = profiles
    }

    /// 按 tag 替换或追加（保持原位置；不存在时追加到末尾）。
    public mutating func upsert(_ profile: TrackedClanProfile) {
        if let index = profiles.firstIndex(where: { $0.clanTag == profile.clanTag }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// 删除指定 tag（幂等）。
    public mutating func remove(tag: String) {
        profiles.removeAll { $0.clanTag == tag }
    }

    // MARK: - Codable（逐条容错）

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [TrackedClanProfile] = []
        var guardCounter = 0
        let maxEntries = 10_000
        while !container.isAtEnd && guardCounter < maxEntries {
            guardCounter += 1
            if let entry = try? container.decode(TrackedClanProfile.self) {
                decoded.append(entry)
            } else {
                _ = try? container.decode(JSONSkipper.self)
            }
        }
        profiles = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for profile in profiles {
            try container.encode(profile)
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter TrackedClanStoreTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperCore/TrackedClanStore.swift Tests/COCHelperCoreTests/TrackedClanStoreTests.swift
git commit -m "feat: TrackedClanStore 逐条容错持久化容器（Issue #41）"
```

---

### Task 3: AppModel — trackedClans 管理（TDD）

**Files:**
- Modify: `Sources/COCHelperApp/AppModel.swift`
- Test: `Tests/COCHelperCoreTests/AppModelTrackedClansTests.swift`

- [ ] **Step 1: 写失败测试** `AppModelTrackedClansTests.swift`（仿 AppModelTests 的 setUp/tearDown 与 makeModel helper；本任务只需 defaults，不联网）：

```swift
import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

final class AppModelTrackedClansTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelTrackedClansTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    private func makeModel() throws -> AppModel {
        // 全部依赖默认构造（不走网络）；MockURLProtocol 不设置 handler。
        AppModel(defaults: defaults)
    }

    @MainActor
    func testAddTrackedClanSuccess() throws {
        let model = try makeModel()
        let result = model.addTrackedClan(rawTag: "  #2qjq8j88  ", displayName: "我的部落")
        let profile = try XCTUnwrap(result.getSuccess())
        XCTAssertEqual(profile.clanTag, "#2QJQ8J88")
        XCTAssertEqual(profile.displayName, "我的部落")
        XCTAssertEqual(model.trackedClans.count, 1)
    }

    @MainActor
    func testAddTrackedClanInvalidTag() throws {
        let model = try makeModel()
        for bad in ["", "   ", "#", "2QJQ8J88", "#abc-def", nil] {
            let result = model.addTrackedClan(rawTag: bad, displayName: nil)
            guard case .failure(.invalidTag) = result else {
                return XCTFail("\(String(describing: bad)) 应报 invalidTag")
            }
        }
        XCTAssertTrue(model.trackedClans.isEmpty, "非法输入不得产生档案")
    }

    @MainActor
    func testAddTrackedClanDuplicate() throws {
        let model = try makeModel()
        XCTAssertNotNil(model.addTrackedClan(rawTag: "#ABC123", displayName: nil).getSuccess())
        let second = model.addTrackedClan(rawTag: "  #abc123  ", displayName: "别的名字")
        guard case .failure(.duplicate) = second else {
            return XCTFail("重复 tag 应报 duplicate")
        }
        XCTAssertEqual(model.trackedClans.count, 1, "重复添加不得产生重复档案")
        XCTAssertEqual(model.trackedClans[0].displayName, nil, "重复添加不得覆盖原档案")
    }

    @MainActor
    func testTrackedClansPersistAcrossReload() throws {
        let model = try makeModel()
        _ = model.addTrackedClan(rawTag: "#AAA111", displayName: "甲")
        _ = model.addTrackedClan(rawTag: "#BBB222", displayName: nil)
        let reloaded = AppModel(defaults: defaults)
        XCTAssertEqual(reloaded.trackedClans.map(\.clanTag), ["#AAA111", "#BBB222"])
        XCTAssertEqual(reloaded.trackedClans[0].displayName, "甲")
    }

    @MainActor
    func testTrackedClansEmptyWhenNoStorage() throws {
        let model = try makeModel()
        XCTAssertTrue(model.trackedClans.isEmpty, "旧版本无该 key 必须正常启动为空")
    }

    @MainActor
    func testRemoveTrackedClanKeepsSharedClanStateCache() throws {
        let model = try makeModel()
        _ = model.addTrackedClan(rawTag: "#CCC333", displayName: nil)
        // 模拟已有共享 API 缓存（村庄入口刷新留下的 last-good）
        model.seedClanStateForTesting(tag: "#CCC333")  // 测试辅助，见 Step 3
        model.removeTrackedClan(tag: "#CCC333")
        XCTAssertTrue(model.trackedClans.isEmpty)
        XCTAssertNotNil(model.clanState(for: "#CCC333"), "删除跟踪关系必须保留按 Tag 的 API 缓存")
    }

    @MainActor
    func testRemoveTrackedClanIdempotent() throws {
        let model = try makeModel()
        _ = model.addTrackedClan(rawTag: "#DDD444", displayName: nil)
        model.removeTrackedClan(tag: "#DDD444")
        model.removeTrackedClan(tag: "#DDD444") // 不崩溃
        model.removeTrackedClan(tag: "#NOT_EXIST")
        XCTAssertTrue(model.trackedClans.isEmpty)
    }

    @MainActor
    func testIsCurrentVillageClan() throws {
        let model = try makeModel()
        // 无玩家快照时 currentVillageClanTag == nil
        XCTAssertFalse(model.isCurrentVillageClan("#XXX999"))
    }
}

private extension Result {
    func getSuccess() -> Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AppModelTrackedClansTests`
Expected: FAIL（编译错误：addTrackedClan/trackedClans 不存在）

- [ ] **Step 3: 实现 AppModel 变更**

在 `Sources/COCHelperApp/AppModel.swift` 中：

a) 属性区（`@Published public private(set) var clanCapitalStates...` 之后）新增：

```swift
    /// 手动跟踪的部落档案（Issue #41）：独立于村庄档案与玩家快照。
    /// 只存档案元数据（tag/备注/创建时间），部落 API 数据仍在
    /// clanStates 等按 Tag 共享状态层。
    @Published public private(set) var trackedClans: [TrackedClanProfile] = []
```

b) 存储 key 区（`private static let clanCapitalStatesStorageKey` 之后）新增：

```swift
    private static let trackedClansStorageKey = "coc-helper.tracked-clans.v1"
```

c) init 中（`clanCapitalStates = Self.loadClanCapitalStates(from: defaults)` 之后）新增：

```swift
        trackedClans = Self.loadTrackedClans(from: defaults)
```

d) 新增公开 API（放在 `// MARK: - 手动跟踪部落` 新 section）：

```swift
    // MARK: - 手动跟踪部落（Issue #41）

    public enum TrackedClanAddError: Equatable {
        case invalidTag
        case duplicate
    }

    /// 添加手动跟踪部落：只做本地校验与保存，**不触发任何网络请求**。
    /// Tag 规范化失败 → .invalidTag；规范化后已存在 → .duplicate（不覆盖原档案）。
    @discardableResult
    public func addTrackedClan(rawTag: String?, displayName: String?) -> Result<TrackedClanProfile, TrackedClanAddError> {
        guard let tag = ClanTagNormalizer.normalize(rawTag) else { return .failure(.invalidTag) }
        guard !trackedClans.contains(where: { $0.clanTag == tag }) else { return .failure(.duplicate) }
        let profile = TrackedClanProfile(
            clanTag: tag,
            displayName: displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil,
            createdAt: Date()
        )
        trackedClans.append(profile)
        persistTrackedClans()
        return .success(profile)
    }

    /// 删除跟踪关系：**保留**按 Tag 的共享 API 缓存（clanStates 等），
    /// 误删后重新添加不丢失历史数据。
    public func removeTrackedClan(tag: String) {
        guard trackedClans.contains(where: { $0.clanTag == tag }) else { return }
        trackedClans.removeAll { $0.clanTag == tag }
        persistTrackedClans()
    }

    /// 该 Tag 是否为**当前选中村庄**所属部落（列表"当前村庄所属"标识）。
    /// 只做标识展示，不改变手动档案身份。
    public func isCurrentVillageClan(_ tag: String) -> Bool {
        currentVillageClanTag == tag
    }

    private func persistTrackedClans() {
        guard let data = try? JSONEncoder().encode(TrackedClanStore(profiles: trackedClans)) else { return }
        defaults.set(data, forKey: Self.trackedClansStorageKey)
    }

    private static func loadTrackedClans(from defaults: UserDefaults) -> [TrackedClanProfile] {
        guard let data = defaults.data(forKey: Self.trackedClansStorageKey),
              let store = try? JSONDecoder().decode(TrackedClanStore.self, from: data) else {
            return []
        }
        return store.profiles
    }
```

e) 测试辅助（仅 @testable 测试用，放文件末尾）：

```swift
    /// 测试辅助：为指定 Tag 注入共享部落缓存（验证删除跟踪关系保留缓存）。
    /// 仅测试模块可见（public + @testable），生产路径不调用。
    public func seedClanStateForTesting(tag: String) {
        clanStates[tag] = ClanAPIState(
            status: .success,
            lastGood: OfficialClanSnapshot(
                tag: tag, name: "测试部落", clanLevel: 1, members: 1,
                type: nil, requiredTrophies: nil, warWins: nil, warLosses: nil,
                warTies: nil, warWinStreak: nil, isWarLogPublic: nil,
                badgeUrls: nil, clanCapital: nil, unrecognizedKeys: []
            ),
            fetchedAt: Date(), lastErrorReason: nil, parserVersion: ClanAPIState.currentParserVersion
        )
    }
```

（若 `OfficialClanSnapshot` 的成员签名与测试不符，以 `Sources/COCHelperCore/ClanModels.swift` 实际定义为准调整构造参数。）

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter AppModelTrackedClansTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperApp/AppModel.swift Tests/COCHelperCoreTests/AppModelTrackedClansTests.swift
git commit -m "feat: AppModel 手动部落档案管理与持久化（Issue #41）"
```

---

### Task 4: AppModel — 按 Tag 刷新 API（TDD）

**Files:**
- Modify: `Sources/COCHelperApp/AppModel.swift`
- Test: `Tests/COCHelperCoreTests/AppModelTrackedClanRefreshTests.swift`

- [ ] **Step 1: 写失败测试**（仿 AppModelTests 的 TagRecorder + MockURLProtocol + makeModel helper；clan 端点返回合法 `OfficialClanSnapshot` JSON fixture，参考 `Tests/COCHelperCoreTests/Fixtures/` 下已有 clan fixture 的 JSON 结构）：

```swift
import Foundation
import XCTest
@testable import COCHelperApp
@testable import COCHelperCore

final class AppModelTrackedClanRefreshTests: XCTestCase {
    private final class TagRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var tags: [String] = []
        func record(_ tag: String) {
            lock.lock(); tags.append(tag); lock.unlock()
        }
        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }; return tags
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelTrackedClanRefreshTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 可用的部落档案 JSON（字段以 Fixtures 实际为准；本测试只用 clan 端点）。
    private func clanJSON(tag: String) -> Data {
        Data("""
        {"tag":"\(tag)","name":"测试部落","clanLevel":3,"members":5,
         "type":"open","requiredTrophies":0,"warWins":10,"warLosses":2,
         "warTies":0,"warWinStreak":1,"isWarLogPublic":true,"badgeUrls":{}}
        """.utf8)
    }

    @MainActor
    private func makeModel(clanHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) throws -> AppModel {
        let recorder = TagRecorder()
        // 需要可注入的 refresher 路径：仿 AppModelTests.makeModel 构建
        let client = CoAPIClient { _ in "#TESTTOKEN" }
        let clanRefresher = ClanRefresher(client: client)
        // 用 MockURLProtocol 接管 URLSession
        MockURLProtocol.handler = { request in
            recorder.record(request.url?.absoluteString ?? "")
            return try clanHandler(request)
        }
        return AppModel(defaults: defaults, clanRefresher: clanRefresher)
    }
    // 注：ClanRefresher 内部 CoAPIClient 的 URLSession 是否走 MockURLProtocol，
    // 以 AppModelTests 现有模式为准——若 AppModelTests 通过注入
    // URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: nil)
    // 且 configuration.protocolClasses = [MockURLProtocol.self] 的方式建立
    // MockURLProtocol，则必须复刻该构造（见 AppModelTests.makeModel 的 client 构造）。

    @MainActor
    func testRefreshClanByTagRequestsThatTag() async throws {
        let recorder = TagRecorder()
        _ = recorder // 通过 handler 断言
        var requestedTag: String?
        let model = try makeModel(clanHandler: { request in
            requestedTag = request.url?.path.components(separatedBy: "/").last
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.clanJSON(tag: "#ABC123"))
        })
        model.refreshClan(tag: "#ABC123")
        // 等待异步完成
        for _ in 0..<100 where model.clanState(for: "#ABC123") == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let state = try XCTUnwrap(model.clanState(for: "#ABC123"))
        XCTAssertEqual(state.status, .success)
        XCTAssertEqual(requestedTag, "#ABC123")
    }

    @MainActor
    func testManualAndVillageEntryShareState() async throws {
        // 同一 tag：村庄入口（villageID 版）与手动入口（tag 版）只触发一次请求
        var requestCount = 0
        let model = try makeModel(clanHandler: { request in
            requestCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.clanJSON(tag: "#ABC123"))
        })
        model.refreshClan(tag: "#ABC123")
        for _ in 0..<100 where model.clanState(for: "#ABC123") == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let countAfterFirst = requestCount
        model.refreshClan(tag: "#ABC123") // 重复刷新同一 tag
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(requestCount, countAfterFirst + 1, "手动重复刷新允许再次请求（无冷却），但两个入口共享同一状态")
        XCTAssertEqual(model.clanState(for: "#ABC123")?.lastGood?.tag, "#ABC123")
    }

    @MainActor
    func testRefreshClanByTagWhileBusyQueues() async throws {
        // 占用时排队补跑语义：与 refreshClan(villageID:) 一致
        let model = try makeModel(clanHandler: { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.clanJSON(tag: "#QUEUE99"))
        })
        model.refreshClan(tag: "#QUEUE99")
        model.refreshClan(tag: "#QUEUE99") // 第二个请求应排队而非丢弃
        for _ in 0..<200 where model.clanState(for: "#QUEUE99") == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.clanState(for: "#QUEUE99")?.status, .success)
    }

    @MainActor
    func testRefreshWarLogByTag() async throws {
        // warlog 端点分页响应（结构参考 Fixtures/ClanWarLog fixtures）
        let model = try makeModel(clanHandler: { _ in
            (HTTPURLResponse(url: URL(string: "https://api.clashofclans.com/v1/clans/%23ABC/warlog")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"items\":[]}".utf8))
        })
        model.refreshWarLog(tag: "#ABC123")
        for _ in 0..<100 where model.warLogState(for: "#ABC123") == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(model.warLogState(for: "#ABC123"))
    }
}
```

**实现者注意**：以上测试的 URL 断言/JSON 结构必须与实际 `CoAPIClient` 与 Fixtures 对齐；若测试暴露了与现有约定不符的细节，以现有 `CoAPIFetchClanTests`、`CoAPIFetchClanWarTests`、`ClanRefresherTests`、`AppModelTests` 的 fixture 与断言模式为准修正测试（不得放宽断言语义）。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AppModelTrackedClanRefreshTests`
Expected: FAIL（编译错误：refreshClan(tag:) 不存在）

- [ ] **Step 3: 实现 AppModel 按 Tag 刷新 API**

在 AppModel 中新增（沿用现有防重入/队列/同步段捕获模式）：

```swift
    // MARK: - 按 Tag 刷新入口（Issue #41 手动部落）

    /// 按显式 Tag 刷新部落档案（手动部落入口；村庄入口转发）。
    /// 同一 Tag 与村庄入口共享状态与防重入守卫，不产生重复请求。
    public func refreshClan(tag: String) {
        if isRefreshingClanData {
            pendingClanRefreshAll = true
            return
        }
        performClanRefresh(villageClanTags: [tag])
    }
```

同时把现有 `refreshClan(villageID:)` 改为转发（保持行为不变）：

```swift
    public func refreshClan(villageID: UUID) {
        guard let tag = officialClanTag(for: villageID) else { return }
        refreshClan(tag: tag)
    }
```

其余 5 个按 Tag 入口（`refreshClanWar` / `refreshWarLog` / `loadMoreWarLog` / `refreshCapitalRaid` / `loadMoreCapitalRaid`）：

```swift
    /// 按显式 Tag 刷新当前战争（手动入口）。
    public func refreshClanWar(tag: String) {
        guard !isRefreshingClanWarData else { return }
        refreshingClanWarTags = [tag]
        let previous = clanWarStates
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshingClanWarTags.removeAll() }
            let refreshed = await self.clanWarRefresher.refreshClanWars(
                villageClanTags: [tag],
                previous: previous
            )
            self.clanWarStates = ClanWarStateStore(states: self.clanWarStates)
                .merging(refreshed).states
            self.persistClanWarStates()
        }
    }

    /// 按显式 Tag 刷新战争日志（手动入口；force 语义与村庄版一致）。
    public func refreshWarLog(tag: String, force: Bool = false) {
        guard !isRefreshingWarLogData else { return }
        if !force, isWarLogKnownNotPublic(for: tag) { return }
        refreshingWarLogTags = [tag]
        let client = clanLogClient
        let parserVersion = ClanWarLogAPIState.currentParserVersion
        let previous = clanWarLogStates[tag]
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshingWarLogTags.removeAll() }
            let state = await EndpointRefresher.fetchSingle(
                tag: tag, previous: previous, parserVersion: parserVersion
            ) { tag in
                OfficialWarLogPage(page: try await client.fetchWarLog(tag: tag))
            }
            self.clanWarLogStates[tag] = state
            self.persistClanWarLogStates()
        }
    }

    /// 按显式 Tag 战争日志加载更多（手动入口；合并去重 + 跨版本重建语义与村庄版一致）。
    public func loadMoreWarLog(tag: String) {
        guard !isRefreshingWarLogData else { return }
        guard let current = clanWarLogStates[tag],
              current.status == .success,
              let cursor = current.lastGood?.after else { return }
        refreshingWarLogTags = [tag]
        let client = clanLogClient
        let parserVersion = ClanWarLogAPIState.currentParserVersion
        let needsRebuild = current.parserVersion != parserVersion
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshingWarLogTags.removeAll() }
            let state = await EndpointRefresher.fetchSingle(
                tag: tag, previous: current, parserVersion: parserVersion
            ) { tag in
                if needsRebuild {
                    OfficialWarLogPage(page: try await client.fetchWarLog(tag: tag))
                } else {
                    OfficialWarLogPage(page: try await client.fetchWarLog(tag: tag, after: cursor))
                }
            }
            if state.status == .success,
               let fetched = state.lastGood,
               let existing = current.lastGood,
               !needsRebuild {
                var merged = state
                merged.lastGood = OfficialWarLogPage(
                    page: PaginationMerge.mergedPage(existing: existing.page, fetched: fetched.page)
                )
                self.clanWarLogStates[tag] = merged
            } else {
                self.clanWarLogStates[tag] = state
            }
            self.persistClanWarLogStates()
        }
    }

    /// 按显式 Tag 刷新部落资本赛季（手动入口）。
    public func refreshCapitalRaid(tag: String) {
        guard !isRefreshingCapitalData else { return }
        refreshingCapitalTags = [tag]
        let client = clanLogClient
        let parserVersion = ClanCapitalAPIState.currentParserVersion
        let previous = clanCapitalStates[tag]
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshingCapitalTags.removeAll() }
            let state = await EndpointRefresher.fetchSingle(
                tag: tag, previous: previous, parserVersion: parserVersion
            ) { tag in
                OfficialCapitalRaidPage(page: try await client.fetchCapitalRaidSeasons(tag: tag))
            }
            self.clanCapitalStates[tag] = state
            self.persistClanCapitalStates()
        }
    }

    /// 按显式 Tag 资本赛季加载更多（手动入口）。
    public func loadMoreCapitalRaid(tag: String) {
        guard !isRefreshingCapitalData else { return }
        guard let current = clanCapitalStates[tag],
              current.status == .success,
              let cursor = current.lastGood?.after else { return }
        refreshingCapitalTags = [tag]
        let client = clanLogClient
        let parserVersion = ClanCapitalAPIState.currentParserVersion
        let needsRebuild = current.parserVersion != parserVersion
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshingCapitalTags.removeAll() }
            let state = await EndpointRefresher.fetchSingle(
                tag: tag, previous: current, parserVersion: parserVersion
            ) { tag in
                if needsRebuild {
                    OfficialCapitalRaidPage(page: try await client.fetchCapitalRaidSeasons(tag: tag))
                } else {
                    OfficialCapitalRaidPage(page: try await client.fetchCapitalRaidSeasons(tag: tag, after: cursor))
                }
            }
            if state.status == .success,
               let fetched = state.lastGood,
               let existing = current.lastGood,
               !needsRebuild {
                var merged = state
                merged.lastGood = OfficialCapitalRaidPage(
                    page: PaginationMerge.mergedPage(existing: existing.page, fetched: fetched.page)
                )
                self.clanCapitalStates[tag] = merged
            } else {
                self.clanCapitalStates[tag] = state
            }
            self.persistClanCapitalStates()
        }
    }
```

现有 villageID 版本（`refreshClanWar(villageID:)` / `refreshWarLog(villageID:force:)` / `loadMoreWarLog(villageID:)` / `refreshCapitalRaid(villageID:)` / `loadMoreCapitalRaid(villageID:)`）改为转发 tag 版（`guard let tag = officialClanTag(for: villageID) else { return }` + 调 tag 版），`refreshCurrentClan`/`refreshCurrentClanWar`/`refreshCurrentWarLog`/`loadMoreCurrentWarLog`/`refreshCurrentCapitalRaid`/`loadMoreCurrentCapitalRaid` 兼容转发链不变。**注意**：`refreshClan(villageID:)` 原有"占用时 pendingClanRefreshAll 排队补跑"逻辑移动到 tag 版后语义等价（村庄转发即排队全量补跑，与现状一致）。

- [ ] **Step 4: 运行全部测试确认通过**

Run: `swift test`
Expected: PASS（422 + 新增全部通过；现有 AppModelTests 是转发行为回归闸门）

- [ ] **Step 5: 提交**

```bash
git add Sources/COCHelperApp/AppModel.swift Tests/COCHelperCoreTests/AppModelTrackedClanRefreshTests.swift
git commit -m "feat: AppModel 按 Tag 刷新入口（村庄版转发，Issue #41）"
```

---

### Task 5: UI — 侧边栏部落 Section + 详情页 + 卡片双入口

**Files:**
- Modify: `Sources/COCHelper/ContentView.swift`
- Create: `Sources/COCHelper/TrackedClanDetailView.swift`
- Modify: `Sources/COCHelper/ClanCardView.swift`、`ClanWarCardView.swift`、`WarLogCardView.swift`、`CapitalRaidCardView.swift`

- [ ] **Step 1: 先改造 4 张卡片为双入口（方案 A），编译验证村庄入口零改动**

以 `ClanCardView.swift` 为例，完整改动：

```swift
struct ClanCardView: View {
    @EnvironmentObject private var model: AppModel
    /// 本卡片数据来源的村庄（显式路由，不得读全局选中村庄）。
    /// 手动部落入口传 nil，并直接注入 `clanTag`。
    let villageID: UUID?
    /// 手动部落入口注入的部落 tag（村庄入口为 nil）。
    let injectedClanTag: String?

    init(villageID: UUID? = nil, clanTag: String? = nil) {
        self.villageID = villageID
        self.injectedClanTag = clanTag
    }

    /// 手动入口直接使用注入 tag；村庄入口从玩家快照派生。
    private var isManualEntry: Bool { injectedClanTag != nil }

    /// 本卡片部落归属 tag（nil = 无部落 / 从未成功抓取）。
    private var clanTag: String? {
        injectedClanTag ?? villageID.flatMap { model.officialClanTag(for: $0) }
    }

    /// 本卡片所属部落的共享状态（nil = 无部落 / 从未请求）。
    private var clanState: ClanAPIState? {
        guard let clanTag else { return nil }
        return model.clanState(for: clanTag)
    }
```

`statusContent` 状态分支改为（unknown/no-clan 仅村庄入口显示）：

```swift
    @ViewBuilder
    private var statusContent: some View {
        let statusUnknown = villageID.map { model.clanStatusUnknown(for: $0) } ?? false
        if !isManualEntry, statusUnknown {
            unknownClanState
        } else if !isManualEntry, clanTag == nil {
            noClanState
        } else if let clanTag, let state = clanState {
            statusLine(state)
            // ... 原有内容不变 ...
            Button {
                model.refreshClan(tag: clanTag)
            } label: { ... }
        } else if let clanTag {
            // 有 tag 但从未请求
            VStack { ... Button { model.refreshClan(tag: clanTag) } ... }
        }
    }
```

刷新按钮统一调 `model.refreshClan(tag: clanTag)`（原 `refreshClan(villageID:)` 行为等价，因村庄版已转发）。

其余 3 卡完全同构，改动点只有 4 处：
1. `let villageID: UUID` → `let villageID: UUID?` + `let injectedClanTag: String?` + 同款 init
2. `clanTag` 计算属性 → `injectedClanTag ?? villageID.flatMap { model.officialClanTag(for: $0) }` + `isManualEntry`
3. `statusContent` 首两分支加 `!isManualEntry` 门控（`model.clanStatusUnknown(for: villageID)` 改为 `villageID.map { model.clanStatusUnknown(for: $0) } ?? false`）
4. 刷新按钮 `model.refreshX(villageID: villageID)` → `model.refreshX(tag: clanTag)`（warLog 的 force 语义、loadMore 不变）

ClanWarCardView 的 `refreshButton(title:)` 内调用改 `model.refreshClanWar(tag: clanTag)`；WarLogCardView 的 3 处调用（force/普通/loadMore）改 tag 版；CapitalRaidCardView 的 2 处（refresh/loadMore）改 tag 版。

- [ ] **Step 2: 编译验证村庄入口零改动**

Run: `swift build`
Expected: 成功（VillageDetailView/ContentView 现有调用 `ClanCardView(villageID:)` 编译通过——UUID 自动转 UUID?）

- [ ] **Step 3: 新建 `Sources/COCHelper/TrackedClanDetailView.swift`**：

```swift
import SwiftUI
import COCHelperCore
import COCHelperApp

/// 手动跟踪部落的详情页（Issue #41）。
///
/// 数据全部来自按 Tag 共享状态层；与村庄详情页的 4 张卡片共用同一份
/// 缓存，不产生重复存储。刷新全部为显式按需（不自动轮询）。
struct TrackedClanDetailView: View {
    @EnvironmentObject private var model: AppModel
    let clanTag: String

    private var profile: TrackedClanProfile? {
        model.trackedClans.first { $0.clanTag == clanTag }
    }

    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ClanCardView(clanTag: clanTag)
                ClanWarCardView(clanTag: clanTag)
                WarLogCardView(clanTag: clanTag)
                CapitalRaidCardView(clanTag: clanTag)
            }
            .padding(16)
        }
        .navigationTitle(profile?.displayName ?? clanTag)
        .confirmationDialog(
            "删除部落跟踪？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                model.removeTrackedClan(tag: clanTag)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只移除跟踪关系，已获取的部落数据缓存会保留。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile?.displayName ?? "（未命名部落）")
                    .font(.title2.weight(.semibold))
                Text(clanTag)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isCurrentVillageClan(clanTag) {
                Text("当前村庄所属")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.cocAccent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.cocAccent)
            }
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("移除跟踪", systemImage: "trash")
            }
        }
    }
}
```

- [ ] **Step 4: ContentView 侧边栏新增"部落"Section + 添加 sheet**

修改 `Sources/COCHelper/ContentView.swift`：

a) `AppSection` 枚举新增 case：

```swift
    case clan(String)
```

b) 侧边栏在 `Section("官方 API")` 之后新增：

```swift
                    Section("部落") {
                        ForEach(model.trackedClans) { clan in
                            Button {
                                selection = .clan(clan.clanTag)
                            } label: {
                                TrackedClanSidebarRow(clan: clan, isCurrentVillageClan: model.isCurrentVillageClan(clan.clanTag))
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            showAddTrackedClan = true
                        } label: {
                            Label("添加部落", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.cocAccent)
                    }
```

c) `@State private var showAddTrackedClan = false`（selection 旁边）

d) detail 分支新增：

```swift
            case .clan(let tag):
                TrackedClanDetailView(clanTag: tag)
                    .id(tag)
```

e) `.sheet` 挂在 NavigationSplitView 上：

```swift
        .sheet(isPresented: $showAddTrackedClan) {
            AddTrackedClanSheet { tag in
                selection = .clan(tag)
            }
        }
```

f) 新增行视图与 sheet（放 ContentView.swift 文件内）：

```swift
/// 侧边栏部落行：备注/名称 + Tag + "当前村庄所属"标识。
private struct TrackedClanSidebarRow: View {
    let clan: TrackedClanProfile
    let isCurrentVillageClan: Bool

    var body: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(Color.cocAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(clan.displayName ?? clan.clanTag)
                    .lineLimit(1)
                Text(clan.clanTag)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrentVillageClan {
                Text("当前村庄")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.cocAccent)
            }
        }
    }
}

/// 添加部落表单：Tag 输入 + 可选备注 + 校验错误提示。
/// 只做本地校验与保存，不触发任何网络请求。
private struct AddTrackedClanSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onAdded: (String) -> Void

    @State private var rawTag = ""
    @State private var displayName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加部落")
                .font(.headline)
            TextField("部落 Tag（如 #2QJQ8J88）", text: $rawTag)
                .textFieldStyle(.roundedBorder)
            TextField("备注/显示名称（可选）", text: $displayName)
                .textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submit() {
        let name = displayName.isEmpty ? nil : displayName
        switch model.addTrackedClan(rawTag: rawTag, displayName: name) {
        case .success(let profile):
            errorMessage = nil
            onAdded(profile.clanTag)
            dismiss()
        case .failure(.invalidTag):
            errorMessage = "Tag 无效：需要以 # 开头，仅含大写字母和数字。"
        case .failure(.duplicate):
            errorMessage = "该部落已在跟踪列表中。"
        }
    }
}
```

- [ ] **Step 5: 构建验证**

Run: `swift build`
Expected: 成功，无警告新增

- [ ] **Step 6: 提交**

```bash
git add Sources/COCHelper/ContentView.swift Sources/COCHelper/TrackedClanDetailView.swift Sources/COCHelper/ClanCardView.swift Sources/COCHelper/ClanWarCardView.swift Sources/COCHelper/WarLogCardView.swift Sources/COCHelper/CapitalRaidCardView.swift
git commit -m "feat: 侧边栏部落跟踪列表 + 详情页 + 4 卡片双入口（Issue #41）"
```

---

### Task 6: 全量验证与收尾

- [ ] **Step 1: 全量测试 + 构建**

Run: `swift test && swift build -c release && git diff --check`
Expected: 全部通过；release 构建成功；diff 无空白错误

- [ ] **Step 2: 运行 App 构建脚本**

Run: `./scripts/build_app.sh`
Expected: 成功产出 App

- [ ] **Step 3: Reflexion 自查清单**

- [ ] 4 卡村庄入口行为与改造前逐字等价（unknown/no-clan/数据三分支门控正确）？
- [ ] `refreshClan(villageID:)` 转发后 pendingClanRefreshAll 排队语义不变？
- [ ] 手动添加不触发网络请求？（AppModelTrackedClansTests 断言）
- [ ] 删除跟踪保留共享缓存？（测试断言）
- [ ] 同 tag 双入口共享状态？（测试断言）
- [ ] Token 未进入档案/UserDefaults（TrackedClanProfile 无 token 字段）？
- [ ] property-based 测试可复现（种子固定）？

- [ ] **Step 4: 提交（如有自查修复）**

```bash
git add -A && git commit -m "refactor: Issue #41 自查修复"  # 仅当有改动
```
