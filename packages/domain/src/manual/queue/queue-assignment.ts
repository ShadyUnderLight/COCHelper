import type { UuidString } from '@coc-helper/wire';

import {
  isManualBaselineReferenceStructurallyValid,
  isTrackerItemKeyStructurallyValid,
} from '../models';
import type { ManualBaselineReference, TrackerItemKey } from '../types';
import type { LocalQueueCapacitySource } from './capacity-config';
import type { LocalQueueKind } from './local-queue-kind';

export type QueueAssignmentStatus = 'userAssigned' | 'observedOnly' | 'unknown';

export type QueueAssignmentError =
  | { readonly kind: 'invalidItemKey' }
  | { readonly kind: 'invalidBaselineReference' }
  | { readonly kind: 'invalidTimestamp' }
  | { readonly kind: 'villageMismatch' };

export type QueueAssignmentDecision = {
  readonly decisionID: UuidString;
  readonly villageID: UuidString;
  readonly itemKey: TrackerItemKey;
  readonly baselineReference: ManualBaselineReference;
  readonly queueKind: LocalQueueKind;
  readonly source: LocalQueueCapacitySource;
  readonly decidedAtMs: number;
  readonly status: QueueAssignmentStatus;
};

export function createQueueAssignmentDecision(input: {
  readonly decisionID: UuidString;
  readonly villageID: UuidString;
  readonly itemKey: TrackerItemKey;
  readonly baselineReference: ManualBaselineReference;
  readonly queueKind: LocalQueueKind;
  readonly source?: LocalQueueCapacitySource;
  readonly decidedAtMs: number;
  readonly status?: QueueAssignmentStatus;
}): QueueAssignmentDecision {
  if (!isTrackerItemKeyStructurallyValid(input.itemKey)) {
    throw { kind: 'invalidItemKey' } satisfies QueueAssignmentError;
  }
  if (!isManualBaselineReferenceStructurallyValid(input.baselineReference)) {
    throw { kind: 'invalidBaselineReference' } satisfies QueueAssignmentError;
  }
  if (!Number.isFinite(input.decidedAtMs)) {
    throw { kind: 'invalidTimestamp' } satisfies QueueAssignmentError;
  }
  return {
    decisionID: input.decisionID,
    villageID: input.villageID,
    itemKey: input.itemKey,
    baselineReference: input.baselineReference,
    queueKind: input.queueKind,
    source: input.source ?? 'userConfigured',
    decidedAtMs: input.decidedAtMs,
    status: input.status ?? 'userAssigned',
  };
}

export function queueAssignmentErrorsEqual(
  left: QueueAssignmentError,
  right: QueueAssignmentError,
): boolean {
  return left.kind === right.kind;
}
