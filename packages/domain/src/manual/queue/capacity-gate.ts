import type { CatalogDurationState } from '../../catalog/duration-state';
import type { ManualBaselineReference, ManualUpgradeCore, TrackerItemKey } from '../types';
import type { LocalQueueCapacityConfig } from './capacity-config';
import {
  inferredLocalQueueKindForItemKeyAndDuration,
  type LocalQueueKind,
} from './local-queue-kind';
import { localQueueOccupancyIsFull, type LocalQueueOccupancy } from './occupancy';
import { projectQueueOccupancy } from './occupancy-projection';
import type { QueueAssignmentDecision } from './queue-assignment';

export type QueueCapacityGateError =
  | { readonly kind: 'invalidQueueKind' }
  | {
      readonly kind: 'occupancyNotAvailable';
      readonly status: 'unavailable' | 'unreconciled';
    }
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
  readonly currentBaseline: ManualBaselineReference | null;
  readonly storeAvailable: boolean;
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

  const occupancy = projectQueueOccupancy({
    queueKind: inferredQueueKind,
    core: input.core,
    currentBaseline: input.currentBaseline,
    storeAvailable: input.storeAvailable,
    queueCapacityConfigs: input.queueCapacityConfigs,
    queueAssignments: input.queueAssignments,
    nowMs: input.nowMs,
  });
  return validateProjectedQueueCapacity({
    occupancy,
    queueKind: inferredQueueKind,
    capacity: config.capacity,
  });
}

export function validateProjectedQueueCapacity(input: {
  readonly occupancy: LocalQueueOccupancy;
  readonly queueKind: LocalQueueKind;
  readonly capacity: number;
}): QueueCapacityGateError | null {
  if (input.occupancy.status === 'unavailable') {
    return { kind: 'occupancyNotAvailable', status: 'unavailable' };
  }
  if (input.occupancy.status === 'unreconciled') {
    return { kind: 'occupancyNotAvailable', status: 'unreconciled' };
  }
  if (localQueueOccupancyIsFull(input.occupancy)) {
    return {
      kind: 'queueCapacityFull',
      queueKind: input.queueKind,
      activeCount: input.occupancy.activeManualCount,
      confirmedImportedCount: input.occupancy.confirmedImportedCount,
      capacity: input.capacity,
    };
  }
  return null;
}
