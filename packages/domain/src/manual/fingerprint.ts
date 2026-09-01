import { sha256Fingerprint } from '@coc-helper/wire';

import { encodeSwiftSortedJson } from '../account/wire-encode';
import { manualUpgradeCoresEqual } from './equality';
import type { ManualUpgradeCore, ManualUpgradeRecord, ManualItemState } from './types';
import { trackerItemKeyStableId } from './types';

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

export { manualUpgradeCoresEqual };
