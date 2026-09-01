import type { ManualUpgradeCore } from '../types';
import type { ManualBaselineReference } from '../types';
import { isBaselineReconciled } from '../baseline-gate';
import { capacityConfirmingAssignments } from '../queue-assignment-eligibility';
import type { LocalQueueCapacityConfig } from './capacity-config';
import {
  createLocalQueueOccupancy,
  resolveLocalQueueOccupancy,
  type LocalQueueOccupancy,
} from './occupancy';
import type { LocalQueueKind } from './local-queue-kind';
import type { QueueAssignmentDecision } from './queue-assignment';

export function projectQueueOccupancy(input: {
  readonly queueKind: LocalQueueKind;
  readonly core: ManualUpgradeCore;
  readonly currentBaseline: ManualBaselineReference | null;
  readonly storeAvailable: boolean;
  readonly queueCapacityConfigs: readonly LocalQueueCapacityConfig[];
  readonly queueAssignments: readonly QueueAssignmentDecision[];
  readonly nowMs: number;
}): LocalQueueOccupancy {
  const config =
    input.queueCapacityConfigs.find(
      (entry) => entry.queueKind.rawValue === input.queueKind.rawValue,
    ) ?? null;

  if (!input.storeAvailable) {
    return createLocalQueueOccupancy({
      queueKind: input.queueKind,
      activeManualCount: 0,
      confirmedImportedCount: 0,
      capacity: config?.capacity ?? null,
      status: 'unavailable',
    });
  }

  if (
    !isBaselineReconciled({
      core: input.core,
      currentBaseline: input.currentBaseline,
    })
  ) {
    const status = input.currentBaseline === null ? 'unavailable' : 'unreconciled';
    return createLocalQueueOccupancy({
      queueKind: input.queueKind,
      activeManualCount: 0,
      confirmedImportedCount: 0,
      capacity: config?.capacity ?? null,
      status,
    });
  }

  const confirmed = capacityConfirmingAssignments({
    core: input.core,
    queueAssignments: input.queueAssignments,
    queueKind: input.queueKind,
  });

  return resolveLocalQueueOccupancy({
    queueKind: input.queueKind,
    activeRecords: input.core.records,
    confirmedAssignments: confirmed,
    capacityConfig: config,
    nowMs: input.nowMs,
  });
}
