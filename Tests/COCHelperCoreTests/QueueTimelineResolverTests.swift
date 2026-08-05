import XCTest
@testable import COCHelperCore

/// Issue #17：队列时间线边界契约测试。
///
/// 真实账号 JSON（anonymized_account_snapshot.json）实测不存在任何队列字段
/// （queueID/queueKind/assignedItemID/targetLevel/startedAt/totalDurationSeconds 均 0 处），
/// 因此契约必须恒返回结构化 unavailable，禁止编造队列信息。
final class QueueTimelineResolverTests: XCTestCase {
    private func loadFixtureSnapshot() throws -> AccountSnapshot {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "anonymized_account_snapshot", withExtension: "json")
        )
        return try AccountSnapshotImporter.parse(
            String(data: Data(contentsOf: url), encoding: .utf8) ?? "",
            now: Date(timeIntervalSince1970: 1_785_736_333) // == fixture timestamp：age = 0
        )
    }

    private func makeVillage(snapshot: AccountSnapshot) -> VillageProfile {
        VillageProfile(
            name: "测试村庄",
            accountSnapshot: snapshot
        )
    }

    /// 真实 fixture 的升级项 → 结构化 unavailable，缺失字段精确、原因含项目名、溯源透传。
    func testRealFixtureUpgradingItemReturnsStructuredUnavailable() throws {
        let snapshot = try loadFixtureSnapshot()
        let village = makeVillage(snapshot: snapshot)
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: GameCatalog.loadBundled(),
            base: .home,
            now: Date(timeIntervalSince1970: 1_785_736_333)
        )
        let upgrading = try XCTUnwrap(projection.items.first { $0.isUpgrading })

        let resolution = QueueTimelineResolver.resolve(
            for: upgrading,
            snapshotCapturedAt: snapshot.capturedAt,
            catalogVersion: projection.catalogVersion
        )

        guard case .unavailable(let state) = resolution else {
            return XCTFail("队列时间线必须为 unavailable（JSON 无队列字段）")
        }
        XCTAssertEqual(state.missingFields, QueueTimelineUnavailable.missingQueueFields)
        XCTAssertEqual(state.missingFields, [
            "queueID", "queueKind", "assignedItemID",
            "targetLevel", "startedAt", "totalDurationSeconds",
        ])
        XCTAssertTrue(state.reason.contains(upgrading.name), "原因应包含请求的项目名")
        XCTAssertTrue(state.reason.contains("队列"), "原因应明确说明队列信息缺失")
        XCTAssertEqual(state.snapshotCapturedAt, snapshot.capturedAt)
        XCTAssertEqual(state.catalogVersion, "18.400.13")
    }

    /// 非升级项同样不可用：与升级状态无关，任何项目都无队列信息。
    func testNonUpgradingItemAlsoUnavailable() throws {
        let snapshot = try loadFixtureSnapshot()
        let village = makeVillage(snapshot: snapshot)
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: GameCatalog.loadBundled(),
            base: .home,
            now: Date(timeIntervalSince1970: 1_785_736_333)
        )
        let idle = try XCTUnwrap(projection.items.first { !$0.isUpgrading })

        let resolution = QueueTimelineResolver.resolve(
            for: idle,
            snapshotCapturedAt: nil,
            catalogVersion: nil
        )
        guard case .unavailable = resolution else {
            return XCTFail("非升级项同样不可用")
        }
    }

    /// 溯源缺失时如实透传 nil，不伪造快照时间/目录版本。
    func testNilProvenancePassesThrough() throws {
        let snapshot = try loadFixtureSnapshot()
        let village = makeVillage(snapshot: snapshot)
        let projection = VillageCatalogProjection.project(
            village: village,
            catalog: nil,
            base: .home,
            now: Date(timeIntervalSince1970: 1_785_736_333)
        )
        let item = try XCTUnwrap(projection.items.first)

        let resolution = QueueTimelineResolver.resolve(
            for: item,
            snapshotCapturedAt: nil,
            catalogVersion: nil
        )
        guard case .unavailable(let state) = resolution else {
            return XCTFail("应为 unavailable")
        }
        XCTAssertNil(state.snapshotCapturedAt)
        XCTAssertNil(state.catalogVersion)
    }

    /// Codable 契约：编码→解码 round-trip 保持载荷不变（诊断可持久化）。
    func testResolutionCodableRoundTrip() throws {
        let original = QueueTimelineResolution.unavailable(QueueTimelineUnavailable(
            reason: "测试原因",
            missingFields: QueueTimelineUnavailable.missingQueueFields,
            snapshotCapturedAt: Date(timeIntervalSince1970: 1_785_736_333),
            catalogVersion: "18.400.13"
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueueTimelineResolution.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// 缺失字段清单是契约：与 issue 记载的不可得字段一致，改动即破坏契约。
    func testMissingFieldsAreExactContract() {
        XCTAssertEqual(QueueTimelineUnavailable.missingQueueFields, [
            "queueID", "queueKind", "assignedItemID",
            "targetLevel", "startedAt", "totalDurationSeconds",
        ])
    }
}
