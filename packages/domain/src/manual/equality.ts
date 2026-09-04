import type { CatalogUpgradeCost } from '../catalog/types';
import type {
  ManualBaselineReference,
  ManualCatalogProvenance,
  ManualImportedObservation,
  ManualItemState,
  ManualLevelDistribution,
  ManualUpgradeCore,
  ManualUpgradeRecord,
  TrackerItemKey,
} from './types';
import { trackerItemKeyStableId } from './types';

export function baselineReferencesEqual(
  left: ManualBaselineReference,
  right: ManualBaselineReference,
): boolean {
  return left.revision === right.revision && (left.lineageID ?? null) === (right.lineageID ?? null);
}

export function trackerItemKeysEqual(left: TrackerItemKey, right: TrackerItemKey): boolean {
  return trackerItemKeyStableId(left) === trackerItemKeyStableId(right);
}

export function manualLevelDistributionsEqual(
  left: ManualLevelDistribution,
  right: ManualLevelDistribution,
): boolean {
  if (left.levels.length !== right.levels.length) {
    return false;
  }
  for (let index = 0; index < left.levels.length; index += 1) {
    const leftEntry = left.levels[index]!;
    const rightEntry = right.levels[index]!;
    if (leftEntry.level !== rightEntry.level || leftEntry.quantity !== rightEntry.quantity) {
      return false;
    }
  }
  return true;
}

export function manualImportedObservationsEqual(
  left: ManualImportedObservation | null,
  right: ManualImportedObservation | null,
): boolean {
  if (left === null || right === null) {
    return left === right;
  }
  const leftDistribution = left.levelDistribution;
  const rightDistribution = right.levelDistribution;
  return (
    baselineReferencesEqual(left.reference, right.reference) &&
    left.observedTimer === right.observedTimer &&
    left.observedTimerCoverageComplete === right.observedTimerCoverageComplete &&
    left.sourceTimestampMs === right.sourceTimestampMs &&
    (leftDistribution === null && rightDistribution === null
      ? true
      : leftDistribution !== null &&
        rightDistribution !== null &&
        manualLevelDistributionsEqual(leftDistribution, rightDistribution))
  );
}

export function manualItemStatesEqual(left: ManualItemState, right: ManualItemState): boolean {
  return (
    trackerItemKeysEqual(left.itemKey, right.itemKey) &&
    baselineReferencesEqual(left.baselineReference, right.baselineReference) &&
    left.status === right.status &&
    manualLevelDistributionsEqual(
      left.manualCompletedDistribution,
      right.manualCompletedDistribution,
    ) &&
    manualImportedObservationsEqual(left.importedObservation, right.importedObservation)
  );
}

export function catalogUpgradeCostsEqual(
  left: readonly CatalogUpgradeCost[] | null,
  right: readonly CatalogUpgradeCost[] | null,
): boolean {
  if (left === null || right === null) {
    return left === right;
  }
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    const leftCost = left[index]!;
    const rightCost = right[index]!;
    if (
      leftCost.resource !== rightCost.resource ||
      leftCost.amount !== rightCost.amount ||
      leftCost.rawResource !== rightCost.rawResource ||
      leftCost.rawAmount !== rightCost.rawAmount ||
      leftCost.parseFailed !== rightCost.parseFailed
    ) {
      return false;
    }
  }
  return true;
}

export function manualCatalogProvenanceEqual(
  left: ManualCatalogProvenance,
  right: ManualCatalogProvenance,
): boolean {
  return (
    left.gameVersion === right.gameVersion &&
    (left.buildTag ?? null) === (right.buildTag ?? null) &&
    (left.manifestSchemaVersion ?? null) === (right.manifestSchemaVersion ?? null)
  );
}

export function manualUpgradeRecordsEqual(
  left: ManualUpgradeRecord,
  right: ManualUpgradeRecord,
): boolean {
  return (
    left.recordID === right.recordID &&
    trackerItemKeysEqual(left.itemKey, right.itemKey) &&
    left.fromLevel === right.fromLevel &&
    left.targetLevel === right.targetLevel &&
    left.quantity === right.quantity &&
    left.startedAtMs === right.startedAtMs &&
    left.expectedEndAtMs === right.expectedEndAtMs &&
    left.durationSeconds === right.durationSeconds &&
    left.durationKind === right.durationKind &&
    left.status === right.status &&
    left.queueKind === right.queueKind &&
    baselineReferencesEqual(left.baselineReference, right.baselineReference) &&
    manualCatalogProvenanceEqual(left.catalogProvenance, right.catalogProvenance) &&
    catalogUpgradeCostsEqual(left.frozenCosts, right.frozenCosts)
  );
}

export function manualUpgradeCoresEqual(
  left: ManualUpgradeCore,
  right: ManualUpgradeCore,
): boolean {
  if (
    left.itemStates.length !== right.itemStates.length ||
    left.records.length !== right.records.length
  ) {
    return false;
  }
  for (let index = 0; index < left.itemStates.length; index += 1) {
    if (!manualItemStatesEqual(left.itemStates[index]!, right.itemStates[index]!)) {
      return false;
    }
  }
  for (let index = 0; index < left.records.length; index += 1) {
    if (!manualUpgradeRecordsEqual(left.records[index]!, right.records[index]!)) {
      return false;
    }
  }
  return true;
}
