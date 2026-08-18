import Foundation
import os

/// Issue #197：统一 signpost 埋点。
///
/// 只记录耗时（begin/end 区间）、计数与数据规模（整数负载）与 cache hit/miss
/// （布尔负载）；**不得记录账号原文、token、URL 中的敏感参数或完整唯一标识**。
/// 事件名是静态常量（无用户数据）。测试环境 os_signpost 默认 disabled，埋点开销
/// 可忽略；性能证据必须来自 Instruments（Animation Hitches / Time Profiler）。
public enum PerformanceEvent {
    /// VillageCatalogProjection.project：村庄 × base 全量投影。
    case villageCatalogProject
    /// BuildingGroupProjection.project：同类建筑组卡投影。
    case buildingGroupProject
    /// CraftTableProjection.project：精制台整组投影。
    case craftTableProject
    /// UpgradeOverviewProjection.overviewRecords：升级总览 active + pending 单趟投影。
    case upgradeOverviewRecords
    /// UpgradeOverviewProjection.overviewState：升级总览状态面板投影（独立 allRecords）。
    case upgradeOverviewState
    /// VillageItemState.preferredAssetURLs：图片候选 URL 探测（解码在 UI 层，由 Instruments 采集）。
    case assetCandidateProbe

    /// 稳定事件名（os_signpost 的 name 必须是 StaticString；测试用 description 校验）。
    /// 静态常量，不携带任何敏感数据。
    public var signpostName: StaticString {
        switch self {
        case .villageCatalogProject: "VillageCatalogProjection.project"
        case .buildingGroupProject: "BuildingGroupProjection.project"
        case .craftTableProject: "CraftTableProjection.project"
        case .upgradeOverviewRecords: "UpgradeOverviewProjection.overviewRecords"
        case .upgradeOverviewState: "UpgradeOverviewProjection.overviewState"
        case .assetCandidateProbe: "VillageItemState.preferredAssetURLs"
        }
    }
}

public enum PerformanceSignpost {
    /// 统一命名空间（静态标识，无敏感数据）。category 区分投影与资产探测。
    private static let projectionLog = OSLog(
        subsystem: "com.local.coc-helper",
        category: "perf.projection"
    )

    /// 开启区间。`dataScale`/`count` 为整数（数据规模与计数），不得传字符串/ID。
    public static func begin(
        _ event: PerformanceEvent,
        dataScale: Int,
        count: Int
    ) -> OSSignpostID {
        // OSSignpostID(log:) 每次调用生成唯一 ID；事件名由 os_signpost 的 name 参数
        // 单独携带（本 SDK 无 OSSignpostID(log:name:) 初始化器）。
        let id = OSSignpostID(log: projectionLog)
        os_signpost(
            .begin,
            log: projectionLog,
            name: event.signpostName,
            signpostID: id,
            "scale=%d count=%d",
            dataScale,
            count
        )
        return id
    }

    /// 关闭区间。`cacheHit`（可选布尔，0/1）与 `count`（可选整数）只记录
    /// 缓存命中/计数，不得记录敏感数据。基线期无缓存，调用方可省略。
    public static func end(
        _ event: PerformanceEvent,
        id: OSSignpostID,
        cacheHit: Bool? = nil,
        count: Int? = nil
    ) {
        switch (cacheHit, count) {
        case (.some(let ch), .some(let c)):
            os_signpost(
                .end,
                log: projectionLog,
                name: event.signpostName,
                signpostID: id,
                "cache=%d count=%d",
                ch ? 1 : 0,
                c
            )
        case (.some(let ch), .none):
            os_signpost(
                .end,
                log: projectionLog,
                name: event.signpostName,
                signpostID: id,
                "cache=%d",
                ch ? 1 : 0
            )
        case (.none, .some(let c)):
            os_signpost(
                .end,
                log: projectionLog,
                name: event.signpostName,
                signpostID: id,
                "count=%d",
                c
            )
        case (.none, .none):
            os_signpost(
                .end,
                log: projectionLog,
                name: event.signpostName,
                signpostID: id,
                "done"
            )
        }
    }
}
