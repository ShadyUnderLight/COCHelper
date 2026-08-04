import XCTest
@testable import COCHelperCore

final class VillageProfileTests: XCTestCase {
    // MARK: - 旧数据兼容（关键回归：新增字段不得破坏已有 UserDefaults 数据）

    func testOldVillageJSONDecodesWithoutOfficialState() throws {
        let oldJSON = """
        {
          "id": "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D",
          "name": "我的村庄",
          "accountSnapshot": null,
          "createdAt": 1700000000,
          "updatedAt": 1700000001
        }
        """.data(using: .utf8)!

        let village = try JSONDecoder().decode(VillageProfile.self, from: oldJSON)
        XCTAssertNil(village.officialAPIState)
        XCTAssertEqual(village.name, "我的村庄")
    }

    func testOldVillageJSONWithSnapshotStillDecodes() throws {
        // 带快照的旧格式（无 officialAPIState 键）也能解码
        let oldJSON = """
        {
          "id": "B1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D",
          "name": "#ABC",
          "accountSnapshot": {
            "tag": "#ABC",
            "capturedAt": null,
            "importedAt": 1700000000,
            "ageSeconds": null,
            "originalText": "{}",
            "objectSections": {},
            "numericSections": {},
            "boosts": {},
            "unknownTopLevelKeys": [],
            "diagnostics": []
          },
          "createdAt": 1700000000,
          "updatedAt": 1700000001
        }
        """.data(using: .utf8)!

        let village = try JSONDecoder().decode(VillageProfile.self, from: oldJSON)
        XCTAssertNil(village.officialAPIState)
        XCTAssertEqual(village.accountSnapshot?.tag, "#ABC")
    }

    // MARK: - 新字段 round-trip

    func testVillageProfileWithOfficialStateRoundTrip() throws {
        var official = OfficialAPIState(status: .success)
        official.playerTag = "#ABC"
        official.fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        official.parserVersion = OfficialAPIState.currentParserVersion

        let village = VillageProfile(name: "测试", accountSnapshot: nil, officialAPIState: official)
        let data = try JSONEncoder().encode(village)
        let restored = try JSONDecoder().decode(VillageProfile.self, from: data)
        XCTAssertEqual(restored.officialAPIState, official)
        XCTAssertEqual(restored.name, "测试")
    }

    /// 全链路集成：官方快照（含 lastGood + unrecognizedKeys）经 VillageProfile
    /// JSON 编码 → 解码后完整保留（模拟 UserDefaults 持久化往返）。
    func testVillageProfileFullChainRoundTripWithLastGood() throws {
        let good = try JSONDecoder().decode(
            OfficialPlayerSnapshot.self,
            from: fullPlayerFixtureData()
        )
        var official = OfficialAPIState(
            status: .success,
            playerTag: "#ANONYMIZED",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastGood: good,
            unrecognizedKeys: good.unrecognizedKeys
        )
        official.lastErrorReason = nil
        official.lastHTTPStatus = nil

        let village = VillageProfile(
            name: "测试",
            accountSnapshot: AccountSnapshotFixtures.snapshot(tag: "#ANONYMIZED"),
            officialAPIState: official
        )

        let data = try JSONEncoder().encode(village)
        let restored = try JSONDecoder().decode(VillageProfile.self, from: data)

        XCTAssertEqual(restored.officialAPIState?.lastGood, good, "last-good 快照必须完整保留")
        XCTAssertEqual(restored.officialAPIState?.unrecognizedKeys.sorted(), good.unrecognizedKeys.sorted())
        XCTAssertEqual(restored.officialAPIState?.playerTag, "#ANONYMIZED")
        XCTAssertEqual(restored.officialAPIState?.fetchedAt, official.fetchedAt)
        XCTAssertEqual(restored.officialAPIState?.lastErrorReason, nil)
    }

    // MARK: - officialTag

    func testOfficialTagUsesValidNormalizedTag() {
        let snapshot = VillageProfile(
            name: "a",
            accountSnapshot: AccountSnapshotFixtures.snapshot(tag: "  #ABC  ")
        )
        XCTAssertEqual(snapshot.officialTag, "#ABC")
    }

    func testOfficialTagNilWhenMissingOrInvalid() {
        let noTag = VillageProfile(
            name: "a",
            accountSnapshot: AccountSnapshotFixtures.snapshot(tag: nil)
        )
        XCTAssertNil(noTag.officialTag)

        let invalidTag = VillageProfile(
            name: "a",
            accountSnapshot: AccountSnapshotFixtures.snapshot(tag: "abc")
        )
        XCTAssertNil(invalidTag.officialTag)
    }

    // MARK: - 导入快照与官方状态的账号绑定（P1 修复）

    func testApplyImportedSnapshotResetsOfficialStateWhenTagChanges() {
        var village = VillageProfile(
            name: "a",
            accountSnapshot: AccountSnapshotFixtures.snapshot(tag: "#OLD"),
            officialAPIState: OfficialAPIState(status: .success, fetchedAt: Date())
        )

        village.applyImportedSnapshot(AccountSnapshotFixtures.snapshot(tag: "#NEW"))

        XCTAssertEqual(village.accountSnapshot?.tag, "#NEW")
        XCTAssertNil(village.officialAPIState, "tag 变化时必须重置官方数据，避免显示旧账号资料")
    }

    func testApplyImportedSnapshotKeepsOfficialStateWhenTagUnchanged() {
        var village = VillageProfile(
            name: "a",
            accountSnapshot: AccountSnapshotFixtures.snapshot(tag: "#SAME"),
            officialAPIState: OfficialAPIState(status: .success, fetchedAt: Date())
        )

        village.applyImportedSnapshot(AccountSnapshotFixtures.snapshot(tag: "  #SAME  "))

        XCTAssertNotNil(village.officialAPIState, "同 tag 重导入不应重置官方数据")
        XCTAssertEqual(village.officialAPIState?.status, .success)
    }

    func testApplyImportedSnapshotClearsOfficialStateWhenTagBecomesNil() {
        var village = VillageProfile(
            name: "a",
            accountSnapshot: AccountSnapshotFixtures.snapshot(tag: "#OLD"),
            officialAPIState: OfficialAPIState(status: .success, fetchedAt: Date())
        )

        village.applyImportedSnapshot(AccountSnapshotFixtures.snapshot(tag: nil))

        XCTAssertNil(village.officialAPIState, "tag 变为缺失时官方数据不再适用")
    }

    // MARK: - 异步写回竞态校验（P1 修复）

    func testOfficialStateMatchesTag() {
        let village = VillageProfile(
            name: "a",
            accountSnapshot: AccountSnapshotFixtures.snapshot(tag: "#ABC")
        )
        XCTAssertTrue(village.officialStateMatchesTag(at: "#ABC"), "当前 tag 与请求时一致")
        XCTAssertFalse(village.officialStateMatchesTag(at: "#XYZ"), "账号已变化，旧请求结果应丢弃")
        XCTAssertFalse(village.officialStateMatchesTag(at: nil), "有 tag 村庄不能接受无 tag 校验")
    }

    func testOfficialStateMatchesTagWhenBothNil() {
        let village = VillageProfile(name: "a", accountSnapshot: AccountSnapshotFixtures.snapshot(tag: nil))
        XCTAssertTrue(village.officialStateMatchesTag(at: nil), "无 tag 村庄写回 skipped 状态应允许")
    }
}

/// 构造测试用 AccountSnapshot 的最小辅助。
enum AccountSnapshotFixtures {
    static func snapshot(tag: String?) -> AccountSnapshot {
        AccountSnapshot(
            tag: tag,
            capturedAt: nil,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            ageSeconds: nil,
            originalText: "{}",
            objectSections: [:],
            numericSections: [:],
            boosts: [:],
            unknownTopLevelKeys: [],
            diagnostics: []
        )
    }
}
