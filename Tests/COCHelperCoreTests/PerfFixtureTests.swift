import Foundation
import XCTest
@testable import COCHelperCore

/// Issue #197：滚动性能基线的匿名本地 fixtures 契约测试。
///
/// 只验证 fixture 可解码、匿名契约与计数契约；**不设 wall-clock 阈值**（issue 非目标，
/// 性能证据必须来自 Instruments）。
final class PerfFixtureTests: XCTestCase {

    // MARK: - fixture 读取

    private func fixtureText(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    /// 匿名契约：fixture 文本不得含 token/cookie/密钥/真实 tag 形态。
    private func assertAnonymized(_ text: String, file: StaticString = #file, line: UInt = #line) {
        let lower = text.lowercased()
        for forbidden in ["token", "cookie", "secret", "api_key", "bearer"] {
            XCTAssertFalse(
                lower.contains(forbidden),
                "fixture must not contain sensitive marker: \(forbidden)",
                file: file, line: line
            )
        }
    }

    // MARK: - 账号快照

    func testPerfAccountSnapshotHomeParsesAndIsAnonymized() throws {
        let text = try fixtureText("perf_account_snapshot_home")
        assertAnonymized(text)
        let snapshot = try AccountSnapshotImporter.parse(
            text,
            now: Date(timeIntervalSince1970: 1_785_736_933)
        )

        XCTAssertEqual(snapshot.tag, "#ANONYMIZED")
        let buildings = snapshot.objectSections["buildings"] ?? []
        XCTAssertGreaterThanOrEqual(buildings.count, 100, "perf home fixture needs >=100 building records for scroll depth")
        // 墙体/重复数量：城墙（dataID 1000010）应带大 cnt。
        let walls = buildings.filter { $0.dataID == 1_000_010 }
        XCTAssertFalse(walls.isEmpty)
        XCTAssertGreaterThanOrEqual(walls.reduce(0) { $0 + ($1.count ?? 0) }, 300)
        // 同类建筑多等级记录：至少两个 dataID 各含 >=2 条记录。
        let countsByID = Dictionary(grouping: buildings, by: \.dataID)
        let multiLevel = countsByID.filter { $0.value.count >= 2 }
        XCTAssertGreaterThanOrEqual(multiLevel.count, 2)
        // 进行中导入计时：>=5 条 timer > 0。
        let timers = snapshot.allObjectItems.filter { ($0.remainingSeconds ?? 0) > 0 }
        XCTAssertGreaterThanOrEqual(timers.count, 5)
        // 计时结束（remaining == 0）→ 待重新导入确认。
        let ended = snapshot.allObjectItems.filter {
            $0.hasTimer && ($0.remainingSeconds ?? 0) == 0
        }
        XCTAssertGreaterThanOrEqual(ended.count, 2)
        XCTAssertFalse(snapshot.unknownTopLevelKeys.contains("coverage"))
        XCTAssertNil(snapshot.objectSections["coverage"])
    }

    func testPerfAccountSnapshotLargeWallsHas1000PlusSegments() throws {
        let text = try fixtureText("perf_account_snapshot_large_walls")
        assertAnonymized(text)
        let snapshot = try AccountSnapshotImporter.parse(
            text,
            now: Date(timeIntervalSince1970: 1_785_736_933)
        )
        XCTAssertEqual(snapshot.tag, "#PERF-LARGE-WALLS")
        let walls = (snapshot.objectSections["buildings"] ?? []).filter { $0.dataID == 1_000_008 }
        let segmentCount = walls.reduce(0) { $0 + ($1.count ?? 1) }
        XCTAssertGreaterThanOrEqual(segmentCount, 1_000, "Issue #226 perf gate needs >=1000 wall segments")
        XCTAssertFalse(snapshot.unknownTopLevelKeys.contains("coverage"))
    }

    func testPerfAccountSnapshotBuilderParses() throws {
        let text = try fixtureText("perf_account_snapshot_builder")
        assertAnonymized(text)
        let snapshot = try AccountSnapshotImporter.parse(
            text,
            now: Date(timeIntervalSince1970: 1_785_736_933)
        )
        let buildings2 = snapshot.objectSections["buildings2"] ?? []
        XCTAssertGreaterThanOrEqual(buildings2.count, 40, "perf builder fixture needs >=40 records")
        let timers = snapshot.allObjectItems.filter { ($0.remainingSeconds ?? 0) > 0 }
        XCTAssertGreaterThanOrEqual(timers.count, 2)
    }

    /// 混合 fixture：缺失 section（partial coverage）、计时结束（needsReimport）、
    /// 目录未收录 dataID（unknown/auditable）三态可派生。
    func testPerfAccountSnapshotMixedCoversDerivedStates() throws {
        let text = try fixtureText("perf_account_snapshot_mixed")
        assertAnonymized(text)
        let snapshot = try AccountSnapshotImporter.parse(
            text,
            now: Date(timeIntervalSince1970: 1_785_736_933)
        )
        XCTAssertEqual(snapshot.tag, "#PERF-MIXED")
        // 缺失 spells section → 投影层 partial coverage（数据层契约）。
        XCTAssertNil(snapshot.objectSections["spells"])
        // 计时结束项（needsReimport 信号来源）。
        let ended = snapshot.allObjectItems.filter {
            $0.hasTimer && ($0.remainingSeconds ?? 0) == 0
        }
        XCTAssertGreaterThanOrEqual(ended.count, 1)
        // 目录未收录 dataID（9999999）→ displayName nil（投影层 unknown）。
        let unmapped = snapshot.allObjectItems.first { $0.dataID == 9_999_999 }
        XCTAssertNotNil(unmapped)
        XCTAssertNil(unmapped?.displayName)
    }

    /// 冲突变体：与 home 同 tag（#ANONYMIZED），1000002 分布 {15:2,16:5}
    /// 相对 home 的 {15:1,16:6,17:1} 互不支配 → 对账 .conflict；
    /// 顶层 coverage 权威证明（#173/#164：无证明时 fail-closed 为 unknown）。
    func testPerfAccountSnapshotVariantParsesWithCoverageProofs() throws {
        let text = try fixtureText("perf_account_snapshot_variant")
        assertAnonymized(text)
        let snapshot = try AccountSnapshotImporter.parse(
            text,
            now: Date(timeIntervalSince1970: 1_785_736_933)
        )
        XCTAssertEqual(snapshot.tag, "#ANONYMIZED")
        // 1000002 分布 {15:2, 16:5}（无 lvl17）。
        let buildings = snapshot.objectSections["buildings"] ?? []
        let c1000002 = buildings.filter { $0.dataID == 1_000_002 }
        XCTAssertFalse(c1000002.contains { $0.level == 17 })
        XCTAssertEqual(c1000002.filter { $0.level == 15 }.first?.count, 2)
        XCTAssertEqual(c1000002.filter { $0.level == 16 }.first?.count, 5)
        // 顶层 coverage 声明（buildings declared proof）。
        let proofs = JSONSnapshotCoverageAdapter.proofs(for: snapshot)
        if case .declared(source: _, version: _, expectedCount: let expected) = proofs["buildings"] {
            XCTAssertEqual(
                expected,
                snapshot.objectSections["buildings"]?.count ?? 0
            )
            XCTAssertFalse(proofs["buildings"]?.isVerified ?? true)
        } else {
            XCTFail("variant fixture must carry declared coverage proof for buildings")
        }
        XCTAssertFalse(snapshot.unknownTopLevelKeys.contains("coverage"))
        XCTAssertNil(snapshot.objectSections["coverage"])
        XCTAssertFalse(snapshot.diagnostics.contains {
            $0.path == "顶层" && $0.severity == .warning
                && $0.message.contains("未识别字段")
                && $0.message.contains("coverage")
        })
    }

    // MARK: - 战争日志 / 突袭周末多页缓存

    func testPerfWarLogPagesChainCursors() throws {
        let p1 = try JSONDecoder().decode(
            OfficialWarLogPage.self, from: fixtureData("perf_war_log_page_01"))
        let p2 = try JSONDecoder().decode(
            OfficialWarLogPage.self, from: fixtureData("perf_war_log_page_02"))
        let p3 = try JSONDecoder().decode(
            OfficialWarLogPage.self, from: fixtureData("perf_war_log_page_03"))

        XCTAssertEqual(p1.items.count, 10)
        XCTAssertEqual(p2.items.count, 10)
        XCTAssertEqual(p3.items.count, 10)
        XCTAssertEqual(p1.after, "CURSORAFTER1")
        XCTAssertEqual(p2.after, "CURSORAFTER2")
        XCTAssertNil(p3.after, "last page has no after cursor")

        XCTAssertTrue(PaginationLogic.hasMore(
            requestedCursor: p1.after, responseAfter: p2.after))
        XCTAssertFalse(PaginationLogic.hasMore(
            requestedCursor: p2.after, responseAfter: nil))
        XCTAssertEqual(p1.items.first?.result, "win")
        XCTAssertEqual(p2.items.first?.result, "lose")
        XCTAssertEqual(p3.items.first?.result, "win")

        // 多页合并契约：去重后累计（本 fixture 各页条目互异）。
        let merged = PaginationMerge.mergedPage(existing: p1.page, fetched: p2.page)
        XCTAssertEqual(merged.items.count, 20)
        XCTAssertEqual(merged.after, "CURSORAFTER2")
    }

    func testPerfRaidPagesChainCursors() throws {
        let p1 = try JSONDecoder().decode(
            OfficialCapitalRaidPage.self, from: fixtureData("perf_capital_raid_page_01"))
        let p2 = try JSONDecoder().decode(
            OfficialCapitalRaidPage.self, from: fixtureData("perf_capital_raid_page_02"))
        let p3 = try JSONDecoder().decode(
            OfficialCapitalRaidPage.self, from: fixtureData("perf_capital_raid_page_03"))

        XCTAssertEqual(p1.items.count, 6)
        XCTAssertEqual(p2.items.count, 6)
        XCTAssertEqual(p3.items.count, 5)
        XCTAssertEqual(p1.after, "RAIDCURSORAFTER1")
        XCTAssertEqual(p2.after, "RAIDCURSORAFTER2")
        XCTAssertNil(p3.after)

        let merged = PaginationMerge.mergedPage(existing: p1.page, fetched: p2.page)
        XCTAssertEqual(merged.items.count, 12)
    }

    // MARK: - manifest

    /// manifest 的 dataScale 必须与 fixture 实际内容一致（顶层数组元素合计）。
    func testPerfFixtureManifestRecordsEnvironment() throws {
        let manifest = try JSONDecoder().decode(
            PerfFixtureManifest.self, from: fixtureData("perf_fixtures_manifest"))
        XCTAssertEqual(manifest.baselineCommitSHA, "d3b57e8164f81e292a023b052e455085565c3dbb")
        XCTAssertFalse(manifest.catalogFingerprint.isEmpty)
        XCTAssertFalse(manifest.macOSVersion.isEmpty)
        XCTAssertFalse(manifest.hardwareArchitecture.isEmpty)
        XCTAssertFalse(manifest.swiftToolchain.isEmpty)
        XCTAssertFalse(manifest.windowSize.isEmpty)
        XCTAssertFalse(manifest.dataScale.isEmpty)

        // dataScale 与文件内容一致性契约：三个账号 fixture 的顶层数组元素合计。
        let home = try JSONSerialization.jsonObject(
            with: fixtureData("perf_account_snapshot_home")) as? [String: Any]
        let builder = try JSONSerialization.jsonObject(
            with: fixtureData("perf_account_snapshot_builder")) as? [String: Any]
        let mixed = try JSONSerialization.jsonObject(
            with: fixtureData("perf_account_snapshot_mixed")) as? [String: Any]
        let variant = try JSONSerialization.jsonObject(
            with: fixtureData("perf_account_snapshot_variant")) as? [String: Any]
        XCTAssertEqual(
            manifest.dataScale["perf_account_snapshot_home"],
            topLevelArrayTotal(home)
        )
        XCTAssertEqual(
            manifest.dataScale["perf_account_snapshot_builder"],
            topLevelArrayTotal(builder)
        )
        XCTAssertEqual(
            manifest.dataScale["perf_account_snapshot_mixed"],
            topLevelArrayTotal(mixed)
        )
        XCTAssertEqual(
            manifest.dataScale["perf_account_snapshot_variant"],
            topLevelArrayTotal(variant)
        )
        // 分页 fixture 的 scale 与条目数一致。
        XCTAssertEqual(manifest.dataScale["perf_war_log_page_01"], 10)
        XCTAssertEqual(manifest.dataScale["perf_war_log_page_02"], 10)
        XCTAssertEqual(manifest.dataScale["perf_war_log_page_03"], 10)
        XCTAssertEqual(manifest.dataScale["perf_capital_raid_page_01"], 6)
        XCTAssertEqual(manifest.dataScale["perf_capital_raid_page_02"], 6)
        XCTAssertEqual(manifest.dataScale["perf_capital_raid_page_03"], 5)
    }

    /// 顶层数组元素合计（与 manifest dataScale 口径一致）。
    private func topLevelArrayTotal(_ object: [String: Any]?) -> Int {
        guard let object else { return 0 }
        return object.values.reduce(0) { total, value in
            total + ((value as? [Any])?.count ?? 0)
        }
    }
}

/// Issue #197：fixture manifest 结构契约（纯数据，不参与生产逻辑）。
private struct PerfFixtureManifest: Decodable {
    let baselineCommitSHA: String
    let catalogFingerprint: String
    let macOSVersion: String
    let hardwareArchitecture: String
    let swiftToolchain: String
    let windowSize: String
    let dataScale: [String: Int]
}
