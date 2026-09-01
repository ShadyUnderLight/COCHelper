import {
  manualLevelDistributionIsEmpty,
  trackerItemKeyStableId,
  type ManualImportedObservation,
  type ManualItemState,
  type ManualUpgradeCore,
} from './types';
import { coreBaselineLineageID } from './baseline-gate';
import {
  effectiveLocalQueueKindForAssignment,
  localQueueKindsEqual,
  type LocalQueueKind,
} from './queue/local-queue-kind';
import type { QueueAssignmentDecision } from './queue/queue-assignment';

export function manualImportedObservationHasCompleteCoverage(
  observation: ManualImportedObservation,
): boolean {
  const distribution = observation.levelDistribution;
  if (distribution === null || manualLevelDistributionIsEmpty(distribution)) {
    return false;
  }
  return true;
}

export function isManualItemStateQueueAssignmentConfirmable(state: ManualItemState): boolean {
  const observation = state.importedObservation;
  if (observation === null || observation === undefined) {
    return false;
  }
  return (
    observation.observedTimer &&
    observation.observedTimerCoverageComplete &&
    manualImportedObservationHasCompleteCoverage(observation)
  );
}

export function capacityConfirmingAssignments(input: {
  readonly core: ManualUpgradeCore;
  readonly queueAssignments: readonly QueueAssignmentDecision[];
  readonly queueKind: LocalQueueKind;
}): readonly QueueAssignmentDecision[] {
  const currentLineage = coreBaselineLineageID(input.core);
  return input.queueAssignments.filter((assignment) => {
    if (assignment.status !== 'userAssigned') {
      return false;
    }
    if (assignment.baselineReference.lineageID !== currentLineage) {
      return false;
    }
    const effectiveKind = effectiveLocalQueueKindForAssignment(assignment);
    if (effectiveKind === null || !localQueueKindsEqual(effectiveKind, input.queueKind)) {
      return false;
    }
    const itemState = input.core.itemStates.find(
      (state) =>
        trackerItemKeyStableId(state.itemKey) === trackerItemKeyStableId(assignment.itemKey),
    );
    return itemState !== undefined && isManualItemStateQueueAssignmentConfirmable(itemState);
  });
}
