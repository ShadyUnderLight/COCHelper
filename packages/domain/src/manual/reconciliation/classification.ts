import type { UuidString } from '@coc-helper/wire';

import type { ManualUpgradeRecord } from '../types';
import type { ReconciliationObservation, RelatedChangeEvidence } from './evidence';
import {
  confirmedReconciliationRecords,
  distributionsEqual,
  hasProtectableReconciliationLocalState,
  manualLevelDistributionDominates,
} from './helpers';
import type {
  ManualReconciliationClassification,
  ManualReconciliationTimeConfidence,
} from './types';

export function classifyReconciliationItem(input: {
  readonly duplicate: boolean;
  readonly lineageComparable: boolean;
  readonly timeConfidence: ManualReconciliationTimeConfidence;
  readonly hasExistingState: boolean;
  readonly hasProtectableLocalState: boolean;
  readonly previousDistribution: import('../types').ManualLevelDistribution | null;
  readonly observation: ReconciliationObservation | undefined;
  readonly previousObservation: ReconciliationObservation | undefined;
  readonly records: readonly ManualUpgradeRecord[];
  readonly confirmedRecordIDs: readonly UuidString[];
  readonly changes: readonly RelatedChangeEvidence[];
}): ManualReconciliationClassification {
  if (input.duplicate) {
    return 'duplicate';
  }
  if (!input.lineageComparable && input.hasExistingState) {
    return 'lineageMismatch';
  }
  if (input.timeConfidence === 'sourceTimestampConflict' && input.hasExistingState) {
    return 'staleImport';
  }
  if (
    input.observation?.hasTimer === true &&
    input.records.some((record) => record.status === 'active') &&
    input.confirmedRecordIDs.length === 0
  ) {
    return 'possibleDuplicate';
  }
  if (
    input.observation === undefined ||
    !input.observation.distributionComplete ||
    input.observation.distribution === null
  ) {
    return 'unknown';
  }
  const observed = input.observation.distribution;
  if (!input.hasProtectableLocalState) {
    return 'newObservation';
  }
  if (input.observation.sectionTrustGatesOpen === false) {
    return 'unknown';
  }
  if (input.previousDistribution === null) {
    return 'unknown';
  }

  const timerEnded = (input.previousObservation?.hasTimer ?? false) && !input.observation.hasTimer;
  if (timerEnded) {
    if (
      input.previousObservation?.timerCoverageComplete !== true ||
      !input.observation.timerCoverageComplete
    ) {
      return 'unknown';
    }
    if (
      distributionsEqual(observed, input.previousDistribution) &&
      input.records.some((record) => record.status === 'active')
    ) {
      return 'observedTimerEnded';
    }
  }
  if (
    input.timeConfidence === 'sourceTimestampAbsent' ||
    input.timeConfidence === 'localAppliedAtOnly'
  ) {
    return 'unknown';
  }
  if (distributionsEqual(observed, input.previousDistribution)) {
    return 'exactMatch';
  }
  if (manualLevelDistributionDominates(observed, input.previousDistribution)) {
    if (
      input.records.some((record) => record.status === 'active') &&
      input.confirmedRecordIDs.length === 0
    ) {
      return 'unknown';
    }
    return 'observedAhead';
  }
  if (manualLevelDistributionDominates(input.previousDistribution, observed)) {
    return 'manualAhead';
  }
  if (input.changes.some((change) => change.coverageState !== 'complete')) {
    return 'unknown';
  }
  return 'conflict';
}

export function computeConfirmedRecordIDs(input: {
  readonly lineageComparable: boolean;
  readonly timeConfidence: ManualReconciliationTimeConfidence;
  readonly records: readonly ManualUpgradeRecord[];
  readonly previousObservation: ReconciliationObservation | undefined;
  readonly observation: ReconciliationObservation | undefined;
  readonly sourceTimestampMs: number | null;
}): readonly UuidString[] {
  if (!input.lineageComparable || input.timeConfidence !== 'reliableSourceTimestamp') {
    return [];
  }
  return confirmedReconciliationRecords(
    input.records,
    input.previousObservation?.distribution ?? null,
    input.observation?.distribution ?? null,
    input.sourceTimestampMs,
    true,
  );
}

export function computeHasProtectableLocalState(input: {
  readonly state: import('../types').ManualItemState | undefined;
  readonly records: readonly ManualUpgradeRecord[];
  readonly previousDistribution: import('../types').ManualLevelDistribution | null;
}): boolean {
  return hasProtectableReconciliationLocalState(
    input.state,
    input.records,
    input.previousDistribution,
  );
}
