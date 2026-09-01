import type { ManualUpgradeRecord } from '../types';
import type { LocalQueueCapacityConfig } from './capacity-config';
import {
  effectiveLocalQueueKindForAssignment,
  effectiveLocalQueueKindForRecord,
  localQueueKindsEqual,
  type LocalQueueKind,
} from './local-queue-kind';
import type { QueueAssignmentDecision } from './queue-assignment';

export type LocalQueueOccupancyStatus = 'available' | 'unreconciled' | 'unavailable';

export type LocalQueueOccupancy = {
  readonly queueKind: LocalQueueKind;
  readonly activeManualCount: number;
  readonly confirmedImportedCount: number;
  readonly capacity: number | null;
  readonly status: LocalQueueOccupancyStatus;
};

export function createLocalQueueOccupancy(input: {
  readonly queueKind: LocalQueueKind;
  readonly activeManualCount: number;
  readonly confirmedImportedCount?: number;
  readonly capacity: number | null;
  readonly status?: LocalQueueOccupancyStatus;
}): LocalQueueOccupancy {
  return {
    queueKind: input.queueKind,
    activeManualCount: input.activeManualCount,
    confirmedImportedCount: input.confirmedImportedCount ?? 0,
    capacity: input.capacity,
    status: input.status ?? 'available',
  };
}

export function localQueueOccupancyTotalCount(occupancy: LocalQueueOccupancy): number {
  return occupancy.activeManualCount + occupancy.confirmedImportedCount;
}

export function localQueueOccupancyIsCapacityConfigured(occupancy: LocalQueueOccupancy): boolean {
  return occupancy.capacity !== null;
}

export function localQueueOccupancyIsFull(occupancy: LocalQueueOccupancy): boolean {
  if (occupancy.status !== 'available' || occupancy.capacity === null) {
    return false;
  }
  return localQueueOccupancyTotalCount(occupancy) >= occupancy.capacity;
}

export function localQueueOccupancyAvailableSlots(occupancy: LocalQueueOccupancy): number | null {
  if (occupancy.status !== 'available' || occupancy.capacity === null) {
    return null;
  }
  return Math.max(0, occupancy.capacity - localQueueOccupancyTotalCount(occupancy));
}

export function resolveLocalQueueOccupancy(input: {
  readonly queueKind: LocalQueueKind;
  readonly activeRecords: readonly ManualUpgradeRecord[];
  readonly confirmedAssignments?: readonly QueueAssignmentDecision[];
  readonly capacityConfig: LocalQueueCapacityConfig | null;
  readonly nowMs: number;
}): LocalQueueOccupancy {
  const activeManualCount = input.activeRecords.filter((record) => {
    if (record.status !== 'active') {
      return false;
    }
    const effectiveKind = effectiveLocalQueueKindForRecord(record);
    if (effectiveKind === null || !localQueueKindsEqual(effectiveKind, input.queueKind)) {
      return false;
    }
    return record.expectedEndAtMs > input.nowMs;
  }).length;

  const confirmedImportedCount = (input.confirmedAssignments ?? []).filter((assignment) => {
    if (assignment.status !== 'userAssigned') {
      return false;
    }
    const effectiveKind = effectiveLocalQueueKindForAssignment(assignment);
    return effectiveKind !== null && localQueueKindsEqual(effectiveKind, input.queueKind);
  }).length;

  return createLocalQueueOccupancy({
    queueKind: input.queueKind,
    activeManualCount,
    confirmedImportedCount,
    capacity: input.capacityConfig?.capacity ?? null,
  });
}
