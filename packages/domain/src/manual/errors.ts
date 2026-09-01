import type { TrackerItemKey } from './types';
import { trackerItemKeyStableId } from './types';

import type { CatalogDurationState } from '../catalog/duration-state';

export type ManualUpgradeError =
  | { readonly kind: 'invalidItemKey' }
  | { readonly kind: 'invalidBaselineReference' }
  | { readonly kind: 'invalidCatalogProvenance' }
  | { readonly kind: 'invalidLevel' }
  | { readonly kind: 'invalidQuantity' }
  | { readonly kind: 'arithmeticOverflow' }
  | { readonly kind: 'missingItemState'; readonly itemKey: TrackerItemKey }
  | { readonly kind: 'unavailableItemState'; readonly itemKey: TrackerItemKey }
  | { readonly kind: 'conflictingItemState'; readonly itemKey: TrackerItemKey }
  | { readonly kind: 'baselineMismatch'; readonly itemKey: TrackerItemKey }
  | {
      readonly kind: 'insufficientQuantity';
      readonly level: number;
      readonly requested: bigint;
      readonly available: bigint;
    }
  | { readonly kind: 'futureStart' }
  | { readonly kind: 'invalidDuration' }
  | { readonly kind: 'durationUnavailable'; readonly durationState: CatalogDurationState }
  | { readonly kind: 'duplicateRecordID'; readonly recordID: string }
  | { readonly kind: 'recordNotFound'; readonly recordID: string }
  | { readonly kind: 'recordNotActive'; readonly recordID: string }
  | { readonly kind: 'cannotCancelCompleted'; readonly recordID: string }
  | { readonly kind: 'invalidRecord' };

export function manualUpgradeErrorEquals(
  left: ManualUpgradeError,
  right: ManualUpgradeError,
): boolean {
  if (left.kind !== right.kind) {
    return false;
  }
  switch (left.kind) {
    case 'missingItemState':
    case 'unavailableItemState':
    case 'conflictingItemState':
    case 'baselineMismatch':
      return right.kind === left.kind && trackerItemKeysEqual(left.itemKey, right.itemKey);
    case 'insufficientQuantity':
      return (
        right.kind === 'insufficientQuantity' &&
        left.level === right.level &&
        left.requested === right.requested &&
        left.available === right.available
      );
    case 'durationUnavailable':
      return (
        right.kind === 'durationUnavailable' &&
        durationStatesEqual(left.durationState, right.durationState)
      );
    case 'duplicateRecordID':
    case 'recordNotFound':
    case 'recordNotActive':
    case 'cannotCancelCompleted':
      return right.kind === left.kind && left.recordID === right.recordID;
    default:
      return true;
  }
}

function trackerItemKeysEqual(left: TrackerItemKey, right: TrackerItemKey): boolean {
  return trackerItemKeyStableId(left) === trackerItemKeyStableId(right);
}

function durationStatesEqual(left: CatalogDurationState, right: CatalogDurationState): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

export type ManualReconciliationError =
  | { readonly kind: 'villageMismatch' }
  | { readonly kind: 'stalePreview' }
  | { readonly kind: 'invalidObservation'; readonly message: string };

export type ManualTrackerStoreError =
  | { readonly kind: 'unavailable'; readonly message: string }
  | { readonly kind: 'corrupt'; readonly message: string }
  | { readonly kind: 'unsupportedSchema'; readonly version: number }
  | { readonly kind: 'invalidEnvelope'; readonly message: string }
  | { readonly kind: 'writeFailed'; readonly message: string };

export function manualReconciliationErrorsEqual(
  left: ManualReconciliationError,
  right: ManualReconciliationError,
): boolean {
  if (left.kind !== right.kind) {
    return false;
  }
  if (left.kind === 'invalidObservation' && right.kind === 'invalidObservation') {
    return left.message === right.message;
  }
  return true;
}

export function manualTrackerStoreErrorsEqual(
  left: ManualTrackerStoreError,
  right: ManualTrackerStoreError,
): boolean {
  if (left.kind !== right.kind) {
    return false;
  }
  switch (left.kind) {
    case 'unavailable':
    case 'corrupt':
    case 'invalidEnvelope':
    case 'writeFailed':
      return right.kind === left.kind && left.message === (right as typeof left).message;
    case 'unsupportedSchema':
      return right.kind === 'unsupportedSchema' && left.version === right.version;
  }
}
