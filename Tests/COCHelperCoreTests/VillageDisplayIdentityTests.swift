import XCTest
@testable import COCHelperCore

/// Issue #49 Task 1：`VillageDisplayIdentityProjection` 的 TDD 测试。
///
/// 覆盖：名称优先级链（官方昵称 → 本地名 → tag → 未命名）、状态语义
/// （stale/failed + lastGood 保留昵称、lastGood == nil 回退、`at now` 决定 stale）、
/// localAlias 规则、展示 tag 解析、多村庄隔离，以及 property-based 参照一致性。
final class VillageDisplayIdentityTests: XCTestCase {

    // MARK: - Helpers

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static let placeholder = "未命名村庄"

    private func makeSnapshot(name: String?) -> OfficialPlayerSnapshot {
        OfficialPlayerSnapshot(
            tag: nil, name: name,
            townHallLevel: nil, townHallWeaponLevel: nil, builderHallLevel: nil, expLevel: nil,
            trophies: nil, bestTrophies: nil, warStars: nil, attackWins: nil, defenseWins: nil,
            builderBaseTrophies: nil, versusBattleWins: nil, legendStatistics: nil,
            clan: nil, role: nil, warPreference: nil, donations: nil,
            donationsReceived: nil, clanCapitalContributions: nil,
            league: nil, builderBaseLeague: nil, achievements: nil,
            labels: nil, playerHouse: nil,
            troops: nil, heroes: nil, spells: nil, heroEquipment: nil,
            unrecognizedKeys: []
        )
    }

    private func makeState(
        status: OfficialAPIRequestStatus,
        playerTag: String? = nil,
        fetchedAt: Date? = nil,
        lastGoodName: String? = nil
    ) -> OfficialAPIState {
        OfficialAPIState(
            status: status,
            playerTag: playerTag,
            fetchedAt: fetchedAt,
            lastGood: lastGoodName.map { makeSnapshot(name: $0) }
        )
    }

    private func makeVillage(name: String, tag: String? = nil) -> VillageProfile {
        VillageProfile(
            name: name,
            accountSnapshot: tag.map { rawTag in
                AccountSnapshot(
                    tag: rawTag,
                    capturedAt: nil,
                    importedAt: t0,
                    ageSeconds: nil,
                    originalText: "",
                    objectSections: [:],
                    numericSections: [:],
                    boosts: [:],
                    unknownTopLevelKeys: [],
                    diagnostics: []
                )
            }
        )
    }

    // MARK: - 名称优先级链（确定性）

    func testOfficialNameTakesPriorityOverLocalName() {
        let village = makeVillage(name: "我的村", tag: "#RAW")
        let state = makeState(status: .success, playerTag: "#NORM", fetchedAt: t0, lastGoodName: "官名")
        let identity = VillageDisplayIdentityProjection.project(
            village: village, officialState: state, at: t0.addingTimeInterval(60)
        )

        XCTAssertEqual(identity.primaryName, "官名")
        XCTAssertEqual(identity.source, .officialName)
        XCTAssertEqual(identity.localAlias, "我的村")
        XCTAssertEqual(identity.tag, "#NORM")
        XCTAssertEqual(identity.officialStatus, .success)
        XCTAssertEqual(identity.officialFetchedAt, t0)
    }

    func testLocalNameFallbackWhenStateIsNil() {
        let village = makeVillage(name: "我的村", tag: "#ABC")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: nil, at: t0)

        XCTAssertEqual(identity.primaryName, "我的村")
        XCTAssertEqual(identity.source, .localName)
        XCTAssertNil(identity.localAlias)
        XCTAssertEqual(identity.tag, "#ABC")
        XCTAssertEqual(identity.officialStatus, .never)
        XCTAssertNil(identity.officialFetchedAt)
    }

    func testLocalNameFallbackWhenStateHasNoLastGood() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .success)
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.primaryName, "我的村")
        XCTAssertEqual(identity.source, .localName)
        XCTAssertNil(identity.localAlias)
    }

    func testTagFallbackWhenLocalNameIsPlaceholder() {
        // 空白名经 VillageProfile.init 归一化为占位"未命名村庄"；链继续走到 tag。
        let village = makeVillage(name: "   ", tag: "#ABC")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: nil, at: t0)

        XCTAssertEqual(identity.primaryName, "#ABC")
        XCTAssertEqual(identity.source, .tagFallback)
        XCTAssertEqual(identity.tag, "#ABC")
    }

    func testUnnamedWhenNothingAvailable() {
        let village = makeVillage(name: "  ")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: nil, at: t0)

        XCTAssertEqual(identity.primaryName, Self.placeholder)
        XCTAssertEqual(identity.source, .unnamed)
        XCTAssertNil(identity.tag)
    }

    func testWhitespaceOfficialNameCountsAsMissing() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .success, lastGoodName: "  \n  ")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.primaryName, "我的村")
        XCTAssertEqual(identity.source, .localName)
    }

    func testBlankLocalNameFallsThroughToTag() {
        var village = makeVillage(name: "我的村", tag: "#ABC")
        village.name = "   " // 直接 mutation 绕过 init 归一化
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: nil, at: t0)

        XCTAssertEqual(identity.primaryName, "#ABC")
        XCTAssertEqual(identity.source, .tagFallback)
    }

    func testBlankLocalNameWithoutTagIsUnnamed() {
        var village = makeVillage(name: "我的村")
        village.name = " \n "
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: nil, at: t0)

        XCTAssertEqual(identity.primaryName, Self.placeholder)
        XCTAssertEqual(identity.source, .unnamed)
    }

    func testOfficialNameBeingPlaceholderIsStillOfficial() {
        // 占位判定只作用于本地名：官方返回非空白的"未命名村庄"按官方昵称对待。
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .success, lastGoodName: Self.placeholder)
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.primaryName, Self.placeholder)
        XCTAssertEqual(identity.source, .officialName)
        XCTAssertEqual(identity.localAlias, "我的村")
    }

    // MARK: - 状态语义

    func testStaleWithLastGoodKeepsOfficialNameAndStatus() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .success, fetchedAt: t0, lastGoodName: "官名")
        let now = t0.addingTimeInterval(OfficialAPIState.staleThreshold + 60)
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: now)

        XCTAssertEqual(identity.primaryName, "官名")
        XCTAssertEqual(identity.source, .officialName)
        XCTAssertEqual(identity.officialStatus, .stale)
    }

    func testFailedWithLastGoodKeepsOfficialNameAndStatus() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .failed, lastGoodName: "官名")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.primaryName, "官名")
        XCTAssertEqual(identity.source, .officialName)
        XCTAssertEqual(identity.officialStatus, .failed)
    }

    func testFailedWithoutLastGoodFallsBackToLocalName() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .failed)
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.primaryName, "我的村")
        XCTAssertEqual(identity.source, .localName)
        // 状态仍透传，但不伪造官方昵称
        XCTAssertEqual(identity.officialStatus, .failed)
    }

    func testSkippedWithoutLastGoodFallsBackToLocalName() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .skipped)
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.primaryName, "我的村")
        XCTAssertEqual(identity.source, .localName)
        XCTAssertEqual(identity.officialStatus, .skipped)
    }

    func testLoadingWithoutLastGoodFallsBackToLocalName() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .loading)
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.primaryName, "我的村")
        XCTAssertEqual(identity.source, .localName)
        XCTAssertEqual(identity.officialStatus, .loading)
    }

    func testSuccessWithoutFetchedAtIsNotStale() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .success, lastGoodName: "官名")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.officialStatus, .success)
    }

    /// 关键设计验证：`at now` 注入必须决定 stale 派生（同一 state、不同 now）。
    /// 若投影内部改用 `state.displayStatus`（内部取 Date()），此测试不可复现。
    func testNowInjectionDeterminesStaleDerivation() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .success, fetchedAt: t0, lastGoodName: "官名")

        let fresh = VillageDisplayIdentityProjection.project(
            village: village, officialState: state, at: t0.addingTimeInterval(60)
        )
        let stale = VillageDisplayIdentityProjection.project(
            village: village,
            officialState: state,
            at: t0.addingTimeInterval(OfficialAPIState.staleThreshold + 60)
        )

        XCTAssertEqual(fresh.officialStatus, .success)
        XCTAssertEqual(stale.officialStatus, .stale)
    }

    // MARK: - localAlias 规则

    func testAliasNilWhenLocalNameEqualsOfficialName() {
        let village = makeVillage(name: "官名")
        let state = makeState(status: .success, lastGoodName: "官名")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.source, .officialName)
        XCTAssertNil(identity.localAlias)
    }

    func testAliasNilWhenLocalNameIsPlaceholder() {
        let village = makeVillage(name: "   ") // init 归一化为"未命名村庄"
        let state = makeState(status: .success, lastGoodName: "官名")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.source, .officialName)
        XCTAssertNil(identity.localAlias)
    }

    func testAliasValueWhenLocalNameDiffers() {
        let village = makeVillage(name: "我的村")
        let state = makeState(status: .success, lastGoodName: "官名")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.localAlias, "我的村")
    }

    func testAliasOnlyWhenSourceIsOfficial() {
        let village = makeVillage(name: "我的村")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: nil, at: t0)

        XCTAssertEqual(identity.source, .localName)
        XCTAssertNil(identity.localAlias)
    }

    func testAliasTrimsLocalNameWhitespace() {
        var village = makeVillage(name: "我的村")
        village.name = "  我的村  "
        let state = makeState(status: .success, lastGoodName: "官名")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.localAlias, "我的村")
    }

    // MARK: - 展示 tag 解析

    func testDisplayTagPrefersPlayerTag() {
        let village = makeVillage(name: "我的村", tag: "#RAW")
        let state = makeState(status: .success, playerTag: "#NORM", lastGoodName: "官名")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.tag, "#NORM")
    }

    func testDisplayTagFallsBackToVillageTagWhenPlayerTagNil() {
        let village = makeVillage(name: "我的村", tag: "#RAW")
        let state = makeState(status: .success, playerTag: nil, lastGoodName: "官名")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: state, at: t0)

        XCTAssertEqual(identity.tag, "#RAW")
    }

    func testDisplayTagFallsBackToVillageTagWhenStateNil() {
        let village = makeVillage(name: "我的村", tag: "#RAW")
        let identity = VillageDisplayIdentityProjection.project(village: village, officialState: nil, at: t0)

        XCTAssertEqual(identity.tag, "#RAW")
        XCTAssertNil(identity.officialFetchedAt)
    }

    // MARK: - 多村庄隔离

    func testTwoVillagesWithDifferentStatesDoNotLeak() {
        let villageA = makeVillage(name: "甲村", tag: "#AAA")
        let stateA = makeState(status: .success, playerTag: "#AAA", fetchedAt: t0, lastGoodName: "A-官名")

        let villageB = makeVillage(name: "乙村", tag: "#BBB")
        let stateB = makeState(status: .failed, playerTag: "#BBB", fetchedAt: nil, lastGoodName: "B-官名")

        let now = t0.addingTimeInterval(60)
        let identityA = VillageDisplayIdentityProjection.project(village: villageA, officialState: stateA, at: now)
        let identityB = VillageDisplayIdentityProjection.project(village: villageB, officialState: stateB, at: now)

        XCTAssertEqual(identityA.primaryName, "A-官名")
        XCTAssertEqual(identityA.source, .officialName)
        XCTAssertEqual(identityA.officialStatus, .success)
        XCTAssertEqual(identityA.localAlias, "甲村")
        XCTAssertEqual(identityA.tag, "#AAA")

        XCTAssertEqual(identityB.primaryName, "B-官名")
        XCTAssertEqual(identityB.source, .officialName)
        XCTAssertEqual(identityB.officialStatus, .failed)
        XCTAssertEqual(identityB.localAlias, "乙村")
        XCTAssertEqual(identityB.tag, "#BBB")
    }

    // MARK: - Property-based（确定性种子，参照实现对比）

    private let alnum = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    private func randomAlnum(_ rng: inout SeededRandomGenerator, maxLength: Int = 10) -> String {
        let count = rng.randomInt(in: 0...maxLength)
        return (0..<count).map { _ in String(alnum[rng.randomInt(in: 0...(alnum.count - 1))]) }.joined()
    }

    /// 随机原始 tag：约一半 nil，其余多为 "#"+字母数字，少量纯空白（按缺失处理）。
    private func randomVillageTag(_ rng: inout SeededRandomGenerator) -> String? {
        switch rng.randomInt(in: 0...19) {
        case 0...9: return nil
        case 10...17: return "#" + randomAlnum(&rng, maxLength: 8)
        default: return rng.randomWhitespace()
        }
    }

    private func randomOfficialName(_ rng: inout SeededRandomGenerator) -> String? {
        switch rng.randomInt(in: 0...9) {
        case 0...1: return nil // 无 lastGood
        case 2: return rng.randomWhitespace() // 空白 → 视为缺失
        case 3: return Self.placeholder
        default: return randomAlnum(&rng) // 可能为空串 → 视为缺失
        }
    }

    /// 直接覆盖 village.name（绕过 init 归一化），覆盖空白/空串/占位等病态输入。
    private func randomLocalName(_ rng: inout SeededRandomGenerator) -> String {
        switch rng.randomInt(in: 0...9) {
        case 0: return rng.randomWhitespace()
        case 1: return Self.placeholder
        case 2...3: return ""
        default: return randomAlnum(&rng, maxLength: 12)
        }
    }

    private func randomState(_ rng: inout SeededRandomGenerator, lastGoodName: String?) -> OfficialAPIState {
        let statuses: [OfficialAPIRequestStatus] = [.never, .loading, .success, .failed, .skipped]
        let fetchedAt: Date? = rng.randomInt(in: 0...4) == 0
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(rng.randomInt(in: 0...3_000_000_000)))
        let playerTag: String? = rng.randomInt(in: 0...4) == 0
            ? nil
            : "#" + randomAlnum(&rng, maxLength: 8)
        return makeState(
            status: statuses[rng.randomInt(in: 0...4)],
            playerTag: playerTag,
            fetchedAt: fetchedAt,
            lastGoodName: lastGoodName
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 参照实现：与生产代码同一条规范、独立重写（model-based testing）。
    private func referenceIdentity(
        villageName: String,
        lastGoodName: String?,
        villageTag: String?,
        state: OfficialAPIState?,
        now: Date
    ) -> VillageDisplayIdentity {
        let officialName = Self.nonBlank(lastGoodName)
        let localName = Self.nonBlank(villageName)
        let localTag = Self.nonBlank(villageTag)

        let primaryName: String
        let source: VillageIdentitySource
        if let officialName {
            primaryName = officialName
            source = .officialName
        } else if let localName, localName != Self.placeholder {
            primaryName = localName
            source = .localName
        } else if let localTag {
            primaryName = localTag
            source = .tagFallback
        } else {
            primaryName = Self.placeholder
            source = .unnamed
        }

        let localAlias: String?
        if source == .officialName, let localName, localName != Self.placeholder, localName != officialName {
            localAlias = localName
        } else {
            localAlias = nil
        }

        return VillageDisplayIdentity(
            primaryName: primaryName,
            tag: state?.playerTag ?? villageTag,
            localAlias: localAlias,
            source: source,
            officialStatus: Self.referenceStatus(state, at: now),
            officialFetchedAt: state?.fetchedAt
        )
    }

    private static func referenceStatus(_ state: OfficialAPIState?, at now: Date) -> OfficialAPIDisplayStatus {
        guard let state else { return .never }
        switch state.status {
        case .never: return .never
        case .loading: return .loading
        case .success: return state.isStale(at: now) ? .stale : .success
        case .failed: return .failed
        case .skipped: return .skipped
        }
    }

    /// 随机 (lastGoodName, village.name, tag, status) 下，投影与参照实现逐字段一致，
    /// 且 primaryName 永不为空/纯空白。
    func testPropertyProjectionMatchesReference() {
        var rng = SeededRandomGenerator(seed: 2026)
        let now = Date(timeIntervalSince1970: 2_500_000_000)

        for iteration in 0..<2_000 {
            let lastGoodName = randomOfficialName(&rng)
            let localName = randomLocalName(&rng)
            let villageTag = randomVillageTag(&rng)
            let state = randomState(&rng, lastGoodName: lastGoodName)

            var village = makeVillage(name: "占位", tag: villageTag)
            village.name = localName

            let identity = VillageDisplayIdentityProjection.project(
                village: village, officialState: state, at: now
            )
            let reference = referenceIdentity(
                villageName: localName,
                lastGoodName: lastGoodName,
                villageTag: villageTag,
                state: state,
                now: now
            )

            let context = "seed=2026 iteration=\(iteration) lastGoodName=\(String(describing: lastGoodName)) "
                + "localName=\(localName) villageTag=\(String(describing: villageTag)) "
                + "status=\(String(describing: state.status))"
            XCTAssertEqual(identity, reference, "投影与参照不一致 | \(context)")
            XCTAssertFalse(identity.primaryName.isEmpty, "primaryName 不应为空 | \(context)")
            XCTAssertEqual(
                identity.primaryName.trimmingCharacters(in: .whitespacesAndNewlines),
                identity.primaryName,
                "primaryName 不应含首尾空白 | \(context)"
            )
        }
    }

    /// 同一村庄、两个不同官方状态：各自身份只反映传入的 state，互不串扰。
    func testPropertySameVillageDifferentStatesStayIsolated() {
        var rng = SeededRandomGenerator(seed: 777)
        let now = Date(timeIntervalSince1970: 2_500_000_000)
        let village = makeVillage(name: "村庄", tag: "#V")

        for iteration in 0..<500 {
            let stateA = randomState(&rng, lastGoodName: "名字A" + randomAlnum(&rng, maxLength: 4))
            let stateB = randomState(&rng, lastGoodName: "名字B" + randomAlnum(&rng, maxLength: 4))

            let identityA = VillageDisplayIdentityProjection.project(village: village, officialState: stateA, at: now)
            let identityB = VillageDisplayIdentityProjection.project(village: village, officialState: stateB, at: now)

            let referenceA = referenceIdentity(
                villageName: "村庄", lastGoodName: stateA.lastGood?.name, villageTag: "#V",
                state: stateA, now: now
            )
            let referenceB = referenceIdentity(
                villageName: "村庄", lastGoodName: stateB.lastGood?.name, villageTag: "#V",
                state: stateB, now: now
            )

            let context = "seed=777 iteration=\(iteration)"
            XCTAssertEqual(identityA, referenceA, "身份 A 与参照不一致 | \(context)")
            XCTAssertEqual(identityB, referenceB, "身份 B 与参照不一致 | \(context)")
            XCTAssertNotEqual(identityA.primaryName, identityB.primaryName, "A/B 官方名不应相同 | \(context)")
        }
    }
}
