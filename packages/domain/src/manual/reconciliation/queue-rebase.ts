import { createQueueAssignmentDecision } from '../queue/queue-assignment';
import type { QueueAssignmentDecision } from '../queue/queue-assignment';
import type { ManualBaselineReference } from '../types';
import { trackerItemKeyStableId } from '../types';
import type { ReconciliationObservation } from './evidence';

export function rebasedQueueAssignments(
  assignments: readonly QueueAssignmentDecision[],
  newReference: ManualBaselineReference,
  observations: ReadonlyMap<string, ReconciliationObservation>,
): readonly QueueAssignmentDecision[] {
  return assignments.map((assignment) => {
    const lineageChanged = assignment.baselineReference.lineageID !== newReference.lineageID;
    const observation = observations.get(trackerItemKeyStableId(assignment.itemKey));
    const timerStillObserved =
      observation?.hasTimer === true &&
      observation.distributionComplete === true &&
      observation.timerCoverageComplete === true;
    let newStatus = assignment.status;
    if (lineageChanged) {
      newStatus = 'unknown';
    } else if (!timerStillObserved) {
      newStatus = 'observedOnly';
    }
    if (newStatus === assignment.status) {
      return assignment;
    }
    return createQueueAssignmentDecision({
      decisionID: assignment.decisionID,
      villageID: assignment.villageID,
      itemKey: assignment.itemKey,
      baselineReference: assignment.baselineReference,
      queueKind: assignment.queueKind,
      source: assignment.source,
      decidedAtMs: assignment.decidedAtMs,
      status: newStatus,
    });
  });
}
