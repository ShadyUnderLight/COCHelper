import { sha256Fingerprint } from '@coc-helper/wire';

import { encodeSwiftSortedJson } from '../account/wire-encode';
import { trackerItemKeyStableId } from './types';
import type { ManualUpgradeCore, ManualUpgradeRecord, ManualItemState } from './types';

type ManualCoreFingerprintMaterial = {
  readonly itemStates: readonly ManualItemState[];
  readonly records: readonly ManualUpgradeRecord[];
};

export function computeManualCoreContentFingerprint(
  itemStates: readonly ManualItemState[],
  records: readonly ManualUpgradeRecord[],
): string {
  const material: ManualCoreFingerprintMaterial = {
    itemStates: [...itemStates].sort((left, right) =>
      trackerItemKeyStableId(left.itemKey).localeCompare(trackerItemKeyStableId(right.itemKey)),
    ),
    records: [...records].sort((left, right) => left.recordID.localeCompare(right.recordID)),
  };
  return sha256Fingerprint(encodeSwiftSortedJson(encodeManualCoreFingerprintMaterial(material)));
}

function encodeManualCoreFingerprintMaterial(material: ManualCoreFingerprintMaterial): unknown {
  return {
    itemStates: material.itemStates.map(encodeManualItemStateWire),
    records: material.records.map(encodeManualUpgradeRecordWire),
  };
}

function encodeManualItemStateWire(state: ManualItemState): unknown {
  return {
    baselineReference: state.baselineReference,
    importedObservation:
      state.importedObservation === null
        ? null
        : {
            levelDistribution: encodeManualLevelDistributionWire(
              state.importedObservation.levelDistribution,
            ),
            observedTimer: state.importedObservation.observedTimer,
            observedTimerCoverageComplete:
              state.importedObservation.observedTimerCoverageComplete,
            reference: state.importedObservation.reference,
            sourceTimestampMs: state.importedObservation.sourceTimestampMs,
          },
    itemKey: encodeTrackerItemKeyWire(state.itemKey),
    manualCompletedDistribution: encodeManualLevelDistributionWire(
      state.manualCompletedDistribution,
    ),
    status: state.status,
  };
}

function encodeManualUpgradeRecordWire(record: ManualUpgradeRecord): unknown {
  return {
    baselineReference: record.baselineReference,
    catalogProvenance: record.catalogProvenance,
    durationKind: record.durationKind,
    durationSeconds: record.durationSeconds,
    expectedEndAtMs: record.expectedEndAtMs,
    fromLevel: record.fromLevel,
    frozenCosts: record.frozenCosts,
    itemKey: encodeTrackerItemKeyWire(record.itemKey),
    quantity: record.quantity,
    queueKind: record.queueKind,
    recordID: record.recordID,
    startedAtMs: record.startedAtMs,
    status: record.status,
    targetLevel: record.targetLevel,
  };
}

function encodeTrackerItemKeyWire(key: ManualItemState['itemKey']): unknown {
  return {
    base: key.base,
    dataID: key.dataID,
    nestedKind: key.nestedKind,
    nestedPath: key.nestedPath,
    nestedRootIdentity: key.nestedRootIdentity,
    rawSection: key.rawSection,
  };
}

function encodeManualLevelDistributionWire(
  distribution: ManualItemState['manualCompletedDistribution'] | null,
): unknown {
  if (distribution === null) {
    return null;
  }
  return distribution.levels.map((entry) => ({
    level: entry.level,
    quantity: entry.quantity,
  }));
}

export function manualUpgradeCoresEqual(left: ManualUpgradeCore, right: ManualUpgradeCore): boolean {
  if (left.itemStates.length !== right.itemStates.length || left.records.length !== right.records.length) {
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

function manualItemStatesEqual(left: ManualItemState, right: ManualItemState): boolean {
  return (
    trackerItemKeyStableId(left.itemKey) === trackerItemKeyStableId(right.itemKey) &&
    baselineReferencesEqual(left.baselineReference, right.baselineReference) &&
    left.status === right.status &&
    levelDistributionEqual(left.manualCompletedDistribution, right.manualCompletedDistribution) &&
    importedObservationsEqual(left.importedObservation, right.importedObservation)
  );
}

function manualUpgradeRecordsEqual(left: ManualUpgradeRecord, right: ManualUpgradeRecord): boolean {
  return (
    left.recordID === right.recordID &&
    trackerItemKeyStableId(left.itemKey) === trackerItemKeyStableId(right.itemKey) &&
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
    left.catalogProvenance.gameVersion === right.catalogProvenance.gameVersion
  );
}

function baselineReferencesEqual(
  left: ManualItemState['baselineReference'],
  right: ManualItemState['baselineReference'],
): boolean {
  return (
    left.revision === right.revision &&
    (left.fingerprint ?? null) === (right.fingerprint ?? null) &&
    (left.lineageID ?? null) === (right.lineageID ?? null)
  );
}

function levelDistributionEqual(
  left: ManualItemState['manualCompletedDistribution'],
  right: ManualItemState['manualCompletedDistribution'],
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

function importedObservationsEqual(
  left: ManualItemState['importedObservation'],
  right: ManualItemState['importedObservation'],
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
        levelDistributionEqual(leftDistribution, rightDistribution))
  );
}
