import Foundation

/// Issue #188 / #272：queue assignment 占用确认谓词，与 TypeScript 对齐。
public enum ManualQueueAssignmentEligibility {
    public static func capacityConfirmingAssignments(
        core: ManualUpgradeCore,
        queueAssignments: [QueueAssignmentDecision],
        queueKind: LocalQueueKind
    ) -> [QueueAssignmentDecision] {
        let currentLineage = core.baselineReference?.lineageID
        return queueAssignments.filter { assignment in
            guard assignment.status == .userAssigned,
                  assignment.baselineReference.lineageID == currentLineage else {
                return false
            }
            guard LocalQueueKindResolver.effective(for: assignment) == queueKind else {
                return false
            }
            return core.itemStates
                .first(where: { $0.itemKey == assignment.itemKey })?
                .isQueueAssignmentConfirmable == true
        }
    }
}
