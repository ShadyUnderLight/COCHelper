import type { CatalogDurationState } from '../../catalog/duration-state';
import type { ManualUpgradeCore, TrackerItemKey } from '../types';
import { capacityConfirmingAssignments } from '../queue-assignment-eligibility';
import type { LocalQueueCapacityConfig } from './capacity-config';
import {
  inferredLocalQueueKindForItemKeyAndDuration,
  type LocalQueueKind,
} from './local-queue-kind';
import { localQueueOccupancyIsFull, resolveLocalQueueOccupancy } from './occupancy';
import type { QueueAssignmentDecision } from './queue-assignment';

export type QueueCapacityGateError =
  | { readonly kind: 'invalidQueueKind' }
  | {
      readonly kind: 'queueCapacityFull';
      readonly queueKind: LocalQueueKind;
      readonly activeCount: number;
      readonly confirmedImportedCount: number;
      readonly capacity: number;
    };

export function validateStartAgainstQueueCapacity(input: {
  readonly itemKey: TrackerItemKey;
  readonly durationState: CatalogDurationState | null | undefined;
  readonly core: ManualUpgradeCore;
  readonly queueCapacityConfigs: readonly LocalQueueCapacityConfig[];
  readonly queueAssignments: readonly QueueAssignmentDecision[];
  readonly requestedQueueKind?: LocalQueueKind | null;
  readonly nowMs: number;
}): QueueCapacityGateError | null {
  const inferredQueueKind = inferredLocalQueueKindForItemKeyAndDuration(
    input.itemKey,
    input.durationState,
  );
  if (input.requestedQueueKind !== undefined && input.requestedQueueKind !== null) {
    if (
      inferredQueueKind === null ||
      inferredQueueKind.rawValue !== input.requestedQueueKind.rawValue
    ) {
      return { kind: 'invalidQueueKind' };
    }
  }
  if (inferredQueueKind === null) {
    return null;
  }

  const config =
    input.queueCapacityConfigs.find(
      (entry) => entry.queueKind.rawValue === inferredQueueKind.rawValue,
    ) ?? null;
  if (config === null) {
    return null;
  }

  const confirmed = capacityConfirmingAssignments({
    core: input.core,
    queueAssignments: input.queueAssignments,
    queueKind: inferredQueueKind,
  });
  const occupancy = resolveLocalQueueOccupancy({
    queueKind: inferredQueueKind,
    activeRecords: input.core.records,
    confirmedAssignments: confirmed,
    capacityConfig: config,
    nowMs: input.nowMs,
  });
  if (localQueueOccupancyIsFull(occupancy)) {
    return {
      kind: 'queueCapacityFull',
      queueKind: inferredQueueKind,
      activeCount: occupancy.activeManualCount,
      confirmedImportedCount: occupancy.confirmedImportedCount,
      capacity: config.capacity,
    };
  }
  return null;
}
