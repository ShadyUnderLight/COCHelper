import type { UuidString } from '@coc-helper/wire';

import type { CatalogUpgradeCost } from '../catalog/types';
import type { ManualUpgradeError } from './errors';
import {
  assertValidManualLevel,
  assertValidManualNonNegativeInt64,
  assertValidManualQuantity,
  createManualLevelDistribution,
  MANUAL_LEVEL_DISTRIBUTION_EMPTY,
} from './level-distribution';
import { baselineReferencesEqual } from './equality';
import type {
  ManualBaselineReference,
  ManualCatalogProvenance,
  ManualImportedObservation,
  ManualItemState,
  ManualItemStatus,
  ManualUpgradeDurationKind,
  ManualUpgradeRecord,
  ManualUpgradeRecordStatus,
  TrackerItemKey,
} from './types';

export function isTrackerItemKeyStructurallyValid(key: TrackerItemKey): boolean {
  if (key.rawSection.length === 0 || key.dataID <= 0n) {
    return false;
  }
  switch (key.nestedKind) {
    case 'root':
      return key.nestedRootIdentity === null && key.nestedPath.length === 0;
    case 'type':
    case 'module':
      if (key.nestedRootIdentity === null || key.nestedPath.length === 0) {
        return false;
      }
      if (
        !isTrackerRootIdentityStructurallyValid(key.nestedRootIdentity) ||
        key.nestedRootIdentity.base !== key.base ||
        key.nestedRootIdentity.rawSection !== key.rawSection
      ) {
        return false;
      }
      if (!key.nestedPath.every(isTrackerNestedPathComponentStructurallyValid)) {
        return false;
      }
      return (
        key.nestedPath.at(-1)?.kind === key.nestedKind &&
        key.nestedPath.at(-1)?.dataID === key.dataID
      );
  }
}

function isTrackerRootIdentityStructurallyValid(identity: {
  readonly rawSection: string;
  readonly dataID: bigint;
}): boolean {
  return identity.rawSection.length > 0 && identity.dataID > 0n;
}

function isTrackerNestedPathComponentStructurallyValid(component: {
  readonly kind: string;
  readonly dataID: bigint;
}): boolean {
  return component.kind !== 'root' && component.dataID > 0n;
}

export function isManualBaselineReferenceStructurallyValid(
  reference: ManualBaselineReference,
): boolean {
  return reference.revision.trim().length > 0;
}

export function isManualCatalogProvenanceStructurallyValid(
  provenance: ManualCatalogProvenance,
): boolean {
  return provenance.gameVersion.trim().length > 0;
}

export function createManualImportedObservation(input: {
  readonly reference: ManualBaselineReference;
  readonly levelDistribution: ReturnType<typeof createManualLevelDistribution> | null;
  readonly sourceTimestampMs?: number | null;
  readonly observedTimer?: boolean;
  readonly observedTimerCoverageComplete?: boolean;
}): ManualImportedObservation {
  if (!isManualBaselineReferenceStructurallyValid(input.reference)) {
    throw { kind: 'invalidBaselineReference' } satisfies ManualUpgradeError;
  }
  return {
    reference: input.reference,
    levelDistribution: input.levelDistribution,
    sourceTimestampMs: input.sourceTimestampMs ?? null,
    observedTimer: input.observedTimer ?? false,
    observedTimerCoverageComplete: input.observedTimerCoverageComplete ?? false,
  };
}

export function createManualItemState(input: {
  readonly itemKey: TrackerItemKey;
  readonly baselineReference: ManualBaselineReference;
  readonly importedObservation?: ManualImportedObservation | null;
  readonly manualCompletedDistribution?: ReturnType<typeof createManualLevelDistribution>;
  readonly status?: ManualItemStatus;
}): ManualItemState {
  if (!isTrackerItemKeyStructurallyValid(input.itemKey)) {
    throw { kind: 'invalidItemKey' } satisfies ManualUpgradeError;
  }
  if (!isManualBaselineReferenceStructurallyValid(input.baselineReference)) {
    throw { kind: 'invalidBaselineReference' } satisfies ManualUpgradeError;
  }
  const importedObservation = input.importedObservation ?? null;
  if (
    importedObservation !== null &&
    !isManualBaselineReferenceStructurallyValid(importedObservation.reference)
  ) {
    throw { kind: 'invalidBaselineReference' } satisfies ManualUpgradeError;
  }
  if (
    importedObservation !== null &&
    !baselineReferencesEqual(importedObservation.reference, input.baselineReference)
  ) {
    throw { kind: 'baselineMismatch', itemKey: input.itemKey } satisfies ManualUpgradeError;
  }
  const status = input.status ?? 'unknown';
  if (status === 'observed' && importedObservation === null) {
    throw { kind: 'invalidRecord' } satisfies ManualUpgradeError;
  }
  return {
    itemKey: input.itemKey,
    baselineReference: input.baselineReference,
    importedObservation,
    manualCompletedDistribution:
      input.manualCompletedDistribution ?? MANUAL_LEVEL_DISTRIBUTION_EMPTY,
    status,
  };
}

export function isManualItemStateStructurallyValid(state: ManualItemState): boolean {
  if (
    !isTrackerItemKeyStructurallyValid(state.itemKey) ||
    !isManualBaselineReferenceStructurallyValid(state.baselineReference)
  ) {
    return false;
  }
  if (state.importedObservation === null) {
    return state.status !== 'observed';
  }
  return (
    isManualBaselineReferenceStructurallyValid(state.importedObservation.reference) &&
    baselineReferencesEqual(state.importedObservation.reference, state.baselineReference)
  );
}

export function createManualUpgradeRecord(input: {
  readonly recordID: UuidString;
  readonly itemKey: TrackerItemKey;
  readonly fromLevel: number;
  readonly targetLevel: number;
  readonly quantity: bigint;
  readonly startedAtMs: number;
  readonly expectedEndAtMs: number;
  readonly durationSeconds: bigint;
  readonly durationKind: ManualUpgradeDurationKind;
  readonly frozenCosts: readonly CatalogUpgradeCost[] | null;
  readonly catalogProvenance: ManualCatalogProvenance;
  readonly baselineReference: ManualBaselineReference;
  readonly queueKind?: string | null;
  readonly status?: ManualUpgradeRecordStatus;
}): ManualUpgradeRecord {
  if (!isTrackerItemKeyStructurallyValid(input.itemKey)) {
    throw { kind: 'invalidItemKey' } satisfies ManualUpgradeError;
  }
  const fromLevelError = assertValidManualLevel(input.fromLevel);
  if (fromLevelError !== null) {
    throw fromLevelError;
  }
  const targetLevelError = assertValidManualLevel(input.targetLevel);
  if (targetLevelError !== null) {
    throw targetLevelError;
  }
  if (input.targetLevel <= input.fromLevel) {
    throw { kind: 'invalidLevel' } satisfies ManualUpgradeError;
  }
  const quantityError = assertValidManualQuantity(input.quantity);
  if (quantityError !== null) {
    throw quantityError;
  }
  const durationError = assertValidManualNonNegativeInt64(input.durationSeconds);
  if (durationError !== null) {
    throw { kind: 'invalidDuration' } satisfies ManualUpgradeError;
  }
  switch (input.durationKind) {
    case 'timed':
      if (input.durationSeconds <= 0n) {
        throw { kind: 'invalidDuration' } satisfies ManualUpgradeError;
      }
      break;
    case 'instant':
      if (input.durationSeconds !== 0n) {
        throw { kind: 'invalidDuration' } satisfies ManualUpgradeError;
      }
      break;
  }
  if (input.expectedEndAtMs < input.startedAtMs) {
    throw { kind: 'invalidRecord' } satisfies ManualUpgradeError;
  }
  const expectedEndAtMs = computeExpectedEndAtMs(
    input.startedAtMs,
    input.durationSeconds,
    input.durationKind,
  );
  if (input.expectedEndAtMs !== expectedEndAtMs) {
    throw { kind: 'invalidRecord' } satisfies ManualUpgradeError;
  }
  if (!isManualCatalogProvenanceStructurallyValid(input.catalogProvenance)) {
    throw { kind: 'invalidCatalogProvenance' } satisfies ManualUpgradeError;
  }
  if (!isManualBaselineReferenceStructurallyValid(input.baselineReference)) {
    throw { kind: 'invalidBaselineReference' } satisfies ManualUpgradeError;
  }
  return {
    recordID: input.recordID,
    itemKey: input.itemKey,
    fromLevel: input.fromLevel,
    targetLevel: input.targetLevel,
    quantity: input.quantity,
    startedAtMs: input.startedAtMs,
    expectedEndAtMs: input.expectedEndAtMs,
    durationSeconds: input.durationSeconds,
    durationKind: input.durationKind,
    frozenCosts: input.frozenCosts,
    catalogProvenance: input.catalogProvenance,
    baselineReference: input.baselineReference,
    queueKind: input.queueKind ?? null,
    status: input.status ?? 'active',
  };
}

export function computeExpectedEndAtMs(
  startedAtMs: number,
  durationSeconds: bigint,
  durationKind: ManualUpgradeDurationKind,
): number {
  switch (durationKind) {
    case 'instant':
      return startedAtMs;
    case 'timed': {
      const intervalMs = Number(durationSeconds) * 1000;
      if (!Number.isFinite(intervalMs)) {
        throw { kind: 'arithmeticOverflow' } satisfies ManualUpgradeError;
      }
      const expectedEndAtMs = startedAtMs + intervalMs;
      if (!Number.isFinite(expectedEndAtMs) || expectedEndAtMs < startedAtMs) {
        throw { kind: 'arithmeticOverflow' } satisfies ManualUpgradeError;
      }
      return expectedEndAtMs;
    }
  }
}

export {
  baselineReferencesEqual,
  manualItemStatesEqual,
  manualUpgradeRecordsEqual,
  trackerItemKeysEqual,
} from './equality';
