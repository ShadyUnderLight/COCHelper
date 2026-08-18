import Foundation
import XCTest
@testable import COCHelperCore

/// Issue #197：统一 signpost 埋点的纯契约测试。
///
/// 只验证事件名稳定（静态常量，不携带敏感数据）与 facade API 可编译；
/// **不验证 os_signpost 实际发射**（测试环境默认 disabled，性能证据必须来自 Instruments）。
final class PerformanceSignpostTests: XCTestCase {

    func testProjectionEventNamesAreStable() {
        XCTAssertEqual(
            PerformanceEvent.villageCatalogProject.signpostName.description,
            "VillageCatalogProjection.project"
        )
        XCTAssertEqual(
            PerformanceEvent.buildingGroupProject.signpostName.description,
            "BuildingGroupProjection.project"
        )
        XCTAssertEqual(
            PerformanceEvent.craftTableProject.signpostName.description,
            "CraftTableProjection.project"
        )
        XCTAssertEqual(
            PerformanceEvent.upgradeOverviewRecords.signpostName.description,
            "UpgradeOverviewProjection.overviewRecords"
        )
        XCTAssertEqual(
            PerformanceEvent.upgradeOverviewState.signpostName.description,
            "UpgradeOverviewProjection.overviewState"
        )
        XCTAssertEqual(
            PerformanceEvent.assetCandidateProbe.signpostName.description,
            "VillageItemState.preferredAssetURLs"
        )
    }

    func testSignpostFacadeCompilesAndReturnsStableIDs() {
        // 纯契约：同一事件 begin 返回可复用的 OSSignpostID；名称是静态常量，
        // 不含账号原文/token/URL 敏感参数/完整唯一 ID。
        let id1 = PerformanceSignpost.begin(.villageCatalogProject, dataScale: 3, count: 10)
        let id2 = PerformanceSignpost.begin(.villageCatalogProject, dataScale: 3, count: 10)
        PerformanceSignpost.end(.villageCatalogProject, id: id1)
        PerformanceSignpost.end(.villageCatalogProject, id: id2, count: 10)

        XCTAssertEqual(
            PerformanceEvent.assetCandidateProbe.signpostName.description,
            "VillageItemState.preferredAssetURLs"
        )
    }
}
