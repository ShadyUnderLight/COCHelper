import Foundation

public enum ManualQueueCapacityGateError: Equatable, Sendable {
    case invalidQueueKind
    case occupancyNotAvailable(LocalQueueOccupancyStatus)
    case queueCapacityFull(
        queueKind: LocalQueueKind,
        activeCount: Int,
        confirmedImportedCount: Int,
        capacity: Int
    )
}

/// Issue #272 / PR #249：Start 容量 gate，与 TypeScript `validateStartAgainstQueueCapacity` 对齐。
public enum ManualQueueCapacityGate {
    public static func validateStartAgainstQueueCapacity(
        itemKey: TrackerItemKey,
        durationState: CatalogDurationState?,
        core: ManualUpgradeCore,
        queueCapacityConfigs: [LocalQueueCapacityConfig],
        queueAssignments: [QueueAssignmentDecision],
        currentBaseline: ManualBaselineReference?,
        storeAvailable: Bool,
        requestedQueueKind: LocalQueueKind?,
        now: Date
    ) -> ManualQueueCapacityGateError? {
        let inferredQueueKind = LocalQueueKindResolver.inferred(
            for: itemKey,
            durationState: durationState
        )
        if let requestedQueueKind {
            if inferredQueueKind == nil || requestedQueueKind != inferredQueueKind {
                return .invalidQueueKind
            }
        }
        guard let inferredQueueKind else {
            return nil
        }

        let config = queueCapacityConfigs.first(where: { $0.queueKind == inferredQueueKind })
        guard let config else {
            return nil
        }

        let occupancy = ManualQueueOccupancyProjection.project(
            queueKind: inferredQueueKind,
            core: core,
            currentBaseline: currentBaseline,
            storeAvailable: storeAvailable,
            queueCapacityConfigs: queueCapacityConfigs,
            queueAssignments: queueAssignments,
            at: now
        )
        return validateProjectedQueueCapacity(
            occupancy: occupancy,
            queueKind: inferredQueueKind,
            capacity: config.capacity
        )
    }

    public static func validateProjectedQueueCapacity(
        occupancy: LocalQueueOccupancy,
        queueKind: LocalQueueKind,
        capacity: Int
    ) -> ManualQueueCapacityGateError? {
        switch occupancy.status {
        case .unavailable:
            return .occupancyNotAvailable(.unavailable)
        case .unreconciled:
            return .occupancyNotAvailable(.unreconciled)
        case .available:
            break
        }
        guard occupancy.isFull else {
            return nil
        }
        return .queueCapacityFull(
            queueKind: queueKind,
            activeCount: occupancy.activeManualCount,
            confirmedImportedCount: occupancy.confirmedImportedCount,
            capacity: capacity
        )
    }
}

/// Issue #192：occupancy 三态投影，与 TypeScript `projectQueueOccupancy` 对齐。
public enum ManualQueueOccupancyProjection {
    public static func project(
        queueKind: LocalQueueKind,
        core: ManualUpgradeCore,
        currentBaseline: ManualBaselineReference?,
        storeAvailable: Bool,
        queueCapacityConfigs: [LocalQueueCapacityConfig],
        queueAssignments: [QueueAssignmentDecision],
        at now: Date
    ) -> LocalQueueOccupancy {
        let config = queueCapacityConfigs.first(where: { $0.queueKind == queueKind })

        guard storeAvailable else {
            return LocalQueueOccupancy(
                queueKind: queueKind,
                activeManualCount: 0,
                confirmedImportedCount: 0,
                capacity: config?.capacity,
                status: .unavailable
            )
        }

        if !ManualBaselineGate.isBaselineReconciled(core: core, currentBaseline: currentBaseline) {
            let status: LocalQueueOccupancyStatus = currentBaseline == nil ? .unavailable : .unreconciled
            return LocalQueueOccupancy(
                queueKind: queueKind,
                activeManualCount: 0,
                confirmedImportedCount: 0,
                capacity: config?.capacity,
                status: status
            )
        }

        let confirmed = ManualQueueAssignmentEligibility.capacityConfirmingAssignments(
            core: core,
            queueAssignments: queueAssignments,
            queueKind: queueKind
        )
        return LocalQueueOccupancyResolver.occupancy(
            queueKind: queueKind,
            activeRecords: core.activeRecords,
            confirmedAssignments: confirmed,
            capacityConfig: config,
            at: now
        )
    }
}
